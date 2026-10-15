// Random histories for the verifier to check, run on a chain through
// WindowProbe: for each seed, one window of each class, configured at random,
// then a random sequence of waits, admissions, credits and observations.
// Seeded, so a disagreement can be replayed.
//
// Also the scripted boundary burst of step 3: the cap spent in the last second
// before midnight and again in the first second after, under SLIDING and
// TUMBLING.

import { publicClient, deploy, send, events, now } from "../chain/index.js";
import { KINDS } from "./windows.js";

const SENDER = 0;
const DAY = 86_400;
const STEPS = [60, 300, 900, 3600];

/** mulberry32: a small seeded generator, enough for test sequences. */
function generator(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Run `call` in a block with timestamp exactly `t`. */
async function at(t, call) {
  await publicClient.request({ method: "evm_setNextBlockTimestamp", params: [t] });
  return call();
}

function randomConfig(kind, t0, rand) {
  const int = (n) => Math.floor(rand() * n);
  const step = STEPS[int(STEPS.length)];
  return {
    kind: KINDS.indexOf(kind),
    step,
    buckets: kind === "SLIDING" ? 1 + int(12) : 0,
    anchor: t0 + int(2 * step),
    cap: 1000n,
    rate: BigInt(1 + int(300)),
    initial: kind === "STREAM" ? BigInt(int(1001)) : 0n,
  };
}

/** One window's random history, starting after `t`. Returns the time it ended. */
async function randomHistory(probe, id, kind, seed, steps, t) {
  const rand = generator(seed * 31 + KINDS.indexOf(kind));
  const int = (n) => Math.floor(rand() * n);
  const config = randomConfig(kind, t + 1, rand);
  t += 1;
  await at(t, () => send(SENDER, probe, "WindowProbe", "configure", [id, config]));

  const span = (config.buckets ? config.buckets + 2 : 3) * config.step;
  const open = []; // admissions not yet credited: { index, amount }
  for (let i = 0; i < steps; i++) {
    const wait = int(8);
    t += wait === 0 ? 1 : wait <= 4 ? 1 + int(config.step) : wait <= 6 ? 1 + int(3 * config.step) : 1 + int(span);

    const op = int(10);
    if (op < 6) {
      const amount = BigInt(int(400));
      const receipt = await at(t, () => send(SENDER, probe, "WindowProbe", "tryAdd", [id, amount]));
      for (const e of events(receipt, "WindowProbe", "Admitted")) open.push({ index: e.args.admission, amount });
    } else if (op < 8 && open.length > 0) {
      const [a] = open.splice(int(open.length), 1);
      const amount = BigInt(int(Number(a.amount) + 1));
      await at(t, () => send(SENDER, probe, "WindowProbe", "credit", [id, a.index, amount]));
    } else {
      await at(t, () => send(SENDER, probe, "WindowProbe", "observe", [id]));
    }
  }
  return t;
}

/** The scripted boundary burst. Window ids 1 (SLIDING) and 2 (TUMBLING). Returns the time it ended. */
async function boundaryBurst(probe, t) {
  const midnight = (Math.floor(t / DAY) + 2) * DAY;
  const cap = 1000n;
  const sliding = { kind: 0, step: 3600, buckets: 24, anchor: 0, cap, rate: 0n, initial: 0n };
  const tumbling = { kind: 1, step: DAY, buckets: 0, anchor: midnight - DAY, cap, rate: 0n, initial: 0n };
  await at(t + 1, () => send(SENDER, probe, "WindowProbe", "configure", [1n, sliding]));
  await at(t + 2, () => send(SENDER, probe, "WindowProbe", "configure", [2n, tumbling]));
  // One transaction per block, so the two windows' calls are a second apart.
  await at(midnight - 2, () => send(SENDER, probe, "WindowProbe", "tryAdd", [1n, cap]));
  await at(midnight - 1, () => send(SENDER, probe, "WindowProbe", "tryAdd", [2n, cap]));
  await at(midnight + 1, () => send(SENDER, probe, "WindowProbe", "tryAdd", [1n, cap]));
  await at(midnight + 2, () => send(SENDER, probe, "WindowProbe", "tryAdd", [2n, cap]));
  return midnight + 2;
}

/**
 * Deploy a probe and run the boundary burst and `seeds` random histories of
 * `steps` steps for each class. Window id = 10 * seed + class + 10.
 * Returns the probe's address.
 */
export async function runScenarios({ seeds = 8, steps = 60, firstSeed = 1, log = () => {} } = {}) {
  const probe = await deploy(SENDER, "WindowProbe");
  let t = await boundaryBurst(probe, await now());
  log("boundary burst run");
  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    for (const [k, kind] of KINDS.entries()) {
      t = await randomHistory(probe, BigInt(10 * seed + k + 10), kind, seed, steps, t);
    }
    log(`seed ${seed} run`);
  }
  return probe;
}
