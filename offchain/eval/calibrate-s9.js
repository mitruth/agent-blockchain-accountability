// node offchain/eval/calibrate-s9.js [--report docs/reports/calibration-s9-<date>.json] [--target-days 30]
//
// S9's slack k and threshold h (spec v0.2 D19), from the delivery simulator
// (delivery.js) over every 2022 day of home_01:
//
//   k  the p95 of the honest shortfall under B2, over the slots where the
//      agent sold (decision of 25 October 2026: over all slots it is 0, as
//      only a few percent of half-hours fall short at all)
//   h  the smallest, in steps of 100 Wh, whose false alarms under B2 are at
//      least `target-days` apart on average (ARL0), by brute-force CUSUM
//
// Then, with that k and h: B0's false alarms (another controller on the same
// house), and ARL1 under the chronic-oversell attack, every sale made 10 %,
// 20 % or 50 % larger than the plan, which the battery then tries to deliver.

import fs from "node:fs";
import { armSlots, armSettings } from "../oracle/data.js";
import { simulateDelivery, percentile, cusumAlarms } from "./delivery.js";

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
};
const REPORT = arg("report", null);
const TARGET_DAYS = Number(arg("target-days", 30));
const SLOTS_PER_DAY = 48;

const settings = armSettings();
const run = (arm, oversell = 0) => simulateDelivery(armSlots(arm), settings, { oversell });

/** Alarms, their mean spacing in days, and the day of the first. */
function alarmsOf(sim, k, h) {
  const at = cusumAlarms(sim.map((r) => r.shortfallWh), k, h);
  const days = sim.length / SLOTS_PER_DAY;
  return {
    alarms: at.length,
    meanDaysBetween: at.length ? Number((days / at.length).toFixed(1)) : null,
    firstAlarmDay: at.length ? Number((at[0] / SLOTS_PER_DAY).toFixed(2)) : null,
  };
}

function summary(sim) {
  const sold = sim.filter((r) => r.contractWh > 0);
  return {
    slots: sim.length,
    slotsSold: sold.length,
    slotsShort: sim.filter((r) => r.shortfallWh > 0).length,
    soldWh: sold.reduce((a, r) => a + r.contractWh, 0),
    shortWh: sim.reduce((a, r) => a + r.shortfallWh, 0),
    p95ShortfallAllSlotsWh: percentile(sim.map((r) => r.shortfallWh), 95),
    p95ShortfallSellingSlotsWh: percentile(sold.map((r) => r.shortfallWh), 95),
  };
}

const b2 = run("B2");
const b0 = run("B0");
const k = summary(b2).p95ShortfallSellingSlotsWh;

let h = null;
for (let candidate = 100; candidate <= 100_000; candidate += 100) {
  const a = alarmsOf(b2, k, candidate);
  if (a.alarms === 0 || a.meanDaysBetween >= TARGET_DAYS) {
    h = candidate;
    break;
  }
}
if (h === null) throw new Error("no h up to 100 kWh meets the target");

const result = {
  home: "home_01",
  year: 2022,
  rule: "k = p95 of B2's shortfall over selling slots; h = smallest (100 Wh steps) with ARL0 >= target under B2",
  targetDays: TARGET_DAYS,
  kWh: k,
  hWh: h,
  honest: {
    B2: { ...summary(b2), ...alarmsOf(b2, k, h) },
    B0: { ...summary(b0), ...alarmsOf(b0, k, h) },
  },
  attack: Object.fromEntries(
    [0.1, 0.2, 0.5].map((x) => {
      const sim = run("B2", x);
      return [`B2, sales +${x * 100} %`, { ...summary(sim), ...alarmsOf(sim, k, h) }];
    }),
  ),
};

console.log(JSON.stringify(result, null, 2));
if (REPORT) fs.writeFileSync(REPORT, JSON.stringify(result, null, 2) + "\n");
