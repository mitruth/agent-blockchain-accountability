// Random histories for S9, run on a chain: one account on two ProbeMarkets on
// one slot grid, sales and buys for slots around now, partial fills and keeper
// releases, cancellations through the gate, meter readings posted late or not
// at all, pokes by anyone, an occasional owner reset, waits of minutes to half
// a day. Seeded, so a disagreement can be replayed.
//
// Each receipt becomes events of the verifier's history (reconciliation.js),
// from the gate's, the ledger's, the oracle's and S9's events alone.

import { decodeAbiParameters, encodeAbiParameters } from "viem";
import { publicClient, deploy, events, calldata, selector, key, wallet, abi } from "../chain/index.js";
import { signMeter, TYPES } from "../oracle/typed.js";

const OWNER = 0;
const AGENT = 1;
const KEEPER = 2;
const METER = 50;
const EXECUTOR = 2n;
const SLOT = 1800;
const METER_KIND = 3;

// Small enough that the fuzz raises alarms and reaches both penalty levels.
export const RECONCILIATION_CONFIG = {
  k: 50n,
  h: 800n,
  penaltySeconds: 6 * 3600,
  escalationSeconds: 2 * 86_400,
  settlementLagSeconds: SLOT,
  graceSeconds: 2 * SLOT,
  maxProcess: 4,
  window: { kind: "SLIDING", step: SLOT, buckets: 48, anchor: 0, cap: 3_000n, rate: 0n, initial: 0n },
  origin: 0,
  slotSeconds: SLOT,
};

function generator(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

async function at(t, call) {
  await publicClient.request({ method: "evm_setNextBlockTimestamp", params: [t] });
  return call();
}

/** Sent with a fixed gas limit, without simulation: see breaker-fuzz.js. */
async function send(from, address, contract, functionName, args = []) {
  const hash = await wallet(from).writeContract({ address, abi: abi(contract), functionName, args, gas: 15_000_000n });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${contract}.${functionName} reverted`);
  return receipt;
}

const WINDOW = {
  type: "tuple",
  components: [
    { name: "kind", type: "uint8" }, { name: "step", type: "uint32" }, { name: "buckets", type: "uint16" },
    { name: "anchor", type: "uint40" }, { name: "cap", type: "uint64" }, { name: "rate", type: "uint64" }, { name: "initial", type: "uint64" },
  ],
};
const DELIVERY = {
  type: "tuple",
  components: [
    { name: "k", type: "uint64" }, { name: "h", type: "uint64" }, { name: "penaltySeconds", type: "uint32" },
    { name: "escalationSeconds", type: "uint32" }, { name: "settlementLagSeconds", type: "uint32" },
    { name: "graceSeconds", type: "uint32" }, { name: "maxProcess", type: "uint16" }, { ...WINDOW, name: "window" },
  ],
};

/** The ledger's events in a receipt, in log order, with the block's time. */
function ledgerEvents(receipt, ledger, t) {
  const out = [];
  for (const log of events(receipt, "PositionLedger")) {
    if (log.address.toLowerCase() !== ledger.toLowerCase()) continue;
    const a = log.args;
    const base = { at: t, block: log.blockNumber, account: a.account, market: a.market, orderId: a.orderId };
    if (log.eventName === "OrderOpened") out.push({ ...base, type: "opened", side: Number(a.side), slot: Number(a.slot), qtyWh: a.qtyWh });
    else if (log.eventName === "FillBooked") out.push({ ...base, type: "fill", filledWh: a.filledWh, totalFilledWh: a.totalFilledWh });
    else if (log.eventName === "OrderClosed") out.push({ ...base, type: "closed", releasedWh: a.releasedWh });
  }
  return out;
}

/** S9's own events in a receipt: the slots taken in and the alarms. */
function s9Events(receipt) {
  const slots = events(receipt, "DeliveryReconciliationPolicy", "SlotReconciled").map((e) => ({
    slot: Number(e.args.slot), cn: e.args.cn, dn: e.args.dn, s: e.args.s, cusum: e.args.cusum,
  }));
  const alarms = events(receipt, "DeliveryReconciliationPolicy", "DeliveryAlarm").map((e) => ({
    slot: Number(e.args.slot), level: Number(e.args.level), cusum: e.args.cusum, penaltyUntil: Number(e.args.penaltyUntil),
  }));
  return { slots, alarms };
}

/** Run `seeds` x `steps`; returns { history, config } in the verifier's form. */
export async function runReconciliationScenarios({ seeds = 3, steps = 200, firstSeed = 1 } = {}) {
  const chainId = await publicClient.getChainId();
  const ledger = await deploy(OWNER, "PositionLedger");
  const oracle = await deploy(OWNER, "OracleVerifier");
  const gate = await deploy(OWNER, "PolicyGate", [ledger, oracle, 48n]);
  const markets = [await deploy(OWNER, "ProbeMarket"), await deploy(OWNER, "ProbeMarket")];
  const decoder = await deploy(OWNER, "ProbeDecoder");
  const s9 = await deploy(OWNER, "DeliveryReconciliationPolicy", [gate]);
  const account = await deploy(OWNER, "MiniAccount", [key(OWNER).address]);
  const S9 = `0x${"59".repeat(32)}`;

  const asAccount = (target, contract, fn, args) =>
    send(OWNER, account, "MiniAccount", "execute", [target, 0n, calldata(contract, fn, args)]);
  await send(OWNER, account, "MiniAccount", "installModule", [EXECUTOR, gate, "0x"]);
  await asAccount(ledger, "PositionLedger", "setWriter", [gate, true]);
  await send(OWNER, account, "MiniAccount", "enableSession", [key(AGENT).address, gate, selector("PolicyGate", "submit"), 2n ** 47n]);
  for (const market of markets) {
    for (const fn of ["place", "cancel", "replace"]) {
      await asAccount(gate, "PolicyGate", "setDecoder", [market, selector("ProbeMarket", fn), decoder]);
    }
  }
  await asAccount(oracle, "OracleVerifier", "setMeter", [key(METER).address, SLOT]);
  const c = RECONCILIATION_CONFIG;
  const added = await asAccount(gate, "PolicyGate", "addPolicy", [s9, S9, encodeAbiParameters([DELIVERY], [{
    k: c.k, h: c.h, penaltySeconds: c.penaltySeconds, escalationSeconds: c.escalationSeconds,
    settlementLagSeconds: c.settlementLagSeconds, graceSeconds: c.graceSeconds, maxProcess: c.maxProcess,
    window: { kind: 0, step: c.window.step, buckets: c.window.buckets, anchor: 0, cap: c.window.cap, rate: 0n, initial: 0n },
  }])]);
  const configuredAt = Number((await publicClient.getBlock({ blockNumber: added.blockNumber })).timestamp);

  const history = [];
  const open = []; // { market, orderId, qtyWh }
  const read = new Set(); // slot starts with a reading posted
  let t = configuredAt + 10;
  const STEP = 2;

  const submit = async (market, call) => {
    const sub = calldata("PolicyGate", "submit", [market, call, []]);
    const receipt = await at(t, () => send(AGENT, account, "MiniAccount", "executeAsSession", [gate, sub]));
    const submitted = events(receipt, "PolicyGate", "OrderSubmitted")[0];
    const r = events(receipt, "PolicyGate", "PolicyResult").find((x) => x.args.policy.toLowerCase() === s9.toLowerCase()).args.result;
    history.push({
      type: "submission", at: t, account,
      legs: submitted.args.legs.map((l) => ({ kind: Number(l.kind), side: Number(l.side), slot: Number(l.slot), qtyWh: l.qtyWh })),
      s9: { verdict: Number(r.verdict), valueBefore: r.valueBefore, valueAfter: r.valueAfter },
      executed: events(receipt, "PolicyGate", "Executed").length > 0,
      ...s9Events(receipt),
    });
    const ledgerLogs = ledgerEvents(receipt, ledger, t);
    history.push(...ledgerLogs);
    return ledgerLogs.filter((e) => e.type === "opened");
  };

  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    const rand = generator(seed);
    const int = (n) => Math.floor(rand() * n);

    for (let i = 0; i < steps; i++) {
      const wait = int(20);
      t += STEP + (wait < 12 ? int(900) : wait < 19 ? int(2 * 3600) : int(12 * 3600));
      const cur = Math.floor(t / SLOT);
      // Well under the ledger's 64 open orders: release one instead.
      const op = open.length >= 40 ? 9 : int(20);

      if (op <= 6) {
        // A sale (mostly) or a buy, for a slot just ended to a few ahead.
        const side = int(4) === 0 ? 0 : 1;
        const slot = cur - 1 + int(5);
        const qtyWh = BigInt(1 + int(1500));
        const market = markets[int(2)];
        const opened = await submit(market, calldata("ProbeMarket", "place", [side, slot, qtyWh, 100_000n]));
        if (opened.length) open.push({ market, orderId: opened[0].orderId, qtyWh, slot });
      } else if (op <= 7 && open.length) {
        const [o] = open.splice(int(open.length), 1);
        await submit(o.market, calldata("ProbeMarket", "cancel", [o.orderId]));
      } else if (op <= 13 && open.length) {
        // The oldest order, filled (in full half the time), then released by
        // a keeper: most slots are reconciled before S9 reaches them.
        open.sort((a, b) => a.slot - b.slot);
        const [o] = open.splice(int(4) === 0 ? int(open.length) : 0, 1);
        const filled = int(2) === 0 ? o.qtyWh : BigInt(int(Number(o.qtyWh) + 1));
        await at(t, () => send(OWNER, o.market, "ProbeMarket", "setFilled", [o.orderId, filled]));
        t += STEP;
        const receipt = await at(t, () => send(KEEPER, gate, "PolicyGate", "reconcile", [account, o.market, o.orderId]));
        history.push(...ledgerEvents(receipt, ledger, t));
      } else if (op <= 15) {
        // The meter reports most ended slots; a few it never will. What it
        // delivered is often short of a sale.
        for (let back = 1; back <= 8; back++) {
          const slotStart = (cur - back) * SLOT;
          if (read.has(slotStart)) continue;
          read.add(slotStart);
          if (int(40) === 0) continue;
          const delivered = BigInt(int(3) === 0 ? int(1800) : int(300));
          const imported = int(3) === 0 ? BigInt(int(1000)) : 0n;
          const signed = await signMeter(METER, chainId, oracle, { account, slotStart, importWh: imported, exportWh: delivered });
          const receipt = await at(t, () => send(KEEPER, oracle, "OracleVerifier", "accept", [signed]));
          for (const e of events(receipt, "OracleVerifier", "ReadingAccepted")) {
            if (Number(e.args.kind) !== METER_KIND) continue;
            const [m] = decodeAbiParameters([{ type: "tuple", components: TYPES.MeterReading }], e.args.data);
            history.push({ type: "meter", slotStart: Number(m.slotStart), importWh: m.importWh, exportWh: m.exportWh });
          }
          t += STEP;
        }
      } else if (op <= 18) {
        const receipt = await at(t, () => send(KEEPER, gate, "PolicyGate", "poke", [account, s9, S9]));
        history.push({ type: "poke", at: t, account, ...s9Events(receipt) });
      } else if (int(4) === 0) {
        const receipt = await at(t, () => asAccount(gate, "PolicyGate", "resetPolicy", [s9, S9]));
        const e = events(receipt, "DeliveryReconciliationPolicy", "PenaltyReset")[0];
        history.push({ type: "reset", at: t, account, next: Number(e.args.next) });
      }
    }
  }
  return { history, config: { ...RECONCILIATION_CONFIG, configuredAt } };
}
