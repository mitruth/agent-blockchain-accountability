// npm run verify:ledger                     4 seeds of 80 writes
// node offchain/verifier/ledger-cli.js --seeds 10 --steps 200
// node offchain/verifier/ledger-cli.js --quiet   one line; exit code 1 on any failure
//
// The ledger across two markets and two accounts (spec v0.2, C4): the chain's
// per-slot totals after every write, against the verifier's replay of the
// event log. Then the same log, tampered, which the verifier must reject.
// Runs on a fresh in-process chain. Needs the contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runLedgerScenarios } from "./ledger-fuzz.js";
import { readLedgerEvents, verifyLedger } from "./ledger.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? Number(process.argv[i + 1]) : fallback;
}

const seeds = option("seeds", 4);
const steps = option("steps", 80);
const firstSeed = option("first-seed", 1);
const quiet = process.argv.includes("--quiet");
const say = quiet ? () => {} : console.log;

/** Tampered logs: each must produce a disagreement. */
function tamperings(events) {
  const at = (type) => events.findIndex((e) => e.type === type);
  const out = [];
  const fill = at("fill");
  if (fill >= 0) out.push(["a fill dropped", events.filter((_, i) => i !== fill)]);
  const closed = events.findIndex((e) => e.type === "closed" && e.releasedWh > 0n);
  if (closed >= 0) {
    out.push(["a release made larger", events.map((e, i) => (i === closed ? { ...e, releasedWh: e.releasedWh + 1n } : e))]);
  }
  const opened = at("opened");
  if (opened >= 0) {
    const e = events[opened];
    out.push(["a placement booked on the other side", events.map((x, i) => (i === opened ? { ...x, side: 1 - e.side } : x))]);
    out.push(["a placement booked one slot later", events.map((x, i) => (i === opened ? { ...x, slot: e.slot + 1 } : x))]);
  }
  return out;
}

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x ${steps} ledger writes, two markets, two accounts, on an in-process chain ...`);
  const { ledger, checkpoints } = await runLedgerScenarios({ seeds, steps, firstSeed });
  const events = await readLedgerEvents(ledger);
  await connection.close();

  let failures = 0;
  const report = verifyLedger(events, checkpoints);
  const markets = new Set(events.map((e) => e.market.toLowerCase())).size;
  say(`\n${events.length} events, ${checkpoints.length} checkpoints, ${markets} markets`);
  if (report.disagreement) {
    failures++;
    const d = report.disagreement;
    say(`  DISAGREEMENT, ${d.what}: chain ${d.chain}, verifier ${d.verifier}, at block ${d.checkpoint?.block}`);
  } else {
    say(`  ${report.checked} totals compared, every one agrees`);
  }

  say("\nSelf-test: tampered logs the verifier must reject");
  for (const [name, tampered] of tamperings(events)) {
    const caught = verifyLedger(tampered, checkpoints).disagreement !== null;
    if (!caught) failures++;
    say(`  ${caught ? "caught" : "MISSED"}  ${name}`);
  }

  const summary = `ledger: ${report.checked} totals compared, ${failures === 0 ? "no disagreement" : `${failures} FAILURES`}`;
  console.log(quiet ? summary : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
