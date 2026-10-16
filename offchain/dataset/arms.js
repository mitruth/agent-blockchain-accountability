// Reads the honest controller arms of the HEMS simulation, in the sibling
// project Demo_PlanApplyEvaluate, and turns them into integer tables: Wh, W,
// basis points and micro-USD, each rounded once.
//
//   readSettings(dir, home)       the battery, grid and price settings the arms ran with
//   readTasks(dir, home)          the appliance tasks, with their time windows
//   readStepLog(dir, home, arm)   one arm's 48 slots a day
//   readDaily(dir, home, arm)     one arm's daily results, as the simulation computed them
//
// The source counts the steps of a day from 1; here a slot counts from 0, as
// in data/homes/.

import fs from "node:fs";
import path from "node:path";
import { ROOT } from "../chain/paths.js";
import { readCsv } from "./csv.js";
import { scaled } from "./decimal.js";
import { SLOTS_PER_DAY } from "./index.js";

/** Where the arms live: the data folder of the sibling project. */
export const ARMS_DIR = path.join(ROOT, "..", "Demo_PlanApplyEvaluate", "data");

/**
 * The arms extracted by default: every controller that ran for real. A0 to A2
 * are left out while their runs are mock echoes of B0 and B2.
 */
export const ARMS = ["B_null", "B0", "B0star", "B1", "B2", "B2r", "B2nn"];

const wh = (v) => scaled(v, 1000);
const bps = (v) => scaled(v, 10_000);
const micro = (v) => scaled(v, 1_000_000);

/** `processed/eval/<home>/params.json`, as integers. */
export function readSettings(dir, home) {
  const p = JSON.parse(fs.readFileSync(path.join(dir, "processed", "eval", home, "params.json"), "utf8"));
  const n = (k) => {
    if (typeof p[k] !== "number") throw new Error(`params.json: ${k} missing`);
    return String(p[k]);
  };
  if (Number(n("delta_hours")) !== 0.5) throw new Error("params.json: the slot is not 30 minutes");
  return {
    batteryCapacityWh: wh(n("E_cap")),
    batteryPowerW: wh(n("P_bat")),
    etaChargeBps: bps(n("eta_c")),
    etaDischargeBps: bps(n("eta_d")),
    socMinBps: bps(n("s_min")),
    socMaxBps: bps(n("s_max")),
    socInitialBps: bps(n("soc_init")),
    gridLimitW: wh(n("P_conn")),
    exportPriceShareBps: bps(n("phi")),
    wearMicroUsdPerCycle: micro(n("c_deg")),
    forecastWeightBps: bps(n("alpha")),
    slotMinutes: 30,
  };
}

/** `processed/eval/<home>/tasks.csv`: a task may run from `earliestSlot` to `lastSlot`, both included. */
export function readTasks(dir, home) {
  return readCsv(path.join(dir, "processed", "eval", home, "tasks.csv")).map((t) => ({
    date: t.day,
    taskId: t.task_id,
    earliestSlot: Number(t.earliest_step) - 1,
    lastSlot: Number(t.deadline_step) - 1,
    durationSlots: Number(t.duration_steps),
    energyWh: wh(t.energy_kwh),
    slotEnergyWh: wh(t.step_energy_kwh),
  }));
}

const hhmm = (slot) => `${String(Math.floor(slot / 2)).padStart(2, "0")}:${slot % 2 ? "30" : "00"}`;

/** `outputs/eval/<home>/<arm>/step_log.csv`. */
export function readStepLog(dir, home, arm) {
  const rows = readCsv(path.join(dir, "outputs", "eval", home, arm, "step_log.csv"));
  if (rows.length % SLOTS_PER_DAY) throw new Error(`${arm}: ${rows.length} rows is not whole days`);
  return rows.map((r, i) => {
    const slot = Number(r.day_step) - 1;
    if (Number(r.t) !== i || slot !== i % SLOTS_PER_DAY) throw new Error(`${arm}: row ${i} is step ${r.t}, day step ${r.day_step}`);
    return {
      date: r.day, slot, time: hhmm(slot),
      socBps: bps(r.soc),
      chargeWh: wh(r.e_ch),
      dischargeWh: wh(r.e_dis),
      taskWh: wh(r.e_task),
      pvWh: wh(r.pv),
      fixedLoadWh: wh(r.load_fixed),
      netWh: wh(r.net),
      importWh: wh(r.imp),
      exportWh: wh(r.exp),
      curtailedWh: wh(r.curtailed),
      importPriceMicroUsdPerKwh: micro(r.price_imp),
      exportPriceMicroUsdPerKwh: micro(r.price_exp),
      costMicroUsd: micro(r.cost),
      runningTasks: r.running_tasks ?? "",
    };
  });
}

/** `outputs/eval/<home>/<arm>/results_daily.csv`, and the annual line. */
export function readDaily(dir, home, arm) {
  const map = (r) => ({
    arm,
    date: r.date,
    costMicroUsd: micro(r.cost),
    importWh: wh(r.import),
    exportWh: wh(r.export),
    curtailedWh: wh(r.curtailed),
    selfConsumptionBps: bps(r.scr),
    selfSufficiencyBps: bps(r.self_sufficiency),
    peakImportW: wh(r.peak_import_kw),
    cyclesMilli: scaled(r.cycles, 1000),
    tasksMissed: Number(r.tasks_missed),
  });
  const base = path.join(dir, "outputs", "eval", home, arm);
  return {
    daily: readCsv(path.join(base, "results_daily.csv")).map(map),
    annual: readCsv(path.join(base, "results_annual.csv")).map(map)[0],
  };
}
