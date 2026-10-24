// npm run test:offchain
//
// S8's replay without a chain (spec v0.2 section 5): what a submission adds
// to the round trips, the window, and the verdicts.

import { test } from "node:test";
import assert from "node:assert/strict";
import { roundTripAdded, verifyRoundTrip, VERDICT } from "./roundtrip.js";

const A = "0x00000000000000000000000000000000000000aa";
const M1 = "0x0000000000000000000000000000000000000001";
const M2 = "0x0000000000000000000000000000000000000002";
const config = { soft: 500n, window: { kind: "SLIDING", step: 1800, buckets: 48, anchor: 0, cap: 1000n, rate: 0n, initial: 0n } };

const order = (market, orderId, side, slot, qtyWh, releasedWh = null) => ({
  account: A, market, slot, side, qtyWh, filledWh: 0n, releasedWh,
});
const place = (side, slot, qtyWh) => ({ kind: 0, side, slot, qtyWh });
const cancel = (side, slot, qtyWh) => ({ kind: 1, side, slot, qtyWh });

test("only the overlap of the two sides counts, per slot, over every market", () => {
  const orders = [order(M1, "1", 0, 7, 1000n), order(M2, "2", 1, 8, 1000n)];
  assert.equal(roundTripAdded(orders, A, [place(1, 7, 300n)]), 300n, "a sell against market 1's buy");
  assert.equal(roundTripAdded(orders, A, [place(0, 8, 300n)]), 300n, "a buy against market 2's sell");
  assert.equal(roundTripAdded(orders, A, [place(1, 9, 300n)]), 0n, "a slot with no buy");
  assert.equal(roundTripAdded(orders, A, [place(1, 7, 300n), place(0, 8, 200n)]), 500n, "summed over the slots");
  assert.equal(roundTripAdded(orders, A, [place(1, 7, 1500n)]), 1000n, "the buy side binds");
});

test("a cancellation adds nothing; a modification only what it adds", () => {
  const orders = [order(M1, "1", 0, 7, 300n), order(M1, "2", 1, 7, 500n)];
  assert.equal(roundTripAdded(orders, A, [cancel(1, 7, 500n)]), 0n);
  assert.equal(roundTripAdded(orders, A, [cancel(0, 7, 300n), place(0, 7, 400n)]), 100n, "the binding side grown by 100");
  assert.equal(roundTripAdded(orders, A, [cancel(1, 7, 500n), place(1, 8, 500n)]), 0n, "moved out of the slot");
  assert.equal(roundTripAdded([order(M1, "1", 0, 7, 300n, 300n)], A, [place(1, 7, 300n)]), 0n, "a released buy holds nothing");
});

test("a history replays: count, flag, refusal, no credit, the window slides", () => {
  const opened = (orderId, side, slot, qtyWh) => ({ type: "opened", account: A, market: M1, orderId, side, slot, qtyWh });
  const sub = (at, legs, verdict, valueBefore, valueAfter, executed = verdict !== VERDICT.REJECT) => ({
    type: "submission", at, account: A, legs, s8: { verdict, valueBefore, valueAfter, soft: 500n, hard: 1000n }, executed,
  });
  const history = [
    sub(0, [place(0, 7, 2000n)], VERDICT.EXECUTE, 0n, 0n),
    opened("0x1", 0, 7, 2000n),
    sub(10, [place(1, 7, 600n)], VERDICT.FLAG, 0n, 600n),
    opened("0x2", 1, 7, 600n),
    { type: "closed", account: A, market: M1, orderId: "0x2", releasedWh: 600n },
    sub(20, [place(1, 7, 401n)], VERDICT.REJECT, 600n, 1001n),
    sub(30, [place(1, 7, 400n)], VERDICT.FLAG, 600n, 1000n),
    opened("0x3", 1, 7, 400n),
    sub(24 * 3600 + 1800, [place(1, 7, 100n)], VERDICT.EXECUTE, 0n, 100n),
  ];
  const report = verifyRoundTrip(history, config);
  assert.equal(report.disagreement, null);
  assert.equal(report.counted, 3);

  const credited = structuredClone(history);
  credited[5].s8.valueBefore = 0n; // as if the release had given the 600 back
  assert.equal(verifyRoundTrip(credited, config).disagreement.what, "S8 before");
});
