// Reads the six-home HEMS dataset and turns it into the integer tables the
// project uses: Wh, W, basis points and micro-USD, each rounded once.
//
//   readHomes(dir)          the six homes' PV and battery parameters
//   readYear(dir, home, y)  one home's 48 slots a day for calendar year y
//   pickDays(years)         the representative days, with the reason for each

import fs from "node:fs";
import path from "node:path";
import { ROOT } from "../chain/paths.js";
import { scaled } from "./decimal.js";

/** Where Dan keeps the raw dataset. Git-ignored. */
export const SOURCE_DIR = path.join(ROOT, "A Four-Year 30-Minute Simulated Residential HEMS D");

export const SLOTS_PER_DAY = 48;

function readCsv(file) {
  const lines = fs.readFileSync(file, "utf8").replace(/^﻿/, "").trim().split(/\r?\n/);
  const header = lines[0].split(",");
  return lines.slice(1).map((line) => {
    const cells = line.split(",");
    if (cells.length !== header.length) throw new Error(`${file}: a row with ${cells.length} cells`);
    return Object.fromEntries(header.map((h, i) => [h, cells[i]]));
  });
}

/** "A_single_worker" → "single-worker". */
const label = (householdType) => householdType.replace(/^[A-Z]_/, "").replaceAll("_", "-");

/** The six homes, from `MetaData_homes.csv`. */
export function readHomes(dir = SOURCE_DIR) {
  return readCsv(path.join(dir, "MetaData_homes.csv")).map((h) => {
    const id = Number(h.home_id);
    return {
      homeId: id,
      name: `home_${String(id).padStart(2, "0")}`,
      householdType: label(h.household_type),
      people: Number(h.num_people),
      houseAreaM2: h.house_area_m2,
      pvCapacityW: scaled(h.pv_capacity_kw, 1000),
      batteryCapacityWh: scaled(h.battery_capacity_kwh, 1000),
      batteryPowerW: scaled(h.battery_power_kw, 1000),
      socInitialBps: scaled(h.battery_initial_soc_fraction, 10_000),
      socMinBps: scaled(h.battery_min_soc_fraction, 10_000),
      socMaxBps: scaled(h.battery_max_soc_fraction, 10_000),
      etaChargeBps: scaled(h.battery_eta_charge, 10_000),
      etaDischargeBps: scaled(h.battery_eta_discharge, 10_000),
    };
  });
}

/**
 * One home's slots for a calendar year, from `AllData/home_XX.csv`. The file's
 * clock is a plain 30-minute grid in local time, 48 slots every day, with no
 * daylight-saving jumps; a slot is its position in the day.
 */
export function readYear(dir, home, year) {
  const rows = readCsv(path.join(dir, "AllData", `${home.name}.csv`)).filter((r) => r.date.startsWith(`${year}-`));
  if (rows.length === 0) throw new Error(`${home.name}: no rows for ${year}`);
  if (rows.length % SLOTS_PER_DAY) throw new Error(`${home.name} ${year}: ${rows.length} rows is not whole days`);
  return rows.map((r, i) => {
    const [date, clock] = r.date.split(" ");
    const time = clock.slice(0, 5);
    const slot = i % SLOTS_PER_DAY;
    const [hh, mm] = time.split(":").map(Number);
    if (hh * 2 + mm / 30 !== slot) throw new Error(`${home.name}: ${r.date} is not slot ${slot}`);
    const wh = (v) => scaled(v, 1000);
    const baseLoadWh = wh(r.base_load_kwh);
    const appliancesWh = wh(r.washing_machine_kwh) + wh(r.dishwasher_kwh);
    const hvacWh = wh(r.hvac_load_kwh);
    const loadWh = baseLoadWh + appliancesWh + hvacWh;
    const pvWh = wh(r.pv_energy_kwh);
    return {
      date, slot, time,
      baseLoadWh, appliancesWh, hvacWh, loadWh, pvWh,
      netLoadWh: loadWh - pvWh,
      priceMicroUsdPerKwh: scaled(r.rtp_usd_per_kwh, 1_000_000),
    };
  });
}

/** Per day: sums over the 48 slots, and the day's price range. */
export function dailyTotals(slots) {
  const days = [];
  for (let i = 0; i < slots.length; i += SLOTS_PER_DAY) {
    const day = slots.slice(i, i + SLOTS_PER_DAY);
    const sum = (k) => day.reduce((a, s) => a + s[k], 0n);
    const prices = day.map((s) => s.priceMicroUsdPerKwh);
    days.push({
      date: day[0].date,
      loadWh: sum("loadWh"),
      hvacWh: sum("hvacWh"),
      pvWh: sum("pvWh"),
      // Before any battery: what the house would have to buy, and could sell.
      shortfallWh: day.reduce((a, s) => a + (s.netLoadWh > 0n ? s.netLoadWh : 0n), 0n),
      surplusWh: day.reduce((a, s) => a + (s.netLoadWh < 0n ? -s.netLoadWh : 0n), 0n),
      minPriceMicroUsdPerKwh: prices.reduce((a, b) => (b < a ? b : a)),
      maxPriceMicroUsdPerKwh: prices.reduce((a, b) => (b > a ? b : a)),
    });
  }
  return days;
}

const month = (date) => Number(date.slice(5, 7));
const by = (k) => (a, b) => (a[k] < b[k] ? -1 : a[k] > b[k] ? 1 : a.date < b.date ? -1 : 1);

/**
 * The representative days. `years` maps a home name to its slots. PV differs
 * between homes only by a constant factor, so home_01's PV ranks the days for
 * all of them; the heating and cooling peaks use the HVAC energy of all six
 * homes together.
 */
export function pickDays(years) {
  const names = Object.keys(years);
  const perHome = Object.fromEntries(names.map((n) => [n, dailyTotals(years[n])]));
  const days = perHome[names[0]].map((d, i) => ({
    date: d.date,
    pvWh: d.pvWh,
    hvacWh: names.reduce((a, n) => a + perHome[n][i].hvacWh, 0n),
    maxPriceMicroUsdPerKwh: d.maxPriceMicroUsdPerKwh,
  }));
  const season = (months) => days.filter((d) => months.includes(month(d.date)));
  const median = (list) => [...list].sort(by("pvWh"))[Math.floor((list.length - 1) / 2)];
  const picks = [
    ["summer-sunny", "most PV of June to August", [...season([6, 7, 8])].sort(by("pvWh")).at(-1)],
    ["winter-cloudy", "least PV of December to February", [...season([12, 1, 2])].sort(by("pvWh"))[0]],
    ["spring-typical", "median PV of March to May", median(season([3, 4, 5]))],
    ["autumn-typical", "median PV of September to November", median(season([9, 10, 11]))],
    ["heating-peak", "most HVAC energy of November to March, six homes together", [...season([11, 12, 1, 2, 3])].sort(by("hvacWh")).at(-1)],
    ["cooling-peak", "most HVAC energy of May to September, six homes together", [...season([5, 6, 7, 8, 9])].sort(by("hvacWh")).at(-1)],
    ["price-spike", "highest half-hour price of the year", [...days].sort(by("maxPriceMicroUsdPerKwh")).at(-1)],
  ];
  // A day picked twice gets one file named for both reasons.
  const labels = (date) => picks.filter((p) => p[2].date === date).map((p) => p[0]).join("-and-");
  return picks.map(([label, why, d]) => ({ label, why, ...d, file: `${d.date}_${labels(d.date)}.csv` }));
}
