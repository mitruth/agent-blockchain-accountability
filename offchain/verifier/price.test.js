// npm run test:offchain
//
// The price policies' replay without a chain (spec v0.2 section 5): A3T's
// band compared exactly, S7's amounts, window and credits.

import { test } from "node:test";
import assert from "node:assert/strict";
import { tariffFor, outsideBand, excessOf, verifyPrice, VERDICT } from "./price.js";

const SLOT = 1800;
const config = {
  slotSeconds: SLOT,
  maxAge: 86_400,
  buyMarkupBps: 333,
  sellDiscountBps: 333,
  s7: { soft: 50n, window: { kind: "SLIDING", step: 3600, buckets: 24, anchor: 0, cap: 100n, rate: 0n, initial: 0n } },
};
const tariff = (at, retail, feedIn, n = 4) => ({
  type: "tariff", at, issuedAt: at, firstSlotStart: 0, slotSeconds: SLOT, retail: Array(n).fill(retail), feedIn: Array(n).fill(feedIn),
});

test("a tariff serves the slots it covers while it is fresh", () => {
  const t = tariff(10, 100n, 30n);
  assert.deepEqual(tariffFor(t, SLOT * 3, 10, 86_400), { retail: 100n, feedIn: 30n });
  assert.equal(tariffFor(t, SLOT * 4, 10, 86_400), null, "past its last slot");
  assert.equal(tariffFor(t, SLOT + 1, 10, 86_400), null, "between slots");
  assert.equal(tariffFor(t, 0, 10 + 86_401, 86_400), null, "stale");
});

test("A3T's band, compared exactly", () => {
  // 100,001 x 1.0333 = 103,331.03; 100,001 x 0.9667 = 96,670.97.
  const t = { retail: 100_001n, feedIn: 100_001n };
  assert.equal(outsideBand(t, { side: 0, price: 103_331n }, config), false);
  assert.equal(outsideBand(t, { side: 0, price: 103_332n }, config), true);
  assert.equal(outsideBand(t, { side: 1, price: 96_671n }, config), false);
  assert.equal(outsideBand(t, { side: 1, price: 96_670n }, config), true);
  assert.equal(outsideBand(null, { side: 0, price: 1n }, config), true, "no tariff: unjudged");
});

test("S7's excess per side, zero inside the corridor", () => {
  const t = { retail: 100n, feedIn: 30n };
  assert.equal(excessOf(t, { side: 0, price: 120n }), 20n);
  assert.equal(excessOf(t, { side: 0, price: 80n }), 0n);
  assert.equal(excessOf(t, { side: 1, price: 25n }), 5n);
  assert.equal(excessOf(t, { side: 1, price: 40n }), 0n);
});

test("a history replays: charge, flag, refusal, credit", () => {
  // A 30 % band, so a bid at 120 against retail 100 is inside it.
  const wide = { ...config, buyMarkupBps: 3_000 };
  // Excess 20 per kWh: 3,000 Wh give away 60 (flagged above 50); 2,500 more
  // would make 110 > 100 (refused); the first order released half filled
  // gives back 60 - 30 = 30.
  const history = [
    tariff(0, 100n, 30n),
    { type: "submission", at: 10, leg: { side: 0, slot: 1, qtyWh: 3000n, price: 120n }, a3t: false, s7: { verdict: VERDICT.FLAG, valueBefore: 0n, valueAfter: 60n }, orderId: "a" },
    { type: "submission", at: 20, leg: { side: 0, slot: 1, qtyWh: 2500n, price: 120n }, a3t: false, s7: { verdict: VERDICT.REJECT, valueBefore: 60n, valueAfter: 110n }, orderId: null },
    { type: "release", at: 30, orderId: "a", qtyWh: 3000n, filledWh: 1500n, credit: { amount: 30n, credited: 30n } },
    { type: "submission", at: 40, leg: { side: 0, slot: 1, qtyWh: 1000n, price: 100n }, a3t: false, s7: { verdict: VERDICT.EXECUTE, valueBefore: 30n, valueAfter: 30n }, orderId: "b" },
  ];
  assert.equal(verifyPrice(history, wide).disagreement, null);

  const wrong = structuredClone(history);
  wrong[3].credit.credited = 60n;
  assert.equal(verifyPrice(wrong, wide).disagreement.what, "credit given");
});
