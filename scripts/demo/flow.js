// One day of the market on the local node, from order placement to settlement
// (thesis figure 3.3), with agents trading through PolicyGate.
//
//   npx hardhat node                 (in another terminal)
//   npm run demo:deploy
//   npm run demo:flow
//
//   1  the operator opens tomorrow's day-ahead session: 24 hourly slots
//   2  agents place batches for Alice and Carol through the gate; Bob places
//      his own orders, without an agent
//   3  Alice's agent cancels one bid and modifies another
//   4  trading closes; an agent order is now refused
//   5  the matcher matches the session and finalises it
//   6  a keeper expires what was not matched and reconciles the ledger
//   7  delivery passes; each prosumer's sensor settles its slots
//   8  final balances
//
// Run it again for another day: each run opens a new session.

import { parseUnits } from "viem";
import { loadDeployment, send, read, calldata, events, now, warpTo, eur, kWh } from "./lib.js";
import { runMatcher } from "./matcher.js";

const BID = 0;
const OFFER = 1;
const ELECTRICITY = 0;
const OPEN = 1;
const price = (s) => parseUnits(s, 6);
const step = (n, text) => console.log(`\n── ${n}. ${text} ${"─".repeat(Math.max(0, 66 - text.length))}`);

const d = loadDeployment();
const { token, manager, ledger, gate } = d.contracts;
const P = d.prosumers;
const SLOT = d.slotSeconds;

/** An agent's call through the gate: agent → PolicyGate → account → Prosumer. */
async function viaAgent(name, fn, args) {
  const p = P[name];
  const receipt = await send(p.agent.keyIndex, gate, "PolicyGate", "submit", [p.account, p.prosumer, calldata("Prosumer", fn, args)]);
  const legs = events(receipt, "PolicyGate", "OrderSubmitted")[0].args.legs.length;
  return { receipt, legs };
}

/** The owner's own call, through its account, without an agent. */
function viaOwner(name, fn, args) {
  const p = P[name];
  return send(p.owner.keyIndex, p.account, "MiniAccount", "execute", [p.prosumer, 0n, calldata("Prosumer", fn, args)]);
}

const booked = (receipt) => events(receipt, "Prosumer", "OrderBooked").map((e) => e.args);
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
  step(1, "The operator opens tomorrow's day-ahead session");
  // Tomorrow from 00:00 UTC, closing an hour before: the next midnight whose
  // closing time is still ahead.
  const t = await now();
  let day = Math.floor(t / 86400) + 1;
  while (day * 86400 - 3600 <= t) day++;
  const firstSlot = Math.floor((day * 86400) / SLOT);
  const closesAt = firstSlot * SLOT - 3600;
  const config = { energyType: ELECTRICITY, firstSlot, slotCount: 24, closesAt };
  await send(d.roles.operator.keyIndex, manager, "MarketManager", "openSession", [config]);
  const session = await read(manager, "MarketManager", "currentSession", [ELECTRICITY]);
  const hour = (i) => new Date((firstSlot + i) * SLOT * 1000).toISOString().slice(11, 16);
  console.log(`  session ${session}`);
  console.log(`  24 slots from ${new Date(firstSlot * SLOT * 1000).toISOString()}, trading closes ${new Date(closesAt * 1000).toISOString()}`);
  console.log("\n  Balances before trading:");
  await balances();

  // ── 2 ───────────────────────────────────────────────────────────────────
  step(2, "Orders: agents through the gate, Bob on his own");
  const alice = await viaAgent("alice", "placeBids", [
    ELECTRICITY,
    [req(10, 2000, "0.25"), req(11, 1500, "0.26"), req(12, 1500, "0.24"), req(13, 1000, "0.25")],
  ]);
  const aliceBids = booked(alice.receipt);
  console.log(`  alice's agent: 1 call, ${alice.legs} legs → ${aliceBids.length} bids for ${aliceBids.map((b) => hour(b.slot - firstSlot)).join(", ")}`);

  const carol = await viaAgent("carol", "placeOffers", [ELECTRICITY, [req(10, 1000, "0.21"), req(13, 800, "0.23")]]);
  console.log(`  carol's agent: 1 call, ${carol.legs} legs → ${booked(carol.receipt).length} offers`);

  const bob = await viaOwner("bob", "placeOffers", [ELECTRICITY, [req(10, 1800, "0.20"), req(11, 2000, "0.22"), req(12, 1000, "0.27")]]);
  console.log(`  bob, directly: ${booked(bob).length} offers (no gate, no agent)`);

  const openA = await read(ledger, "PositionLedger", "openOrderCount", [P.alice.account]);
  console.log(`  ledger: alice has ${openA} open orders booked`);

  // ── 3 ───────────────────────────────────────────────────────────────────
  step(3, "Alice's agent cancels one bid and modifies another");
  const bid12 = aliceBids.find((b) => b.slot === firstSlot + 12).id;
  const bid13 = aliceBids.find((b) => b.slot === firstSlot + 13).id;
  await viaAgent("alice", "cancelOrder", [bid12]);
  console.log(`  cancelled the ${hour(12)} bid`);
  const modify = await viaAgent("alice", "modifyOrder", [bid13, req(13, 800, "0.24")]);
  console.log(`  modified the ${hour(13)} bid to 0.8 kWh at 0.24: ${modify.legs} legs (cancel, then place)`);

  // ── 4 ───────────────────────────────────────────────────────────────────
  step(4, "Trading closes");
  await warpTo(closesAt);
  try {
    await viaAgent("alice", "placeBids", [ELECTRICITY, [req(14, 500, "0.25")]]);
    console.log("  !! an order after closing was accepted");
  } catch (error) {
    console.log(`  an agent order after closing is refused: ${error.message}`);
  }

  // ── 5 ───────────────────────────────────────────────────────────────────
  step(5, "The matcher matches the session");
  await runMatcher(d, session, { log: (line) => console.log("  " + line) });

  // ── 6 ───────────────────────────────────────────────────────────────────
  step(6, "A keeper expires the rest and reconciles the ledger");
  const keeper = d.roles.keeper.keyIndex;
  const allIds = [
    ...(await read(session, "MarketSession", "bidIds")),
    ...(await read(session, "MarketSession", "offerIds")),
  ];
  let expired = 0;
  for (const id of allIds) {
    const o = await read(session, "MarketSession", "orderOf", [id]);
    if (o.status === OPEN && o.matched < o.quantity) {
      await send(keeper, session, "MarketSession", "expire", [id]);
      expired++;
    }
  }
  console.log(`  expired ${expired} orders with an unmatched remainder`);

  for (const name of ["alice", "carol"]) {
    const p = P[name];
    for (const id of allIds) {
      const rec = await read(ledger, "PositionLedger", "recordOf", [p.account, p.prosumer, id]);
      if (rec.status === OPEN) await send(keeper, gate, "PolicyGate", "reconcile", [p.account, p.prosumer, id]);
    }
    const open = await read(ledger, "PositionLedger", "openOrderCount", [p.account]);
    console.log(`  ${name}: ledger reconciled, ${open} orders left open`);
  }

  console.log("\n  Per slot, the ledger (enforcement) against the prosumer contract (market):");
  const tradedSlots = [];
  for (let i = 0; i < 24; i++) {
    const line = [];
    for (const name of Object.keys(P)) {
      const c = await read(P[name].prosumer, "Prosumer", "commitmentOf", [firstSlot + i]);
      if (c.boughtWh === 0n && c.soldWh === 0n) continue;
      let text = `${name} bought ${kWh(c.boughtWh)} sold ${kWh(c.soldWh)}`;
      if (P[name].agent) {
        const pos = await read(ledger, "PositionLedger", "positionOf", [P[name].account, firstSlot + i]);
        const agrees = pos.clearedBuyWh === c.boughtWh && pos.clearedSellWh === c.soldWh;
        text += agrees ? " (ledger agrees)" : ` (LEDGER DIFFERS: ${pos.clearedBuyWh}/${pos.clearedSellWh})`;
      }
      line.push(text);
    }
    if (line.length) {
      tradedSlots.push(i);
      console.log(`  ${hour(i)}  ${line.join("; ")}`);
    }
  }

  // ── 7 ───────────────────────────────────────────────────────────────────
  step(7, "Delivery, then settlement by each prosumer's sensor");
  const lastSlot = Math.max(...tradedSlots);
  await warpTo((firstSlot + lastSlot + 1) * SLOT);
  // What each sensor measures, as a share of the commitment: Bob falls short
  // at 11:00 by more than 10%, everyone else delivers as committed.
  const delivered = (name, i) => (name === "bob" && i === 11 ? 80n : name === "bob" ? 95n : 100n);
  for (const i of tradedSlots) {
    for (const name of Object.keys(P)) {
      const p = P[name];
      const c = await read(p.prosumer, "Prosumer", "commitmentOf", [firstSlot + i]);
      if (c.boughtWh === 0n && c.soldWh === 0n) continue;
      const net = c.soldWh - c.boughtWh;
      const share = delivered(name, i);
      const exported = net > 0n ? (net * share) / 100n : 0n;
      const imported = net < 0n ? (-net * share) / 100n : 0n;
      const receipt = await send(p.sensor.keyIndex, p.prosumer, "Prosumer", "settle", [firstSlot + i, exported, imported]);
      const s = events(receipt, "Prosumer", "Settled")[0].args;
      console.log(
        `  ${hour(i)} ${name.padEnd(6)} committed ${kWh(net)} net export, measured ${kWh(exported - imported)}` +
          (s.penalty > 0n ? `  → penalty ${eur(s.penalty)}` : "  → within 10%"),
      );
    }
  }

  // ── 8 ───────────────────────────────────────────────────────────────────
  step(8, "Final balances");
  await balances();
  console.log(`  manager (penalties collected) ${eur(await read(token, "LockableERC1155", "balanceOf", [manager, 0n]))}`);
}

main().catch((error) => {
  console.error("\n" + (error.shortMessage ?? error.message ?? error));
  process.exit(1);
});
