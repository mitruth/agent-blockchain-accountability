// npm run test:offchain

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseNano, roundDiv, scaled } from "./decimal.js";

test("a decimal string is read exactly", () => {
  assert.equal(parseNano("0.194018"), 194_018_000n);
  assert.equal(parseNano("1.99797313"), 1_997_973_130n);
  assert.equal(parseNano("0.0"), 0n);
  assert.equal(parseNano("15"), 15_000_000_000n);
  assert.equal(parseNano("-2.5"), -2_500_000_000n);
  assert.equal(parseNano("4.88e-06"), 4_880n);
  assert.equal(parseNano("1E+2"), 100_000_000_000n);
});

test("anything that is not a decimal, or needs more than 9 decimals, is refused", () => {
  for (const bad of ["", "abc", "1.2.3", "0.1234567891", "1e-10", "1.5e"]) {
    assert.throws(() => parseNano(bad), undefined, bad);
  }
});

test("rounding is half away from zero, once", () => {
  assert.equal(roundDiv(5n, 2n), 3n);
  assert.equal(roundDiv(-5n, 2n), -3n);
  assert.equal(roundDiv(4n, 3n), 1n);
  assert.equal(scaled("0.1945", 1000), 195n); // 194.49999... as a float
  assert.equal(scaled("0.02470274", 1_000_000), 24_703n);
  assert.equal(scaled("0.95", 10_000), 9_500n);
});
