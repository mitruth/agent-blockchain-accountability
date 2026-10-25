// npm run verify:delivery                      3 seeds of 300 steps
// node offchain/verifier/reconciliation-cli.js --seeds 10 --steps 400
// node offchain/verifier/reconciliation-cli.js --quiet    one line; exit code 1 on any failure
//
// S9 (spec v0.2 section 5): the chain's slots, alarms and verdicts against the
// verifier's own replay of the ledger, the meter and the window from the event
// log, then the same log, tampered, which the verifier must reject. Runs on a
// fresh in-process chain. Needs the contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runReconciliationScenarios } from "./reconciliation-fuzz.js";
import { verifyReconciliation, VERDICT } from "./reconciliation.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? Number(process.argv[i + 1]) : fallback;
}

const seeds = option("seeds", 3);
const steps = option("steps", 300);
const firstSeed = option("first-seed", 1);
const quiet = process.argv.includes("--quiet");
const say = quiet ? () => {} : console.log;

const edit = (history, index, change) => history.map((e, i) => (i === index ? change(e) : e));
const find = (history, test) => history.findIndex(test);
const takesIn = (e) => (e.type === "poke" || (e.type === "submission" && e.executed)) && e.slots.length > 0;

/** Tampered histories, each picked where the change must show. */
function tamperings(history) {
  const out = [];
  const short = find(history, (e) => takesIn(e) && e.slots.some((s) => s.s > 0n));
  if (short >= 0) {
    out.push(["a shortfall under-reported", edit(history, short, (e) => ({
      ...e, slots: e.slots.map((s) => (s.s > 0n ? { ...s, s: s.s - 1n } : s)),
    }))]);
    // The reading behind that shortfall, made larger: less was missed.
    const slot = history[short].slots.find((s) => s.s > 0n).slot;
    const meter = find(history.slice(0, short), (e) => e.type === "meter" && e.slotStart === slot * 1800);
    if (meter >= 0) out.push(["a meter reading inflated", edit(history, meter, (e) => ({ ...e, exportWh: e.exportWh + 5_000n }))]);
  }
  const alarmed = find(history, (e) => (e.type === "poke" || e.type === "submission") && e.alarms.length > 0);
  if (alarmed >= 0) out.push(["an alarm hidden", edit(history, alarmed, (e) => ({ ...e, alarms: e.alarms.slice(1) }))]);
  const refused = find(history, (e) => e.type === "submission" && e.s9.verdict === VERDICT.REJECT);
  if (refused >= 0) out.push(["a refusal reported as an execution", edit(history, refused, (e) => ({ ...e, s9: { ...e.s9, verdict: VERDICT.EXECUTE } }))]);
  // A fill dropped for a sale whose slot S9 later took in.
  const fill = find(history, (e, i) => e.type === "fill" && history.slice(i).some((x) => takesIn(x) && x.slots.some((s) => s.cn > 0n)));
  if (fill >= 0) out.push(["a fill dropped", history.filter((_, i) => i !== fill)]);
  const reset = find(history, (e) => e.type === "reset");
  if (reset >= 0) out.push(["a reset's pointer moved", edit(history, reset, (e) => ({ ...e, next: e.next + 1 }))]);
  return out;
}

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x ${steps} steps of S9 on an in-process chain ...`);
  const { history, config } = await runReconciliationScenarios({ seeds, steps, firstSeed });
  await connection.close();

  let failures = 0;
  const report = verifyReconciliation(history, config);
  const subs = history.filter((e) => e.type === "submission");
  say(
    `\n${report.submissions} submissions (${subs.filter((e) => e.s9.verdict === VERDICT.REJECT).length} refused by S9, ` +
      `${subs.filter((e) => e.s9.verdict === VERDICT.FLAG).length} flagged), ` +
      `${history.filter((e) => e.type === "poke").length} pokes, ${history.filter((e) => e.type === "meter").length} readings, ` +
      `${history.filter((e) => e.type === "reset").length} resets; ${report.slots} slots taken in, ${report.alarms} alarms`,
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
    const caught = verifyReconciliation(tampered, config).disagreement !== null;
    if (!caught) failures++;
    say(`  ${caught ? "caught" : "MISSED"}  ${name}`);
  }

  const summary = `delivery: ${report.checked} figures compared, ${report.alarms} alarms, ${failures === 0 ? "no disagreement" : `${failures} FAILURES`}`;
  console.log(quiet ? summary : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
