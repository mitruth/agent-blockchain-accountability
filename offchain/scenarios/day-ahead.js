// One day of the market on the local node, from order placement to settlement
// (thesis figure 3.3), with agents trading through PolicyGate.
//
//   npm run node                     (in another terminal)
//   npm run demo:deploy
//   npm run demo:flow
//
//   1  the operator opens the day-ahead session for the next delivery day:
//      every half hour from 00:00 to 24:00 Brussels time, trading closing at
//      12:00 the day before, as on the European day-ahead market. The clock
//      first moves to 09:00 that day, if it is earlier
//   2  the oracles report: the PV relay posts each agent's forecast, from the
//      data's day; each house's BMS signs its battery's state
//   3  every prosumer places an order for every half hour: Alice's and
//      Carol's agents through the gate, the battery reading with the first
//      order; Bob on his own, without an agent
//   4  Alice's agent modifies one of her bids: past her soft budget, flagged
//   5  Alice's agent tries to go past her hard budget: refused, by S1 and S3,
//      and the refusal is in the log
//   6  Carol's agent offers more than her battery can deliver overnight:
//      refused by S3; a smaller offer passes
//   7  Carol's agent hands in an older, fuller battery reading: refused by
//      the oracle verifier
//   8  trading closes; an agent order is now refused
//   9  the matcher matches every slot and finalises the session
//  10  a keeper expires what was not matched and reconciles the ledger
//  11  the delivery day passes; each prosumer's sensor settles its slots
//  12  final balances
//
// The agents trade under the policies of prosumers.json's "agentPolicies":
// per-action bounds, a budget S1, export and import caps S2 and a
// cancellation quota S6 (step 4); deliverability S3, cycles S4 and the ramp
// S5, set from each prosumer's battery (step 5).
//
// Run it again for another day: each run opens the next session.

import { loadDeployment, send, read, calldata, events, now, warpTo, price, usd, kWh } from "../chain/index.js";
import { runMatcher } from "../matcher/index.js";
import { expireUnmatched, reconcile } from "../keeper/index.js";
import { commitmentOf, report } from "../sensor/index.js";
import { postForecast, bmsReading, batteryOf, batteryAt, forecastAt } from "../oracle/index.js";
import { wallClock, nextDayAhead, brussels, addDays, label, hhmm } from "./calendar.js";

const ELECTRICITY = 0;
const step = (n, text) => console.log(`\n── ${n}. ${text} ${"─".repeat(Math.max(0, 66 - text.length))}`);

const d = loadDeployment();
const { token, manager, ledger, gate } = d.contracts;
const P = d.prosumers;
const SLOT = d.slotSeconds;
const nameOf = Object.fromEntries(Object.entries(P).map(([name, p]) => [p.account.toLowerCase(), name]));

// --- the prosumers' days ----------------------------------------------------
//
// Each returns, for an hour of the Brussels day, the order that prosumer
// places: [side, Wh in that hour, USD per kWh]. A half-hour slot takes half
// the hour's Wh.

const profiles = {
  // A household: buys every hour, more at the morning and evening peaks, and
  // pays more for the evening peak.
  alice: (h) => ["bid", h < 6 ? 600 : h < 9 ? 1200 : h < 17 ? 800 : h < 22 ? 1500 : 700, h >= 17 && h < 21 ? "0.27" : "0.24"],
  // PV and a battery: sells PV through the day, the battery otherwise.
  bob: (h) => (h >= 8 && h < 17 ? ["offer", 2000, "0.18"] : ["offer", 800, "0.22"]),
  // A small PV roof: sells around midday, cheaper than Bob, and buys the rest
  // of the day.
  carol: (h) => (h >= 9 && h < 16 ? ["offer", 700, "0.17"] : ["bid", 400, "0.23"]),
};

// --- calls -----------------------------------------------------------------

/**
 * An agent's call: with its session key the agent has the account call the
 * gate's submit, and the gate has the account call the prosumer contract.
 * agent → account (session) → PolicyGate → account → Prosumer.
 */
async function viaAgent(name, fn, args, readings = []) {
  const p = P[name];
  const submit = calldata("PolicyGate", "submit", [p.prosumer, calldata("Prosumer", fn, args), readings]);
  const receipt = await send(p.agent.keyIndex, p.account, "MiniAccount", "executeAsSession", [gate, submit]);
  const legs = events(receipt, "PolicyGate", "OrderSubmitted")[0].args.legs.length;
  const rejected = events(receipt, "PolicyGate", "Rejected").length > 0;
  return { receipt, legs, gas: receipt.gasUsed, rejected };
}

/** Every policy instance's result on one submission, by instance name. */
function policyResults(name, receipt) {
  const names = Object.fromEntries((P[name].policies ?? []).map((p) => [p.id.toLowerCase(), p.name]));
  const flagged = new Set(events(receipt, "PolicyGate", "PolicyFlag").map((e) => e.args.policyId.toLowerCase()));
  return events(receipt, "PolicyGate", "PolicyResult").map((e) => ({
    name: names[e.args.policyId.toLowerCase()] ?? e.args.policyId,
    ...e.args.result,
    flagged: flagged.has(e.args.policyId.toLowerCase()),
  }));
}

const VERDICT = ["execute", "FLAG", "REJECT"];

/** One policy's result, in its own units. */
function describe(r) {
  if (r.name.startsWith("S1")) return `${usd(r.valueBefore)} → ${usd(r.valueAfter)}, hard ${usd(r.hard)}`;
  if (r.name.startsWith("A1")) return `bounds broken: ${r.valueAfter}`;
  if (r.valueAfter === 2n ** 256n - 1n) return "cannot judge it (no fresh reading, or beyond the horizon)";
  if (r.name.startsWith("S3")) return `undeliverable ${kWh(r.valueBefore)} → ${kWh(r.valueAfter)}`;
  if (r.name.startsWith("S4")) return `drawn from the cells ${kWh(r.valueBefore)} → ${kWh(r.valueAfter)}, cap ${kWh(r.hard)}`;
  if (r.name.startsWith("S5")) return `largest step ${kWh(r.valueBefore)} → ${kWh(r.valueAfter)}, at most ${kWh(r.hard)}`;
  return `${r.valueBefore} → ${r.valueAfter} of ${r.hard}`;
}

/** Which instances refused a submission. */
function refusedBy(name, receipt) {
  return policyResults(name, receipt).filter((r) => r.verdict === 2).map((r) => `${r.name} (${describe(r)})`).join("; ");
}

/** The owner's own call, through its account, without an agent. */
async function viaOwner(name, fn, args, _readings) {
  const p = P[name];
  const receipt = await send(p.owner.keyIndex, p.account, "MiniAccount", "execute", [p.prosumer, 0n, calldata("Prosumer", fn, args)]);
  return { receipt, legs: null, gas: receipt.gasUsed };
}

const req = (slot, wh, eurPerKWh) => ({ slot, quantity: BigInt(wh), price: price(eurPerKWh) });

async function balances() {
  for (const name of Object.keys(P)) {
    const a = P[name].account;
    const total = await read(token, "LockableERC1155", "balanceOf", [a, 0n]);
    const locked = await read(token, "LockableERC1155", "lockedBalanceOf", [a]);
    console.log(`  ${name.padEnd(6)} ${usd(total).padStart(18)}   of which locked ${usd(locked)}`);
  }
}

async function main() {
  // ── 1 ───────────────────────────────────────────────────────────────────
  step(1, "The operator opens the day-ahead session");
  // At 09:00 the day before delivery the physical policies' horizon, 96
  // half-hour slots, reaches the end of the delivery day.
  const day = nextDayAhead(await now(), SLOT);
  const morning = brussels(addDays(wallClock(day.start), -1), 9);
  if (morning > (await now())) await warpTo(morning);
  const t = await now();
  const { start, end, closesAt, firstSlot, slotCount } = nextDayAhead(t, SLOT);
  const slotStart = (i) => (firstSlot + i) * SLOT;

  await send(d.roles.operator.keyIndex, manager, "MarketManager", "openSession", [
    { energyType: ELECTRICITY, firstSlot, slotCount, closesAt },
  ]);
  const session = await read(manager, "MarketManager", "currentSession", [ELECTRICITY]);
  console.log(`  session  ${session}`);
  console.log(`  delivery ${label(start)} → ${label(end)}: ${slotCount} half-hour slots`);
  console.log(`  trading  open now (${label(t)}), closes ${label(closesAt)}`);
  console.log("\n  Balances before trading:");
  await balances();

  // ── 2 ───────────────────────────────────────────────────────────────────
  step(2, "The oracles report");
  const nowSlot = Math.floor(t / SLOT) * SLOT;
  const readings = {};
  const horizon = d.oracles.horizonSlots ?? 96;
  console.log(`  data: ${d.dataDate}, laid on the delivery day; the forecast is the PV that came`);
  for (const name of Object.keys(P).filter((n) => P[n].bms)) {
    const state = batteryAt(P[name], d.dataDate, start, nowSlot);
    const pvWh = forecastAt(P[name], d.dataDate, start, nowSlot, horizon, SLOT);
    await postForecast(d, name, { firstSlotStart: nowSlot, pvWh, issuedAt: await now() });
    readings[name] = [await bmsReading(d, name, nowSlot, state)];
    const tomorrow = pvWh.slice((start - nowSlot) / SLOT, (end - nowSlot) / SLOT).reduce((a, b) => a + b, 0);
    console.log(
      `  ${name.padEnd(6)} battery ${kWh(state.socWh)} stored, odometer ${kWh(state.dischargeOdometerWh)} (${state.source});` +
        ` forecast ${pvWh.length} slots, ${kWh(tomorrow)} of PV on the delivery day`,
    );
  }

  // ── 3 ───────────────────────────────────────────────────────────────────
  step(3, "Every prosumer places an order for every half hour");
  const placed = {};
  for (const name of Object.keys(P)) {
    const bids = [];
    const offers = [];
    for (let i = 0; i < slotCount; i++) {
      const [side, whPerHour, eurPerKWh] = profiles[name](wallClock(slotStart(i)).h);
      (side === "bid" ? bids : offers).push(req(i, (whPerHour * SLOT) / 3600, eurPerKWh));
    }
    const how = P[name].agent ? "agent → gate" : "directly";
    const call = P[name].agent ? viaAgent : viaOwner;
    placed[name] = [];
    // At most 24 orders a call: a whole day of half-hour slots under every
    // policy would pass the 16.8M gas a transaction may use (EIP-7825).
    const calls = [];
    for (const [fn, all] of [["placeBids", bids], ["placeOffers", offers]]) {
      for (let k = 0; k < all.length; k += 24) calls.push([fn, all.slice(k, k + 24)]);
    }
    for (const [fn, list] of calls) {
      // The agent brings the battery reading with its first order.
      const extra = P[name].agent && readings[name] ? [readings[name]] : [];
      if (extra.length) delete readings[name];
      const { receipt, legs, gas, rejected } = await call(name, fn, [ELECTRICITY, list], ...extra);
      if (rejected) console.log(`  !! ${name}'s ${fn} was refused: ${refusedBy(name, receipt)}`);
      placed[name].push(...events(receipt, "Prosumer", "OrderBooked").map((e) => e.args));
      const what = fn === "placeBids" ? "bids" : "offers";
      console.log(
        `  ${name.padEnd(6)} ${how.padEnd(12)} 1 call: ${`${String(list.length).padStart(2)} ${what},`.padEnd(11)}` +
          (legs ? `${String(legs).padStart(2)} legs, ` : "         ") + `${gas.toLocaleString("en").padStart(9)} gas`,
      );
    }
  }
  for (const name of Object.keys(P).filter((n) => P[n].agent)) {
    const open = await read(ledger, "PositionLedger", "openOrderCount", [P[name].account]);
    console.log(`  ledger: ${name} has ${open} open orders booked`);
  }

  // ── 4 ───────────────────────────────────────────────────────────────────
  step(4, "Alice's agent modifies her 19:00 bid");
  const evening = placed.alice.find((o) => wallClock(Number(o.slot) * SLOT).h === 19);
  const modify = await viaAgent("alice", "modifyOrder", [evening.id, req(Number(evening.slot) - firstSlot, 900, "0.28")]);
  console.log(`  19:00: 0.75 kWh at 0.27 → 0.9 kWh at 0.28, ${modify.legs} legs (cancel, then place)`);
  const budget = policyResults("alice", modify.receipt).find((r) => r.name === "S1 budget");
  console.log(
    `  S1 budget: ${usd(budget.valueBefore)} → ${usd(budget.valueAfter)}, soft ${usd(budget.soft)}, ` +
      `hard ${usd(budget.hard)}: ${VERDICT[budget.verdict]}`,
  );

  // ── 5 ───────────────────────────────────────────────────────────────────
  step(5, "Alice's agent tries to go past her budget");
  const greedy = await viaAgent("alice", "placeBids", [ELECTRICITY, [req(12, 5000, "0.40")]]);
  console.log(`  one more bid: 5 kWh at 0.40, ${usd(price("0.40") * 5n)} — ${greedy.rejected ? "refused" : "!! executed"}`);
  for (const r of policyResults("alice", greedy.receipt)) {
    console.log(`    ${r.name.padEnd(18)} ${VERDICT[r.verdict].padEnd(8)} ${describe(r)}`);
  }
  console.log("  The call did not revert: the refusal and every policy's view of it are on chain.");

  // ── 6 ───────────────────────────────────────────────────────────────────
  step(6, "Carol's agent offers more than her battery can deliver");
  const night = (h, m) => req((brussels(wallClock(start), h) + m * 60 - start) / SLOT, 2500, "0.25");
  const oversell = await viaAgent("carol", "placeOffers", [ELECTRICITY, [night(21, 0), night(21, 30), night(22, 0), night(22, 30)]]);
  const s3 = policyResults("carol", oversell.receipt).find((r) => r.name === "S3 deliverability");
  console.log(`  10 kWh offered between 21:00 and 23:00, after sunset — ${oversell.rejected ? "refused" : "!! executed"}`);
  console.log(`    S3 deliverability  ${VERDICT[s3.verdict].padEnd(8)} ${describe(s3)}`);
  // The horizon reaches into the night after the delivery day, when the
  // battery must also cover Carol's reserve until the sun is back.
  const fewer = await viaAgent("carol", "placeOffers", [ELECTRICITY, [{ ...night(21, 0), quantity: 200n }, { ...night(21, 30), quantity: 200n }]]);
  const s3fewer = policyResults("carol", fewer.receipt).find((r) => r.name === "S3 deliverability");
  console.log(`  0.4 kWh offered at 21:00 and 21:30 instead — ${fewer.rejected ? "!! refused: " + refusedBy("carol", fewer.receipt) : "placed"}`);
  console.log(`    S3 deliverability  ${VERDICT[s3fewer.verdict].padEnd(8)} ${describe(s3fewer)}`);

  // ── 7 ───────────────────────────────────────────────────────────────────
  step(7, "Carol's agent hands in an older, fuller battery reading");
  const held = await batteryOf(d, "carol");
  const older = await bmsReading(d, "carol", Number(held.timestamp) - 60, { socWh: 9000, dischargeOdometerWh: held.dischargeOdometerWh });
  try {
    await viaAgent("carol", "placeOffers", [ELECTRICITY, [night(22, 0)]], [older]);
    console.log("  !! the older reading was accepted");
  } catch (error) {
    console.log(`  a genuine reading, a minute older than the one held, showing 9 kWh: ${error.message}`);
  }

  // ── 8 ───────────────────────────────────────────────────────────────────
  step(8, "Trading closes at 12:00 the day before delivery");
  await warpTo(closesAt);
  // The agent's battery reading is no longer fresh, so the gate refuses first,
  // without reaching the market. Bob, without a gate, meets the market's rule.
  const late = await viaAgent("alice", "placeBids", [ELECTRICITY, [req(0, 500, "0.25")]]);
  console.log(`  an agent order after closing — ${late.rejected ? "refused by the gate: " + refusedBy("alice", late.receipt) : "!! accepted"}`);
  try {
    await viaOwner("bob", "placeOffers", [ELECTRICITY, [req(0, 500, "0.25")]]);
    console.log("  !! an order after closing was accepted by the market");
  } catch (error) {
    console.log(`  Bob's own order after closing is refused by the market: ${error.message}`);
  }

  // ── 9 ───────────────────────────────────────────────────────────────────
  step(9, "The matcher matches every slot");
  const trades = await runMatcher(d, session, {
    log: (line) => !line.startsWith("              ") && console.log("  " + line),
  });
  const bySlot = new Map();
  for (const tr of trades) {
    const bid = await read(session, "MarketSession", "orderOf", [tr.bidId]);
    const offer = await read(session, "MarketSession", "orderOf", [tr.offerId]);
    const slot = Number(bid.slot);
    if (!bySlot.has(slot)) bySlot.set(slot, []);
    bySlot.get(slot).push(
      `${nameOf[bid.account.toLowerCase()]}←${nameOf[offer.account.toLowerCase()]} ${kWh(tr.quantity)} @${usd(tr.price).replace(" USD", "")}`,
    );
  }
  for (let i = 0; i < slotCount; i++) {
    console.log(`  ${hhmm(slotStart(i))}  ${(bySlot.get(firstSlot + i) ?? ["no trade"]).join(";  ")}`);
  }

  // ── 10 ──────────────────────────────────────────────────────────────────
  step(10, "A keeper expires the rest and reconciles the ledger");
  console.log(`  expired ${await expireUnmatched(d, session)} orders with an unmatched remainder`);

  for (const name of Object.keys(P).filter((n) => P[n].agent)) {
    const p = P[name];
    await reconcile(d, session, name);
    let agree = 0;
    let differ = 0;
    for (let i = 0; i < slotCount; i++) {
      const c = await commitmentOf(d, name, firstSlot + i);
      const pos = await read(ledger, "PositionLedger", "positionOf", [p.account, firstSlot + i]);
      if (pos.clearedBuyWh === c.boughtWh && pos.clearedSellWh === c.soldWh) agree++;
      else differ++;
    }
    const open = await read(ledger, "PositionLedger", "openOrderCount", [p.account]);
    console.log(
      `  ${name.padEnd(6)} ${open} orders left open; ledger and market agree in ${agree} of ${slotCount} slots` +
        (differ ? `, DIFFER in ${differ}` : ""),
    );
  }

  // ── 11 ──────────────────────────────────────────────────────────────────
  step(11, "The delivery day passes; sensors settle every slot");
  await warpTo(end);
  // Measured, as a share of the commitment: Bob's battery falls short at
  // 19:00, by more than 10%; otherwise he delivers 95% and everyone else 100%.
  const delivered = (name, h) => (name === "bob" ? (h === 19 ? 80n : 95n) : 100n);
  const tally = {};
  for (const name of Object.keys(P)) tally[name] = { bought: 0n, sold: 0n, paid: 0n, received: 0n, penalty: 0n, settled: 0 };
  for (let i = 0; i < slotCount; i++) {
    const h = wallClock(slotStart(i)).h;
    for (const name of Object.keys(P)) {
      const c = await commitmentOf(d, name, firstSlot + i);
      if (c.boughtWh === 0n && c.soldWh === 0n) continue;
      const net = c.soldWh - c.boughtWh;
      const share = delivered(name, h);
      const exported = net > 0n ? (net * share) / 100n : 0n;
      const imported = net < 0n ? (-net * share) / 100n : 0n;
      const s = await report(d, name, firstSlot + i, exported, imported);
      const x = tally[name];
      x.bought += c.boughtWh;
      x.sold += c.soldWh;
      x.paid += c.paid;
      x.received += c.received;
      x.penalty += s.penalty;
      x.settled++;
      if (s.penalty > 0n) {
        console.log(`  ${hhmm(slotStart(i))} ${name}: committed ${kWh(net)}, measured ${kWh(exported - imported)} → penalty ${usd(s.penalty)}`);
      }
    }
  }
  for (const [name, x] of Object.entries(tally)) {
    console.log(
      `  ${name.padEnd(6)} ${String(x.settled).padStart(2)} slots settled: bought ${kWh(x.bought)} for ${usd(x.paid)},` +
        ` sold ${kWh(x.sold)} for ${usd(x.received)}, penalties ${usd(x.penalty)}`,
    );
  }

  // ── 12 ──────────────────────────────────────────────────────────────────
  step(12, "Final balances");
  await balances();
  console.log(`  manager (penalties collected) ${usd(await read(token, "LockableERC1155", "balanceOf", [manager, 0n]))}`);
}

main().catch((error) => {
  console.error("\n" + (error.shortMessage ?? error.message ?? error));
  process.exit(1);
});
