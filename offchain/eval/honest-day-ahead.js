// node offchain/eval/honest-day-ahead.js [--arm B2] [--days 364] [--first-day 2022-01-02] [--report file.json] [--full] [--delivery]
//
// An honest agent, day after day, through the gate (spec v0.2 step 2: G1 must
// never suspend an honest arm; decision of 21 October 2026).
//
// For each data day, Alice's agent trades what the honest arm actually did
// that day: per half-hour slot, the net of the arm's planned grid import and
// export becomes one order, a BUY for a net import and a SELL for a net
// export. A net flow below A1's minimum order is carried into the next
// slot's, until the sum reaches the minimum: an honest agent does not place
// dust. Each order is priced at the slot's tariff, the outside option (v0.2
// step 3, decision of 22 October 2026): a BUY at retail, a SELL at feed-in; a
// slot whose tariff is zero at 1 unit, the market's least price. The orders go
// in day-ahead batches of at most 24, before the session closes, with the
// battery reading (the arm replayed), the PV forecast and the tariff the
// policies need. Bob, the counterparty, places the mirror of every order at
// the same price, so every order fills in full. Then the
// matcher finalises the session and a keeper reconciles the ledger.
//
// Alice trades under the demo's policies (offchain/deploy/prosumers.json)
// plus the session circuit breaker G1 at the spec's defaults, without S3 and
// S4 (decision of 22 October 2026): S3's constant reserve load reads a
// household's imports as battery charge, so it rejects honest days whatever
// G1 does; that is a finding for v0.2 step 8. --full keeps them. The run counts,
// per policy, the submissions it rejected and those it flagged, and every
// suspension. Rejections and flags here are honest false positives.
//
// S9 (v0.2 step 5) reads the house's meter. Before each morning's orders the
// meter's readings are posted for every delivery slot that has ended, and a
// keeper pokes S9 until it has taken them in; the run counts S9's alarms. By
// default the orders are the arm's realized flows, so the meter shows them
// delivered exactly. --delivery trades a day-ahead plan from forecasts
// instead (offchain/eval/delivery.js, the delivery simulator): the meter then
// shows what the real sun and load, and the re-dispatched battery, delivered.
//
// Runs on a fresh chain inside this process; needs the contracts built
// (npm run build). Writes its deployment to deployments/honest.json (git
// ignored), or to HONEST_DEPLOYMENT_FILE, never to deployments/local.json.

import fs from "node:fs";
import path from "node:path";
import { ROOT } from "../chain/paths.js";

// Before anything reads it: chain/deployment.js takes the file at import.
process.env.DEPLOYMENT_FILE = process.env.HONEST_DEPLOYMENT_FILE ?? path.join(ROOT, "deployments", "honest.json");

const { useInProcessChain, send, read, calldata, events, now, warpTo, price } = await import("../chain/index.js");
const { deploySystem, loadConfig } = await import("../deploy/index.js");
const { runMatcher } = await import("../matcher/index.js");
const { expireUnmatched, reconcile } = await import("../keeper/index.js");
const {
  postForecast, postTariff, postMeter, postEnvelope, bmsReading, batteryAt, forecastAt, tariffAt, dataIndexAt, homeSlots, armSlots,
  armSettings, indexOfDate,
} = await import("../oracle/index.js");
const { simulateDelivery } = await import("./delivery.js");
const { envelopeOf } = await import("./envelope-feed.js");
const { nextDayAhead, brussels, addDays, wallClock } = await import("../scenarios/calendar.js");

const ELECTRICITY = 0;
const BATCH = 24;
// StaticOrderPolicy's bits, as its constants name them.
const STATIC_BITS = { 1: "A1 quantity", 2: "A2 value", 4: "A3 price", 8: "A4 time of day", 16: "A6 horizon", 32: "A1 minimum", 64: "A3T tariff band" };

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const ARM = option("arm", "B2");
const DAYS = Number(option("days", 364));
const FIRST_DAY = option("first-day", "2022-01-02");
const REPORT = option("report", null);

/** prosumers.json with Alice replaying `ARM` and Bob as the counterparty, both well funded. */
const FULL = process.argv.includes("--full");
const DELIVERY = process.argv.includes("--delivery");

function honestConfig() {
  const config = loadConfig();
  const alice = { ...config.prosumers.find((p) => p.name === "alice"), replay: ARM, fundsUSD: 1_000_000 };
  const bob = { ...config.prosumers.find((p) => p.name === "bob"), fundsUSD: 1_000_000 };
  const omit = FULL ? [] : ["S3 deliverability", "S4 cycles"];
  // The agent's session must outlast the run: the demo's 30 days would not.
  const agentValidityDays = DAYS + 30;
  return { ...config, agentValidityDays, agentPolicies: { ...config.agentPolicies, omit }, prosumers: [alice, bob] };
}

/** An order request at `unitsPerKWh`, at least the market's least price, 1. */
const req = (slot, wh, unitsPerKWh) => ({ slot, quantity: BigInt(wh), price: BigInt(Math.max(1, unitsPerKWh)) });

async function main() {
  const connection = await useInProcessChain();
  const d = await deploySystem(honestConfig(), { log: () => {} });
  const SLOT = d.slotSeconds;
  const alice = d.prosumers.alice;
  const bob = d.prosumers.bob;
  const { manager, gate } = d.contracts;

  // G1 is configured by the deploy, from prosumers.json's "breaker".
  if (!loadConfig().agentPolicies.breaker) throw new Error("prosumers.json names no breaker: G1 would be off");

  const names = Object.fromEntries(alice.policies.map((p) => [p.id.toLowerCase(), p.name]));
  const MIN_WH = Number(loadConfig().agentPolicies.perAction.minQtyWh ?? 0);
  const tally = {
    policies: alice.policies.map((p) => p.name), delivery: DELIVERY, days: 0, submissions: 0, orders: 0, rejected: 0,
    flagged: 0, suspensions: 0, mergedSlots: 0, droppedWh: 0, byPolicy: {}, staticBounds: {},
    meterReadings: 0, pokes: 0, s9Alarms: [], contractedSaleWh: 0, shortfallWh: 0,
  };
  const count = (policyId, what) => {
    const name = names[policyId.toLowerCase()] ?? policyId;
    tally.byPolicy[name] ??= { rejected: 0, flagged: 0 };
    tally.byPolicy[name][what]++;
  };

  const slots = armSlots(ARM, alice.home);
  const first = indexOfDate(slots, FIRST_DAY);
  const days = Math.min(DAYS, Math.floor((slots.length - first) / 48) - 1);

  // What the agent contracts and what the meter measures, per data slot: the
  // arm's realized flows, or the delivery simulator's plan and outcome.
  const sim = DELIVERY ? simulateDelivery(slots, armSettings(alice.home)) : null;
  const netImportOf = (k) => (sim ? -sim[k].contractWh : Number(slots[k].importWh) - Number(slots[k].exportWh));
  const meterOf = (k) =>
    sim ? { importWh: sim[k].importWh, exportWh: sim[k].exportWh } : { importWh: Number(slots[k].importWh), exportWh: Number(slots[k].exportWh) };

  // S10's connection rating, for the DSO's synthetic envelope; the house's
  // data slots, for the envelope's local times and cut days.
  const envelopeW = loadConfig().agentPolicies.envelope?.connectionW ?? 0;
  const houseSlots = homeSlots(alice.home);

  // S9's instance, for the keeper's pokes; the meter readings still to post.
  const s9 = alice.policies.find((p) => p.name === "S9 delivery");
  const pendingMeter = [];
  const countAlarms = (receipt) => {
    for (const e of events(receipt, "DeliveryReconciliationPolicy", "DeliveryAlarm")) {
      tally.s9Alarms.push({ at: Number(receipt.blockNumber), slot: Number(e.args.slot), level: Number(e.args.level) });
    }
  };
  /** Post every reading whose slot has ended, then poke S9 until it has taken in all it can. */
  const catchUpMeter = async () => {
    const t = await now();
    while (pendingMeter.length && pendingMeter[0].slotStart + SLOT <= t) {
      await postMeter(d, "alice", pendingMeter.shift());
      tally.meterReadings++;
    }
    if (!s9) return;
    for (;;) {
      const receipt = await send(d.roles.keeper.keyIndex, gate, "PolicyGate", "poke", [alice.account, s9.policy, s9.id]);
      tally.pokes++;
      countAlarms(receipt);
      const poked = events(receipt, "PolicyGate", "Poked")[0];
      if (!poked || poked.args.processed === 0n) break;
    }
  };

  for (let n = 0; n < days; n++) {
    const dataDate = slots[first + 48 * n].date;

    // 09:00 Brussels the day before delivery: the session opens, the
    // oracles report, and the 96-slot horizon reaches the end of the day.
    const day = nextDayAhead(await now(), SLOT);
    const morning = brussels(addDays(wallClock(day.start), -1), 9);
    if (morning > (await now())) await warpTo(morning);
    const { start, closesAt, firstSlot, slotCount } = nextDayAhead(await now(), SLOT);
    await send(d.roles.operator.keyIndex, manager, "MarketManager", "openSession", [
      { energyType: ELECTRICITY, firstSlot, slotCount, closesAt },
    ]);
    const session = await read(manager, "MarketManager", "currentSession", [ELECTRICITY]);

    const t = await now();
    const nowSlot = Math.floor(t / SLOT) * SLOT;
    const horizon = d.oracles.horizonSlots;
    await postForecast(d, "alice", { firstSlotStart: nowSlot, pvWh: forecastAt(alice, dataDate, start, nowSlot, horizon, SLOT), issuedAt: t });
    const tariff = tariffAt(alice, dataDate, start, nowSlot, horizon, SLOT);
    await postTariff(d, "alice", { firstSlotStart: nowSlot, ...tariff, issuedAt: t });
    // The DSO's envelope over the same slots (v0.2 step 6, envelope-feed.js).
    if (envelopeW) {
      const limits = [];
      for (let k = 0; k < horizon; k++) {
        limits.push(envelopeOf(houseSlots[dataIndexAt(alice.home, dataDate, start, nowSlot + k * SLOT)], envelopeW, SLOT));
      }
      await postEnvelope(d, "alice", {
        firstSlotStart: nowSlot, issuedAt: t,
        exportLimitWh: limits.map((l) => l.exportLimitWh), importLimitWh: limits.map((l) => l.importLimitWh),
      });
    }
    const ahead = (start - nowSlot) / SLOT; // the delivery day's first slot in the schedule
    let reading = [await bmsReading(d, "alice", nowSlot, batteryAt(alice, dataDate, start, nowSlot))];
    // The meter of the delivery so far, taken in by S9 before the agent acts.
    await catchUpMeter();

    // The arm's day, slot by slot, as net orders; Bob mirrors each.
    const bids = [];
    const offers = [];
    const dayIndex = first + 48 * n;
    let carry = 0;
    for (let i = 0; i < slotCount; i++) {
      const s = slots[dayIndex + i];
      if (!s) break;
      // The meter will report this slot of the delivery day once it ends.
      pendingMeter.push({ slotStart: start + i * SLOT, ...meterOf(dayIndex + i) });
      if (sim) {
        tally.contractedSaleWh += Math.max(0, sim[dayIndex + i].contractWh);
        tally.shortfallWh += sim[dayIndex + i].shortfallWh;
      }
      const own = netImportOf(dayIndex + i);
      const net = carry + own;
      if (Math.abs(net) < MIN_WH) {
        if (own !== 0) tally.mergedSlots++;
        carry = net;
        continue;
      }
      carry = 0;
      if (net > 0) bids.push(req(i, net, tariff.retail[ahead + i]));
      else if (net < 0) offers.push(req(i, -net, tariff.feedIn[ahead + i]));
    }
    tally.droppedWh += Math.abs(carry);

    const agentCalls = [];
    for (const [fn, all] of [["placeBids", bids], ["placeOffers", offers]]) {
      for (let k = 0; k < all.length; k += BATCH) agentCalls.push([fn, all.slice(k, k + BATCH)]);
    }
    for (const [fn, list] of agentCalls) {
      const submit = calldata("PolicyGate", "submit", [alice.prosumer, calldata("Prosumer", fn, [ELECTRICITY, list]), reading]);
      reading = [];
      const receipt = await send(alice.agent.keyIndex, alice.account, "MiniAccount", "executeAsSession", [gate, submit]);
      countAlarms(receipt);
      tally.submissions++;
      tally.orders += list.length;
      if (events(receipt, "PolicyGate", "Rejected").length) tally.rejected++;
      if (events(receipt, "PolicyGate", "PolicyFlag").length) tally.flagged++;
      for (const e of events(receipt, "PolicyGate", "PolicyResult")) {
        if (e.args.result.verdict === 2) count(e.args.policyId, "rejected");
        if (e.args.result.verdict === 1) count(e.args.policyId, "flagged");
        // A1-A6 report which bounds broke, as a bitmask: count each.
        if (e.args.result.verdict === 2 && names[e.args.policyId.toLowerCase()] === "A1-A6 per action") {
          for (const [bit, bound] of Object.entries(STATIC_BITS)) {
            if ((e.args.result.valueAfter & BigInt(bit)) !== 0n) tally.staticBounds[bound] = (tally.staticBounds[bound] ?? 0) + 1;
          }
        }
      }
      tally.suspensions += events(receipt, "SessionBreaker", "AgentSuspended").length;
    }

    // Bob takes the other side of everything Alice placed.
    const mirror = [["placeOffers", bids.map((r) => ({ ...r }))], ["placeBids", offers.map((r) => ({ ...r }))]];
    for (const [fn, all] of mirror) {
      for (let k = 0; k < all.length; k += BATCH) {
        await send(bob.owner.keyIndex, bob.account, "MiniAccount", "execute", [
          bob.prosumer, 0n, calldata("Prosumer", fn, [ELECTRICITY, all.slice(k, k + BATCH)]),
        ]);
      }
    }

    await warpTo(closesAt);
    await runMatcher(d, session, { log: () => {} });
    await expireUnmatched(d, session);
    await reconcile(d, session, "alice");
    tally.days++;
    if (n % 30 === 0) {
      console.log(
        `  ${dataDate}: ${tally.submissions} submissions, ${tally.rejected} rejected, ${tally.flagged} flagged, ` +
          `${tally.suspensions} suspensions, ${tally.s9Alarms.length} S9 alarms`,
      );
    }
  }

  await connection.close();
  const alarms = tally.s9Alarms.length;
  const s9Arl0Days = alarms ? Number((tally.days / alarms).toFixed(1)) : null;
  const result = { arm: ARM, firstDay: FIRST_DAY, full: FULL, minQtyWh: MIN_WH, ...tally, s9Arl0Days };
  console.log(JSON.stringify(result, null, 2));
  if (REPORT) fs.writeFileSync(REPORT, JSON.stringify(result, null, 2) + "\n");
  process.exit(tally.suspensions === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
