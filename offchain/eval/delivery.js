// The delivery simulator (spec v0.2 section 7, decision of 25 October 2026):
// what an honest agent contracts a day ahead, from forecasts, and what the
// meter then measures, once the real sun and load come and the battery tries
// to honour the contracts. S9 needs both; the arms in data/arms/ record only
// what happened, so an agent selling their flows never falls short.
//
// Per slot of a day, from an arm's step log (B2 by default):
//
//   forecast   PV and the fixed load (base load and HVAC) by an exponentially
//              weighted average of the same slot on earlier days, with the
//              arm's own weight (settings.csv, forecastWeightBps), as B2
//              forecasts. The first day has no past: its forecast is exact.
//              Appliance tasks are the agent's own schedule: known.
//   contract   net export planned = PV forecast - load forecast - tasks
//              - the arm's charge + its discharge (the arm's battery schedule
//              is the plan), within the connection's limit. Positive is a
//              SELL, negative a BUY.
//   delivery   the real PV and load. The battery is re-dispatched to make the
//              grid flow equal the contract: it discharges to cover a
//              shortfall and charges a surplus, within its power and state of
//              charge (the Battery class, carried over the whole year). What
//              the connection cannot export is curtailed.
//   meter      the grid flow that results: import and export, whole Wh.
//
// The shortfall is S9's: s = min(cn, max(0, cn - dn)), with cn the contracted
// net export (0 for a buy) and dn the delivered one.

import { Battery } from "../oracle/battery.js";

const BPS = 10_000;

const n = (x) => Number(x);

/** S9's shortfall for one slot: contracted net export `cn` (>= 0), delivered `dn`. */
export function shortfall(cn, dn) {
  if (cn <= 0) return 0;
  return Math.min(cn, Math.max(0, cn - dn));
}

/**
 * The year, slot by slot: [{ date, slot, contractWh, importWh, exportWh,
 * shortfallWh, socWh }]. `slots` is an arm's step log in order (whole days);
 * `settings` its settings.csv row. `oversell`, for the attack: every planned
 * sale is made `1 + oversell` times larger (an agent that believes an
 * inflated state of charge), and the battery tries to deliver it.
 */
export function simulateDelivery(slots, settings, { slotSeconds = 1800, oversell = 0 } = {}) {
  const perDay = Math.round(86_400 / slotSeconds);
  if (slots.length % perDay !== 0) throw new Error(`the log is not whole days of ${perDay} slots`);
  const w = n(settings.forecastWeightBps) / BPS;
  const gridLimitWh = Math.floor((n(settings.gridLimitW) * slotSeconds) / 3600);
  const battery = new Battery(settings, slotSeconds);

  const pvF = new Array(perDay).fill(0);
  const loadF = new Array(perDay).fill(0);
  const out = [];
  for (let d = 0; d * perDay < slots.length; d++) {
    const day = slots.slice(d * perDay, (d + 1) * perDay);
    for (let i = 0; i < perDay; i++) {
      const s = day[i];
      const pv = n(s.pvWh);
      const load = n(s.fixedLoadWh);
      const task = n(s.taskWh);
      // The forecast for today, from the days before.
      const pvHat = d === 0 ? pv : pvF[i];
      const loadHat = d === 0 ? load : loadF[i];

      let planned = pvHat - loadHat - task - n(s.chargeWh) + n(s.dischargeWh);
      if (planned > 0) planned *= 1 + oversell;
      const contractWh = Math.max(-gridLimitWh, Math.min(gridLimitWh, Math.round(planned)));

      // The day as it comes: the battery makes up the difference it can.
      const residual = pv - load - task;
      const need = contractWh - residual; // > 0: the battery must give; < 0: it may take
      let grid = residual;
      if (need > 0) grid += battery.discharge(need);
      else if (need < 0) grid -= battery.charge(-need);
      const exportWh = Math.min(Math.max(0, grid), gridLimitWh);
      const importWh = Math.max(0, -grid);

      out.push({
        date: s.date,
        slot: n(s.slot),
        contractWh,
        importWh,
        exportWh,
        shortfallWh: shortfall(Math.max(0, contractWh), exportWh - importWh),
        socWh: battery.socWh,
      });

      // Tomorrow's forecast takes today in.
      pvF[i] = d === 0 ? pv : w * pv + (1 - w) * pvF[i];
      loadF[i] = d === 0 ? load : w * load + (1 - w) * loadF[i];
    }
  }
  return out;
}

/** The p-th percentile (0..100) of `values`, nearest rank. */
export function percentile(values, p) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.max(1, Math.ceil((p / 100) * sorted.length));
  return sorted[rank - 1];
}

/**
 * S9's upper CUSUM over a series of shortfalls, by its definition: C = max(0,
 * C + s - k), an alarm when C > h, then C = 0. Returns the indexes of the
 * slots that raised an alarm.
 */
export function cusumAlarms(shortfalls, k, h) {
  const alarms = [];
  let c = 0;
  shortfalls.forEach((s, i) => {
    c = Math.max(0, c + s - k);
    if (c > h) {
      alarms.push(i);
      c = 0;
    }
  });
  return alarms;
}
