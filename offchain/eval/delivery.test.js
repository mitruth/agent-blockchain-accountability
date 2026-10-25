// npm run test:offchain
//
// The delivery simulator (spec v0.2 section 7) on synthetic days: a perfect
// forecast delivers exactly, the battery makes up a forecast miss within its
// limits, the connection's limit holds; and S9's arithmetic by definition.

import { test } from "node:test";
import assert from "node:assert/strict";
import { simulateDelivery, shortfall, percentile, cusumAlarms } from "./delivery.js";

const settings = {
  batteryCapacityWh: 5000, batteryPowerW: 3000, etaChargeBps: 10000, etaDischargeBps: 10000,
  socMinBps: 1000, socMaxBps: 10000, socInitialBps: 5000, gridLimitW: 9000, forecastWeightBps: 3000,
};

/** `days` days of 48 slots; `pv(d, i)` and `load(d, i)` in Wh. */
function series(days, pv, load = () => 100) {
  const out = [];
  for (let d = 0; d < days; d++) {
    for (let i = 0; i < 48; i++) {
      out.push({ date: `day${d}`, slot: i, pvWh: pv(d, i), fixedLoadWh: load(d, i), taskWh: 0, chargeWh: 0, dischargeWh: 0 });
    }
  }
  return out;
}

test("S9's shortfall: none for a buy, at most the sale", () => {
  assert.equal(shortfall(0, -500), 0, "nothing sold");
  assert.equal(shortfall(1000, 400), 600);
  assert.equal(shortfall(1000, 1200), 0, "over-delivered");
  assert.equal(shortfall(1000, -3000), 1000, "imported: the whole sale, no more");
});

test("the same day every day: the forecast is exact and every sale is delivered", () => {
  const sim = simulateDelivery(series(3, (d, i) => (i >= 20 && i < 30 ? 1200 : 0)), settings);
  assert.equal(sim.reduce((a, r) => a + r.shortfallWh, 0), 0);
  const sale = sim.find((r) => r.date === "day2" && r.slot === 25);
  assert.equal(sale.contractWh, 1100, "PV 1,200 less the load of 100");
  assert.equal(sale.exportWh, 1100);
});

test("a cloudy day after a sunny one: the battery makes up what it can", () => {
  // Day 0 sunny (1,200 Wh at slot 25), day 1 cloudy (200 Wh). Day 1's
  // forecast is day 0, so the agent sells 1,100 and the sun gives 100 net:
  // the battery, at 2,500 Wh with a 500 Wh floor, gives up to 1,500 a slot.
  const sim = simulateDelivery(series(2, (d, i) => (i === 25 ? (d === 0 ? 1200 : 200) : 0), () => 100), settings);
  const r = sim.find((x) => x.date === "day1" && x.slot === 25);
  assert.equal(r.contractWh, 1100);
  assert.equal(r.exportWh, 1100, "the battery covered the miss");
  assert.equal(r.shortfallWh, 0);
});

test("an empty battery cannot cover a miss: the shortfall is what the meter misses", () => {
  const flat = { ...settings, socInitialBps: 1000 };
  // Load 100 every slot and no sun on day 0: the battery, at its floor, can
  // give nothing; day 1 forecasts a sale it cannot make.
  const sim = simulateDelivery(series(2, (d, i) => (i === 25 && d === 0 ? 1200 : 0)), flat);
  const r = sim.find((x) => x.date === "day1" && x.slot === 25);
  assert.ok(r.contractWh > 0, "a sale planned on yesterday's sun");
  assert.equal(r.exportWh, 0);
  assert.equal(r.shortfallWh, r.contractWh);
});

test("the connection's limit bounds both the contract and the export", () => {
  const big = { ...settings, gridLimitW: 2000 }; // 1,000 Wh a half-hour
  const sim = simulateDelivery(series(2, (d, i) => (i === 25 ? 3000 : 0), () => 0), big);
  const r = sim.find((x) => x.date === "day1" && x.slot === 25);
  assert.equal(r.contractWh, 1000);
  assert.ok(r.exportWh <= 1000);
});

test("an oversell inflates every planned sale", () => {
  const days = series(2, (d, i) => (i === 25 ? 1100 : 0), () => 0);
  const honest = simulateDelivery(days, settings).find((x) => x.date === "day1" && x.slot === 25);
  const attack = simulateDelivery(days, settings, { oversell: 0.5 }).find((x) => x.date === "day1" && x.slot === 25);
  assert.equal(honest.contractWh, 1100);
  assert.equal(attack.contractWh, 1650);
});

test("the CUSUM, by its definition", () => {
  // k 100, h 1000: 600 -> 500; 600 -> 1000 (not above); 200 -> 1100: alarm, reset.
  assert.deepEqual(cusumAlarms([600, 600, 200, 0, 1200], 100, 1000), [2, 4]);
  assert.deepEqual(cusumAlarms([0, 0, 0], 0, 0), []);
});

test("percentiles by nearest rank", () => {
  assert.equal(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95), 10);
  assert.equal(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50), 5);
  assert.equal(percentile([], 95), 0);
});
