// Random histories for S8, run on a chain: one account on two ProbeMarkets on
// one slot grid, placements on either side of a few slots, cancellations and
// modifications through the gate, partial fills and keeper releases, waits of
// seconds to 30 hours. Seeded, so a disagreement can be replayed.
//
// Each receipt becomes events of the verifier's history (roundtrip.js), from
// the gate's and the ledger's events alone.

import { encodeAbiParameters } from "viem";
import { publicClient, deploy, events, calldata, selector, key, wallet, abi } from "../chain/index.js";

const OWNER = 0;
const AGENT = 1;
const KEEPER = 2;
const EXECUTOR = 2n;
const SLOT = 1800;

// Small enough that the fuzz reaches both bounds.
export const ROUNDTRIP_CONFIG = {
  soft: 800n,
  window: { kind: "SLIDING", step: SLOT, buckets: 48, anchor: 0, cap: 1_600n, rate: 0n, initial: 0n },
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
const ROUNDTRIP = { type: "tuple", components: [{ name: "soft", type: "uint64" }, { ...WINDOW, name: "window" }] };

/** The ledger's events in a receipt, in log order, in ledger.js's form. */
function ledgerEvents(receipt, ledger) {
  const out = [];
  for (const log of events(receipt, "PositionLedger")) {
    if (log.address.toLowerCase() !== ledger.toLowerCase()) continue;
    const a = log.args;
    const base = { block: log.blockNumber, account: a.account, market: a.market, orderId: a.orderId };
    if (log.eventName === "OrderOpened") out.push({ ...base, type: "opened", side: Number(a.side), slot: Number(a.slot), qtyWh: a.qtyWh });
    else if (log.eventName === "FillBooked") out.push({ ...base, type: "fill", filledWh: a.filledWh, totalFilledWh: a.totalFilledWh });
    else if (log.eventName === "OrderClosed") out.push({ ...base, type: "closed", releasedWh: a.releasedWh });
  }
  return out;
}

/** Run `seeds` × `steps`; returns the history, in the verifier's form. */
export async function runRoundTripScenarios({ seeds = 3, steps = 400, firstSeed = 1 } = {}) {
  const ledger = await deploy(OWNER, "PositionLedger");
  const oracle = await deploy(OWNER, "OracleVerifier");
  const gate = await deploy(OWNER, "PolicyGate", [ledger, oracle, 48n]);
  const markets = [await deploy(OWNER, "ProbeMarket"), await deploy(OWNER, "ProbeMarket")];
  const decoder = await deploy(OWNER, "ProbeDecoder");
  const s8 = await deploy(OWNER, "RoundTripPolicy", [gate]);
  const account = await deploy(OWNER, "MiniAccount", [key(OWNER).address]);

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
  const w = ROUNDTRIP_CONFIG.window;
  await asAccount(gate, "PolicyGate", "addPolicy", [s8, `0x${"58".repeat(32)}`, encodeAbiParameters([ROUNDTRIP], [{
    soft: ROUNDTRIP_CONFIG.soft, window: { kind: 0, step: w.step, buckets: w.buckets, anchor: 0, cap: w.cap, rate: 0n, initial: 0n },
  }])]);

  const history = [];
  const open = []; // { market, orderId, side, slot, qtyWh }
  let t = Number((await publicClient.getBlock()).timestamp) + 10;
  const STEP = 2;

  const submit = async (market, call) => {
    const sub = calldata("PolicyGate", "submit", [market, call, []]);
    const receipt = await at(t, () => send(AGENT, account, "MiniAccount", "executeAsSession", [gate, sub]));
    const submitted = events(receipt, "PolicyGate", "OrderSubmitted")[0];
    const r = events(receipt, "PolicyGate", "PolicyResult").find((x) => x.args.policy.toLowerCase() === s8.toLowerCase()).args.result;
    history.push({
      type: "submission", at: t, account,
      legs: submitted.args.legs.map((l) => ({ kind: Number(l.kind), side: Number(l.side), slot: Number(l.slot), qtyWh: l.qtyWh })),
      s8: { verdict: Number(r.verdict), valueBefore: r.valueBefore, valueAfter: r.valueAfter, soft: r.soft, hard: r.hard },
      executed: events(receipt, "PolicyGate", "Executed").length > 0,
    });
    const ledgerLogs = ledgerEvents(receipt, ledger);
    history.push(...ledgerLogs);
    return ledgerLogs.filter((e) => e.type === "opened");
  };

  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    const rand = generator(seed);
    const int = (n) => Math.floor(rand() * n);

    for (let i = 0; i < steps; i++) {
      const wait = int(20);
      t += STEP + (wait < 12 ? int(600) : wait < 19 ? int(4 * 3600) : int(30 * 3600));
      // A few slots near now, so both sides of one slot meet often.
      const base = Math.floor(t / SLOT) + 4;
      // Well under the ledger's 64 open orders.
      const op = open.length >= 40 ? 0 : int(10);

      if (op <= 1 && open.length > 0) {
        // Part filled, then released by a keeper.
        const [o] = open.splice(int(open.length), 1);
        const filled = BigInt(int(Number(o.qtyWh) + 1));
        await at(t, () => send(OWNER, o.market, "ProbeMarket", "setFilled", [o.orderId, filled]));
        t += STEP;
        const receipt = await at(t, () => send(KEEPER, gate, "PolicyGate", "reconcile", [account, o.market, o.orderId]));
        history.push(...ledgerEvents(receipt, ledger));
        continue;
      }
      if (op <= 3 && open.length > 0) {
        // Cancelled through the gate, sometimes part filled first.
        const [o] = open.splice(int(open.length), 1);
        if (int(2) === 0) {
          await at(t, () => send(OWNER, o.market, "ProbeMarket", "setFilled", [o.orderId, BigInt(int(Number(o.qtyWh) + 1))]));
          t += STEP;
        }
        await submit(o.market, calldata("ProbeMarket", "cancel", [o.orderId]));
        continue;
      }
      let side = int(2);
      let slot = base + int(4);
      const qtyWh = BigInt(1 + int(1500));
      if (op <= 5 && open.length > 0) {
        // Modified: the old order cancelled, a new one on the same market;
        // half the time resized in place (same side and slot).
        const k = int(open.length);
        const o = open[k];
        if (int(2) === 0) [side, slot] = [o.side, o.slot];
        const opened = await submit(o.market, calldata("ProbeMarket", "replace", [o.orderId, side, slot, qtyWh, 100_000n]));
        if (opened.length > 0) {
          open.splice(k, 1);
          open.push({ market: o.market, orderId: opened[0].orderId, side, slot, qtyWh });
        }
        continue;
      }
      const market = markets[int(2)];
      const opened = await submit(market, calldata("ProbeMarket", "place", [side, slot, qtyWh, 100_000n]));
      if (opened.length > 0) open.push({ market, orderId: opened[0].orderId, side, slot, qtyWh });
    }
  }
  return history;
}
