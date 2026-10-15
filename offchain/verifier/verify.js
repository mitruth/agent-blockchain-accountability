// Replay a window's event log against the definitions and compare every
// figure the chain reported: the count and the limit at each admission,
// refusal and observation; the decision to admit or refuse; the amount given
// back by each credit. The first disagreement is reported, with the event.
//
// A history is { id, events } with events in log order:
//
//   { type: "configured", at, config }
//   { type: "admitted",   at, admission, amount, usedBefore, limit }
//   { type: "refused",    at, amount, usedBefore, limit }
//   { type: "credited",   at, admission, amount, credited }
//   { type: "observed",   at, used, limit }

import { usedAt, limitAt, creditApplies, sameShape } from "./windows.js";
import { slidingGuarantees, maxInAnyInterval } from "./guarantees.js";

/** Verify one window. Returns { id, kind, checked, disagreement, admissions, guarantees }. */
export function verifyWindow(history) {
  let cfg = null;
  let admissions = [];
  let checked = 0;
  let disagreement = null;

  const differ = (event, what, chain, verifier) => {
    disagreement ??= { event, what, chain, verifier };
  };
  const compare = (event, what, chain, verifier) => {
    checked++;
    if (chain !== verifier) differ(event, what, chain, verifier);
  };

  for (const e of history.events) {
    if (disagreement) break;
    if (e.type === "configured") {
      if (cfg && !sameShape(cfg, e.config)) admissions = []; // a new shape starts afresh
      cfg = e.config;
      continue;
    }
    if (!cfg) {
      differ(e, "event before any configuration", e.type, "none");
      break;
    }

    if (e.type === "admitted" || e.type === "refused") {
      const used = usedAt(cfg, admissions, e.at);
      const limit = limitAt(cfg, e.at);
      compare(e, "count before the decision", e.usedBefore, used);
      compare(e, "limit", e.limit, limit);
      compare(e, "decision", e.type, used + e.amount <= limit ? "admitted" : "refused");
      if (e.type === "admitted") {
        compare(e, "admission number", e.admission, admissions.length);
        admissions.push({ at: e.at, amount: e.amount, credit: null });
      }
    } else if (e.type === "credited") {
      const a = admissions[e.admission];
      if (!a) {
        differ(e, "credit for an unknown admission", e.admission, "none");
        break;
      }
      const applies = creditApplies(cfg, a.at, e.at);
      compare(e, "amount given back", e.credited, applies ? e.amount : 0n);
      if (applies) a.credit = { at: e.at, amount: e.amount };
    } else if (e.type === "observed") {
      compare(e, "count", e.used, usedAt(cfg, admissions, e.at));
      compare(e, "limit", e.limit, limitAt(cfg, e.at));
    }
  }

  return {
    id: history.id,
    kind: cfg?.kind,
    config: cfg,
    checked,
    disagreement,
    admissions,
    guarantees: cfg ? guaranteesOf(cfg, admissions) : null,
  };
}

/**
 * What the paper states about each class, measured on this history.
 *   SLIDING   G1 and G2 (spec 5.3)
 *   TUMBLING  the most admitted within one period's length: up to 2 x cap
 *             across a boundary
 */
function guaranteesOf(cfg, admissions) {
  if (cfg.kind === "SLIDING") {
    const { g1, g2 } = slidingGuarantees(cfg, admissions);
    return { holds: g1.holds && g2.holds, g1, g2 };
  }
  if (cfg.kind === "TUMBLING") {
    const burst = maxInAnyInterval(admissions, cfg.step - 1);
    return { holds: true, burst };
  }
  return { holds: true };
}

/** Verify every window of a probe's log. */
export function verifyAll(histories) {
  return histories.map(verifyWindow);
}
