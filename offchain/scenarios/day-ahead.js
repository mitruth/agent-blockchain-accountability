// One day of the market on the local node, from order placement to settlement
// (thesis figure 3.3), with agents trading through PolicyGate.
//
//   npm run node                     (in another terminal)
//   npm run demo:deploy
//   npm run demo:flow
//
//   1  the operator opens the day-ahead session for the next delivery day:
//      every hour from 00:00 to 24:00 Brussels time, trading closing at 12:00
//      the day before, as on the European day-ahead market
//   2  every prosumer places an order for every hour: Alice's and Carol's
//      agents through the gate, Bob on his own, without an agent
//   3  Alice's agent modifies one of her bids: past her soft budget, flagged
//   4  Alice's agent tries to go past her hard budget: refused by S1, and the
//      refusal is in the log
//   5  trading closes; an agent order is now refused
//   6  the matcher matches every hour and finalises the session
//   7  a keeper expires what was not matched and reconciles the ledger
//   8  the delivery day passes; each prosumer's sensor settles its hours
//   9  final balances
//
// The agents trade under the policies of prosumers.json's "agentPolicies"
// (step 4): per-action bounds, a budget S1, export and import caps S2, and a
// cancellation quota S6.
//
// Run it again for another day: each run opens the next session.

import { loadDeployment, send, read, calldata, events, now, warpTo, price, eur, kWh } from "../chain/index.js";
import { runMatcher } from "../matcher/index.js";
import { expireUnmatched, reconcile } from "../keeper/index.js";
import { commitmentOf, report } from "../sensor/index.js";
import { wallClock, nextDayAhead, label, hhmm } from "./calendar.js";

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
// places: [side, Wh, EUR per kWh].

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
async function viaAgent(name, fn, args) {
  const p = P[name];
  const submit = calldata("PolicyGate", "submit", [p.prosumer, calldata("Prosumer", fn, args)]);
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

/** The owner's own call, through its account, without an agent. */
async function viaOwner(name, fn, args) {
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
    console.log(`  ${name.padEnd(6)} ${eur(total).padStart(18)}   of which locked ${eur(locked)}`);
  }
}

async function main() {
  // ── 1 ───────────────────────────────────────────────────────────────────
  step(1, "The operator opens the day-ahead session");
  const t = await now();
  const { start, end, closesAt, firstSlot, slotCount } = nextDayAhead(t, SLOT);
  const slotStart = (i) => (firstSlot + i) * SLOT;

  await send(d.roles.operator.keyIndex, manager, "MarketManager", "openSession", [
    { energyType: ELECTRICITY, firstSlot, slotCount, closesAt },
  ]);
  const session = await read(manager, "MarketManager", "currentSession", [ELECTRICITY]);
  console.log(`  session  ${session}`);
  console.log(`  delivery ${label(start)} → ${label(end)}: ${slotCount} hourly slots`);
  console.log(`  trading  open now (${label(t)}), closes ${label(closesAt)}`);
  console.log("\n  Balances before trading:");
  await balances();

  // ── 2 ───────────────────────────────────────────────────────────────────
  step(2, "Every prosumer places an order for every hour");
  const placed = {};
  for (const name of Object.keys(P)) {
    const bids = [];
    const offers = [];
    for (let i = 0; i < slotCount; i++) {
      const [side, wh, eurPerKWh] = profiles[name](wallClock(slotStart(i)).h);
      (side === "bid" ? bids : offers).push(req(i, wh, eurPerKWh));
    }
    const how = P[name].agent ? "agent → gate" : "directly";
    const call = P[name].agent ? viaAgent : viaOwner;
    placed[name] = [];
    for (const [fn, list] of [["placeBids", bids], ["placeOffers", offers]]) {
      if (list.length === 0) continue;
      const { receipt, legs, gas } = await call(name, fn, [ELECTRICITY, list]);
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

  // ── 3 ───────────────────────────────────────────────────────────────────
  step(3, "Alice's agent modifies her 19:00 bid");
  const evening = placed.alice.find((o) => wallClock(Number(o.slot) * SLOT).h === 19);
  const modify = await viaAgent("alice", "modifyOrder", [evening.id, req(Number(evening.slot) - firstSlot, 1800, "0.28")]);
  console.log(`  19:00: 1.5 kWh at 0.27 → 1.8 kWh at 0.28, ${modify.legs} legs (cancel, then place)`);
  const budget = policyResults("alice", modify.receipt).find((r) => r.name === "S1 budget");
  console.log(
    `  S1 budget: ${eur(budget.valueBefore)} → ${eur(budget.valueAfter)}, soft ${eur(budget.soft)}, ` +
      `hard ${eur(budget.hard)}: ${VERDICT[budget.verdict]}`,
  );

  // ── 4 ───────────────────────────────────────────────────────────────────
  step(4, "Alice's agent tries to go past her budget");
  const greedy = await viaAgent("alice", "placeBids", [ELECTRICITY, [req(12, 5000, "0.40")]]);
  console.log(`  one more bid: 5 kWh at 0.40, ${eur(price("0.40") * 5n)} — ${greedy.rejected ? "refused" : "!! executed"}`);
  for (const r of policyResults("alice", greedy.receipt)) {
    const amounts = r.name.startsWith("S1")
      ? `${eur(r.valueBefore)} → ${eur(r.valueAfter)}, hard ${eur(r.hard)}`
      : r.name.startsWith("A1")
        ? `bounds broken: ${r.valueAfter}`
        : `${r.valueBefore} → ${r.valueAfter} of ${r.hard}`;
    console.log(`    ${r.name.padEnd(16)} ${VERDICT[r.verdict].padEnd(8)} ${amounts}`);
  }
  console.log("  The call did not revert: the refusal and every policy's view of it are on chain.");

  // ── 5 ───────────────────────────────────────────────────────────────────
  step(5, "Trading closes at 12:00 the day before delivery");
  await warpTo(closesAt);
  try {
    await viaAgent("alice", "placeBids", [ELECTRICITY, [req(0, 500, "0.25")]]);
    console.log("  !! an order after closing was accepted");
  } catch (error) {
    console.log(`  an agent order after closing is refused: ${error.message}`);
  }

  // ── 6 ───────────────────────────────────────────────────────────────────
  step(6, "The matcher matches every hour");
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
      `${nameOf[bid.account.toLowerCase()]}←${nameOf[offer.account.toLowerCase()]} ${kWh(tr.quantity)} @${eur(tr.price).replace(" EUR", "")}`,
    );
  }
  for (let i = 0; i < slotCount; i++) {
    console.log(`  ${hhmm(slotStart(i))}  ${(bySlot.get(firstSlot + i) ?? ["no trade"]).join(";  ")}`);
  }

  // ── 7 ───────────────────────────────────────────────────────────────────
  step(7, "A keeper expires the rest and reconciles the ledger");
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
      `  ${name.padEnd(6)} ${open} orders left open; ledger and market agree in ${agree} of ${slotCount} hours` +
        (differ ? `, DIFFER in ${differ}` : ""),
    );
  }

  // ── 8 ───────────────────────────────────────────────────────────────────
  step(8, "The delivery day passes; sensors settle every hour");
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
        console.log(`  ${hhmm(slotStart(i))} ${name}: committed ${kWh(net)}, measured ${kWh(exported - imported)} → penalty ${eur(s.penalty)}`);
      }
    }
  }
  for (const [name, x] of Object.entries(tally)) {
    console.log(
      `  ${name.padEnd(6)} ${String(x.settled).padStart(2)} hours settled: bought ${kWh(x.bought)} for ${eur(x.paid)},` +
        ` sold ${kWh(x.sold)} for ${eur(x.received)}, penalties ${eur(x.penalty)}`,
    );
  }

  // ── 9 ───────────────────────────────────────────────────────────────────
  step(9, "Final balances");
  await balances();
  console.log(`  manager (penalties collected) ${eur(await read(token, "LockableERC1155", "balanceOf", [manager, 0n]))}`);
}

main().catch((error) => {
  console.error("\n" + (error.shortMessage ?? error.message ?? error));
  process.exit(1);
});
