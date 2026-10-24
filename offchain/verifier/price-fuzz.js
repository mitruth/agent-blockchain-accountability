// Random histories for the price policies, A3T and S7, run on a chain: tariffs
// posted at random (some days not at all, so they go stale), placements on
// either side at prices around the band, partial fills and releases, waits of
// seconds to a day. Seeded, so a disagreement can be replayed.
//
// Each receipt becomes one event of the verifier's history (price.js), from the
// oracle's, the gate's, the ledger's and S7's events alone.

import { decodeAbiParameters, encodeAbiParameters } from "viem";
import { publicClient, deploy, read, events, calldata, selector, key, wallet, abi } from "../chain/index.js";
import { signTariff, TYPES } from "../oracle/typed.js";

const OWNER = 0;
const AGENT = 1;
const KEEPER = 2;
const RETAILER = 21;
const EXECUTOR = 2n;
const TARIFF = 2;
const SLOT = 1800;
const MAX_AGE = 86_400;
const A3T_BIT = 64n;

export const PRICE_CONFIG = {
  slotSeconds: SLOT,
  maxAge: MAX_AGE,
  buyMarkupBps: 1_000,
  sellDiscountBps: 1_500,
  s7: { soft: 150_000n, window: { kind: "SLIDING", step: 3600, buckets: 24, anchor: 0, cap: 300_000n, rate: 0n, initial: 0n } },
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

const STATIC = {
  type: "tuple",
  components: [
    { name: "maxQtyWh", type: "uint64" }, { name: "maxValue", type: "uint64" }, { name: "sellFloor", type: "uint64" },
    { name: "buyCeiling", type: "uint64" }, { name: "buyBlockedHours", type: "uint24" }, { name: "sellBlockedHours", type: "uint24" },
    { name: "horizonSeconds", type: "uint32" }, { name: "minQtyWh", type: "uint64" }, { name: "ratedPowerW", type: "uint32" },
    { name: "tariffBand", type: "bool" }, { name: "buyMarkupBps", type: "uint16" }, { name: "sellDiscountBps", type: "uint16" },
  ],
};
const WINDOW = {
  type: "tuple",
  components: [
    { name: "kind", type: "uint8" }, { name: "step", type: "uint32" }, { name: "buckets", type: "uint16" },
    { name: "anchor", type: "uint40" }, { name: "cap", type: "uint64" }, { name: "rate", type: "uint64" }, { name: "initial", type: "uint64" },
  ],
};
const DOMINATED = { type: "tuple", components: [{ name: "soft", type: "uint64" }, { ...WINDOW, name: "window" }] };

/** Run `seeds` × `steps`; returns the history, in the verifier's form. */
export async function runPriceScenarios({ seeds = 3, steps = 120, firstSeed = 1 } = {}) {
  const chainId = await publicClient.getChainId();
  const ledger = await deploy(OWNER, "PositionLedger");
  const oracle = await deploy(OWNER, "OracleVerifier");
  const gate = await deploy(OWNER, "PolicyGate", [ledger, oracle, 48n]);
  const market = await deploy(OWNER, "ProbeMarket");
  const decoder = await deploy(OWNER, "ProbeDecoder");
  const statics = await deploy(OWNER, "StaticOrderPolicy", [gate]);
  const s7 = await deploy(OWNER, "DominatedTradePolicy", [gate]);
  const account = await deploy(OWNER, "MiniAccount", [key(OWNER).address]);

  const asAccount = (target, contract, fn, args) =>
    send(OWNER, account, "MiniAccount", "execute", [target, 0n, calldata(contract, fn, args)]);
  await send(OWNER, account, "MiniAccount", "installModule", [EXECUTOR, gate, "0x"]);
  await asAccount(ledger, "PositionLedger", "setWriter", [gate, true]);
  await send(OWNER, account, "MiniAccount", "enableSession", [key(AGENT).address, gate, selector("PolicyGate", "submit"), 2n ** 47n]);
  await asAccount(gate, "PolicyGate", "setDecoder", [market, selector("ProbeMarket", "place"), decoder]);
  await asAccount(oracle, "OracleVerifier", "setDevice", [TARIFF, key(RETAILER).address, MAX_AGE]);
  // A1-A6 out of the way; only A3T's bit is compared.
  await asAccount(gate, "PolicyGate", "addPolicy", [statics, `0x${"a3".repeat(32)}`, encodeAbiParameters([STATIC], [{
    maxQtyWh: 2n ** 63n, maxValue: 2n ** 63n, sellFloor: 0n, buyCeiling: 2n ** 63n, buyBlockedHours: 0, sellBlockedHours: 0,
    horizonSeconds: 4_000_000_000, minQtyWh: 0n, ratedPowerW: 4_000_000_000,
    tariffBand: true, buyMarkupBps: PRICE_CONFIG.buyMarkupBps, sellDiscountBps: PRICE_CONFIG.sellDiscountBps,
  }])]);
  const w = PRICE_CONFIG.s7.window;
  await asAccount(gate, "PolicyGate", "addPolicy", [s7, `0x${"57".repeat(32)}`, encodeAbiParameters([DOMINATED], [{
    soft: PRICE_CONFIG.s7.soft, window: { kind: 0, step: w.step, buckets: w.buckets, anchor: 0, cap: w.cap, rate: 0n, initial: 0n },
  }])]);

  const history = [];
  const open = []; // { orderId, qtyWh }
  let t = Number((await publicClient.getBlock()).timestamp) + 10;
  const STEP = 2;

  const postTariff = async (int) => {
    const first = Math.floor(t / SLOT) * SLOT;
    // Mostly a full schedule; sometimes a short one, so slots fall outside it.
    const n = int(4) === 0 ? 1 + int(96) : 96;
    const retail = [];
    const feedIn = [];
    for (let i = 0; i < n; i++) {
      const r = BigInt(int(400_000));
      retail.push(r);
      feedIn.push((r * BigInt(int(101))) / 100n);
    }
    const signed = await signTariff(RETAILER, chainId, oracle, {
      account, issuedAt: t, firstSlotStart: first, slotSeconds: SLOT, retail, feedIn,
    });
    const receipt = await at(t, () => send(KEEPER, oracle, "OracleVerifier", "accept", [signed]));
    for (const e of events(receipt, "OracleVerifier", "ReadingAccepted")) {
      if (Number(e.args.kind) !== TARIFF) continue;
      const [s] = decodeAbiParameters([{ type: "tuple", components: TYPES.TariffSchedule }], e.args.data);
      history.push({
        type: "tariff", at: t, issuedAt: Number(s.issuedAt), firstSlotStart: Number(s.firstSlotStart),
        slotSeconds: Number(s.slotSeconds), retail: [...s.retail], feedIn: [...s.feedIn],
      });
    }
    return { retail, feedIn, first };
  };

  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    const rand = generator(seed);
    const int = (n) => Math.floor(rand() * n);
    t += STEP;
    let schedule = await postTariff(int);

    for (let i = 0; i < steps; i++) {
      const wait = int(20);
      t += STEP + (wait < 12 ? int(600) : wait < 19 ? int(4 * 3600) : int(30 * 3600));
      const op = int(10);

      if (op <= 1) {
        schedule = await postTariff(int);
        continue;
      }
      if (op <= 3 && open.length > 0) {
        // Release an open order: part of it filled, the rest closed.
        const [o] = open.splice(int(open.length), 1);
        const filled = BigInt(int(Number(o.qtyWh) + 1));
        await at(t, () => send(OWNER, market, "ProbeMarket", "setFilled", [o.orderId, filled]));
        t += STEP;
        const receipt = await at(t, () => send(KEEPER, gate, "PolicyGate", "reconcile", [account, market, o.orderId]));
        const c = events(receipt, "DominatedTradePolicy", "Credited")[0];
        history.push({
          type: "release", at: t, orderId: o.orderId, qtyWh: o.qtyWh, filledWh: filled,
          credit: c ? { amount: c.args.amount, credited: c.args.credited } : null,
        });
        continue;
      }

      // A placement around the band: the reference is the schedule's slot if
      // it has one, else any price.
      const side = int(2);
      const slot = Math.floor(t / SLOT) + 1 + int(100);
      const k = slot - schedule.first / SLOT;
      const ref = k >= 0 && k < schedule.retail.length ? (side === 0 ? schedule.retail[k] : schedule.feedIn[k]) : 200_000n;
      const price = (ref * BigInt(70 + int(60))) / 100n + BigInt(int(3)) || 1n;
      const qtyWh = BigInt(1 + int(3000));
      const leg = { side, slot, qtyWh, price };
      const submit = calldata("PolicyGate", "submit", [market, calldata("ProbeMarket", "place", [side, slot, qtyWh, price]), []]);
      const receipt = await at(t, () => send(AGENT, account, "MiniAccount", "executeAsSession", [gate, submit]));

      const results = events(receipt, "PolicyGate", "PolicyResult");
      const a3 = results.find((r) => r.args.policy.toLowerCase() === statics.toLowerCase()).args.result;
      const s7r = results.find((r) => r.args.policy.toLowerCase() === s7.toLowerCase()).args.result;
      const opened = events(receipt, "PositionLedger", "OrderOpened")[0];
      history.push({
        type: "submission", at: t, leg,
        a3t: (a3.valueAfter & A3T_BIT) !== 0n,
        s7: { verdict: Number(s7r.verdict), valueBefore: s7r.valueBefore, valueAfter: s7r.valueAfter },
        orderId: opened ? opened.args.orderId : null,
      });
      if (opened) open.push({ orderId: opened.args.orderId, qtyWh });
    }
  }
  return history;
}
