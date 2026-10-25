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
import oracle2 from "./catalogs/oracle2.js";
import breaker from "./catalogs/breaker.js";
import price from "./catalogs/price.js";
import roundtrip from "./catalogs/roundtrip.js";
import delivery from "./catalogs/delivery.js";
import envelope from "./catalogs/envelope.js";
import pending from "./catalogs/pending.js";

export const CATALOGS = { gate, ledger, market, window, policies, physical, oracle2, breaker, price, roundtrip, delivery, envelope, accounts };
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
 *
 * The tests run in Foundry's Docker image unless `runner` is "hardhat". On
 * 24 October a mutant took 17-18 s there, failing tests or not, and 71-87 s
 * under Hardhat 3, which spends about a minute on any run with a failing
 * test (every caught mutant has one). A catalogue whose tests need Foundry
 * (`runner: "forge-docker"`) always runs there.
 */
export function runMutant(catalog, mutant, { verifierRuns = { seeds: 3, steps: 40 }, runner = "forge-docker" } = {}) {
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
    const files = mutant.tests ?? catalog.tests;
    const forge = catalog.runner === "forge-docker" || runner === "forge-docker";
    const tests = forge ? forgeInDocker(files) : hardhatTests(files);
    if (!tests.compiled) return { verdict: "did not build", detail: tests.detail };

    const by = [];
    const failing = tests.failing;
    if (tests.failed) by.push("tests");

    if (catalog.verifier) {
      const build = run("npx", ["hardhat", "build", "--no-tests"]);
      if (build.code === 0) {
        const v = run("node", ["offchain/verifier/cli.js", "--quiet", "--seeds", String(verifierRuns.seeds), "--steps", String(verifierRuns.steps)]);
        if (v.code !== 0) by.push("verifier");
      }
    }
    return { verdict: by.length ? "caught" : "NOT CAUGHT", by, failing, detail: tests.detail };
  } finally {
    restoreCurrent();
  }
}

/** The test files under Hardhat. Returns { compiled, failed, failing, detail }. */
function hardhatTests(files) {
  const tests = run("npx", ["hardhat", "test", "solidity", ...files]);
  if (!tests.out.includes("Running Solidity tests")) {
    return { compiled: false, detail: tests.out.split(/\r?\n/).find((l) => /Error/.test(l)) ?? "" };
  }
  return { compiled: true, failed: tests.code !== 0, failing: failingTests(tests.out), detail: tests.timedOut ? "tests timed out" : "" };
}

/** Whether the Docker engine answers. The runner never starts it. */
export function dockerUp() {
  return spawnSync("docker", ["info", "--format", "{{.ServerVersion}}"], { encoding: "utf8", timeout: 30_000 }).status === 0;
}

/**
 * The test files in the Foundry image (forge.exe is blocked on this machine).
 * Assumes Docker is running and the volume foundry-svm holds the compilers;
 * never starts Docker itself. Foundry takes one --match-path, so several
 * files become one brace glob. Returns { compiled, failed, failing, detail }.
 *
 * Docker is called with an argument list and no host shell: on Windows a host
 * shell is cmd.exe, which does not take single quotes as quoting, and the
 * container's sh then received a broken command.
 */
function forgeInDocker(files) {
  const repo = ROOT.replace(/\\/g, "/");
  const glob = files.length === 1 ? files[0] : `{${files.join(",")}}`;
  const p = spawnSync(
    "docker",
    [
      "run", "--rm", "-v", `${repo}:/repo`, "-v", "foundry-svm:/home/foundry/.svm", "-w", "/repo",
      "--entrypoint", "sh", "ghcr.io/foundry-rs/foundry:v1.8.5", "-c", `forge test --match-path '${glob}' 2>&1`,
    ],
    { cwd: ROOT, encoding: "utf8", timeout: TEST_TIMEOUT, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, MSYS_NO_PATHCONV: "1" } },
  );
  const out = (p.stdout ?? "") + (p.stderr ?? "");
  if (out.includes("Compiler run failed") || !out.includes("Suite result")) {
    return { compiled: false, detail: out.split(/\r?\n/).find((l) => /Error|error/.test(l)) ?? "" };
  }
  // "Ran 20 tests for test/x.t.sol:XTest", then "[FAIL: reason] test_name() (gas: 1)";
  // the summary repeats each failure under "Encountered 1 failing test in test/x.t.sol:XTest".
  const failing = [];
  let suite = "";
  for (const line of out.split(/\r?\n/)) {
    const s = line.match(/^(?:Ran \d+ tests? for|Encountered \d+ failing tests? in) [^:]+:(\w+)/);
    if (s) suite = s[1];
    const f = line.match(/^\[FAIL[^\]]*\]\s+(\w+)\(/);
    if (f && !failing.includes(`${suite}.${f[1]}`)) failing.push(`${suite}.${f[1]}`);
  }
  const failed = failing.length > 0 || /Suite result: FAILED/.test(out);
  return { compiled: true, failed, failing, detail: p.error?.code === "ETIMEDOUT" ? "tests timed out" : "" };
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
