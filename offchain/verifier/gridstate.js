// A10, the grid-state direction gate (spec v0.2 sections 5 S12 and 11.3),
// recomputed from the events alone.
//
// From the grid states the oracle accepted, the verifier keeps the latest of
// the operator the account registered; at each submission it decides
// whether that state is fresh, which slots it covers, and, from the decoded
// legs, each slot's change of net export. It compares A10's verdict and
// figures with what the chain reported.
//
// A history, in log order:
//
//   { type: "grid", signer, issuedAt, validUntil, level, direction, horizonSlots }
//   { type: "submission", at, legs, a10, executed }
//       legs  [{ kind, side, slot, qtyWh }]; kind 0 PLACE, 1 CANCEL
//       a10   { verdict, valueBefore, valueAfter, soft, hard } as the chain reported
//
// config = { operator, minLevel, origin, slotSeconds }. Times and slots
// Number; Wh BigInt. level 0 NORMAL, 1 ALERT, 2 EMERGENCY; direction 0
// DEFICIT, 1 SURPLUS, 2 NONE.

export const VERDICT = { EXECUTE: 0, FLAG: 1, REJECT: 2 };
const DEFICIT = 0;
const SURPLUS = 1;
const EMERGENCY = 2;

/** A10's judgement of `legs` at time `at` under `state` (or none). */
export function judgeGrid(state, legs, at, config) {
  const result = { verdict: VERDICT.EXECUTE, valueBefore: 0n, valueAfter: 0n, soft: BigInt(config.minLevel), hard: 0n };
  const fresh = state && state.issuedAt <= at && at <= state.validUntil;
  if (!fresh || state.level < config.minLevel) return result;
  result.valueBefore = BigInt(state.level);
  result.valueAfter = BigInt(state.direction);
  result.hard = BigInt(state.horizonSlots);

  const change = new Map(); // slot -> { ne, placed }
  for (const l of legs) {
    const c = change.get(l.slot) ?? { ne: 0n, placed: false };
    const qty = l.kind === 0 ? l.qtyWh : -l.qtyWh;
    c.ne += l.side === 1 ? qty : -qty;
    if (l.kind === 0) c.placed = true;
    change.set(l.slot, c);
  }
  const horizonEnd = at + state.horizonSlots * config.slotSeconds;
  for (const [slot, c] of change) {
    const start = config.origin + slot * config.slotSeconds;
    if (start + config.slotSeconds <= at || start >= horizonEnd) continue;
    const refused =
      state.direction === DEFICIT ? c.ne < 0n : state.direction === SURPLUS ? c.ne > 0n : state.level === EMERGENCY && c.placed;
    if (refused) {
      result.verdict = VERDICT.REJECT;
      break;
    }
  }
  return result;
}

/** Replay a history. Returns { checked, disagreement, submissions, refused }. */
export function verifyGridState(history, config) {
  let state = null;
  let checked = 0;
  let disagreement = null;
  let submissions = 0;
  let refused = 0;
  const compare = (event, what, chain, verifier) => {
    checked++;
    if (chain !== verifier) disagreement ??= { event, what, chain, verifier };
  };
  for (const e of history) {
    if (e.type === "grid") {
      // Kept per signer; only the account's operator counts, and a state
      // replaces the held one when it is not older.
      if (e.signer.toLowerCase() === config.operator.toLowerCase() && (!state || e.issuedAt >= state.issuedAt)) state = e;
      continue;
    }
    if (e.type !== "submission") continue;
    submissions++;
    const j = judgeGrid(state, e.legs, e.at, config);
    for (const f of ["verdict", "valueBefore", "valueAfter", "soft", "hard"]) compare(e, `A10 ${f}`, e.a10[f], j[f]);
    if (j.verdict === VERDICT.REJECT) {
      refused++;
      compare(e, "executed though refused", e.executed, false);
    }
  }
  return { checked, disagreement, submissions, refused };
}
