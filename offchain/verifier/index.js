// verifier: the independent check of the windows (spec 8).
//
// It rebuilds every window from the event log alone and recomputes it from
// the definitions, by a different algorithm from the contract's; it reports
// the first figure it and the chain disagree on, and measures the guarantees
// of spec 5.3 over every interval of the history.
//
//   windows.js     the five classes, from their definitions
//   guarantees.js  G1 and G2 for SLIDING, bursts, over every interval
//   verify.js      replays a history, compares every figure
//   history.js     a probe's event log as histories
//   fuzz.js        random and scripted histories, run through WindowProbe
//   selftest.js    tampered histories it must reject
//   cli.js         npm run verify:window
//
// Step 4 adds the policies' events (PolicyResult) as a second source of
// histories; the definitions stay as they are.

export { KINDS, usedAt, limitAt, stillCounts, creditApplies, slidingStart, period } from "./windows.js";
export { slidingGuarantees, maxInAnyInterval } from "./guarantees.js";
export { verifyWindow, verifyAll } from "./verify.js";
export { readHistories, toConfig } from "./history.js";
export { runScenarios } from "./fuzz.js";
export { selfTest } from "./selftest.js";
