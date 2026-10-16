// npm run data:extract                         2022, from the dataset folder at the root
// node offchain/dataset/cli.js --year 2023     another year
// node offchain/dataset/cli.js --source <dir> --out <dir>
//
// Reads Dan's raw HEMS dataset (git-ignored) and writes data/homes/: the
// homes' parameters, a year of 30-minute slots per home, the prices, daily
// totals and a few representative days. Same input, same files: nothing in
// the output depends on when it ran.

import fs from "node:fs";
import path from "node:path";
import { ROOT } from "../chain/paths.js";
import { SOURCE_DIR, readHomes, readYear, dailyTotals, pickDays } from "./index.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const source = path.resolve(option("source", SOURCE_DIR));
const year = Number(option("year", 2022));
const out = path.resolve(option("out", path.join(ROOT, "data", "homes")));

function writeCsv(file, columns, rows) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const lines = [columns.join(","), ...rows.map((r) => columns.map((c) => String(r[c])).join(","))];
  fs.writeFileSync(file, lines.join("\n") + "\n");
  console.log(`  ${path.relative(ROOT, file).replaceAll("\\", "/")}  ${rows.length} rows`);
}

if (!fs.existsSync(source)) {
  console.error(`No dataset at ${source}. Pass --source <dir>.`);
  process.exit(1);
}

console.log(`Reading ${path.relative(ROOT, source) || source}, year ${year} ...`);
const homes = readHomes(source);
const years = Object.fromEntries(homes.map((h) => [h.name, readYear(source, h, year)]));

// One price signal for every home: checked, then written once.
const first = years[homes[0].name];
for (const h of homes) {
  const slots = years[h.name];
  if (slots.length !== first.length || slots.some((s, i) => s.priceMicroUsdPerKwh !== first[i].priceMicroUsdPerKwh || s.date !== first[i].date)) {
    throw new Error(`${h.name}: prices or dates differ from ${homes[0].name}`);
  }
}

const yearDir = path.join(out, String(year));
const fileOf = (h) => `${h.name}-${h.householdType}-30min.csv`;

writeCsv(path.join(out, "homes.csv"), [
  "homeId", "name", "householdType", "people", "houseAreaM2", "pvCapacityW",
  "batteryCapacityWh", "batteryPowerW", "socInitialBps", "socMinBps", "socMaxBps", "etaChargeBps", "etaDischargeBps",
], homes);

writeCsv(path.join(yearDir, "prices-30min.csv"), ["date", "slot", "time", "priceMicroUsdPerKwh"], first);

for (const h of homes) {
  writeCsv(path.join(yearDir, fileOf(h)), [
    "date", "slot", "time", "baseLoadWh", "appliancesWh", "hvacWh", "loadWh", "pvWh", "netLoadWh",
  ], years[h.name]);
}

writeCsv(path.join(yearDir, "daily-totals.csv"), [
  "name", "date", "loadWh", "hvacWh", "pvWh", "shortfallWh", "surplusWh", "minPriceMicroUsdPerKwh", "maxPriceMicroUsdPerKwh",
], homes.flatMap((h) => dailyTotals(years[h.name]).map((d) => ({ name: h.name, ...d }))));

const days = pickDays(years);
// The days folder holds only this run's picks.
fs.rmSync(path.join(yearDir, "days"), { recursive: true, force: true });
writeCsv(path.join(yearDir, "days", "index.csv"),
  ["file", "date", "label", "why", "pvWhHome01", "hvacWhSixHomes", "maxPriceMicroUsdPerKwh"],
  days.map((d) => ({ ...d, why: `"${d.why}"`, pvWhHome01: d.pvWh, hvacWhSixHomes: d.hvacWh })));
for (const d of days.filter((d, i) => days.findIndex((e) => e.file === d.file) === i)) {
  const rows = homes.flatMap((h) =>
    years[h.name].filter((s) => s.date === d.date).map((s) => ({ name: h.name, ...s })));
  writeCsv(path.join(yearDir, "days", d.file), [
    "name", "date", "slot", "time", "loadWh", "pvWh", "netLoadWh", "priceMicroUsdPerKwh",
  ], rows);
}
console.log("Done.");
