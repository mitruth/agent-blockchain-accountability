// S9, delivery reconciliation (spec v0.2 section 5), recomputed from the
// events alone.
//
// The contract keeps a pointer, C, a penalty and a SELL window, and updates
// them in place. The verifier keeps its own copy of each and rebuilds every
// input afresh at every call: the slot's committed and cleared volume from
// the ledger's events (ledger.js), the meter's reading from the oracle's
// accepted readings, and level 1's window by brute force over every placed
// sell and its release (windows.js). It then compares, call by call, the
// slots S9 took in (cn, dn, s, C), its alarms (slot, level, penalty end),
// and, for every submission, its verdict and its C before and after.
//
// A history, in log order:
//
//   { type: "opened" | "fill" | "closed", at, ... }  the ledger's events (ledger.js), with their block time
//   { type: "meter", slotStart, importWh, exportWh }   a reading the oracle accepted
//   { type: "submission", at, account, legs, s9, executed, slots, alarms }
//       legs     [{ kind, side, slot, qtyWh }] as decoded
//       s9       { verdict, valueBefore, valueAfter } as S9 reported
//       slots    [{ slot, cn, dn, s, cusum }] S9's SlotReconciled events, if executed
//       alarms   [{ slot, level, cusum, penaltyUntil }] its DeliveryAlarm events
//   { type: "poke", at, account, slots, alarms }        the same, from a poke
//   { type: "reset", at, account, next }                the owner's reset
//
// config = { k, h, penaltySeconds, escalationSeconds, settlementLagSeconds,
// graceSeconds, maxProcess, window: { kind: "SLIDING", step, buckets, cap },
// origin, slotSeconds, configuredAt }. Wh and C are BigInt; times and slots
// are Number. side: 0 BUY, 1 SELL; kind: 0 PLACE, 1 CANCEL.

import { usedAt, creditApplies } from "./windows.js";
import { replayLedger, positionAt } from "./ledger.js";

export const VERDICT = { EXECUTE: 0, FLAG: 1, REJECT: 2 };

const orderKey = (e) => `${e.market.toLowerCase()}|${e.orderId.toLowerCase()}`;

/** S9's shortfall: s = min(cn, max(0, cn - dn)). */
export function shortfallOf(cn, dn) {
  if (dn <= 0n) return cn;
  return dn < cn ? cn - dn : 0n;
}

/** The level after decay: one step per W_esc since the last alarm. */
export function levelAt(state, cfg, t) {
  if (state.level === 0 || cfg.escalationSeconds === 0) return state.level;
  const steps = t > state.lastAlarmAt ? Math.floor((t - state.lastAlarmAt) / cfg.escalationSeconds) : 0;
  return steps >= state.level ? 0 : state.level - steps;
}

/**
 * What processing at time `t` takes in, by S9's definition, against the
 * ledger and meter as they stand: { state, slots, alarms, blocked }.
 */
export function processAt(state, cfg, t, orders, meters, account) {
  const s = { ...state };
  const first = cfg.configuredAt <= cfg.origin ? 0 : Math.ceil((cfg.configuredAt - cfg.origin) / cfg.slotSeconds);
  if (s.next < first) s.next = first;
  const slots = [];
  const alarms = [];
  let blocked = false;
  while (slots.length < cfg.maxProcess) {
    const slot = s.next;
    const start = cfg.origin + slot * cfg.slotSeconds;
    const settledAt = start + cfg.slotSeconds + cfg.settlementLagSeconds;
    if (t < settledAt) break;
    const p = positionAt(orders, account, slot);
    const cn = p.clearedSellWh > p.clearedBuyWh ? p.clearedSellWh - p.clearedBuyWh : 0n;
    const reconciled = p.committedBuyWh === p.clearedBuyWh && p.committedSellWh === p.clearedSellWh;
    const m = meters.get(start);
    if (!reconciled || (cn > 0n && !m)) {
      blocked = p.committedSellWh > 0n && t >= settledAt + cfg.graceSeconds;
      break;
    }
    const dn = m ? m.exportWh - m.importWh : 0n;
    const sh = shortfallOf(cn, dn);
    const sum = s.cusum + sh;
    const cusum = sum > cfg.k ? sum - cfg.k : 0n;
    slots.push({ slot, cn, dn, s: sh, cusum });
    if (cusum > cfg.h) {
      const level = levelAt(s, cfg, t) >= 1 ? 2 : 1;
      s.level = level;
      s.penaltyUntil = t + cfg.penaltySeconds;
      s.lastAlarmAt = t;
      s.cusum = 0n;
      alarms.push({ slot, level, cusum, penaltyUntil: s.penaltyUntil });
    } else {
      s.cusum = cusum;
    }
    s.next = slot + 1;
  }
  return { state: s, slots, alarms, blocked };
}

/** The submission's placed SELL Wh. */
const sellsOf = (legs) => legs.reduce((a, l) => (l.kind === 0 && l.side === 1 ? a + l.qtyWh : a), 0n);

/** Replay a history. Returns { checked, disagreement, slots, alarms, submissions }. */
export function verifyReconciliation(history, cfg) {
  const ledgerEvents = [];
  const meters = new Map(); // slotStart -> { importWh, exportWh }
  const sells = []; // admissions of level 1's window: one per placed SELL order
  const sellOf = new Map(); // order key -> admission
  let state = { next: 0, cusum: 0n, level: 0, penaltyUntil: 0, lastAlarmAt: 0 };
  let checked = 0;
  let disagreement = null;
  let slotCount = 0;
  let alarmCount = 0;
  let submissions = 0;
  const compare = (event, what, chain, verifier) => {
    checked++;
    if (chain !== verifier) disagreement ??= { event, what, chain, verifier };
  };
  const compareRun = (e, run) => {
    compare(e, "slots taken in", e.slots.length, run.slots.length);
    run.slots.forEach((mine, i) => {
      const theirs = e.slots[i] ?? {};
      for (const f of ["slot", "cn", "dn", "s", "cusum"]) compare(e, `slot ${mine.slot} ${f}`, theirs[f], mine[f]);
    });
    compare(e, "alarms", e.alarms.length, run.alarms.length);
    run.alarms.forEach((mine, i) => {
      const theirs = e.alarms[i] ?? {};
      for (const f of ["slot", "level", "cusum", "penaltyUntil"]) compare(e, `alarm ${f}`, theirs[f], mine[f]);
    });
    slotCount += run.slots.length;
    alarmCount += run.alarms.length;
  };

  for (const e of history) {
    if (e.type === "opened" || e.type === "fill" || e.type === "closed") {
      ledgerEvents.push(e);
      // Every placed SELL is in level 1's window from its placement, and its
      // unfilled rest is given back to that placement's bucket on release.
      if (e.type === "opened" && e.side === 1) {
        const admission = { at: e.at, amount: e.qtyWh, credit: null };
        sells.push(admission);
        sellOf.set(orderKey(e), admission);
      }
      if (e.type === "closed" && e.releasedWh > 0n && sellOf.has(orderKey(e))) {
        const admission = sellOf.get(orderKey(e));
        if (creditApplies(cfg.window, admission.at, e.at)) admission.credit = { at: e.at, amount: e.releasedWh };
      }
      continue;
    }
    if (e.type === "meter") {
      if (!meters.has(e.slotStart)) meters.set(e.slotStart, { importWh: e.importWh, exportWh: e.exportWh });
      continue;
    }
    if (e.type === "reset") {
      const settledUntil = Math.max(0, e.at - cfg.settlementLagSeconds);
      const firstUnsettled = settledUntil >= cfg.origin + cfg.slotSeconds ? Math.floor((settledUntil - cfg.origin) / cfg.slotSeconds) : 0;
      const next = Math.max(state.next, firstUnsettled);
      compare(e, "reset pointer", e.next, next);
      state = { next, cusum: 0n, level: 0, penaltyUntil: 0, lastAlarmAt: 0 };
      continue;
    }

    const { orders, problems } = replayLedger(ledgerEvents);
    if (problems.length) disagreement ??= { ...problems[0], what: `ledger: ${problems[0].what}` };
    const run = processAt(state, cfg, e.at, orders, meters, e.account);

    if (e.type === "poke") {
      compareRun(e, run);
      state = run.state;
      continue;
    }

    // A submission.
    submissions++;
    const amount = sellsOf(e.legs);
    const penalty = e.at < run.state.penaltyUntil;
    const level = levelAt(run.state, cfg, e.at);
    const used = usedAt(cfg.window, sells, e.at);
    let verdict;
    if (amount !== 0n && run.blocked) verdict = VERDICT.REJECT;
    else if (amount !== 0n && penalty && level >= 2) verdict = VERDICT.REJECT;
    else if (amount !== 0n && penalty && level === 1 && used + amount > cfg.window.cap) verdict = VERDICT.REJECT;
    else if (run.alarms.length) verdict = VERDICT.FLAG;
    else verdict = VERDICT.EXECUTE;
    compare(e, "S9 verdict", e.s9.verdict, verdict);
    compare(e, "S9 C before", e.s9.valueBefore, state.cusum);
    compare(e, "S9 C after", e.s9.valueAfter, run.state.cusum);
    if (verdict === VERDICT.REJECT) compare(e, "executed though refused", e.executed, false);

    if (e.executed) {
      compareRun(e, run);
      state = run.state;
    } else {
      compare(e, "slots taken in by a refused submission", e.slots.length, 0);
    }
  }
  return { checked, disagreement, slots: slotCount, alarms: alarmCount, submissions };
}
