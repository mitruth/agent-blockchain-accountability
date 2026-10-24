// S8, the same-slot round-trip quota (spec v0.2 section 5), recomputed from the
// events alone.
//
// The contract reads the ledger's running sums and counts into a ring of
// buckets. The verifier keeps neither: before each submission it rebuilds
// every order of the account from the ledger's events (ledger.js), sums the
// slot's committed buy and sell afresh, and works out what the submission's
// decoded legs add to min(buy, sell) on each slot they touch. Every
// placement it admitted is kept, and the window is counted afresh by brute
// force over all of them (windows.js). It then compares S8's figures and
// verdict with what the chain reported.
//
// A history, in log order:
//
//   { type: "opened" | "fill" | "closed", ... }   the ledger's events, as ledger.js reads them
//   { type: "submission", at, account, legs, s8, executed }
//       legs      [{ kind, side, slot, qtyWh }] as the gate decoded them; kind 0 PLACE, 1 CANCEL
//       s8        { verdict, valueBefore, valueAfter, soft, hard } as the chain reported
//       executed  whether the submission went to the market
//
// config = { soft, window: { kind: "SLIDING", step, buckets, cap } }. Amounts
// are BigInt; times are seconds (Number). side: 0 BUY, 1 SELL.

import { usedAt, limitAt } from "./windows.js";
import { replayLedger, positionAt } from "./ledger.js";

export const VERDICT = { EXECUTE: 0, FLAG: 1, REJECT: 2 };

const min = (a, b) => (a < b ? a : b);

/** What `legs` add to the account's round trips, against the orders as they stand. */
export function roundTripAdded(orders, account, legs) {
  const change = new Map(); // slot → { buy, sell }
  for (const leg of legs) {
    const d = change.get(leg.slot) ?? { buy: 0n, sell: 0n };
    const qty = leg.kind === 0 ? leg.qtyWh : -leg.qtyWh;
    if (leg.side === 0) d.buy += qty;
    else d.sell += qty;
    change.set(leg.slot, d);
  }
  let added = 0n;
  for (const [slot, d] of change) {
    const p = positionAt(orders, account, slot);
    const before = min(p.committedBuyWh, p.committedSellWh);
    const after = min(p.committedBuyWh + d.buy, p.committedSellWh + d.sell);
    if (after > before) added += after - before;
  }
  return added;
}

/** Replay a history. Returns { checked, disagreement, placed, counted }. */
export function verifyRoundTrip(history, config) {
  const cfg = config.window;
  const ledgerEvents = [];
  const admissions = []; // { at, amount, credit: null }; S8 gives nothing back
  let checked = 0;
  let placed = 0;
  let counted = 0;
  let disagreement = null;
  const compare = (event, what, chain, verifier) => {
    checked++;
    if (chain !== verifier) disagreement ??= { event, what, chain, verifier };
  };

  for (const e of history) {
    if (e.type !== "submission") {
      ledgerEvents.push(e);
      continue;
    }
    const { orders, problems } = replayLedger(ledgerEvents);
    if (problems.length > 0) disagreement ??= { ...problems[0], what: `ledger: ${problems[0].what}` };

    const amount = roundTripAdded(orders, e.account, e.legs);
    const used = usedAt(cfg, admissions, e.at);
    const limit = limitAt(cfg, e.at);
    compare(e, "S8 before", e.s8.valueBefore, used);
    compare(e, "S8 after", e.s8.valueAfter, used + amount);
    compare(e, "S8 soft", e.s8.soft, config.soft);
    compare(e, "S8 hard", e.s8.hard, limit);

    let verdict;
    if (amount === 0n) verdict = VERDICT.EXECUTE;
    else if (used + amount > limit) verdict = VERDICT.REJECT;
    else if (used + amount > config.soft) verdict = VERDICT.FLAG;
    else verdict = VERDICT.EXECUTE;
    compare(e, "S8 verdict", e.s8.verdict, verdict);
    if (verdict === VERDICT.REJECT) compare(e, "executed though refused", e.executed, false);

    if (e.executed) {
      placed++;
      if (amount !== 0n) {
        admissions.push({ at: e.at, amount, credit: null });
        counted++;
      }
    }
  }
  return { checked, disagreement, placed, counted };
}
