// npm run data:extract                         both parts, with the sources where Dan keeps them
// node offchain/dataset/cli.js --only homes    the six homes only (needs the raw dataset)
// node offchain/dataset/cli.js --only arms     the controller arms only (needs Demo_PlanApplyEvaluate)
// node offchain/dataset/cli.js --year 2023     another year of the homes
// node offchain/dataset/cli.js --arms B0,B2    other arms, by their folder names
// node offchain/dataset/cli.js --source <dir> --arms-source <dir> --out <dir>
//
// Two parts, each written from its own source:
//   data/homes/  from the raw HEMS dataset (git-ignored, at the root): the
//                homes' parameters, a year of 30-minute slots per home, the
//                prices, daily totals and representative days;
//   data/arms/   from the sibling project Demo_PlanApplyEvaluate: what each
//                honest controller did, slot by slot, with the settings it
//                ran with, the appliance tasks and its daily results.
// When both run, the arms are checked against the homes. Same input, same
// files: nothing in the output depends on when it ran.

import fs from "node:fs";
import path from "node:path";
import { ROOT } from "../chain/paths.js";
import { writeCsv } from "./csv.js";
import { SOURCE_DIR, readHomes, readYear, dailyTotals, pickDays } from "./index.js";
import { ARMS_DIR, ARMS, readSettings, readTasks, readStepLog, readDaily } from "./arms.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const only = option("only", "both");
const out = path.resolve(option("out", path.join(ROOT, "data")));
const show = (p) => path.relative(ROOT, p).replaceAll("\\", "/") || p;
const write = (file, columns, rows) => console.log(`  ${show(file)}  ${writeCsv(file, columns, rows)} rows`);

function need(dir, what) {
  if (fs.existsSync(dir)) return;
  console.error(`No ${what} at ${dir}.`);
  process.exit(1);
}

// ---------------------------------------------------------------- the homes

function extractHomes() {
  const source = path.resolve(option("source", SOURCE_DIR));
  const year = Number(option("year", 2022));
  need(source, "HEMS dataset (pass --source <dir>)");
  console.log(`Homes: reading ${show(source)}, year ${year} ...`);
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

  const dir = path.join(out, "homes");
  const yearDir = path.join(dir, String(year));
  write(path.join(dir, "homes.csv"), [
    "homeId", "name", "householdType", "people", "houseAreaM2", "pvCapacityW",
    "batteryCapacityWh", "batteryPowerW", "socInitialBps", "socMinBps", "socMaxBps", "etaChargeBps", "etaDischargeBps",
  ], homes);
  write(path.join(yearDir, "prices-30min.csv"), ["date", "slot", "time", "priceMicroUsdPerKwh"], first);
  for (const h of homes) {
    write(path.join(yearDir, `${h.name}-${h.householdType}-30min.csv`), [
      "date", "slot", "time", "baseLoadWh", "appliancesWh", "hvacWh", "loadWh", "pvWh", "netLoadWh",
    ], years[h.name]);
  }
  write(path.join(yearDir, "daily-totals.csv"), [
    "name", "date", "loadWh", "hvacWh", "pvWh", "shortfallWh", "surplusWh", "minPriceMicroUsdPerKwh", "maxPriceMicroUsdPerKwh",
  ], homes.flatMap((h) => dailyTotals(years[h.name]).map((d) => ({ name: h.name, ...d }))));

  const days = pickDays(years);
  // The days folder holds only this run's picks.
  fs.rmSync(path.join(yearDir, "days"), { recursive: true, force: true });
  write(path.join(yearDir, "days", "index.csv"),
    ["file", "date", "label", "why", "pvWhHome01", "hvacWhSixHomes", "maxPriceMicroUsdPerKwh"],
    days.map((d) => ({ ...d, why: `"${d.why}"`, pvWhHome01: d.pvWh, hvacWhSixHomes: d.hvacWh })));
  for (const d of days.filter((d, i) => days.findIndex((e) => e.file === d.file) === i)) {
    const rows = homes.flatMap((h) =>
      years[h.name].filter((s) => s.date === d.date).map((s) => ({ name: h.name, ...s })));
    write(path.join(yearDir, "days", d.file), [
      "name", "date", "slot", "time", "loadWh", "pvWh", "netLoadWh", "priceMicroUsdPerKwh",
    ], rows);
  }
  return years;
}

// ----------------------------------------------------------------- the arms

/** The file name says what the controller is; the folder name stays first. */
const ARM_NAMES = {
  B_null: "no-battery",
  B0: "rules",
  B0star: "tuned-rules",
  B1: "perfect-foresight",
  B2: "forecast-plan",
  B2r: "tuned-forecast-plan",
  B2nn: "mlp-forecast-plan",
};
const armFile = (arm) => `${arm}${ARM_NAMES[arm] ? "-" + ARM_NAMES[arm] : ""}-30min.csv`;

function extractArms(homeYears) {
  const source = path.resolve(option("arms-source", ARMS_DIR));
  const home = option("home", "home_01");
  const arms = option("arms", ARMS.join(",")).split(",");
  need(source, "Demo_PlanApplyEvaluate data folder (pass --arms-source <dir>)");
  console.log(`Arms: reading ${show(source)}, ${home}, ${arms.join(" ")} ...`);

  const settings = readSettings(source, home);
  const tasks = readTasks(source, home);
  const logs = Object.fromEntries(arms.map((a) => [a, readStepLog(source, home, a)]));
  const results = arms.map((a) => readDaily(source, home, a));

  const years = new Set(Object.values(logs).flatMap((l) => [l[0].date.slice(0, 4), l.at(-1).date.slice(0, 4)]));
  if (years.size !== 1) throw new Error(`the arms span ${[...years].join(", ")}, not one year`);
  const year = [...years][0];
  const dir = path.join(out, "arms", home, year);
  fs.rmSync(dir, { recursive: true, force: true });

  write(path.join(dir, "settings.csv"), Object.keys(settings), [settings]);
  write(path.join(dir, "appliance-tasks.csv"),
    ["date", "taskId", "earliestSlot", "lastSlot", "durationSlots", "energyWh", "slotEnergyWh"], tasks);
  for (const a of arms) {
    write(path.join(dir, armFile(a)), [
      "date", "slot", "time", "socBps", "chargeWh", "dischargeWh", "taskWh", "pvWh", "fixedLoadWh", "netWh",
      "importWh", "exportWh", "curtailedWh", "importPriceMicroUsdPerKwh", "exportPriceMicroUsdPerKwh", "costMicroUsd", "runningTasks",
    ], logs[a]);
  }
  const daily = ["arm", "date", "costMicroUsd", "importWh", "exportWh", "curtailedWh", "selfConsumptionBps",
    "selfSufficiencyBps", "peakImportW", "cyclesMilli", "tasksMissed"];
  write(path.join(dir, "daily-results.csv"), daily, results.flatMap((r) => r.daily));
  write(path.join(dir, "annual-results.csv"), daily.filter((c) => c !== "date"), results.map((r) => r.annual));

  check(logs, results, settings, homeYears?.[home]);
}

/** Checks the arms against themselves and, when read in the same run, against the homes. */
function check(logs, results, settings, homeSlots) {
  const fails = [];
  const ok = (cond, msg) => { if (!cond) fails.push(msg); };
  const abs = (x) => (x < 0n ? -x : x);
  const first = Object.values(logs)[0];
  for (const [arm, log] of Object.entries(logs)) {
    ok(log.length === first.length && log.every((s, i) => s.date === first[i].date && s.importPriceMicroUsdPerKwh === first[i].importPriceMicroUsdPerKwh),
      `${arm}: dates or prices differ from ${Object.keys(logs)[0]}`);
    // The export price is a fixed share of the import price.
    const share = settings.exportPriceShareBps;
    ok(log.every((s) => abs(s.exportPriceMicroUsdPerKwh * 10_000n - s.importPriceMicroUsdPerKwh * share) <= 10_000n),
      `${arm}: the export price is not ${share} bps of the import price`);
    ok(log.every((s) => s.socBps >= settings.socMinBps && s.socBps <= settings.socMaxBps), `${arm}: state of charge out of bounds`);
    // Slot sums against the simulation's own daily figures: rounding allows 1 Wh per slot.
    const daily = results.find((r) => r.daily[0].arm === arm).daily;
    let worst = 0n;
    daily.forEach((d, k) => {
      const day = log.slice(k * 48, k * 48 + 48);
      ok(day[0].date === d.date, `${arm}: day ${k} is ${day[0].date} in the log, ${d.date} in the results`);
      for (const [a, b] of [["importWh", "importWh"], ["exportWh", "exportWh"]]) {
        const diff = abs(day.reduce((x, s) => x + s[a], 0n) - d[b]);
        if (diff > worst) worst = diff;
      }
    });
    ok(worst <= 48n, `${arm}: a day's import or export differs from its slots by ${worst} Wh`);
    if (homeSlots) {
      ok(log.length === homeSlots.length, `${arm}: ${log.length} slots, the home has ${homeSlots.length}`);
      ok(log.every((s, i) => s.date === homeSlots[i].date && s.slot === homeSlots[i].slot), `${arm}: slots out of step with data/homes`);
      ok(log.every((s, i) => s.importPriceMicroUsdPerKwh === homeSlots[i].priceMicroUsdPerKwh), `${arm}: import price differs from data/homes`);
      ok(log.every((s, i) => s.pvWh === homeSlots[i].pvWh), `${arm}: PV differs from data/homes`);
      // The arms schedule the appliances themselves, except B_null, which takes them as they came.
      const fixed = (h) => (arm === "B_null" ? h.loadWh : h.baseLoadWh + h.hvacWh);
      ok(log.every((s, i) => abs(s.fixedLoadWh - fixed(homeSlots[i])) <= 1n), `${arm}: fixed load differs from data/homes by more than 1 Wh`);
    }
  }
  const against = homeSlots ? ", and against data/homes" : "";
  if (fails.length) {
    console.error(`Checks failed:\n  ${fails.join("\n  ")}`);
    process.exit(1);
  }
  console.log(`  checked: the arms agree with each other and with their daily results${against}`);
}

let homeYears;
if (only === "both" || only === "homes") homeYears = extractHomes();
if (only === "both" || only === "arms") extractArms(homeYears);
console.log("Done.");
