// npm run test:offchain
//
// G1's replay without a chain (spec v0.2 section 5): counts over buckets,
// suspension, cooldown, owner reinstatement, configuration changes.

import { test } from "node:test";
import assert from "node:assert/strict";
import { countAt, verifyBreaker, REASON } from "./breaker.js";

const H = 3600;
const shape = (cap, step = 300, buckets = 12) => ({ step, buckets, cap });
const config = (rejectCap = 2, flagCap = 3, cooldownSeconds = 0) => ({
  rejects: shape(rejectCap), flags: shape(flagCap, H, 24), cooldownSeconds,
});
const sub = (at, { rejected = false, flagged = false, reinstated = null, suspended = null } = {}) => ({
  type: "submission", at, rejected, flagged, reinstated, suspended,
});

test("a sliding window counts the last n buckets, to the second", () => {
  const s = shape(10); // 12 buckets of 5 minutes
  assert.equal(countAt(s, [0, 299], H - 1), 2);
  assert.equal(countAt(s, [0, 299], H), 0, "bucket 0 left at bucket 12");
  assert.equal(countAt(s, [300], H), 1);
  assert.equal(countAt(s, [H + 300], H), 0, "a later bucket is not counted");
});

test("the breaker suspends on the first count above the cap", () => {
  const ok = verifyBreaker([
    { type: "config", at: 0, config: config() },
    sub(10, { rejected: true }),
    sub(20, { rejected: true }),
    sub(30, { rejected: true, suspended: { reason: REASON.REJECTS, rejectsUsed: 3, flagsUsed: 0 } }),
    sub(40),
  ]);
  assert.equal(ok.disagreement, null);
  assert.equal(ok.suspensions, 1);

  const early = verifyBreaker([
    { type: "config", at: 0, config: config() },
    sub(10, { rejected: true }),
    sub(20, { rejected: true, suspended: { reason: REASON.REJECTS, rejectsUsed: 2, flagsUsed: 0 } }),
  ]);
  assert.equal(early.disagreement.what, "suspended");
});

test("a chain that never suspends is caught", () => {
  const r = verifyBreaker([
    { type: "config", at: 0, config: config() },
    sub(10, { rejected: true }), sub(20, { rejected: true }), sub(30, { rejected: true }),
  ]);
  assert.equal(r.disagreement.what, "suspended");
  assert.equal(r.disagreement.verifier, true);
});

test("rejections spaced beyond the window never suspend", () => {
  const r = verifyBreaker([
    { type: "config", at: 0, config: config() },
    sub(0, { rejected: true }), sub(H, { rejected: true }), sub(2 * H, { rejected: true }), sub(3 * H, { rejected: true }),
  ]);
  assert.equal(r.disagreement, null);
  assert.equal(r.suspensions, 0);
});

test("flags count in their own window", () => {
  const r = verifyBreaker([
    { type: "config", at: 0, config: config(10, 1) },
    sub(10, { flagged: true }),
    sub(20, { flagged: true, suspended: { reason: REASON.FLAGS, rejectsUsed: 0, flagsUsed: 2 } }),
  ]);
  assert.equal(r.disagreement, null);
});

test("while suspended nothing counts; the cooldown reinstates the next submission", () => {
  const history = [
    { type: "config", at: 0, config: config(0, 10, 600) },
    sub(10, { rejected: true, suspended: { reason: REASON.REJECTS, rejectsUsed: 1, flagsUsed: 0 } }),
    sub(20, { rejected: true }),
    sub(609),
    sub(610, { reinstated: "AUTO" }),
  ];
  assert.equal(verifyBreaker(history).disagreement, null);
  // One second early is wrong.
  const early = structuredClone(history);
  early[3].reinstated = "AUTO";
  assert.equal(verifyBreaker(early).disagreement.what, "auto reinstatement");
});

test("an owner reinstatement resets both windows", () => {
  const r = verifyBreaker([
    { type: "config", at: 0, config: config(1) },
    sub(10, { rejected: true }),
    sub(20, { rejected: true, suspended: { reason: REASON.REJECTS, rejectsUsed: 2, flagsUsed: 0 } }),
    { type: "reinstate", at: 30 },
    sub(40, { rejected: true }),
  ]);
  assert.equal(r.disagreement, null);
});

test("a change of a window's shape starts it afresh; a change of cap does not", () => {
  const keep = verifyBreaker([
    { type: "config", at: 0, config: config(5) },
    sub(10, { rejected: true }), sub(20, { rejected: true }),
    { type: "config", at: 30, config: config(1) },
    sub(40, { rejected: true, suspended: { reason: REASON.REJECTS, rejectsUsed: 3, flagsUsed: 0 } }),
  ]);
  assert.equal(keep.disagreement, null);

  const reshaped = { ...config(1), rejects: shape(1, 600, 6) };
  const fresh = verifyBreaker([
    { type: "config", at: 0, config: config(5) },
    sub(10, { rejected: true }), sub(20, { rejected: true }),
    { type: "config", at: 30, config: reshaped },
    sub(40, { rejected: true }),
  ]);
  assert.equal(fresh.disagreement, null);
});
