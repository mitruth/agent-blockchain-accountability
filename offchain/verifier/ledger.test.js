// npm run test:offchain
//
// The ledger replay without a chain (spec v0.2, C4): positions summed across
// markets, releases, and logs that cannot be.

import { test } from "node:test";
import assert from "node:assert/strict";
import { replayLedger, positionAt, verifyLedger } from "./ledger.js";

const ALICE = "0x00000000000000000000000000000000000000aa";
const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const id = (n) => `0x${n.toString(16).padStart(64, "0")}`;

const opened = (block, market, n, side, slot, qty) => ({
  type: "opened", block, account: ALICE, market, orderId: id(n), side, slot, qtyWh: BigInt(qty),
});
const fill = (block, market, n, filled, total) => ({
  type: "fill", block, account: ALICE, market, orderId: id(n), filledWh: BigInt(filled), totalFilledWh: BigInt(total),
});
const closed = (block, market, n, released) => ({
  type: "closed", block, account: ALICE, market, orderId: id(n), releasedWh: BigInt(released),
});

test("a slot's totals hold the orders of every market", () => {
  // The same order id on both markets is two orders.
  const { orders, problems } = replayLedger([opened(1, A, 1, 1, 5, 400), opened(2, B, 1, 1, 5, 700), opened(3, B, 2, 0, 5, 300)]);
  assert.deepEqual(problems, []);
  assert.deepEqual(positionAt(orders, ALICE, 5), {
    committedBuyWh: 300n, committedSellWh: 1100n, clearedBuyWh: 0n, clearedSellWh: 0n,
  });
  assert.equal(positionAt(orders, ALICE, 6).committedSellWh, 0n);
});

test("a release leaves the filled part committed and cleared", () => {
  const { orders } = replayLedger([opened(1, A, 1, 0, 2, 2000), fill(2, A, 1, 1500, 1500), closed(3, A, 1, 500)]);
  assert.deepEqual(positionAt(orders, ALICE, 2), {
    committedBuyWh: 1500n, committedSellWh: 0n, clearedBuyWh: 1500n, clearedSellWh: 0n,
  });
});

test("a log that cannot be is a problem", () => {
  assert.equal(replayLedger([fill(1, A, 1, 1, 1)]).problems[0].what, "not an open order");
  assert.equal(replayLedger([opened(1, A, 1, 0, 2, 10), fill(2, A, 1, 5, 6)]).problems[0].what, "fill does not add up");
  assert.equal(replayLedger([opened(1, A, 1, 0, 2, 10), fill(2, A, 1, 11, 11)]).problems[0].what, "filled beyond the quantity");
  assert.equal(
    replayLedger([opened(1, A, 1, 0, 2, 10), closed(2, A, 1, 9)]).problems[0].what,
    "released other than the unfilled rest",
  );
  assert.equal(replayLedger([opened(1, A, 1, 0, 2, 10), opened(2, A, 1, 0, 2, 10)]).problems[0].what, "placed twice");
});

test("a checkpoint is compared with the replay up to its block", () => {
  const events = [opened(1, A, 1, 1, 5, 400), opened(2, B, 2, 1, 5, 700)];
  const at = (block, sell) => ({
    block, account: ALICE, slot: 5,
    position: { committedBuyWh: 0n, committedSellWh: BigInt(sell), clearedBuyWh: 0n, clearedSellWh: 0n },
  });
  assert.equal(verifyLedger(events, [at(1, 400), at(2, 1100)]).disagreement, null);
  // A chain that kept the second market's order apart.
  const d = verifyLedger(events, [at(2, 700)]).disagreement;
  assert.equal(d.what, "committedSellWh");
  assert.equal(d.verifier, 1100n);
});
