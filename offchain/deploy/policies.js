// The owner's policies for an agent (step 4), from prosumers.json's
// "agentPolicies": the per-action bounds, the budget S1, the export and import
// caps S2 and the cancellation quota S6, each on a sliding window.
//
// A policy's configuration is the ABI encoding of its Config struct.

import { encodeAbiParameters, keccak256, toHex } from "viem";
import { price } from "../chain/index.js";

const SLIDING = 0;

const WINDOW = {
  type: "tuple",
  components: [
    { name: "kind", type: "uint8" },
    { name: "step", type: "uint32" },
    { name: "buckets", type: "uint16" },
    { name: "anchor", type: "uint40" },
    { name: "cap", type: "uint64" },
    { name: "rate", type: "uint64" },
    { name: "initial", type: "uint64" },
  ],
};

const STATIC_CONFIG = {
  type: "tuple",
  components: [
    { name: "maxQtyWh", type: "uint64" },
    { name: "maxValue", type: "uint64" },
    { name: "sellFloor", type: "uint64" },
    { name: "buyCeiling", type: "uint64" },
    { name: "buyBlockedHours", type: "uint24" },
    { name: "sellBlockedHours", type: "uint24" },
    { name: "horizonSeconds", type: "uint32" },
  ],
};

const WINDOW_CONFIG = {
  type: "tuple",
  components: [{ name: "quantity", type: "uint8" }, { name: "soft", type: "uint64" }, { ...WINDOW, name: "window" }],
};

const QUOTA_CONFIG = {
  type: "tuple",
  components: [
    { ...WINDOW, name: "window" },
    { name: "maxCancelledWh", type: "uint64" },
    { name: "maxMessages", type: "uint64" },
    { name: "gateWeightPercent", type: "uint32" },
    { name: "gateWindowSeconds", type: "uint32" },
    { name: "ratioPercent", type: "uint32" },
    { name: "freeCancelWh", type: "uint64" },
  ],
};

/** WindowPolicy's quantities, as its enum numbers them. */
export const QUANTITY = { BUY_VALUE: 0, SELL_WH: 1, BUY_WH: 2 };

/** Policy ids: a readable name, hashed. */
export const policyId = (name) => keccak256(toHex(name));

function sliding(hours, cap, bucketSeconds = 3600) {
  const buckets = Math.round((hours * 3600) / bucketSeconds);
  return { kind: SLIDING, step: bucketSeconds, buckets, anchor: 0, cap: BigInt(cap), rate: 0n, initial: 0n };
}

/**
 * The instances to add for one agent: [{ contract, id, name, config }], where
 * `contract` is "statics", "windows" or "quota" and `config` the encoded bytes.
 */
export function agentPolicyInstances(p) {
  const out = [];
  const a = p.perAction;
  out.push({
    contract: "statics",
    name: "A1-A6 per action",
    config: encodeAbiParameters([STATIC_CONFIG], [{
      maxQtyWh: BigInt(a.maxQtyWh),
      maxValue: price(a.maxValueUSD),
      sellFloor: price(a.sellFloorUSD),
      buyCeiling: price(a.buyCeilingUSD),
      buyBlockedHours: 0,
      sellBlockedHours: 0,
      horizonSeconds: a.horizonHours * 3600,
    }]),
  });

  const b = p.budget;
  out.push({
    contract: "windows",
    name: "S1 budget",
    config: encodeAbiParameters([WINDOW_CONFIG], [{
      quantity: QUANTITY.BUY_VALUE, soft: price(b.softUSD), window: sliding(b.hours, price(b.capUSD)),
    }]),
  });

  const e = p.exportImport;
  out.push({
    contract: "windows",
    name: "S2 export",
    config: encodeAbiParameters([WINDOW_CONFIG], [{
      quantity: QUANTITY.SELL_WH, soft: BigInt(e.exportWh), window: sliding(e.hours, e.exportWh),
    }]),
  });
  out.push({
    contract: "windows",
    name: "S2 import",
    config: encodeAbiParameters([WINDOW_CONFIG], [{
      quantity: QUANTITY.BUY_WH, soft: BigInt(e.importWh), window: sliding(e.hours, e.importWh),
    }]),
  });

  const q = p.cancelQuota;
  out.push({
    contract: "quota",
    name: "S6 cancel quota",
    config: encodeAbiParameters([QUOTA_CONFIG], [{
      window: sliding(q.minutes / 60, 0, q.bucketMinutes * 60),
      maxCancelledWh: BigInt(q.maxCancelledWh),
      maxMessages: BigInt(q.maxMessages),
      gateWeightPercent: q.gateWeightPercent,
      gateWindowSeconds: q.gateWindowMinutes * 60,
      ratioPercent: q.ratioPercent,
      freeCancelWh: BigInt(q.freeCancelWh),
    }]),
  });

  return out.map((x) => ({ ...x, id: policyId(x.name) }));
}
