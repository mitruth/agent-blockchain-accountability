# Project guide

What every file does, and how to run everything yourself.

For *why* a design choice was made, see `docs/decisions/design-decisions.md`. This file is the map and
the runbook.

---

## 1. What this project is, in one page

A home energy agent decides when to buy electricity from the grid, when to sell
back, and when to charge or discharge a battery. The owner delegates spending
authority to it. **This repository is the layer that makes that delegation
safe:** an on-chain policy the agent operates under and cannot change, plus
evidence that every action stayed inside it.

The enforced rule is narrow on purpose:

```
windowSum(day) = sum of net spend over [day - 6, day]        (7 days, both ends included)
require( windowSum(day) <= cap )
```

Net spend is **signed**. On a sunny day the house can earn more from exporting
than it spends importing, and that credit reduces the rolling sum.

Per-transaction limits are not the point — anyone can do those. The contribution
is **sequence-level** enforcement: catching cumulative exposure built out of
individually legal transactions.

### The three keys

The whole security argument rests on these being three different keys.

| Key | Can | Cannot |
|---|---|---|
| **Owner** | Change the policy, install/uninstall modules, set who may write the ledger, revoke the agent, unpause after a delay | — |
| **Agent** (session key) | Submit one daily spend record | Touch the policy, install or uninstall anything, write the ledger directly, pause |
| **Guardian** | Pause spending and pause the agent | Change any config value, unpause, write the ledger |

The original student version used **one** key as both owner and agent, so the
agent could raise its own spending cap. That was audit finding F1 and it is the
reason this rebuild exists — a policy the agent can change is not delegated
authority, and no number measured on that version means anything.

### The proposer is never trusted

The governing principle. Every output is checked against a reference the thing
being checked does not control. This is why there are **two independent
implementations** of the same rule — the Solidity, and a Python verifier written
by someone who never saw the Solidity. If they only ever agree, one of them is
probably just a copy of the other, and neither is evidence.

---

## 2. Two generations of code in here

This matters for reading the repo, and it is the main thing that will confuse
you.

- **The student's original** — built around a single contract,
  `SpendingLimitModule`, with one key doing everything. That contract and its
  tooling were deleted in the rebuild. All of it is preserved at commit
  `1f49b7e` if you ever need to look.
- **The rebuild** — `contracts/`, `test/`, `verifier/`, `differential/`. This is
  the live code. It runs entirely on your machine; no testnet, no gas, no keys.

The audited original is preserved at commit `1f49b7e` if you ever need it.

---

## 3. File and folder map

### `contracts/` — the on-chain enforcement layer (live)

| File | Lines | What it does |
|---|---|---|
| `PolicyConfig.sol` | 369 | Holds the cap, the window length, pause state, and who the three keys are. Owner-only writes. Every change bumps a version and emits the full new state plus the day it applies from, so anyone can reconstruct the cap on any past day from events alone. |
| `SpendLedger.sol` | 177 | The accounting. One signed record per day. **Deployed once, never redeployed** — so its storage layout is permanent. Who may write to it is an explicit owner-controlled list, deliberately *not* "whoever is an installed module". |
| `SpendValidator.sol` | 155 | The rule itself. Reads the config, writes the ledger, enforces `windowSum <= cap`. Holds no durable state, so it can be swapped without resetting anyone's spending window. This is the upgradeable piece. |
| `SmartAccount.sol` | 166 | The account that holds funds. Owner-only. Runs every installed validator before letting a transfer through, and refuses to run at all if no validator is selected. |
| `interfaces/IModule.sol` | 10 | Install/uninstall/type hooks a module must expose. |
| `interfaces/IValidator.sol` | 16 | The `validateTransaction` hook the account calls. |

**How they fit together:** `PolicyConfig` says what the rule *is*. `SpendLedger`
records what *happened*. `SpendValidator` compares the two. `SmartAccount` holds
the money and calls the validator. Config and ledger are permanent; the
validator can be replaced.

### `test/` — local tests (live, this is where to look first)

Solidity tests, run on a local simulated chain. No network, no keys, no cost.

| File | Lines | What it proves |
|---|---|---|
| `Authorization.t.sol` | 440 | The permission table above, **one test per row**. Every "cannot" is a real test, including the sneaky escalation paths — if the agent could uninstall the validator, the cap is gone and restricting the policy never mattered. |
| `Enforcement.t.sol` | 379 | The rule. Equality at the cap passes; one over fails; the oldest day counts and drops out a day later; export credit reduces the sum; a paused day is a zero not a gap; swapping the validator does not reset the window. |
| `Differential.t.sol` | 243 | Replays scenarios through the real contracts and prints the chain's verdict as CSV, for comparison against the Python verifier. |
| `ArmData.sol` | 35 | **Generated.** A year of real daily spend for each simulation arm, packed as bytes so the tests can replay actual data. Regenerate with `differential/gen_arm_data.py`. |

### `verifier/` — the independent second implementation (live)

Python. Written from `enforcement-rule.md` alone by an author that was blocked from reading
any Solidity. That isolation is the entire value: it can *disagree*.

| File | Lines | What it does |
|---|---|---|
| `verify.py` | 740 | The implementation, plus a CLI. Recomputes every day's window from scratch over the whole record set — no running total — precisely because the chain uses a running walk. |
| `test_verify.py` | 597 | 58 tests, written against the spec. |
| `fixtures/` | — | Small hand-made inputs for the CLI. |

Its two documents live under `docs/`: the specification it was written from is
`docs/spec/enforcement-rule.md`, and its notes and ambiguity list are
`docs/verifier/implementation-notes.md`.

### `differential/` — running both and diffing them (live)

| File | What it does |
|---|---|
| `run_diff.py` | The main event. Runs the Solidity tests, captures the chain's verdict, feeds the same policy events to the Python verifier, and reports every day where they disagree. |
| `gen_arm_data.py` | Regenerates `test/ArmData.sol` from the record CSVs. |
| `data/` | Scratch output, regenerated every run, gitignored. |

### `scripts/` — key generation (live)

| File | What it does |
|---|---|
| `keys/generate_roles.js` | Generates the three keys — owner, agent, guardian — with a note on what each may do. |
| `keys/generate_destination.js` | Generates a throwaway address to receive test transfers. |

The student's original testnet tooling lived here: deploy scripts, limit
readers, an LLM agent that proposed new spending limits, and five "tests" that
ran against live Base Sepolia, spent real gas, waited on network sync and
printed results rather than asserting them. All of it was built around
`SpendingLimitModule` and a single key holding both owner and agent authority.
The contract was deleted in the rebuild and the scripts were removed with it;
they are preserved at commit `1f49b7e`.

**There is currently no deployment path for the rebuilt contracts.** The old
scripts could not have provided one — they deploy a contract that no longer
exists, and the new wiring needs three keys plus an explicit ledger allowlist
step the old flow had no concept of.

### `docs/` — all documentation, one folder per category

| Folder | Holds |
|---|---|
| `docs/guide/` | This file. The map and the runbook. |
| `docs/decisions/` | `design-decisions.md` — every non-obvious choice, why it was taken, what was rejected, and the open questions. |
| `docs/spec/` | `enforcement-rule.md` — the rule as behaviour. Both implementations are written from this; neither is derived from the other. |
| `docs/verifier/` | `implementation-notes.md` — **read the ambiguity list.** 22 places the spec was under-determined and 7 the author judged wrong. The most useful document here. |

New documentation goes in a category folder under `docs/`, never at the
repository root. Add a folder when a genuinely new category appears —
`docs/security/` and `docs/evaluation/` are the two expected next.

### Data and config

| File | What it is |
|---|---|
| `records_B0.csv`, `records_B1.csv`, `records_B2.csv` | One simulated year (365 days) of the same house under three different controllers. `B0` = simple if-then rules. `B1` = optimal with perfect foresight (unrealistic best case). `B2` = optimal using forecasts (realistic). The column that matters is `spendMilliUsd` — daily net cost in thousandths of a dollar, signed. |
| `hardhat.config.js` | Build and network config. Loads three separate keys, never one. |
| `remappings.txt` | Points `forge-std/` at `node_modules`. |
| `.env.example` | Template. The real `.env` holds private keys and is gitignored. |

---

## 4. Runbook

Nothing below needs a network, a wallet, or any money. It all runs locally.

### One-time setup

```bash
npm install
```

Python needs nothing beyond the standard library. Check you have it:

```bash
python --version
```

### The four commands that matter

**1. Run the Solidity tests.** This is the main one.

```bash
npm test
```

Expect **57 passing**. That is 30 authorization tests, 21 enforcement tests, and
6 differential scenarios. Takes a minute or two; the first run downloads the
compiler.

**2. Run the Python verifier's own tests.**

```bash
python -m unittest discover -s verifier -p "test_*.py" -v
```

Expect **58 tests, OK**.

**3. Run the differential.** The interesting one — runs both implementations and
diffs them.

```bash
python differential/run_diff.py
```

Expect a table, and **28 disagreements**, all in the `churn` scenario. That is
the known open defect (F7), not a regression. The three real data arms should
show **0**.

**4. Try the verifier by hand on a small example.**

```bash
python verifier/verify.py --records verifier/fixtures/records_example.csv --policy verifier/fixtures/policy_example.csv --out -
```

You will see one breach on day 5 and a negative day on day 2 reducing the
window.

### Useful extras

Compile without testing:

```bash
npx hardhat compile
```

Generate three fresh keys:

```bash
node scripts/keys/generate_roles.js
```

See the rebuilt daily records reproduce byte-for-byte from the simulation (run
from the *other* repo, `Demo_PlanApplyEvaluate`):

```bash
python scripts/export_records.py
```

---

## 5. How to read the output

### `npm test`

Test names are written to be read as sentences. `test_agent_mayNotWritePolicyConfig`
is the F1 finding in test form. `test_oldestDayIsIncludedInWindow` pins one of
the two classic off-by-one errors.

A failure prints the contract, the line, and the revert reason.

### `differential/run_diff.py`

The table has one row per scenario:

- `days` — day-rows compared
- `policy` — how many policy changes that scenario made
- `breaches(chain)` — days the chain judged over the cap. Not errors; the strict
  cap is *meant* to bind.
- `disagreements` — **this is the number that matters.** Anything other than the
  known 28 in `churn` is new and worth investigating.

### Proving the tests actually work

A passing suite means nothing if the tests cannot fail. Break something on
purpose and confirm a test catches it — change `<=` to `<` on the cap comparison
in `contracts/SpendValidator.sol` (`sumAfter > regime.cap` → `sumAfter >= regime.cap`),
run `npm test`, and expect 4 failures. Then undo it.

This is the discipline the whole project runs on, and step 4 automates it as a
mutation suite.

---

## 6. Current state

Steps 1–3 of the rebuild are done and committed.

| Finding | Status |
|---|---|
| F1 — agent could change its own cap | **Fixed.** Three keys, permission table asserted. |
| F2 — no independent verifier | **Fixed.** Python verifier, written blind, differential running. |
| F3 — negative days had no credit path | **Fixed.** Signed `int256` end to end. |
| F4 — rounding claimed but untested | Half-done. Correct in `export_records.py`; asserted in the verifier; no contract-side path yet. |
| F5 — agent could empty the window alone | **Fixed.** Day index derived on-chain from block time. |
| F6 — validated and recorded numbers differ | **Open.** A decision, not a bug — see `docs/decisions/design-decisions.md` Q2. |
| F7 — event lacks the submission day | **Open.** Found by the differential; needs a contract change. |

**What is fair to say right now:** contract implemented, test suite present, two
independent implementations agreeing on 1,095 days of real data, one schema
defect found and specified.

**What is not yet fair to say:** that enforcement is validated. The evaluation is
not finished, and F6, F7 and the cap calibration are all open.
