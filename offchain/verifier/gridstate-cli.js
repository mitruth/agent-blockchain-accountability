// npm run verify:gridstate                      3 seeds of 200 steps
// node offchain/verifier/gridstate-cli.js --seeds 10 --steps 400
// node offchain/verifier/gridstate-cli.js --quiet    one line; exit code 1 on any failure
//
// A10 (spec v0.2 sections 5 S12 and 11.3): the chain's verdicts and figures
// against the verifier's own reading of the grid states and the legs, then the
// same log, tampered, which the verifier must reject. Runs on a fresh
// in-process chain. Needs the contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runGridStateScenarios, GRID_CONFIG } from "./gridstate-fuzz.js";
import { verifyGridState, VERDICT } from "./gridstate.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? Number(process.argv[i + 1]) : fallback;
}

const seeds = option("seeds", 3);
const steps = option("steps", 200);
const firstSeed = option("first-seed", 1);
const quiet = process.argv.includes("--quiet");
const say = quiet ? () => {} : console.log;

const edit = (history, index, change) => history.map((e, i) => (i === index ? change(e) : e));
const find = (history, test) => history.findIndex(test);
const sub = (e) => e.type === "submission";

/** Tampered histories, each picked where the change must show. */
function tamperings(history) {
  const out = [];
  const refused = find(history, (e) => sub(e) && e.a10.verdict === VERDICT.REJECT);
  if (refused >= 0) {
    out.push(["a refusal reported as an execution", edit(history, refused, (e) => ({ ...e, a10: { ...e.a10, verdict: VERDICT.EXECUTE } }))]);
    // The state behind that refusal, its direction turned round (or, with
    // none, its level lowered to ALERT).
    let g = -1;
    for (let i = refused; i >= 0; i--) {
      if (history[i].type === "grid" && history[i].signer.toLowerCase() === GRID_CONFIG.operator.toLowerCase()) { g = i; break; }
    }
    if (g >= 0) {
      out.push(["the state behind a refusal changed", edit(history, g, (e) =>
        e.direction === 2 ? { ...e, level: 1 } : { ...e, direction: 1 - e.direction })]);
    }
  }
  const applied = find(history, (e) => sub(e) && e.a10.valueBefore > 0n);
  if (applied >= 0) out.push(["the level in force misreported", edit(history, applied, (e) => ({ ...e, a10: { ...e.a10, valueBefore: e.a10.valueBefore + 1n } }))]);
  // A state from another signer passed off as the operator's.
  const foreign = find(history, (e) => e.type === "grid" && e.signer.toLowerCase() !== GRID_CONFIG.operator.toLowerCase() && e.level > 0);
  if (foreign >= 0) {
    out.push(["a stranger's state taken as the operator's", edit(history, foreign, (e) => ({ ...e, signer: GRID_CONFIG.operator }))]);
  }
  return out;
}

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x ${steps} steps of A10 on an in-process chain ...`);
  const history = await runGridStateScenarios({ seeds, steps, firstSeed });
  await connection.close();

  let failures = 0;
  const report = verifyGridState(history, GRID_CONFIG);
  say(`\n${report.submissions} submissions (${report.refused} refused), ${history.filter((e) => e.type === "grid").length} grid states`);
  if (report.disagreement) {
    failures++;
    const d = report.disagreement;
    say(`  DISAGREEMENT, ${d.what}: chain ${d.chain}, verifier ${d.verifier}, at ${d.event?.at}`);
  } else {
    say(`  ${report.checked} figures compared, every one agrees`);
  }

  say("\nSelf-test: tampered logs the verifier must reject");
  const made = tamperings(history);
  if (made.length < 4) say(`  (only ${made.length} of 4 tamperings could be built from this history: run more steps)`);
  for (const [name, tampered] of made) {
    const caught = verifyGridState(tampered, GRID_CONFIG).disagreement !== null;
    if (!caught) failures++;
    say(`  ${caught ? "caught" : "MISSED"}  ${name}`);
  }

  const summary = `gridstate: ${report.checked} figures compared, ${failures === 0 ? "no disagreement" : `${failures} FAILURES`}`;
  console.log(quiet ? summary : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
