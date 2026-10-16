// npm run test:offchain
//
// The oracles' own logic, without a chain: the battery model, an arm
// replayed, the forecasts, the data and the slot resampling.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Battery, replayArm } from "./battery.js";
import { pvForecast } from "./forecast.js";
import { homeParams, homeSlots, armSettings, armSlots, indexOfDate, resample } from "./data.js";

// home_01 as the arms ran it: 5 kWh, 3 kW, 95 % each way, 10 % to 100 %, from 50 %.
const ARM = {
  batteryCapacityWh: 5000, batteryPowerW: 3000, etaChargeBps: 9500, etaDischargeBps: 9500,
  socMinBps: 1000, socMaxBps: 10000, socInitialBps: 5000,
};

test("the battery stores what it takes times the charge efficiency, rounded down", () => {
  const b = new Battery(ARM, 1800);
  assert.equal(b.charge(1000), 1000);
  assert.equal(b.socWh, 2500 + 950);
});

test("the battery gives what it draws times the discharge efficiency, and counts the draw", () => {
  const b = new Battery(ARM, 1800);
  assert.equal(b.discharge(950), 950);
  assert.equal(b.socWh, 2500 - 1000);
  assert.equal(b.odometerWh, 1000);
});

test("power limits one slot: 3 kW for half an hour is 1.5 kWh", () => {
  const b = new Battery(ARM, 1800);
  assert.equal(b.charge(4000), 1500);
  assert.equal(b.discharge(4000), 1500);
  const hourly = new Battery(ARM, 3600);
  assert.equal(hourly.charge(4000), 2632); // stops at full: 2500 Wh of room needs 2631.6 Wh
});

test("the battery stops at its limits, and rounding never overfills it", () => {
  const b = new Battery({ ...ARM, socInitialBps: 9900 }, 1800);
  assert.equal(b.charge(1000), 53); // 50 Wh of room needs 52.6 Wh, taken as 53
  assert.equal(b.socWh, 5000);
  const low = new Battery({ ...ARM, socInitialBps: 1100 }, 1800);
  assert.equal(low.discharge(1000), 47); // 50 Wh above the 10 % floor
  assert.equal(low.socWh, 500);
  assert.equal(low.discharge(1), 0);
});

test("a step charges a surplus and covers a shortfall, and says what is left for the grid", () => {
  const b = new Battery(ARM, 1800);
  assert.deepEqual(b.step(2000), { chargedWh: 1500, dischargedWh: 0, gridWh: 500 });
  assert.deepEqual(b.step(-300), { chargedWh: 0, dischargedWh: 300, gridWh: 0 });
});

test("an arm replayed starts from its initial charge and runs one slot behind its log", () => {
  const slots = [
    { socBps: 5000, dischargeWh: 0 },
    { socBps: 4000, dischargeWh: 475 },
    { socBps: 4000, dischargeWh: 0 },
  ];
  assert.deepEqual(replayArm(ARM, slots), [
    { socWh: 2500, dischargeOdometerWh: 0 },
    { socWh: 2500, dischargeOdometerWh: 0 },
    { socWh: 2000, dischargeOdometerWh: 500 },
  ]);
});

test("B2's year replayed: the odometer over the capacity is the arm's own cycle count", () => {
  const settings = armSettings();
  const slots = armSlots("B2");
  const states = replayArm(settings, slots);
  const last = slots.at(-1);
  const total = states.at(-1).dischargeOdometerWh + Math.ceil((last.dischargeWh * 10_000) / settings.etaDischargeBps);
  const cycles = total / settings.batteryCapacityWh;
  assert.ok(Math.abs(cycles - 452.07) < 0.5, `${cycles} cycles`); // annual-results.csv: 452,074 milli
  for (const s of states) {
    assert.ok(s.socWh >= 500 && s.socWh <= 5000);
  }
});

test("the forecast is the actual PV, or the same slots a day earlier", () => {
  const slots = homeSlots("home_01");
  const june13 = indexOfDate(slots, "2022-06-13");
  const actual = pvForecast(slots, june13, 48, "actual");
  const yesterday = pvForecast(slots, june13, 48, "yesterday");
  assert.equal(actual.length, 48);
  assert.equal(actual[24], slots[june13 + 24].pvWh);
  assert.equal(yesterday[24], slots[june13 - 48 + 24].pvWh);
  assert.notDeepEqual(actual, yesterday);
  assert.throws(() => pvForecast(slots, 10, 4, "yesterday"));
  assert.throws(() => pvForecast(slots, 0, 4, "tomorrow"));
});

test("data slots sum to the market's slot length", () => {
  assert.deepEqual(resample([1, 2, 3, 4], 1800), [1, 2, 3, 4]);
  assert.deepEqual(resample([1, 2, 3, 4], 3600), [3, 7]);
  assert.throws(() => resample([1, 2], 900));
});

test("the data the oracles read is the extract's", () => {
  assert.equal(homeParams("home_05").batteryCapacityWh, 10000);
  assert.equal(homeSlots("home_03").length, 17520);
  assert.equal(armSettings().socMinBps, 1000);
  assert.equal(armSlots("B0").length, 17520);
});
