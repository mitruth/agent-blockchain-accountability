// npm run mutate                          every catalogue (about 20 s a mutant)
// npm run mutate -- window                one catalogue: gate, ledger, market, window
// npm run mutate -- window --only stream  the mutants whose name contains "stream"
// npm run mutate -- --list                the catalogues, their sizes, and what is pending
// npm run mutate -- --check               every pattern still where its catalogue says
// npm run mutate -- window --report docs/reports/mutation-window.md
// npm run mutate -- accounts              the real-account tests (Foundry only)
// npm run mutate -- policies --all-tests  every mutant against the catalogue's whole list
// npm run mutate -- price --hardhat       the tests under Hardhat instead (about 5x slower)
//
// The tests run in Foundry's Docker image: start Docker Desktop first; the
// runner never starts it. Changes contract files in place while it runs (and
// restores them): do not edit contracts or run other builds meanwhile.

import fs from "node:fs";
import { CATALOGS, pending, acquireLock, runCatalog, rebuild, stalePatterns, dockerUp } from "./index.js";

const args = process.argv.slice(2);
const value = (flag) => (args.includes(flag) ? args[args.indexOf(flag) + 1] : undefined);
const only = value("--only");
const reportFile = value("--report");
const names = args.filter((a, i) => !a.startsWith("--") && !["--only", "--report"].includes(args[i - 1]));

if (args.includes("--list")) {
  for (const c of Object.values(CATALOGS)) {
    console.log(`${c.name.padEnd(8)} ${String(c.mutants.length).padStart(3)} mutants   tests: ${c.tests.join(", ")}${c.verifier ? "   + verifier" : ""}`);
  }
  console.log("\nPending, for the step that builds their code:");
  for (const p of pending) console.log(`  step ${p.step}  ${p.name}  (${p.note})`);
  process.exit(0);
}

if (args.includes("--check")) {
  let bad = 0;
  for (const c of Object.values(CATALOGS)) {
    const stale = stalePatterns(c);
    bad += stale.length;
    console.log(`${c.name.padEnd(8)} ${stale.length ? `${stale.length} STALE` : "every pattern found once"}`);
    for (const s of stale) console.log(`  ${s.name}: ${s.detail}`);
  }
  process.exit(bad ? 1 : 0);
}

// Foundry in Docker by default; --hardhat runs the tests under Hardhat, where
// a catalogue that needs Foundry (accounts) is skipped. (--docker, which
// used to be needed for accounts, is accepted and changes nothing.)
const allTests = args.includes("--all-tests");
const runner = args.includes("--hardhat") ? "hardhat" : "forge-docker";

let chosen = names.length ? names.map((n) => CATALOGS[n] ?? (console.error(`No catalogue ${n}`), process.exit(2))) : Object.values(CATALOGS);
if (runner === "hardhat") {
  const docker = chosen.filter((c) => c.runner === "forge-docker");
  if (docker.length) console.log(`Skipping ${docker.map((c) => c.name).join(", ")}: needs Foundry in Docker`);
  chosen = chosen.filter((c) => c.runner !== "forge-docker");
}
if ((runner === "forge-docker" || chosen.some((c) => c.runner === "forge-docker")) && !dockerUp()) {
  console.error("Docker is not running. Start Docker Desktop, or pass --hardhat to run the tests under Hardhat.");
  process.exit(2);
}
try {
  const restored = acquireLock();
  if (restored.length) console.log(`Restored after an interrupted run: ${restored.join(", ")}`);
} catch (error) {
  console.error(error.message);
  process.exit(2);
}

const all = [];
const started = Date.now();
for (const catalog of chosen) {
  const where = runner === "forge-docker" || catalog.runner === "forge-docker" ? "Foundry in Docker" : "Hardhat";
  console.log(`\n${catalog.name}: ${catalog.mutants.length} mutants, tests ${catalog.tests.join(", ")}${catalog.verifier ? ", and the verifier" : ""}, under ${where}`);
  const run = allTests ? { ...catalog, mutants: catalog.mutants.map(({ tests, ...m }) => m) } : catalog;
  const rows = runCatalog(run, {
    only,
    runner,
    log: (r) =>
      console.log(
        `  ${r.verdict.padEnd(13)} ${r.name}` +
          (r.by?.length ? `  [${r.by.join(" + ")}${r.failing?.length ? `: ${r.failing.length} failing, e.g. ${r.failing[0]}` : ""}]` : "") +
          (r.detail ? `  (${r.detail})` : ""),
      ),
  });
  all.push(...rows);
}
rebuild();

const count = (v) => all.filter((r) => r.verdict === v).length;
const minutes = ((Date.now() - started) / 60000).toFixed(1);
console.log(
  `\n${all.length} mutants in ${minutes} min: ${count("caught")} caught, ${count("accepted")} accepted survivors, ${count("NOT CAUGHT")} not caught, ` +
    `${count("did not build")} did not build, ${count("bad pattern")} bad patterns`,
);
for (const r of all.filter((r) => r.verdict === "NOT CAUGHT")) console.log(`  not caught: ${r.catalog} / ${r.name}`);

if (reportFile) {
  const lines = [
    `# Mutation run, ${new Date().toISOString().slice(0, 10)}`,
    "",
    `${all.length} mutants: ${count("caught")} caught, ${count("accepted")} accepted survivors, ${count("NOT CAUGHT")} not caught, ${count("did not build")} did not build, ${count("bad pattern")} bad patterns.`,
    "",
    "| Catalogue | Mutant | Verdict | Caught by, or why accepted |",
    "| --------- | ------ | ------- | -------------------------- |",
    ...all.map((r) => `| ${r.catalog} | ${r.name} | ${r.verdict} | ${r.verdict === "accepted" ? r.detail : (r.by?.join(", ") ?? "")} |`),
    "",
  ];
  fs.writeFileSync(reportFile, lines.join("\n"));
  console.log(`\nWritten: ${reportFile}`);
}
process.exit(count("NOT CAUGHT") + count("bad pattern") === 0 ? 0 : 1);
