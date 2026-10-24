// npm run verify:roundtrip                      3 seeds of 400 steps
// node offchain/verifier/roundtrip-cli.js --seeds 10 --steps 300
// node offchain/verifier/roundtrip-cli.js --quiet    one line; exit code 1 on any failure
//
// S8 (spec v0.2 section 5): the chain's figures and verdicts against the
// verifier's own replay of the ledger and the window from the event log, then
// the same log, tampered, which the verifier must reject. Runs on a fresh
// in-process chain. Needs the contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runRoundTripScenarios, ROUNDTRIP_CONFIG } from "./roundtrip-fuzz.js";
import { verifyRoundTrip, VERDICT } from "./roundtrip.js";
import { replayLedger, positionAt } from "./ledger.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? Number(process.argv[i + 1]) : fallback;
}

const seeds = option("seeds", 3);
const steps = option("steps", 400);
const firstSeed = option("first-seed", 1);
const quiet = process.argv.includes("--quiet");
const say = quiet ? () => {} : console.log;

const edit = (history, index, change) => history.map((e, i) => (i === index ? change(e) : e));
const find = (history, test) => history.findIndex(test);
const isSub = (e) => e.type === "submission";

/** Tampered histories: each must produce a disagreement. */
function tamperings(history) {
  const out = [];
  const counted = find(history, (e) => isSub(e) && e.executed && e.s8.valueAfter > e.s8.valueBefore);
  if (counted >= 0) {
    out.push(["a round trip under-reported", edit(history, counted, (e) => ({ ...e, s8: { ...e.s8, valueAfter: e.s8.valueAfter - 1n } }))]);
    // The sell side of the slot it counted on, opened earlier, made smaller.
    const slot = history[counted].legs.find((l) => l.kind === 0)?.slot;
    const opened = find(history.slice(0, counted), (e) => e.type === "opened" && e.slot === slot);
    if (opened >= 0) out.push(["an earlier order of the slot shrunk", edit(history, opened, (e) => ({ ...e, qtyWh: e.qtyWh > 1n ? e.qtyWh / 2n : e.qtyWh + 5n }))]);
  }
  const refused = find(history, (e) => isSub(e) && e.s8.verdict === VERDICT.REJECT);
  if (refused >= 0) out.push(["a refusal turned into a flag", edit(history, refused, (e) => ({ ...e, s8: { ...e.s8, verdict: VERDICT.FLAG } }))]);
  const flagged = find(history, (e) => isSub(e) && e.s8.verdict === VERDICT.FLAG);
  if (flagged >= 0) out.push(["a flag hidden", edit(history, flagged, (e) => ({ ...e, s8: { ...e.s8, verdict: VERDICT.EXECUTE } }))]);
  // A cancellation leg dropped from a counted resize (same side and slot)
  // whose side still binds afterwards: without the cancellation that side is
  // larger, and so is the round trip. Chosen from the ledger's replay
  // (ledger.js, checked on its own by verify:ledger), not from S8's arithmetic.
  const resized = find(history, (e, i) => isSub(e) && e.executed && bindingResize(history.slice(0, i), e));
  if (resized >= 0) out.push(["a resize's cancellation dropped", edit(history, resized, (e) => ({ ...e, legs: e.legs.filter((l) => l.kind === 0) }))]);
  // A release other than the unfilled rest: the ledger replay must refuse it.
  const closed = find(history, (e) => e.type === "closed" && e.releasedWh > 0n);
  if (closed >= 0) out.push(["a release made smaller", edit(history, closed, (e) => ({ ...e, releasedWh: e.releasedWh - 1n }))]);
  return out;
}

/** A modification resizing one order in place, counted, with the resized side still the smaller after it. */
function bindingResize(before, e) {
  if (e.legs.length !== 2 || e.s8.valueAfter <= e.s8.valueBefore) return false;
  const [c, p] = e.legs;
  if (c.kind !== 1 || p.kind !== 0 || c.side !== p.side || c.slot !== p.slot || c.qtyWh === 0n) return false;
  const pos = positionAt(replayLedger(before.filter((x) => !isSub(x))).orders, e.account, p.slot);
  const [mine, other] = p.side === 0 ? [pos.committedBuyWh, pos.committedSellWh] : [pos.committedSellWh, pos.committedBuyWh];
  return mine - c.qtyWh + p.qtyWh < other;
}

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x ${steps} steps of S8 on an in-process chain ...`);
  const history = await runRoundTripScenarios({ seeds, steps, firstSeed });
  await connection.close();

  let failures = 0;
  const report = verifyRoundTrip(history, ROUNDTRIP_CONFIG);
  const subs = history.filter(isSub);
  say(
    `\n${subs.length} submissions (${subs.filter((e) => e.legs.length === 2).length} modifications, ` +
      `${subs.filter((e) => e.legs.every((l) => l.kind === 1)).length} cancellations, ` +
      `${subs.filter((e) => e.s8.verdict === VERDICT.FLAG).length} flagged, ` +
      `${subs.filter((e) => e.s8.verdict === VERDICT.REJECT).length} refused), ` +
      `${report.counted} round trips counted, ${history.filter((e) => e.type === "closed").length} orders closed`,
  );
  if (report.disagreement) {
    failures++;
    const d = report.disagreement;
    say(`  DISAGREEMENT, ${d.what}: chain ${d.chain}, verifier ${d.verifier}, at ${d.event?.at}`);
  } else {
    say(`  ${report.checked} figures compared, every one agrees`);
  }

  say("\nSelf-test: tampered logs the verifier must reject");
  const made = tamperings(history);
  if (made.length < 6) say(`  (only ${made.length} of 6 tamperings could be built from this history: run more steps)`);
  for (const [name, tampered] of made) {
    const caught = verifyRoundTrip(tampered, ROUNDTRIP_CONFIG).disagreement !== null;
    if (!caught) failures++;
    say(`  ${caught ? "caught" : "MISSED"}  ${name}`);
  }

  const summary = `roundtrip: ${report.checked} figures compared, ${failures === 0 ? "no disagreement" : `${failures} FAILURES`}`;
  console.log(quiet ? summary : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
