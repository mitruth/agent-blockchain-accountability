// npm run test:offchain

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseDecimal, roundDiv, scaled } from "./decimal.js";

test("a decimal string is read exactly, in every form the CSVs use", () => {
  assert.deepEqual(parseDecimal("0.194018"), { digits: 194018n, exp: -6 });
  assert.deepEqual(parseDecimal("4.88e-06"), { digits: 488n, exp: -8 });
  assert.deepEqual(parseDecimal("1E+2"), { digits: 1n, exp: 2 });
  assert.deepEqual(parseDecimal("-2.5"), { digits: -25n, exp: -1 });
  assert.equal(scaled("-0.0", 1000), 0n);
  assert.equal(scaled("15", 1000), 15_000n);
});

test("anything that is not a decimal is refused", () => {
  for (const bad of ["", "abc", "1.2.3", "1.5e", "nan", "0x10"]) {
    assert.throws(() => parseDecimal(bad), undefined, bad);
  }
});

test("rounding is half away from zero, once, after every digit is read", () => {
  assert.equal(roundDiv(5n, 2n), 3n);
  assert.equal(roundDiv(-5n, 2n), -3n);
  assert.equal(roundDiv(4n, 3n), 1n);
  assert.equal(scaled("0.1945", 1000), 195n); // 194.49999... as a float
  assert.equal(scaled("-0.1945", 1000), -195n);
  assert.equal(scaled("0.02470274", 1_000_000), 24_703n);
  assert.equal(scaled("1.4999999952631584", 1000), 1_500n);
  assert.equal(scaled("2.4249999786007947e-09", 1000), 0n);
  assert.equal(scaled("0.4999998865263159", 10_000), 5_000n);
});
