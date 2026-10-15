// npm run test:offchain
//
// The verifier's own definitions, without a chain: hand-computed cases, the
// REFILL closed form against a step-by-step simulation, and histories that
// break a guarantee or misreport a figure.

import { test } from "node:test";
import assert from "node:assert/strict";
import { usedAt, limitAt, creditApplies } from "./windows.js";
import { slidingGuarantees, maxInAnyInterval } from "./guarantees.js";
import { verifyWindow } from "./verify.js";

const H = 3600;
const sliding = { kind: "SLIDING", step: H, buckets: 24, anchor: 0, cap: 100n, rate: 0n, initial: 0n };
const adm = (at, amount, credit = null) => ({ at, amount: BigInt(amount), credit });

test("a sliding window holds 24 hourly buckets, to the second", () => {
  const admissions = [adm(1800, 10), adm(5 * H + 1800, 20)];
  assert.equal(usedAt(sliding, admissions, 24 * H - 1), 30n);
  assert.equal(usedAt(sliding, admissions, 24 * H), 20n);
  assert.equal(usedAt(sliding, admissions, 29 * H - 1), 20n);
  assert.equal(usedAt(sliding, admissions, 29 * H), 0n);
});

test("a credit counts only while its admission is in the window", () => {
  assert.equal(creditApplies(sliding, 0, 24 * H - 1), true);
  assert.equal(creditApplies(sliding, 0, 24 * H), false);
  const refill = { ...sliding, kind: "REFILL", rate: 10n };
  assert.equal(creditApplies(refill, 10, H - 1), true);
  assert.equal(creditApplies(refill, 10, H), false);
});

test("a stream unlocks its initial amount, then its rate per interval, up to its cap", () => {
  const stream = { kind: "STREAM", step: H, buckets: 0, anchor: 1000, cap: 100n, rate: 10n, initial: 20n };
  assert.equal(limitAt(stream, 0), 20n);
  assert.equal(limitAt(stream, 1000 + H - 1), 20n);
  assert.equal(limitAt(stream, 1000 + H), 30n);
  assert.equal(limitAt(stream, 1000 + 100 * H), 100n);
});

test("REFILL's closed form agrees with a step-by-step simulation", () => {
  let seed = 7;
  const rand = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  for (let run = 0; run < 200; run++) {
    const cfg = { kind: "REFILL", step: 60, buckets: 0, anchor: 0, cap: 1000n, rate: BigInt(1 + Math.floor(rand() * 50)), initial: 0n };
    const admissions = [];
    let simulated = 0n;
    let mark = 0;
    let t = 0;
    for (let i = 0; i < 30; i++) {
      t += 1 + Math.floor(rand() * 200);
      const back = BigInt(Math.floor(t / 60) - mark) * cfg.rate;
      simulated = back >= simulated ? 0n : simulated - back;
      mark = Math.floor(t / 60);
      if (rand() < 0.7) {
        const amount = BigInt(Math.floor(rand() * 100));
        admissions.push(adm(t, amount));
        simulated += amount;
      } else if (admissions.length > 0) {
        const a = admissions[Math.floor(rand() * admissions.length)];
        if (!a.credit && creditApplies(cfg, a.at, t)) {
          a.credit = { at: t, amount: a.amount };
          simulated -= a.amount;
        }
      }
      assert.equal(usedAt(cfg, admissions, t), simulated, `run ${run}, step ${i}`);
    }
  }
});

test("twice the cap within W - b breaks G1", () => {
  const { g1 } = slidingGuarantees(sliding, [adm(0, 100), adm(23 * H - 1, 100)]);
  assert.equal(g1.holds, false);
  assert.equal(g1.worst.amount, 200n);
});

test("the cap twice, W apart, keeps both guarantees", () => {
  const { g1, g2 } = slidingGuarantees(sliding, [adm(0, 100), adm(24 * H, 100)]);
  assert.equal(g1.holds, true);
  assert.equal(g2.holds, true);
  assert.equal(g2.worst.excess, 100n, "an interval of exactly W holds one bucket more");
});

test("a tumbling window's boundary burst is twice its cap", () => {
  const burst = maxInAnyInterval([adm(86_399, 100), adm(86_401, 100)], 86_399);
  assert.equal(burst.amount, 200n);
});

test("a decision the definitions do not support is reported", () => {
  const history = {
    id: 1n,
    events: [
      { type: "configured", at: 0, config: sliding },
      { type: "admitted", at: 10, admission: 0, amount: 100n, usedBefore: 0n, limit: 100n },
      { type: "admitted", at: 20, admission: 1, amount: 1n, usedBefore: 100n, limit: 100n },
    ],
  };
  const report = verifyWindow(history);
  assert.equal(report.disagreement.what, "decision");
  assert.equal(report.disagreement.event.at, 20);
});
