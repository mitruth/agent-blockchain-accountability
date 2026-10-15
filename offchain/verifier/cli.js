// npm run verify:window                    8 seeds of 60 steps per class
// node offchain/verifier/cli.js --seeds 40 --steps 100 --first-seed 1000
// node offchain/verifier/cli.js --quiet    one line; exit code 1 on any failure
//
// Runs on a fresh chain inside this process: it needs no node and touches
// none. Needs the contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runScenarios } from "./fuzz.js";
import { readHistories } from "./history.js";
import { verifyAll } from "./verify.js";
import { selfTest } from "./selftest.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? Number(process.argv[i + 1]) : fallback;
}

const seeds = option("seeds", 8);
const steps = option("steps", 60);
const firstSeed = option("first-seed", 1);
const quiet = process.argv.includes("--quiet");
const say = quiet ? () => {} : console.log;

const ratio = (amount, cap) => (Number(amount) / Number(cap)).toFixed(2);

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x 5 classes x ${steps} steps, and the boundary burst, on an in-process chain ...`);
  const probe = await runScenarios({ seeds, steps, firstSeed });
  const histories = await readHistories(probe);
  const reports = verifyAll(histories);
  await connection.close();

  let failures = 0;
  let checked = 0;

  // The scripted boundary burst: windows 1 and 2.
  const sliding = reports.find((r) => r.id === 1n);
  const tumbling = reports.find((r) => r.id === 2n);
  say("\nBoundary burst: the cap at 23:59:58/59 and again at 00:00:01/02");
  say(`  SLIDING   admitted ${ratio(sliding.guarantees.g1.worst.amount, sliding.config.cap)} x cap within W - b`);
  say(`  TUMBLING  admitted ${ratio(tumbling.guarantees.burst.amount, tumbling.config.cap)} x cap within ${tumbling.guarantees.burst.to - tumbling.guarantees.burst.from} seconds`);
  if (sliding.guarantees.g1.worst.amount !== sliding.config.cap) failures++;
  if (tumbling.guarantees.burst.amount !== 2n * tumbling.config.cap) failures++;

  say("\nRandom histories");
  say("  window  class      checks  admitted  agrees  G1 max/cap  G2 max excess  burst/cap");
  for (const r of reports) {
    checked += r.checked;
    const g = r.guarantees ?? {};
    const agrees = !r.disagreement;
    if (!agrees || !g.holds) failures++;
    if (r.id < 10n) continue;
    say(
      `  ${String(r.id).padStart(6)}  ${r.kind.padEnd(9)} ${String(r.checked).padStart(7)}  ${String(r.admissions.length).padStart(8)}  ` +
        `${agrees ? "yes" : "NO "}     ` +
        (r.kind === "SLIDING"
          ? `${ratio(g.g1.worst.amount, r.config.cap).padStart(10)}  ${String(g.g2.worst.excess).padStart(13)}`
          : " ".repeat(25)) +
        (r.kind === "TUMBLING" ? `  ${ratio(g.burst.amount, r.config.cap).padStart(9)}` : ""),
    );
    if (r.disagreement) {
      const d = r.disagreement;
      say(`          first disagreement, ${d.what}: chain ${d.chain}, verifier ${d.verifier}, at ${d.event.at} (${d.event.type})`);
    }
    if (!g.holds) say(`          guarantee broken: ${JSON.stringify(g, (_, v) => (typeof v === "bigint" ? String(v) : v))}`);
  }

  const tampering = selfTest(histories);
  say("\nSelf-test: tampered histories the verifier must reject");
  for (const s of tampering) {
    say(`  ${s.caught === s.tried ? "caught" : "MISSED"}  ${s.caught}/${s.tried}  ${s.name}`);
    if (s.caught !== s.tried || s.tried === 0) failures++;
  }

  const summary = `${reports.length} windows, ${checked} figures compared, ${failures === 0 ? "no disagreement, every guarantee holds" : `${failures} FAILURES`}`;
  console.log(quiet ? `verifier: ${summary}` : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
