// S10, operating-envelope compliance (spec v0.2 section 5), recomputed from
// the events alone.
//
// Before each submission the verifier rebuilds every order of the account
// from the ledger's events (ledger.js) and sums the slot's committed net
// position afresh; it takes the envelope in force from the envelopes the
// oracle accepted (the latest, if fresh and covering the slot), or the static
// limit; and it works out each touched slot's use and excess before and after
// the submission's decoded legs. It compares S10's verdict and figures.
//
// A history, in log order:
//
//   { type: "opened" | "fill" | "closed", ... }   the ledger's events, as ledger.js reads them
//   { type: "envelope", issuedAt, firstSlotStart, slotSeconds, exportLimitWh: [], importLimitWh: [] }
//   { type: "submission", at, account, legs, s10, executed }
//       legs  [{ kind, side, slot, qtyWh }]; kind 0 PLACE, 1 CANCEL
//       s10   { verdict, valueBefore, valueAfter, soft, hard } as the chain reported
//
// config = { connectionW, softBps, slotSeconds, origin, maxAge }. Wh BigInt;
// times and slots Number; side 0 BUY, 1 SELL.

import { replayLedger, positionAt } from "./ledger.js";

export const VERDICT = { EXECUTE: 0, FLAG: 1, REJECT: 2 };
const BPS = 10_000n;
const UNBOUNDED = 2n ** 256n - 1n;

/** The limits for the slot starting at `slotStart` at time `at`: the envelope's, or the static ones. */
export function limitsFor(envelope, slotStart, at, config) {
  const stat = (BigInt(config.connectionW) * BigInt(config.slotSeconds)) / 3600n;
  const fallback = { exportWh: stat, importWh: stat, fromEnvelope: false };
  if (!envelope || envelope.issuedAt > at || at - envelope.issuedAt > config.maxAge) return fallback;
  if (slotStart < envelope.firstSlotStart) return fallback;
  const offset = slotStart - envelope.firstSlotStart;
  if (offset % envelope.slotSeconds !== 0) return fallback;
  const i = offset / envelope.slotSeconds;
  if (i >= envelope.exportLimitWh.length) return fallback;
  return { exportWh: envelope.exportLimitWh[i], importWh: envelope.importLimitWh[i], fromEnvelope: true };
}

/** Use of a limit, in bps, rounded up; unbounded against a zero limit. */
export function useOf(ne, limits) {
  if (ne === 0n) return 0n;
  const magnitude = ne > 0n ? ne : -ne;
  const limit = ne > 0n ? limits.exportWh : limits.importWh;
  if (limit === 0n) return UNBOUNDED;
  return (magnitude * BPS + limit - 1n) / limit;
}

/** Wh beyond the limit the position faces. */
export function excessOf(ne, limits) {
  if (ne > 0n) return ne > limits.exportWh ? ne - limits.exportWh : 0n;
  return -ne > limits.importWh ? -ne - limits.importWh : 0n;
}

/** S10's judgement of `legs` against the orders and the envelope as they stand. */
export function judge(orders, account, legs, envelope, at, config) {
  const change = new Map(); // slot -> net export the legs add
  for (const l of legs) {
    const qty = l.kind === 0 ? l.qtyWh : -l.qtyWh;
    change.set(l.slot, (change.get(l.slot) ?? 0n) + (l.side === 1 ? qty : -qty));
  }
  let before = 0n;
  let after = 0n;
  let worse = false;
  let flag = false;
  for (const [slot, delta] of change) {
    const p = positionAt(orders, account, slot);
    const ne = p.committedSellWh - p.committedBuyWh;
    const ne2 = ne + delta;
    const limits = limitsFor(envelope, config.origin + slot * config.slotSeconds, at, config);
    const u = useOf(ne, limits);
    const u2 = useOf(ne2, limits);
    if (u > before) before = u;
    if (u2 > after) after = u2;
    if (excessOf(ne2, limits) > excessOf(ne, limits)) worse = true;
    if (u2 > BigInt(config.softBps) && u2 > u) flag = true;
  }
  return { before, after, verdict: worse ? VERDICT.REJECT : flag ? VERDICT.FLAG : VERDICT.EXECUTE };
}

/** Replay a history. Returns { checked, disagreement, submissions, refused, flagged }. */
export function verifyEnvelope(history, config) {
  const ledgerEvents = [];
  let envelope = null;
  let checked = 0;
  let disagreement = null;
  let submissions = 0;
  let refused = 0;
  let flagged = 0;
  const compare = (event, what, chain, verifier) => {
    checked++;
    if (chain !== verifier) disagreement ??= { event, what, chain, verifier };
  };
  for (const e of history) {
    if (e.type === "envelope") {
      if (!envelope || e.issuedAt > envelope.issuedAt) envelope = e;
      continue;
    }
    if (e.type !== "submission") {
      ledgerEvents.push(e);
      continue;
    }
    submissions++;
    const { orders, problems } = replayLedger(ledgerEvents);
    if (problems.length) disagreement ??= { ...problems[0], what: `ledger: ${problems[0].what}` };
    const j = judge(orders, e.account, e.legs, envelope, e.at, config);
    compare(e, "S10 verdict", e.s10.verdict, j.verdict);
    compare(e, "S10 use before", e.s10.valueBefore, j.before);
    compare(e, "S10 use after", e.s10.valueAfter, j.after);
    compare(e, "S10 soft", e.s10.soft, BigInt(config.softBps));
    compare(e, "S10 hard", e.s10.hard, BPS);
    if (j.verdict === VERDICT.REJECT) {
      refused++;
      compare(e, "executed though refused", e.executed, false);
    }
    if (j.verdict === VERDICT.FLAG) flagged++;
  }
  return { checked, disagreement, submissions, refused, flagged };
}
