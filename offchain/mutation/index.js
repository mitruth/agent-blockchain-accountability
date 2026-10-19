// mutation: the mutation suite (spec 8). A mutant is one small defect put into
// a contract on purpose; it must make at least one test fail. A mutant that
// survives is a hole in the tests.
//
//   catalogs/   one file per part of the system: the mutants, and the tests
//               that should catch them
//   index.js    applies one mutant at a time, runs the tests, restores
//   cli.js      npm run mutate
//
// A mutant is { name, file, find, replace, nth?, tests? }: `find` must occur
// exactly once in `file`, or `nth` says which occurrence. Line endings are
// matched whatever the file uses. `tests`, when given, replaces the
// catalogue's list for that mutant: the tests of the code it breaks.
//
// The contract file is changed in place while its tests run. The original
// bytes are kept beside it as <file>.mutation-backup and restored afterwards,
// on Ctrl+C, and at the start of the next run if a run was killed.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { ROOT } from "../chain/paths.js";

import gate from "./catalogs/gate.js";
import ledger from "./catalogs/ledger.js";
import market from "./catalogs/market.js";
import window from "./catalogs/window.js";
import accounts from "./catalogs/accounts.js";
import policies from "./catalogs/policies.js";
import physical from "./catalogs/physical.js";
import pending from "./catalogs/pending.js";

export const CATALOGS = { gate, ledger, market, window, policies, physical, accounts };
export { pending };

const BACKUP = ".mutation-backup";
const TEST_TIMEOUT = 15 * 60 * 1000;

let current = null; // { file, original } while a mutant is applied

function restoreCurrent() {
  if (!current) return;
  fs.writeFileSync(current.file, current.original);
  fs.rmSync(current.file + BACKUP, { force: true });
  current = null;
}

process.on("SIGINT", () => {
  restoreCurrent();
  process.exit(130);
});

// One run at a time. The lock holds the running process's id; a lock whose
// process is gone was left by a killed run, and only then are its backups
// restored. Without this, a second run (or a recovery) would put the original
// back under a mutant another run is testing.
const LOCK = path.join(ROOT, "offchain", "mutation", ".running");

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

/**
 * Take the lock, restoring whatever a killed run left mutated. Throws if
 * another run is alive. Returns the files restored.
 */
export function acquireLock() {
  if (fs.existsSync(LOCK)) {
    const pid = Number(fs.readFileSync(LOCK, "utf8"));
    if (pid && pid !== process.pid && alive(pid)) {
      throw new Error(`Another mutation run (process ${pid}) is in progress; wait for it or stop it first`);
    }
  }
  const restored = recover();
  fs.writeFileSync(LOCK, String(process.pid));
  process.on("exit", () => {
    restoreCurrent();
    if (fs.existsSync(LOCK) && Number(fs.readFileSync(LOCK, "utf8")) === process.pid) fs.rmSync(LOCK);
  });
  return restored;
}

/** Put back any file a killed run left mutated. Returns the files restored. Call only holding the lock. */
function recover() {
  const restored = [];
  for (const catalog of Object.values(CATALOGS)) {
    for (const file of new Set(catalog.mutants.map((m) => m.file))) {
      const full = path.join(ROOT, file);
      if (fs.existsSync(full + BACKUP)) {
        fs.copyFileSync(full + BACKUP, full);
        fs.rmSync(full + BACKUP);
        restored.push(file);
      }
    }
  }
  return restored;
}

function run(command, args, timeout = TEST_TIMEOUT) {
  const p = spawnSync(command, args, { cwd: ROOT, shell: true, encoding: "utf8", timeout, maxBuffer: 64 * 1024 * 1024 });
  return { code: p.status, out: (p.stdout ?? "") + (p.stderr ?? ""), timedOut: p.error?.code === "ETIMEDOUT" };
}

/** The failing tests in Hardhat's Solidity test output: "  1) Contract#test_name()". */
function failingTests(out) {
  const names = new Set();
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^\s*\d+\)\s+(\w+)#(\w+)/);
    if (m) names.add(`${m[1]}.${m[2]}`);
  }
  return [...names];
}

/** Index of the nth (1-based) occurrence of `find` in `text`, or -1; and how many there are. */
function locate(text, find, nth) {
  const positions = [];
  for (let i = text.indexOf(find); i >= 0; i = text.indexOf(find, i + 1)) positions.push(i);
  if (nth) return { index: positions[nth - 1] ?? -1, count: positions.length };
  return { index: positions.length === 1 ? positions[0] : -1, count: positions.length };
}

/**
 * Apply one mutant, run the catalogue's tests (and the verifier, if the
 * catalogue asks), restore. Returns { verdict, by, failing, detail }:
 *
 *   caught           at least one test (or the verifier) failed
 *   NOT CAUGHT       everything passed with the defect in place
 *   did not build    the mutant does not compile: not a test of anything
 *   bad pattern      `find` is not where the catalogue says
 *
 * runCatalog turns NOT CAUGHT into "accepted" for a mutant that carries an
 * `accepted` reason in its catalogue.
 */
export function runMutant(catalog, mutant, { verifierRuns = { seeds: 3, steps: 40 } } = {}) {
  const file = path.join(ROOT, mutant.file);
  if (!fs.existsSync(file)) return { verdict: "bad pattern", detail: `no file ${mutant.file}` };
  const original = fs.readFileSync(file);
  const text = original.toString("utf8");
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  const find = mutant.find.replace(/\n/g, eol);
  const replace = mutant.replace.replace(/\n/g, eol);
  const { index, count } = locate(text, find, mutant.nth);
  if (index < 0) return { verdict: "bad pattern", detail: `${count} occurrences${mutant.nth ? `, wanted #${mutant.nth}` : ""}` };

  current = { file, original };
  fs.writeFileSync(file + BACKUP, original);
  fs.writeFileSync(file, text.slice(0, index) + replace + text.slice(index + find.length));
  try {
    if (catalog.runner === "forge-docker") return forgeInDocker(catalog);
    const tests = run("npx", ["hardhat", "test", "solidity", ...(mutant.tests ?? catalog.tests)]);
    const compiled = tests.out.includes("Running Solidity tests");
    if (!compiled) return { verdict: "did not build", detail: tests.out.split(/\r?\n/).find((l) => /Error/.test(l)) ?? "" };

    const by = [];
    const failing = failingTests(tests.out);
    if (tests.code !== 0) by.push("tests");

    if (catalog.verifier) {
      const build = run("npx", ["hardhat", "build", "--no-tests"]);
      if (build.code === 0) {
        const v = run("node", ["offchain/verifier/cli.js", "--quiet", "--seeds", String(verifierRuns.seeds), "--steps", String(verifierRuns.steps)]);
        if (v.code !== 0) by.push("verifier");
      }
    }
    return { verdict: by.length ? "caught" : "NOT CAUGHT", by, failing, detail: tests.timedOut ? "tests timed out" : "" };
  } finally {
    restoreCurrent();
  }
}

/**
 * The Foundry-only tests, in the Foundry image (forge.exe is blocked on this
 * machine). Assumes Docker is running and the volume foundry-svm holds the
 * compilers; never starts Docker itself.
 *
 * Docker is called with an argument list and no host shell: on Windows a host
 * shell is cmd.exe, which does not take single quotes as quoting, and the
 * container's sh then received a broken command.
 */
function forgeInDocker(catalog) {
  const repo = ROOT.replace(/\\/g, "/");
  const match = catalog.tests.map((t) => `--match-path "${t}"`).join(" ");
  const p = spawnSync(
    "docker",
    [
      "run", "--rm", "-v", `${repo}:/repo`, "-v", "foundry-svm:/home/foundry/.svm", "-w", "/repo",
      "--entrypoint", "sh", "ghcr.io/foundry-rs/foundry:v1.8.5", "-c", `forge test ${match} 2>&1`,
    ],
    { cwd: ROOT, encoding: "utf8", timeout: TEST_TIMEOUT, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, MSYS_NO_PATHCONV: "1" } },
  );
  const out = (p.stdout ?? "") + (p.stderr ?? "");
  if (out.includes("Compiler run failed") || !out.includes("Suite result")) {
    return { verdict: "did not build", detail: out.split(/\r?\n/).find((l) => /Error|error/.test(l)) ?? "" };
  }
  const failing = out.split(/\r?\n/).filter((l) => l.startsWith("[FAIL")).map((l) => l.slice(0, 120));
  return { verdict: failing.length ? "caught" : "NOT CAUGHT", by: failing.length ? ["forge tests"] : [], failing, detail: "" };
}

/** Every mutant whose `find` is not where the catalogue says, without running anything. */
export function stalePatterns(catalog) {
  const stale = [];
  for (const mutant of catalog.mutants) {
    const file = path.join(ROOT, mutant.file);
    if (!fs.existsSync(file)) {
      stale.push({ name: mutant.name, detail: `no file ${mutant.file}` });
      continue;
    }
    const text = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
    const { index, count } = locate(text, mutant.find, mutant.nth);
    if (index < 0) stale.push({ name: mutant.name, detail: `${count} occurrences${mutant.nth ? `, wanted #${mutant.nth}` : ""}` });
  }
  return stale;
}

/** Run every mutant of a catalogue (or those whose name contains `only`). */
export function runCatalog(catalog, { only, log = () => {}, ...options } = {}) {
  const rows = [];
  for (const mutant of catalog.mutants) {
    if (only && !mutant.name.includes(only)) continue;
    const result = runMutant(catalog, mutant, options);
    // A survivor the catalogue explains (a fault in a test double, say) is
    // reported as accepted, with its reason, rather than as a hole.
    if (result.verdict === "NOT CAUGHT" && mutant.accepted) {
      result.verdict = "accepted";
      result.detail = mutant.accepted;
    }
    const row = { catalog: catalog.name, name: mutant.name, ...result };
    rows.push(row);
    log(row);
  }
  return rows;
}

/** Leave the artifacts matching the restored sources. */
export function rebuild() {
  return run("npx", ["hardhat", "build", "--no-tests"]).code === 0;
}
