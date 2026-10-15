// The guarantees of spec 5.3, checked empirically over every interval of the
// history, not only bucket-aligned ones.
//
// The amount admitted in an interval [s, t] is what was admitted at times in
// [s, t], less what was given back for those admissions by time t. It only
// grows at an admission, so it is enough to look at intervals that end at an
// admission and start at one.

import { slidingStart } from "./windows.js";

/** Net amount admitted in [admissions[i].at, admissions[j].at], as of admissions[j].at. */
function netBetween(admissions, i, j) {
  const t = admissions[j].at;
  let sum = 0n;
  for (let m = i; m <= j; m++) {
    const a = admissions[m];
    sum += a.amount;
    if (a.credit && a.credit.at <= t) sum -= a.credit.amount;
  }
  return sum;
}

/**
 * The most admitted in any interval no longer than `length` seconds.
 * Returns { amount, from, to } (times of the interval's ends).
 */
export function maxInAnyInterval(admissions, length) {
  let best = { amount: 0n, from: null, to: null };
  for (let j = 0; j < admissions.length; j++) {
    for (let i = j; i >= 0 && admissions[j].at - admissions[i].at <= length; i--) {
      const amount = netBetween(admissions, i, j);
      if (amount > best.amount) best = { amount, from: admissions[i].at, to: admissions[j].at };
    }
  }
  return best;
}

/**
 * A sliding window's two guarantees, for window W = n * b:
 *
 *   G1  any interval of length <= W - b admits at most the cap
 *   G2  an interval of length <= W admits at most the cap plus what it holds
 *       of one bucket, the bucket that has just left the window
 *
 * Returns { g1: {holds, worst}, g2: {holds, worst} }; `worst` is the interval
 * that came closest, or the first that broke the guarantee.
 */
export function slidingGuarantees(cfg, admissions) {
  const W = cfg.buckets * cfg.step;
  const g1 = { holds: true, worst: { amount: 0n } };
  const g2 = { holds: true, worst: { excess: 0n } };

  for (let j = 0; j < admissions.length; j++) {
    const t = admissions[j].at;
    const start = slidingStart(cfg, t);
    for (let i = j; i >= 0 && t - admissions[i].at <= W; i--) {
      const s = admissions[i].at;
      const amount = netBetween(admissions, i, j);

      if (t - s <= W - cfg.step) {
        if (amount > g1.worst.amount) g1.worst = { amount, from: s, to: t };
        if (amount > cfg.cap && g1.holds) {
          g1.holds = false;
          g1.worst = { amount, from: s, to: t };
        }
      }

      // What the interval holds from outside the window at t: all of it must
      // lie in a single bucket, and the rest must fit under the cap.
      let outside = 0n;
      const outsideBuckets = new Set();
      for (let m = i; m <= j; m++) {
        const a = admissions[m];
        if (a.at >= start) continue;
        outside += a.amount - (a.credit && a.credit.at <= t ? a.credit.amount : 0n);
        outsideBuckets.add(Math.floor(a.at / cfg.step));
      }
      const excess = amount - cfg.cap;
      if (excess > g2.worst.excess) g2.worst = { excess, amount, from: s, to: t, outside };
      if ((amount - outside > cfg.cap || outsideBuckets.size > 1) && g2.holds) {
        g2.holds = false;
        g2.worst = { excess, amount, from: s, to: t, outside, buckets: outsideBuckets.size };
      }
    }
  }
  return { g1, g2 };
}
