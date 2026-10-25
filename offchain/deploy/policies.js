// The owner's policies for an agent, from prosumers.json's "agentPolicies":
// the per-action bounds, the budget S1, the export and import caps S2 and the
// cancellation quota S6, each on a sliding window (step 4); and, where the
// prosumer has a battery, deliverability S3, cycles S4 and the ramp S5 (step
// 5), set from that battery.
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
    { name: "minQtyWh", type: "uint64" },
    { name: "ratedPowerW", type: "uint32" },
    { name: "tariffBand", type: "bool" },
    { name: "buyMarkupBps", type: "uint16" },
    { name: "sellDiscountBps", type: "uint16" },
  ],
};

const DOMINATED_CONFIG = {
  type: "tuple",
  components: [{ name: "soft", type: "uint64" }, { ...WINDOW, name: "window" }],
};

const ROUND_TRIP_CONFIG = DOMINATED_CONFIG; // { soft, window }, the same shape

const DELIVERY_CONFIG = {
  type: "tuple",
  components: [
    { name: "k", type: "uint64" },
    { name: "h", type: "uint64" },
    { name: "penaltySeconds", type: "uint32" },
    { name: "escalationSeconds", type: "uint32" },
    { name: "settlementLagSeconds", type: "uint32" },
    { name: "graceSeconds", type: "uint32" },
    { name: "maxProcess", type: "uint16" },
    { ...WINDOW, name: "window" },
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

const S3_CONFIG = {
  type: "tuple",
  components: [
    { name: "horizonSlots", type: "uint16" },
    { name: "capacityWh", type: "uint64" },
    { name: "socMinProfileBps", type: "uint16[24]" },
    { name: "socMaxBps", type: "uint16" },
    { name: "chargePowerW", type: "uint32" },
    { name: "dischargePowerW", type: "uint32" },
    { name: "etaChargeBps", type: "uint16" },
    { name: "etaDischargeBps", type: "uint16" },
    { name: "pvCreditBps", type: "uint16" },
    { name: "reserveLoadWh", type: "uint64" },
  ],
};

const S4_CONFIG = {
  type: "tuple",
  components: [
    { name: "softWh", type: "uint64" },
    { ...WINDOW, name: "window" },
    { name: "horizonSlots", type: "uint16" },
    { name: "pvCreditBps", type: "uint16" },
    { name: "etaDischargeBps", type: "uint16" },
  ],
};

const S5_CONFIG = {
  type: "tuple",
  components: [{ name: "softStepWh", type: "uint64" }, { name: "maxStepWh", type: "uint64" }],
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
 * `contract` is "statics", "windows", "quota", "dominated", "roundTrip",
 * "delivery", "deliverability", "cycles" or "ramp", and `config` the encoded
 * bytes. `battery` is the prosumer's, from
 * prosumers.json; without one, the physical policies are left out.
 */
export function agentPolicyInstances(p, { battery, slotSeconds } = {}) {
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
      minQtyWh: BigInt(a.minQtyWh),
      ratedPowerW: a.ratedPowerW,
      // A3T (v0.2 step 3), against the signed tariff, when "tariffBand" names it.
      tariffBand: Boolean(a.tariffBand),
      buyMarkupBps: Math.round((a.tariffBand?.buyMarkupPercent ?? 0) * 100),
      sellDiscountBps: Math.round((a.tariffBand?.sellDiscountPercent ?? 0) * 100),
    }]),
  });

  // S7 (v0.2 step 3): the value given away against the tariff, over a sliding
  // window, when "dominated" names it.
  const dt = p.dominated;
  if (dt) {
    out.push({
      contract: "dominated",
      name: "S7 dominated trades",
      config: encodeAbiParameters([DOMINATED_CONFIG], [{
        soft: price(dt.softUSD), window: sliding(dt.days * 24, price(dt.capUSD), (dt.bucketHours ?? 1) * 3600),
      }]),
    });
  }

  // S8 (v0.2 step 4): Wh bought and sold in the same slot, over a sliding
  // window of one-slot buckets, when "roundTrip" names it.
  const rt = p.roundTrip;
  if (rt) {
    out.push({
      contract: "roundTrip",
      name: "S8 round trip",
      config: encodeAbiParameters([ROUND_TRIP_CONFIG], [{
        soft: BigInt(rt.softWh), window: sliding(rt.hours, rt.capWh, slotSeconds),
      }]),
    });
  }

  // S9 (v0.2 step 5): sold against delivered, a CUSUM on the shortfall, when
  // "delivery" names it. H_pen, level 1's cap on sells, is a share of S2's
  // export cap (spec default 50 %).
  const dl = p.delivery;
  if (dl) {
    out.push({
      contract: "delivery",
      name: "S9 delivery",
      config: encodeAbiParameters([DELIVERY_CONFIG], [{
        k: BigInt(dl.kWh),
        h: BigInt(dl.hWh),
        penaltySeconds: dl.penaltyHours * 3600,
        escalationSeconds: dl.escalationDays * 86_400,
        settlementLagSeconds: dl.settlementLagSlots * slotSeconds,
        graceSeconds: dl.graceSlots * slotSeconds,
        maxProcess: dl.maxProcess,
        window: sliding(dl.windowHours, Math.round(p.exportImport.exportWh * dl.penaltyCapShareOfExport), slotSeconds),
      }]),
    });
  }

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

  const ph = p.physical;
  if (ph && battery) {
    const pvCreditBps = Math.round(ph.pvCreditPercent * 100);
    out.push({
      contract: "deliverability",
      name: "S3 deliverability",
      config: encodeAbiParameters([S3_CONFIG], [{
        horizonSlots: ph.horizonSlots,
        capacityWh: BigInt(battery.capacityWh),
        // One floor all day: the HEMS battery has a constant minimum (C3).
        socMinProfileBps: Array(24).fill(battery.socMinBps),
        socMaxBps: battery.socMaxBps,
        chargePowerW: battery.powerW,
        dischargePowerW: battery.powerW,
        etaChargeBps: battery.etaChargeBps,
        etaDischargeBps: battery.etaDischargeBps,
        pvCreditBps,
        reserveLoadWh: BigInt(battery.reserveLoadWh),
      }]),
    });
    // N_max cycles a day: N_max x C_bat drawn from the cells over a sliding
    // day, in buckets of one slot.
    const cap = BigInt(Math.round(ph.cyclesPerDay * battery.capacityWh));
    out.push({
      contract: "cycles",
      name: "S4 cycles",
      config: encodeAbiParameters([S4_CONFIG], [{
        softWh: BigInt(Math.round(ph.softCyclesPerDay * battery.capacityWh)),
        window: sliding(24, cap, slotSeconds),
        horizonSlots: ph.horizonSlots,
        pvCreditBps,
        etaDischargeBps: battery.etaDischargeBps,
      }]),
    });
    out.push({
      contract: "ramp",
      name: "S5 ramp",
      config: encodeAbiParameters([S5_CONFIG], [{ softStepWh: BigInt(ph.softStepWh), maxStepWh: BigInt(ph.maxStepWh) }]),
    });
  }

  return out.map((x) => ({ ...x, id: policyId(x.name) }));
}
