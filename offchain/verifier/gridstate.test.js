// npm run test:offchain
//
// A10's replay without a chain (spec v0.2 sections 5 S12 and 11.3): the rules
// per direction, the horizon, freshness, the operator; and the scripted
// episodes.

import { test } from "node:test";
import assert from "node:assert/strict";
import { judgeGrid, verifyGridState, VERDICT } from "./gridstate.js";
import { episodeOf } from "../eval/grid-feed.js";

const OP = "0x00000000000000000000000000000000000000aa";
const SLOT = 1800;
const config = { operator: OP, minLevel: 1, origin: 0, slotSeconds: SLOT };
const state = (level, direction, horizonSlots = 10, issuedAt = 0, validUntil = 3600) =>
  ({ type: "grid", signer: OP, issuedAt, validUntil, level, direction, horizonSlots });
const buy = (slot, qtyWh = 100n, kind = 0) => ({ kind, side: 0, slot, qtyWh });
const sell = (slot, qtyWh = 100n, kind = 0) => ({ kind, side: 1, slot, qtyWh });

test("DEFICIT refuses what lowers net export; SURPLUS the mirror", () => {
  const d = state(1, 0);
  assert.equal(judgeGrid(d, [buy(2)], 0, config).verdict, VERDICT.REJECT);
  assert.equal(judgeGrid(d, [sell(2)], 0, config).verdict, VERDICT.EXECUTE);
  assert.equal(judgeGrid(d, [sell(2, 100n, 1)], 0, config).verdict, VERDICT.REJECT, "cancelling a sale: the D10 exception");
  assert.equal(judgeGrid(d, [sell(2, 100n, 1), sell(2, 150n)], 0, config).verdict, VERDICT.EXECUTE, "a sale raised by a modification");
  const s = state(1, 1);
  assert.equal(judgeGrid(s, [sell(2)], 0, config).verdict, VERDICT.REJECT);
  assert.equal(judgeGrid(s, [buy(2, 100n, 1)], 0, config).verdict, VERDICT.REJECT);
});

test("NONE: at EMERGENCY no placement; at ALERT nothing", () => {
  assert.equal(judgeGrid(state(2, 2), [buy(2)], 0, config).verdict, VERDICT.REJECT);
  assert.equal(judgeGrid(state(2, 2), [sell(2, 100n, 1)], 0, config).verdict, VERDICT.EXECUTE, "a cancellation");
  assert.equal(judgeGrid(state(1, 2), [buy(2)], 0, config).verdict, VERDICT.EXECUTE);
});

test("the horizon, freshness and the level", () => {
  const d = state(1, 0, 10);
  assert.equal(judgeGrid(d, [buy(9)], 0, config).verdict, VERDICT.REJECT, "the last slot inside");
  assert.equal(judgeGrid(d, [buy(10)], 0, config).verdict, VERDICT.EXECUTE, "the first outside");
  assert.equal(judgeGrid(d, [buy(2)], 3601, config).verdict, VERDICT.EXECUTE, "stale: NORMAL");
  assert.equal(judgeGrid(state(0, 0), [buy(2)], 0, config).verdict, VERDICT.EXECUTE, "NORMAL");
  assert.equal(judgeGrid(d, [buy(2)], 0, { ...config, minLevel: 2 }).verdict, VERDICT.EXECUTE, "ALERT below minLevel");
});

test("a history: only the account's operator counts", () => {
  const history = [
    { ...state(1, 0), signer: "0x00000000000000000000000000000000000000bb" },
    { type: "submission", at: 10, legs: [buy(2)], a10: { verdict: 0, valueBefore: 0n, valueAfter: 0n, soft: 1n, hard: 0n }, executed: true },
    state(1, 0, 10, 20),
    { type: "submission", at: 30, legs: [buy(2)], a10: { verdict: 2, valueBefore: 1n, valueAfter: 0n, soft: 1n, hard: 10n }, executed: false },
  ];
  assert.equal(verifyGridState(history, config).disagreement, null);
});

test("the scripted episodes", () => {
  assert.equal(episodeOf("2022-01-04").direction, 0, "day 3: DEFICIT");
  assert.equal(episodeOf("2022-01-06").direction, 1, "day 5: SURPLUS");
  assert.equal(episodeOf("2022-01-31").level, 2, "day 30: EMERGENCY");
  assert.equal(episodeOf("2022-01-05"), null);
});
