// npm run verify:breaker                    4 seeds of 120 steps
// node offchain/verifier/breaker-cli.js --seeds 10 --steps 300
// node offchain/verifier/breaker-cli.js --quiet   one line; exit code 1 on any failure
//
// G1 (spec v0.2 section 5): the breaker's suspensions and reinstatements on a
// chain, against the verifier's replay of the event log, which counts every
// window afresh over the submissions themselves. Then the same log, tampered,
// which the verifier must reject. Runs on a fresh in-process chain. Needs the
// contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runBreakerScenarios } from "./breaker-fuzz.js";
import { verifyBreaker } from "./breaker.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? Number(process.argv[i + 1]) : fallback;
}

const seeds = option("seeds", 4);
const steps = option("steps", 120);
const firstSeed = option("first-seed", 1);
const quiet = process.argv.includes("--quiet");
const say = quiet ? () => {} : console.log;

const edit = (history, index, change) => history.map((e, i) => (i === index ? change(e) : e));

/** Tampered histories: each must produce a disagreement. */
function tamperings(history) {
  const out = [];
  const first = history.findIndex((e) => e.type === "submission" && e.suspended);
  if (first >= 0) {
    out.push(["a suspension hidden", edit(history, first, (e) => ({ ...e, suspended: null }))]);
    out.push(["a suspension's count misreported", edit(history, first, (e) => ({ ...e, suspended: { ...e.suspended, rejectsUsed: e.suspended.rejectsUsed + 1, flagsUsed: e.suspended.flagsUsed + 1 } }))]);
    out.push(["the submission that tripped it reported clean", edit(history, first, (e) => ({ ...e, rejected: false, flagged: false }))]);
  }
  const clean = history.findIndex((e, i) => e.type === "submission" && !e.suspended && !e.rejected && !e.flagged && i < first);
  if (clean >= 0) out.push(["a suspension invented", edit(history, clean, (e) => ({ ...e, suspended: { reason: 0, rejectsUsed: 0, flagsUsed: 0 } }))]);
  const auto = history.findIndex((e) => e.type === "submission" && e.reinstated === "AUTO");
  if (auto >= 0) out.push(["an automatic reinstatement hidden", edit(history, auto, (e) => ({ ...e, reinstated: null }))]);
  return out;
}

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x ${steps} steps of G1 on an in-process chain ...`);
  const history = await runBreakerScenarios({ seeds, steps, firstSeed });
  await connection.close();

  let failures = 0;
  const report = verifyBreaker(history);
  const submissions = history.filter((e) => e.type === "submission");
  const auto = submissions.filter((e) => e.reinstated === "AUTO").length;
  say(
    `\n${submissions.length} submissions (${submissions.filter((e) => e.rejected).length} rejected, ` +
      `${submissions.filter((e) => e.flagged).length} flagged), ${history.filter((e) => e.type === "config").length} configurations, ` +
      `${report.suspensions} suspensions, ${history.filter((e) => e.type === "reinstate").length} owner and ${auto} automatic reinstatements`,
  );
  if (report.disagreement) {
    failures++;
    const d = report.disagreement;
    say(`  DISAGREEMENT, ${d.what}: chain ${d.chain}, verifier ${d.verifier}, at ${d.event.at}`);
  } else {
    say(`  ${report.checked} figures compared, every one agrees`);
  }
  if (report.suspensions === 0) {
    failures++;
    say("  no suspension in the run: it proves nothing; use more steps");
  }

  say("\nSelf-test: tampered logs the verifier must reject");
  for (const [name, tampered] of tamperings(history)) {
    const caught = verifyBreaker(tampered).disagreement !== null;
    if (!caught) failures++;
    say(`  ${caught ? "caught" : "MISSED"}  ${name}`);
  }

  const summary = `breaker: ${report.checked} figures compared, ${report.suspensions} suspensions, ${failures === 0 ? "no disagreement" : `${failures} FAILURES`}`;
  console.log(quiet ? summary : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
