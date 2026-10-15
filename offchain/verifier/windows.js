// The five window classes of spec 5.3, computed from their definitions over
// the whole history, by brute force.
//
// Deliberately not the on-chain algorithm (spec 8: "never port the
// Solidity"): no ring of buckets, no running total, no stored mark, no lazy
// reset. Each question is answered from scratch from the list of admissions:
//
//   SLIDING   sum every admission made at or after the window's start time
//   TUMBLING  sum every admission made in the same period
//   REFILL    the closed form of a reflected random walk: the most any run of
//             recent intervals consumed beyond what was refilled meanwhile
//   STREAM, LIFETIME  sum everything
//
// Times are seconds (Number); amounts are BigInt. An admission is
// { at, amount, credit } where `credit` is { at, amount } once a credit was
// given back for it, or null.

export const KINDS = ["SLIDING", "TUMBLING", "REFILL", "STREAM", "LIFETIME"];

const floorDiv = (a, b) => Math.floor(a / b);

/** The first second a sliding window still holds at time t. */
export function slidingStart(cfg, t) {
  return (floorDiv(t, cfg.step) - cfg.buckets + 1) * cfg.step;
}

/** Which period of a tumbling window t falls in. Time before the anchor belongs to the first period. */
export function period(cfg, t) {
  return t > cfg.anchor ? floorDiv(t - cfg.anchor, cfg.step) : 0;
}

/** Whether an amount consumed at `at` still counts at time `t`. */
export function stillCounts(cfg, at, t) {
  if (at > t) return false;
  if (cfg.kind === "SLIDING") return at >= slidingStart(cfg, t);
  if (cfg.kind === "TUMBLING") return period(cfg, at) === period(cfg, t);
  return true;
}

/**
 * Whether a credit made at `t`, for an amount consumed at `at`, is given back.
 * REFILL: only while no refill has happened since the consumption, that is,
 * within the same interval; any other class: while the amount still counts.
 */
export function creditApplies(cfg, at, t) {
  if (at > t) return false;
  if (cfg.kind === "REFILL") return floorDiv(at, cfg.step) === floorDiv(t, cfg.step);
  return stillCounts(cfg, at, t);
}

/** What the window allows at time t. */
export function limitAt(cfg, t) {
  if (cfg.kind !== "STREAM") return cfg.cap;
  const intervals = t > cfg.anchor ? BigInt(floorDiv(t - cfg.anchor, cfg.step)) : 0n;
  const unlocked = cfg.initial + intervals * cfg.rate;
  return unlocked < cfg.cap ? unlocked : cfg.cap;
}

/** Every change to the count up to t: +amount when admitted, -amount when a credit was given back. */
function deltas(admissions, t) {
  const out = [];
  for (const a of admissions) {
    if (a.at <= t) out.push({ at: a.at, amount: a.amount });
    if (a.credit && a.credit.at <= t) out.push({ at: a.credit.at, amount: -a.credit.amount });
  }
  return out;
}

/**
 * REFILL's count at t, in closed form. With A_j the net change in interval j,
 * the count at the start of interval I is
 *
 *     max(0, max over k < I of (A_k + ... + A_(I-1) - rate * (I - k)))
 *
 * (the reflected random walk, as for the waiting time of a queue), and within
 * interval I the count is that plus the changes so far in I.
 */
function refillUsed(cfg, admissions, t) {
  const I = floorDiv(t, cfg.step);
  const changes = deltas(admissions, t);
  let within = 0n;
  const starts = new Set();
  for (const d of changes) {
    const j = floorDiv(d.at, cfg.step);
    if (j === I) within += d.amount;
    else starts.add(j);
  }
  let best = 0n;
  for (const k of starts) {
    let run = 0n;
    for (const d of changes) {
      const j = floorDiv(d.at, cfg.step);
      if (j >= k && j < I) run += d.amount;
    }
    const left = run - BigInt(I - k) * cfg.rate;
    if (left > best) best = left;
  }
  return best + within;
}

/** What the window counts as consumed at time t. */
export function usedAt(cfg, admissions, t) {
  if (cfg.kind === "REFILL") return refillUsed(cfg, admissions, t);
  let sum = 0n;
  for (const a of admissions) {
    if (!stillCounts(cfg, a.at, t)) continue;
    sum += a.amount;
    if (a.credit && a.credit.at <= t) sum -= a.credit.amount;
  }
  return sum;
}

/** Whether two configurations have the same shape; a change of shape starts a window afresh. */
export function sameShape(a, b) {
  return a.kind === b.kind && a.step === b.step && a.buckets === b.buckets && a.anchor === b.anchor;
}
