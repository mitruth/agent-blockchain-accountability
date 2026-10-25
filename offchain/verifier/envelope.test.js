// npm run test:offchain
//
// S10's replay without a chain (spec v0.2 section 5): the limits in force,
// use and excess, and a history through the static fallback, an envelope, a
// tightening and a stale envelope. And the synthetic envelope feed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { limitsFor, useOf, excessOf, verifyEnvelope, VERDICT } from "./envelope.js";
import { envelopeOf, isCutDay } from "../eval/envelope-feed.js";

const A = "0x00000000000000000000000000000000000000aa";
const M = "0x0000000000000000000000000000000000000001";
const SLOT = 1800;
const config = { connectionW: 9000, softBps: 9000, slotSeconds: SLOT, origin: 0, maxAge: 86_400 };
const envelope = (issuedAt, exportWh, importWh, n = 4) => ({
  type: "envelope", issuedAt, firstSlotStart: 0, slotSeconds: SLOT, exportLimitWh: Array(n).fill(exportWh), importLimitWh: Array(n).fill(importWh),
});

test("the limits: the envelope's while fresh and covering, else the connection's", () => {
  const e = envelope(100, 2000n, 3000n);
  assert.deepEqual(limitsFor(e, 2 * SLOT, 100, config), { exportWh: 2000n, importWh: 3000n, fromEnvelope: true });
  assert.equal(limitsFor(e, 4 * SLOT, 100, config).fromEnvelope, false, "beyond its slots");
  assert.equal(limitsFor(e, 2 * SLOT, 100 + 86_401, config).fromEnvelope, false, "stale");
  assert.equal(limitsFor(null, 0, 0, config).exportWh, 4500n, "9 kW for a half-hour");
});

test("use in bps, rounded up; excess beyond the limit faced", () => {
  const l = { exportWh: 2000n, importWh: 3000n };
  assert.equal(useOf(1800n, l), 9000n);
  assert.equal(useOf(1801n, l), 9005n);
  assert.equal(useOf(1001n, { exportWh: 3000n, importWh: 3000n }), 3337n, "3,336.67 rounded up");
  assert.equal(useOf(-3000n, l), 10_000n);
  assert.equal(useOf(1n, { exportWh: 0n, importWh: 1n }), 2n ** 256n - 1n, "against a zero limit");
  assert.equal(excessOf(2500n, l), 500n);
  assert.equal(excessOf(-3500n, l), 500n);
  assert.equal(excessOf(-1000n, l), 0n);
});

test("a history: static, an envelope, a tightening, D10", () => {
  const sub = (at, legs, verdict, valueBefore, valueAfter, executed = verdict !== VERDICT.REJECT) => ({
    type: "submission", at, account: A, legs, s10: { verdict, valueBefore, valueAfter, soft: 9000n, hard: 10_000n }, executed,
  });
  const sell = (slot, qtyWh) => ({ kind: 0, side: 1, slot, qtyWh });
  const opened = (orderId, slot, qtyWh) => ({ type: "opened", account: A, market: M, orderId, side: 1, slot, qtyWh });
  const history = [
    sub(10, [sell(1, 4500n)], VERDICT.FLAG, 0n, 10_000n), // static: at the limit, flagged
    opened("0x1", 1, 4500n),
    sub(20, [sell(1, 1n)], VERDICT.REJECT, 10_000n, 10_003n), // 4,501 of 4,500
    envelope(30, 2000n, 3000n),
    sub(40, [sell(2, 1800n)], VERDICT.EXECUTE, 0n, 9000n),
    opened("0x2", 2, 1800n),
    sub(50, [sell(1, 1n)], VERDICT.REJECT, 22_500n, 22_505n), // 4,500 now faces 2,000: worse
    sub(60, [{ kind: 1, side: 1, slot: 1, qtyWh: 4500n }], VERDICT.EXECUTE, 22_500n, 0n), // cancelling passes
  ];
  const report = verifyEnvelope(history, config);
  assert.equal(report.disagreement, null);
  assert.equal(report.refused, 2);

  const wrong = structuredClone(history);
  wrong[6].s10.verdict = VERDICT.FLAG;
  assert.equal(verifyEnvelope(wrong, config).disagreement.what, "S10 verdict");
});

test("the synthetic feed: every fifth day, export cut at midday", () => {
  assert.equal(isCutDay("2022-01-01"), true, "day 0");
  assert.equal(isCutDay("2022-01-02"), false);
  assert.equal(isCutDay("2022-01-06"), true);
  assert.deepEqual(envelopeOf({ date: "2022-01-06", slot: 24 }, 9000, SLOT), { exportLimitWh: 1800, importLimitWh: 4500 });
  assert.deepEqual(envelopeOf({ date: "2022-01-06", slot: 30 }, 9000, SLOT), { exportLimitWh: 4500, importLimitWh: 4500 }, "15:00, past the cut");
  assert.deepEqual(envelopeOf({ date: "2022-01-07", slot: 24 }, 9000, SLOT), { exportLimitWh: 4500, importLimitWh: 4500 });
});
