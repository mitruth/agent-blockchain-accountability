// The project's data, as the oracles use it: a home's 30-minute slots and
// parameters (data/homes/), and an honest arm's slots and settings
// (data/arms/). Written by `npm run data:extract`.
//
// A series runs on without a break from the first slot of the year, so a
// market day can be laid on any stretch of it: slot k of the day is
// `indexOfDate(date) + k`, continuing into the next date when a day is longer
// than 48 slots.

import fs from "node:fs";
import path from "node:path";
import { ROOT } from "../chain/index.js";

export const DATA_SLOT_SECONDS = 1800;
export const SLOTS_PER_DAY = 48;

function readCsv(file) {
  const [head, ...lines] = fs.readFileSync(file, "utf8").trim().split(/\r?\n/);
  const columns = head.split(",");
  return lines.map((line) => {
    const cells = line.split(",");
    return Object.fromEntries(columns.map((c, i) => [c, /^-?\d+$/.test(cells[i]) ? Number(cells[i]) : cells[i]]));
  });
}

function findFile(dir, prefix) {
  const file = fs.readdirSync(dir).find((f) => f.startsWith(prefix) && f.endsWith("-30min.csv"));
  if (!file) throw new Error(`no ${prefix}*-30min.csv in ${path.relative(ROOT, dir)}`);
  return path.join(dir, file);
}

/** A home's row of data/homes/homes.csv: PV, battery, the dataset's charge limits. */
export function homeParams(home) {
  const row = readCsv(path.join(ROOT, "data", "homes", "homes.csv")).find((h) => h.name === home);
  if (!row) throw new Error(`no ${home} in data/homes/homes.csv`);
  return row;
}

/** A home's slots for a year: date, slot, time, loadWh, pvWh, netLoadWh and the load's parts. */
export function homeSlots(home, year = 2022) {
  return readCsv(findFile(path.join(ROOT, "data", "homes", String(year)), `${home}-`));
}

/** The settings an arm ran with: battery, grid limit, export price share. */
export function armSettings(home = "home_01", year = 2022) {
  return readCsv(path.join(ROOT, "data", "arms", home, String(year), "settings.csv"))[0];
}

/** An arm's slots: state of charge after the slot, charge, discharge, import, export, prices. */
export function armSlots(arm, home = "home_01", year = 2022) {
  return readCsv(findFile(path.join(ROOT, "data", "arms", home, String(year)), `${arm}-`));
}

/** Index of `date`'s first slot in a series. */
export function indexOfDate(slots, date) {
  const i = slots.findIndex((s) => s.date === date && s.slot === 0);
  if (i < 0) throw new Error(`${date} is not in the series`);
  return i;
}

/**
 * Data slots to market slots: each market slot sums `slotSeconds / 1800`
 * consecutive data slots. The market's slot must be a whole number of them.
 */
export function resample(values, slotSeconds) {
  const factor = slotSeconds / DATA_SLOT_SECONDS;
  if (!Number.isInteger(factor) || factor < 1) throw new Error(`a ${slotSeconds} s slot is not whole half-hours`);
  const out = [];
  for (let i = 0; i + factor <= values.length; i += factor) {
    out.push(values.slice(i, i + factor).reduce((a, b) => a + b, 0));
  }
  return out;
}
