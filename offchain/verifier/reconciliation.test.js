// npm run test:offchain
//
// S9's replay without a chain (spec v0.2 section 5): the shortfall, the
// level's decay, and a history through an alarm, a penalty and a missing
// reading.

import { test } from "node:test";
import assert from "node:assert/strict";
import { shortfallOf, levelAt, processAt, verifyReconciliation, VERDICT } from "./reconciliation.js";

const A = "0x00000000000000000000000000000000000000aa";
const M = "0x0000000000000000000000000000000000000001";
const SLOT = 1800;
const config = {
  k: 100n, h: 1000n, penaltySeconds: 86_400, escalationSeconds: 7 * 86_400, settlementLagSeconds: SLOT,
  graceSeconds: 2 * SLOT, maxProcess: 8, window: { kind: "SLIDING", step: SLOT, buckets: 48, anchor: 0, cap: 2_500n, rate: 0n, initial: 0n },
  origin: 0, slotSeconds: SLOT, configuredAt: 10 * SLOT,
};

test("the shortfall: the sale missed, never more than the sale", () => {
  assert.equal(shortfallOf(1000n, 400n), 600n);
  assert.equal(shortfallOf(1000n, 1200n), 0n);
  assert.equal(shortfallOf(1000n, -300n), 1000n);
  assert.equal(shortfallOf(0n, -300n), 0n);
});

test("the level falls by one per W_esc", () => {
  const st = { level: 2, lastAlarmAt: 0 };
  assert.equal(levelAt(st, config, 7 * 86_400 - 1), 2);
  assert.equal(levelAt(st, config, 7 * 86_400), 1);
  assert.equal(levelAt(st, config, 14 * 86_400), 0);
});

test("a history: two missed sales raise an alarm; level 1 caps sells; a missing reading blocks", () => {
  // Sales of 1,000 Wh for slots 10 and 11, filled in full and closed; the
  // meter shows nothing delivered. At slot 11's settlement: C = 900, then 1,800.
  const t0 = 12 * SLOT + SLOT; // slot 11 ends at 12 * SLOT, settles a slot later
  const sale = (orderId, slot) => [
    { type: "opened", at: 10 * SLOT, account: A, market: M, orderId, side: 1, slot, qtyWh: 1000n },
    { type: "fill", at: 10 * SLOT, account: A, market: M, orderId, filledWh: 1000n, totalFilledWh: 1000n },
    { type: "closed", at: 10 * SLOT, account: A, market: M, orderId, releasedWh: 0n },
  ];
  const history = [
    ...sale("0x1", 10),
    ...sale("0x2", 11),
    { type: "meter", slotStart: 10 * SLOT, importWh: 0n, exportWh: 0n },
    { type: "meter", slotStart: 11 * SLOT, importWh: 0n, exportWh: 0n },
    {
      type: "poke", at: t0, account: A,
      slots: [
        { slot: 10, cn: 1000n, dn: 0n, s: 1000n, cusum: 900n },
        { slot: 11, cn: 1000n, dn: 0n, s: 1000n, cusum: 1800n },
      ],
      alarms: [{ slot: 11, level: 1, cusum: 1800n, penaltyUntil: t0 + 86_400 }],
    },
    // 2,000 Wh of sells counted: 500 more fit H_pen; 501 do not.
    { type: "submission", at: t0 + 1, account: A, legs: [{ kind: 0, side: 1, slot: 20, qtyWh: 501n }],
      s9: { verdict: VERDICT.REJECT, valueBefore: 0n, valueAfter: 0n }, executed: false, slots: [], alarms: [] },
    { type: "submission", at: t0 + 2, account: A, legs: [{ kind: 0, side: 0, slot: 20, qtyWh: 5000n }],
      s9: { verdict: VERDICT.EXECUTE, valueBefore: 0n, valueAfter: 0n }, executed: true, slots: [], alarms: [] },
  ];
  const report = verifyReconciliation(history, config);
  assert.equal(report.disagreement, null);
  assert.equal(report.alarms, 1);

  const hidden = structuredClone(history);
  hidden[8].alarms = [];
  assert.equal(verifyReconciliation(hidden, config).disagreement.what, "alarms");

  // Slot 12 sold, no reading: blocked once its grace has passed, not before.
  const orders = [{ account: A, market: M, slot: 12, side: 1, qtyWh: 500n, filledWh: 500n, releasedWh: 0n }];
  const state = { next: 12, cusum: 0n, level: 0, penaltyUntil: 0, lastAlarmAt: 0 };
  const settled = 13 * SLOT + SLOT;
  assert.equal(processAt(state, config, settled + 2 * SLOT - 1, orders, new Map(), A).blocked, false);
  assert.equal(processAt(state, config, settled + 2 * SLOT, orders, new Map(), A).blocked, true);
});
