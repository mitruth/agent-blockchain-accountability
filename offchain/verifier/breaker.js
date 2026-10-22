// The session circuit breaker G1 (spec v0.2 section 5), recomputed from the
// events alone.
//
// The contract counts rejected and flagged submissions in two SLIDING
// windows, a ring of buckets with a running total. The verifier keeps no
// ring: it keeps every counted submission's time and, at each submission,
// counts afresh those whose bucket is among the window's last n. From that it
// derives when the breaker must suspend, and compares with what the chain
// reported, inputs included.
//
// A history is one account's, in log order:
//
//   { type: "config",     at, config }      config applied; null turns G1 off
//   { type: "reinstate",  at }               the owner reinstated
//   { type: "submission", at, rejected, flagged, reinstated, suspended }
//       reinstated  "AUTO" when the chain reinstated after the cooldown at the
//                   start of this submission, else null
//       suspended   { reason, rejectsUsed, flagsUsed } when the chain
//                   suspended after it, else null
//
// config = { rejects: { step, buckets, cap }, flags: { step, buckets, cap }, cooldownSeconds }
//
// Rules, as the contract states them:
//   - while suspended, a submission is not counted;
//   - after the cooldown (if any), the first submission reinstates the
//     account, and is then counted as usual; the windows are not reset;
//   - an owner reinstatement resets both windows;
//   - a new configuration keeps a window's count unless the window's shape
//     (step, buckets) changed, which starts it afresh;
//   - a submission that is rejected or flagged is counted, and then the
//     breaker suspends if a window's count exceeds its cap; reason 0 rejects,
//     1 flags (rejects first when both). A clean submission never suspends.

export const REASON = { REJECTS: 0, FLAGS: 1 };

/** How many of `times` the window of `shape` counts at time `t`: buckets c - n + 1 to c. */
export function countAt(shape, times, t) {
  const c = Math.floor(t / shape.step);
  let n = 0;
  for (const s of times) {
    const b = Math.floor(s / shape.step);
    if (b <= c && b > c - shape.buckets) n++;
  }
  return n;
}

const sameShape = (a, b) => a && b && a.step === b.step && a.buckets === b.buckets;

/** Replay one account's history. Returns { checked, disagreement, suspensions }. */
export function verifyBreaker(history) {
  let config = null;
  let suspendedAt = null;
  let rejects = [];
  let flags = [];
  let checked = 0;
  let suspensions = 0;
  let disagreement = null;
  const compare = (event, what, chain, verifier) => {
    checked++;
    if (chain !== verifier) disagreement ??= { event, what, chain, verifier };
  };

  for (const e of history) {
    if (e.type === "config") {
      if (!config || !e.config || !sameShape(config.rejects, e.config.rejects)) rejects = [];
      if (!config || !e.config || !sameShape(config.flags, e.config.flags)) flags = [];
      config = e.config;
      if (!config) suspendedAt = null;
      continue;
    }
    if (e.type === "reinstate") {
      suspendedAt = null;
      rejects = [];
      flags = [];
      continue;
    }

    // A submission.
    const auto =
      suspendedAt !== null && config !== null && config.cooldownSeconds > 0 && e.at >= suspendedAt + config.cooldownSeconds;
    compare(e, "auto reinstatement", e.reinstated === "AUTO", auto);
    if (auto) suspendedAt = null;

    if (config === null || suspendedAt !== null) {
      compare(e, "suspended", e.suspended !== null, false);
      continue;
    }
    if (e.rejected) rejects.push(e.at);
    if (e.flagged) flags.push(e.at);
    const r = countAt(config.rejects, rejects, e.at);
    const f = countAt(config.flags, flags, e.at);
    // The breaker judges only a submission it counts: a clean one never
    // suspends, whatever the windows still hold after a cooldown.
    const counted = e.rejected || e.flagged;
    const overR = counted && r > config.rejects.cap;
    const overF = counted && f > config.flags.cap;
    compare(e, "suspended", e.suspended !== null, overR || overF);
    if (e.suspended && (overR || overF)) {
      compare(e, "reason", e.suspended.reason, overR ? REASON.REJECTS : REASON.FLAGS);
      compare(e, "rejects counted", e.suspended.rejectsUsed, r);
      compare(e, "flags counted", e.suspended.flagsUsed, f);
    }
    if (overR || overF) {
      suspendedAt = e.at;
      suspensions++;
    }
  }
  return { checked, disagreement, suspensions };
}
