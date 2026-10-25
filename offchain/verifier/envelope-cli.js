// npm run verify:envelope                      3 seeds of 200 steps
// node offchain/verifier/envelope-cli.js --seeds 10 --steps 400
// node offchain/verifier/envelope-cli.js --quiet    one line; exit code 1 on any failure
//
// S10 (spec v0.2 section 5): the chain's verdicts and figures against the
// verifier's own replay of the ledger and the envelope from the event log,
// then the same log, tampered, which the verifier must reject. Runs on a
// fresh in-process chain. Needs the contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runEnvelopeScenarios, ENVELOPE_CONFIG } from "./envelope-fuzz.js";
import { verifyEnvelope, VERDICT } from "./envelope.js";

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
  const refused = find(history, (e) => sub(e) && e.s10.verdict === VERDICT.REJECT);
  if (refused >= 0) out.push(["a refusal reported as an execution", edit(history, refused, (e) => ({ ...e, s10: { ...e.s10, verdict: VERDICT.EXECUTE } }))]);
  const flagged = find(history, (e) => sub(e) && e.s10.verdict === VERDICT.FLAG);
  if (flagged >= 0) out.push(["a flag hidden", edit(history, flagged, (e) => ({ ...e, s10: { ...e.s10, verdict: VERDICT.EXECUTE } }))]);
  const used = find(history, (e) => sub(e) && e.s10.valueAfter > 0n && e.s10.valueAfter < 2n ** 255n);
  if (used >= 0) out.push(["a use under-reported", edit(history, used, (e) => ({ ...e, s10: { ...e.s10, valueAfter: e.s10.valueAfter - 1n } }))]);
  // The envelope in force at a refusal, every limit made far larger.
  if (refused >= 0) {
    let envelope = -1;
    for (let i = refused; i >= 0; i--) if (history[i].type === "envelope") { envelope = i; break; }
    if (envelope >= 0) {
      out.push(["an envelope's limits raised", edit(history, envelope, (e) => ({
        ...e, exportLimitWh: e.exportLimitWh.map((x) => x + 100_000n), importLimitWh: e.importLimitWh.map((x) => x + 100_000n),
      }))]);
    }
  }
  // An earlier order of a slot a refusal touched, made larger: the first
  // refusal with such an order.
  for (let r = 0; r < history.length; r++) {
    const e = history[r];
    if (!sub(e) || e.s10.verdict !== VERDICT.REJECT) continue;
    const slot = e.legs[0].slot;
    const opened = find(history.slice(0, r), (x) => x.type === "opened" && x.slot === slot);
    if (opened < 0) continue;
    out.push(["an earlier order of the slot changed", edit(history, opened, (x) => ({ ...x, qtyWh: x.qtyWh + 7_000n }))]);
    break;
  }
  return out;
}

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x ${steps} steps of S10 on an in-process chain ...`);
  const history = await runEnvelopeScenarios({ seeds, steps, firstSeed });
  await connection.close();

  let failures = 0;
  const report = verifyEnvelope(history, ENVELOPE_CONFIG);
  say(
    `\n${report.submissions} submissions (${report.refused} refused, ${report.flagged} flagged), ` +
      `${history.filter((e) => e.type === "envelope").length} envelopes, ${history.filter((e) => e.type === "closed").length} orders closed`,
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
  if (made.length < 5) say(`  (only ${made.length} of 5 tamperings could be built from this history: run more steps)`);
  for (const [name, tampered] of made) {
    const caught = verifyEnvelope(tampered, ENVELOPE_CONFIG).disagreement !== null;
    if (!caught) failures++;
    say(`  ${caught ? "caught" : "MISSED"}  ${name}`);
  }

  const summary = `envelope: ${report.checked} figures compared, ${failures === 0 ? "no disagreement" : `${failures} FAILURES`}`;
  console.log(quiet ? summary : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
