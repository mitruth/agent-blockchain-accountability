// The price policies, A3T and S7 (spec v0.2 section 5), recomputed from the
// events alone.
//
// From the tariffs the oracle accepted and the orders the gate decoded, the
// verifier works out each placement's band and what it gives away, by its own
// arithmetic: exact fractions compared by cross-multiplication for A3T, not
// the contract's rounded bounds; for S7, every placement kept as an admission
// and the window counted afresh by brute force over all of them
// (windows.js). It then compares A3T's verdict, S7's figures and verdict, and
// every credit with what the chain reported.
//
// A history, in log order:
//
//   { type: "tariff", at, issuedAt, firstSlotStart, slotSeconds, retail, feedIn }
//   { type: "submission", at, leg: { side, slot, qtyWh, price }, a3t, s7, orderId }
//       a3t      whether the chain set A3T's bit
//       s7       { verdict, valueBefore, valueAfter } as the chain reported
//       orderId  set when the order was placed
//   { type: "release", at, orderId, qtyWh, filledWh, credit }
//       credit   { amount, credited } as S7 reported, or null
//
// config = { slotSeconds, maxAge, buyMarkupBps, sellDiscountBps, s7: { soft, window } }
// with window { kind: "SLIDING", step, buckets, cap }. Prices and amounts are
// BigInt; times are seconds (Number). side: 0 BUY, 1 SELL.

import { usedAt, limitAt, creditApplies } from "./windows.js";

const BPS = 10_000n;
const MAX = 2n ** 256n - 1n;
export const VERDICT = { EXECUTE: 0, FLAG: 1, REJECT: 2 };

/** The tariff for the slot starting at `slotStart`, at time `at`, or null. */
export function tariffFor(tariff, slotStart, at, maxAge) {
  if (!tariff || tariff.issuedAt > at || at - tariff.issuedAt > maxAge) return null;
  if (slotStart < tariff.firstSlotStart) return null;
  const offset = slotStart - tariff.firstSlotStart;
  if (offset % tariff.slotSeconds !== 0) return null;
  const i = offset / tariff.slotSeconds;
  if (i >= tariff.retail.length) return null;
  return { retail: tariff.retail[i], feedIn: tariff.feedIn[i] };
}

/**
 * A3T: outside the band, or not judgeable. Compared exactly: a BUY passes when
 * price x 10,000 <= r x (10,000 + beta_b), and price is an integer, which is
 * the floor; a SELL when price x 10,000 >= f x (10,000 - beta_s), the ceiling.
 */
export function outsideBand(t, leg, cfg) {
  if (!t) return true;
  if (leg.side === 0) return leg.price * BPS > t.retail * (BPS + BigInt(cfg.buyMarkupBps));
  return leg.price * BPS < t.feedIn * (BPS - BigInt(cfg.sellDiscountBps));
}

/** S7: what a placement gives away per kWh. */
export function excessOf(t, leg) {
  if (leg.side === 0) return leg.price > t.retail ? leg.price - t.retail : 0n;
  return t.feedIn > leg.price ? t.feedIn - leg.price : 0n;
}

const up = (perKWh, qtyWh) => (perKWh * qtyWh + 999n) / 1000n;

/** Replay a history. Returns { checked, disagreement, placed, credits }. */
export function verifyPrice(history, config) {
  const cfg = config.s7.window;
  let tariff = null;
  const admissions = []; // { at, amount, credit }, one per placement that gave something away
  const byOrder = new Map(); // orderId → { admission, excess, qtyWh }
  let checked = 0;
  let placed = 0;
  let credits = 0;
  let disagreement = null;
  const compare = (event, what, chain, verifier) => {
    checked++;
    if (chain !== verifier) disagreement ??= { event, what, chain, verifier };
  };

  for (const e of history) {
    if (e.type === "tariff") {
      if (!tariff || e.issuedAt > tariff.issuedAt) tariff = e;
      continue;
    }
    if (e.type === "release") {
      const o = byOrder.get(e.orderId);
      if (!o || o.excess === 0n) {
        compare(e, "a credit where nothing was charged", e.credit !== null, false);
        continue;
      }
      const amount = up(o.excess, o.qtyWh) - up(o.excess, e.filledWh);
      if (amount === 0n) {
        compare(e, "a credit of nothing", e.credit !== null, false);
        continue;
      }
      const credited = creditApplies(cfg, o.admission.at, e.at) ? amount : 0n;
      compare(e, "credit asked", e.credit?.amount, amount);
      compare(e, "credit given", e.credit?.credited, credited);
      o.admission.credit = { at: e.at, amount: credited };
      credits++;
      continue;
    }

    // A submission.
    const slotStart = e.leg.slot * config.slotSeconds;
    const t = tariffFor(tariff, slotStart, e.at, config.maxAge);
    const band = outsideBand(t, e.leg, config);
    compare(e, "A3T", e.a3t, band);

    const used = usedAt(cfg, admissions, e.at);
    compare(e, "S7 before", e.s7.valueBefore, used);
    let verdict;
    let amount = 0n;
    if (!t) {
      verdict = VERDICT.REJECT;
      compare(e, "S7 after, unjudged", e.s7.valueAfter, MAX);
    } else {
      amount = up(excessOf(t, e.leg), e.leg.qtyWh);
      compare(e, "S7 after", e.s7.valueAfter, used + amount);
      if (amount === 0n) verdict = VERDICT.EXECUTE;
      else if (used + amount > limitAt(cfg, e.at)) verdict = VERDICT.REJECT;
      else if (used + amount > config.s7.soft) verdict = VERDICT.FLAG;
      else verdict = VERDICT.EXECUTE;
    }
    compare(e, "S7 verdict", e.s7.verdict, verdict);
    compare(e, "placed", e.orderId !== null, !band && verdict !== VERDICT.REJECT);

    if (e.orderId !== null) {
      placed++;
      const excess = t ? excessOf(t, e.leg) : 0n;
      const admission = { at: e.at, amount, credit: null };
      if (amount !== 0n) admissions.push(admission);
      byOrder.set(e.orderId, { admission, excess, qtyWh: e.leg.qtyWh });
    }
  }
  return { checked, disagreement, placed, credits };
}
