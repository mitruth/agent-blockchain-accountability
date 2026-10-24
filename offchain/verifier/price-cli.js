// npm run verify:price                      3 seeds of 120 steps
// node offchain/verifier/price-cli.js --seeds 10 --steps 300
// node offchain/verifier/price-cli.js --quiet    one line; exit code 1 on any failure
//
// A3T and S7 (spec v0.2 section 5): the chain's verdicts, figures and credits
// against the verifier's own arithmetic from the event log, then the same log,
// tampered, which the verifier must reject. Runs on a fresh in-process chain.
// Needs the contracts built (npm run build).

import { useInProcessChain } from "../chain/index.js";
import { runPriceScenarios, PRICE_CONFIG } from "./price-fuzz.js";
import { verifyPrice } from "./price.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? Number(process.argv[i + 1]) : fallback;
}

const seeds = option("seeds", 3);
const steps = option("steps", 120);
const firstSeed = option("first-seed", 1);
const quiet = process.argv.includes("--quiet");
const say = quiet ? () => {} : console.log;

const edit = (history, index, change) => history.map((e, i) => (i === index ? change(e) : e));
const find = (history, test) => history.findIndex(test);

/** Tampered histories: each must produce a disagreement. */
function tamperings(history) {
  const out = [];
  const band = find(history, (e) => e.type === "submission" && e.a3t);
  if (band >= 0) out.push(["an A3T refusal hidden", edit(history, band, (e) => ({ ...e, a3t: false }))]);
  const charged = find(history, (e) => e.type === "submission" && e.orderId && e.s7.valueAfter > e.s7.valueBefore);
  if (charged >= 0) out.push(["an S7 charge under-reported", edit(history, charged, (e) => ({ ...e, s7: { ...e.s7, valueAfter: e.s7.valueAfter - 1n } }))]);
  const credit = find(history, (e) => e.type === "release" && e.credit && e.credit.credited > 0n);
  if (credit >= 0) out.push(["a credit inflated", edit(history, credit, (e) => ({ ...e, credit: { ...e.credit, credited: e.credit.credited + 1n } }))]);
  // The tariff in force at the first charged placement, raised and lowered.
  let tariff = -1;
  for (let i = charged; i >= 0; i--) if (history[i].type === "tariff") { tariff = i; break; }
  if (tariff >= 0) {
    const shift = (d) => (e) => ({ ...e, retail: e.retail.map((r) => r + d), feedIn: e.feedIn.map((f) => (f + d > 0n ? f + d : 0n)) });
    out.push(["a tariff raised", edit(history, tariff, shift(1000n))]);
    out.push(["a tariff lowered", edit(history, tariff, shift(-1000n))]);
  }
  return out;
}

async function main() {
  const connection = await useInProcessChain();
  say(`Running ${seeds} seeds x ${steps} steps of A3T and S7 on an in-process chain ...`);
  const history = await runPriceScenarios({ seeds, steps, firstSeed });
  await connection.close();

  let failures = 0;
  const report = verifyPrice(history, PRICE_CONFIG);
  const subs = history.filter((e) => e.type === "submission");
  say(
    `\n${subs.length} submissions (${subs.filter((e) => e.a3t).length} outside A3T's band or unjudged, ` +
      `${subs.filter((e) => e.s7.verdict === 2).length} refused by S7, ${report.placed} placed), ` +
      `${history.filter((e) => e.type === "tariff").length} tariffs, ${report.credits} credits`,
  );
  if (report.disagreement) {
    failures++;
    const d = report.disagreement;
    say(`  DISAGREEMENT, ${d.what}: chain ${d.chain}, verifier ${d.verifier}, at ${d.event.at}`);
  } else {
    say(`  ${report.checked} figures compared, every one agrees`);
  }

  say("\nSelf-test: tampered logs the verifier must reject");
  for (const [name, tampered] of tamperings(history)) {
    const caught = verifyPrice(tampered, PRICE_CONFIG).disagreement !== null;
    if (!caught) failures++;
    say(`  ${caught ? "caught" : "MISSED"}  ${name}`);
  }

  const summary = `price: ${report.checked} figures compared, ${failures === 0 ? "no disagreement" : `${failures} FAILURES`}`;
  console.log(quiet ? summary : `\n${summary}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
