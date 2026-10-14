# Project guide

> **Earlier design.** This document describes the daily spend rule that came before
> Policy Spec v0.1 (`PolicyConfig`, `SpendLedger`, `SpendValidator`). It is kept for
> reference and is no longer maintained. The current project is described in
> `docs/guide/project-guide.md`.

What every file does, and how to run everything yourself.

**New to the project?** Start with `docs/earlier-design/hands-on-tour.md` — an hour of
running it, looking at real days, and breaking it on purpose.

For *why* a design choice was made, see `docs/earlier-design/design-decisions.md`.
For what comes next, see `docs/earlier-design/roadmap.md`. This file is the map and the
runbook.

---

## 1. What this project is, in one page

A home energy agent decides when to buy electricity from the grid, when to sell
back, and when to charge or discharge a battery. The owner delegates spending
authority to it. **This repository is the layer that makes that delegation
safe:** a spending cap the agent cannot change, spend the agent cannot
misreport, and evidence that anyone can recheck.

The rule:

```
spend(day)     = Σ over 48 half-hours (import × import price − export × export price)
windowSum(day) = Σ spend over [day − 6, day]              (7 days, both ends included)
the agent may act only while windowSum(last settled day) ≤ cap in force today
```

Spend is **signed**: on a sunny day the house can earn more from exporting than
it pays for importing, and that credit reduces the window.

Per-transaction limits are not the point. The contribution is **sequence-level**
enforcement: catching cumulative exposure built out of individually legal
actions.

### Who does what

Five keys. The security argument rests on their being different.

| Key | Does | Cannot |
|---|---|---|
| **Owner** | Sets the cap and window; chooses the meter and price oracle; installs modules; allowlists ledger writers; revokes the agent; unpauses after a delay | — |
| **Agent** (session key) | Transfers through the account, **only while authorised** | Change policy, install anything, write the ledger, pause, sign meter readings, publish prices |
| **Guardian** | Pauses spending and the agent | Change any setting, unpause, write the ledger |
| **Meter** | Signs each day's import and export readings | Anything else; can never be the agent's key |
| **Price publisher** | Publishes each day's prices, once | Anything else |

In this project the meter and the price publisher are **simulated**: the HEMS
simulator plays the meter, and a script publishes the real CAISO prices from the
dataset. Enforcement is sound *provided the meter and the publisher are honest*
— neither is the agent, and a real deployment would have both.

### How the audited version failed, and what changed

The student's original let one key act as owner and agent, so the agent could
raise its own cap (F1). The first rebuild separated the keys but still had the
agent **report its own daily spend** — so the cap bounded what the agent chose
to report (F8). The current design takes spend out of the agent's hands
entirely: it is computed on-chain from the meter's readings and the oracle's
prices.

### The proposer is never trusted

Every result is checked against a reference the thing being checked does not
control. That is why the rule is implemented **twice** — in Solidity, and in a
Python verifier written by an author who was never allowed to see the Solidity
— and the two are run against the same real data.

---

## 2. How a day flows

```
end of day d
   │
   ├── price publisher ── PriceOracle.publishDay(d, 48 import prices, 48 export prices)
   │                         stores a hash, emits the prices
   │
   ├── meter ───────────── signs (d, 48 import mWh, 48 export mWh)
   │
   └── anyone ──────────── SpendValidator.settleDay(readings + signature, prices)
                              ├─ day d has ended, and is the next unsettled day
                              ├─ prices match the oracle's hash
                              ├─ readings signed by the registered meter
                              ├─ spend = exact integer total, rounded once
                              └─ SpendLedger records it — even if over the cap

day d+1, the agent tries to transfer
   └── SmartAccount.execute ── asks SpendValidator.authorization()
                                  NoSessionKey | AgentPaused | SettlementStale | OverCap | Authorized
```

Two things worth noticing. An over-cap day is **recorded**, not refused —
refusing it used to leave a gap that counted as zero and handed the agent more
headroom after a breach. And **anyone** can settle a day, so an agent cannot hide
a bad day by not reporting it; if settlement stalls for more than two days, the
agent loses authority anyway.

---

## 3. File and folder map

### `contracts/` — the on-chain system

| File | Lines | What it does |
|---|---|---|
| `PolicyConfig.sol` | 441 | The cap and window, their history, pause state, and the registry of keys: owner, agent, guardian, meter, price oracle. Every policy change is versioned and emitted with the day it was made and the day it applies from. Lowering applies at once; raising waits for a window boundary. |
| `PriceOracle.sol` | 115 | One UTC day of 48 import and 48 export prices, published once, never amended. Stores a hash, emits the prices. |
| `MeterReadings.sol` | 110 | Library. Checks a meter signature over a day's readings (EIP-712), bound to this chain and this ledger. |
| `SpendMath.sol` | 69 | Library. Daily spend from readings and prices, exact, rounded once half away from zero. |
| `SpendValidator.sol` | 325 | Settles days, computes the window, and decides whether the agent is authorised. Holds no durable state, so it can be replaced without resetting anyone's window. |
| `SpendLedger.sol` | 271 | One signed spend figure per day, in a ring holding the last 365 days. Deployed once, never replaced. Only allowlisted writers may write. |
| `SmartAccount.sol` | 176 | Holds the money. The owner or the agent may transfer; every installed validator must agree. Refuses everything if no validator is selected. |
| `interfaces/` | 26 | `IModule`, `IValidator`. |

### `test/` — Solidity tests, 144 in all

Run on a local simulated chain. No network, no keys, no cost.

| File | Tests | What it proves |
|---|---|---|
| `Authorization.t.sol` | 30 | The permission table, one test per row, including the escalation paths. |
| `PriceOracle.t.sol` | 18 | Only the publisher publishes; a day is final; a price vector cannot be passed off for another day or altered by one unit. |
| `MeterReadings.t.sol` | 21 | Only the meter's signature verifies; any change to readings, day, chain or ledger breaks it; the digest matches an independent EIP-712 encoder. |
| `Settlement.t.sol` | 22 | Spend on a real simulator day matches the simulator; rounding at the exact half in both signs; wrong signer, altered price, skipped day, unfinished day all refused; an over-cap day is recorded. |
| `Enforcement.t.sol` | 34 | Authorisation: over the cap, stale settlement, pause, revocation; the window rule; cap changes; upgrades; the regression test for the old breach-creates-headroom defect. |
| `Retention.t.sol` | 13 | The one-year ring: eviction frees a slot, a year-old record never reads as current, the window can never reach past it. |
| `Differential.t.sol` | 6 | Not assertions: replays real days through settlement and writes the chain's verdict for comparison. |

### `verifier/` — the independent second implementation

Python, standard library only. Written from `docs/earlier-design/enforcement-rule.md` by
an author who was blocked from reading any Solidity.

| File | What it does |
|---|---|
| `verify.py` | The verifier and its CLI. Recomputes every day's window from scratch over all settled days — deliberately unlike the chain's incremental walk. |
| `test_verify.py` | 53 tests written against the spec. |
| `fixtures/` | Small policy files for trying the CLI. |

### `differential/` — running both and comparing them

| File | What it does |
|---|---|
| `build_settlement_inputs.py` | Turns each arm's HEMS step log into what the meter and publisher would publish: 364 UTC days of readings and prices. Needs the sibling `Demo_PlanApplyEvaluate` repo. |
| `run_diff.py` | Builds inputs if missing, runs the chain replay, runs the verifier on the same data, compares day by day and policy write by policy write. |
| `show_day.py` | Shows one real day end to end: its 48 half-hours, the spend worked out step by step, and what the simulator, the chain and the verifier each concluded. `python differential/show_day.py B2 19158` |
| `data/` | Generated inputs and outputs. Not committed. |

The differential runs six scenarios, all on real simulator days:

| Scenario | Days | Cap (milli-USD, 7-day) | What it exercises |
|---|---|---|---|
| `B0`, `B1`, `B2` | 364 each | 100,000 | A full year per controller; a handful of breaches |
| `B2strict` | 364 | 18,096 | A tight cap: 51 breach days, authority withdrawn after each |
| `B2atCap` | 364 | 107,036 | The cap equals B2's largest window, reached once on day 19349 — the only scenario where equality at the cap actually occurs |
| `churn` | 60 | starts at 14,000 | Ten policy writes aimed at every cap-change rule: raises deferred to a boundary, a raise made on a boundary, a lowering cancelling a pending raise, an unchanged cap, a window-length-only change |

### `docs/`

| Folder | Holds |
|---|---|
| `guide/` | This file. |
| `plan/` | `roadmap.md` — status and next phases. |
| `decisions/` | `design-decisions.md` — every non-obvious choice, why, what was rejected, and open questions. |
| `spec/` | `enforcement-rule.md` — the rule as behaviour; both implementations follow it. |
| `verifier/` | `implementation-notes.md` — the verifier author's notes and **ambiguity list**. Worth reading: it is where the spec was challenged. |

### Everything else

| Item | What it is |
|---|---|
| `scripts/keys/` | `generate_roles.js` makes the owner, agent and guardian keys; `generate_destination.js` makes a throwaway payee. |
| `records_B0/B1/B2.csv` | The earlier per-day records (agent-reported era, degradation included, local days). Superseded by `differential/data/inputs/`; kept until caps are recalibrated. |
| `hardhat.config.js` | Build config. Loads separate keys, never one. Lets Solidity tests read and write `differential/data` only. |
| `remappings.txt` | Points `forge-std/` at `node_modules`. |
| `.env.example` | Template. The real `.env` holds keys and is gitignored. |

The audited original is preserved at commit `1f49b7e`.

---

## 4. Runbook

Nothing below needs a network, a wallet or any money.

### Setup, once

```bash
npm install
```

The differential also needs `pandas` for building inputs:

```bash
python -m pip install pandas
```

### The four commands that matter

**1. Solidity tests.** Expect **144 passing**, in about a minute.

```bash
npm test
```

**2. Verifier tests.** Expect **53 tests, OK**.

```bash
python -m unittest discover -s verifier -p "test_*.py"
```

**3. The differential.** Builds inputs if needed, replays real days on the
chain, runs the verifier on the same data, compares. Expect a table with
**0 disagreements** and **0 deferral findings**.

```bash
python differential/run_diff.py
```

**4. The verifier by hand**, on a real year of B2 readings (after command 3 has
built the inputs):

```bash
python verifier/verify.py --readings differential/data/inputs/B2.readings.csv --prices differential/data/inputs/prices.csv --policy verifier/fixtures/policy_genesis_w7.csv --out -
```

The first line is a summary: 364 settled days, 728,421 milli-USD, 26 breaches at
that fixture's 50,000 cap. Add `--policy-report report.csv` to see, for each
policy write, the effective day the rule derives next to the one the chain
recorded.

Exit codes: **0** clean, **1** at least one anomaly (an incomplete day, a gap, a
deferral mismatch, and similar — details on stderr), **2** unreadable input.
**Breaches do not change the exit code** — they are results, not anomalies — so
read the output rather than relying on the exit status. Try
`verifier/fixtures/policy_deferral_mismatch.csv` to see exit 1.

### Reading the differential table

| Column | Meaning |
|---|---|
| `days` | Settled days compared |
| `writes` | Policy writes, including genesis |
| `breaches` | Days over the cap. Not errors — tight caps are meant to bind |
| `unauth` | Days after which the agent lost authority |
| `disagree` | **The number that matters.** Any day where chain and verifier differ |
| `deferral` | Policy writes whose effective day the chain got wrong |
| `max \|chain-sim\|` | Largest gap between on-chain spend and the simulator's own cost; stays under 0.5 milli-USD |

### Proving the tests can fail

A passing suite means nothing if it cannot fail. Try one:

In `contracts/SpendMath.sol`, change `if (2 * absR >= d) {` to `if (false) {`.
That turns rounding into truncation. Run `npm test` — **3 tests fail**. Then run
`python differential/run_diff.py --differential-only` — **thousands of
disagreements** across every scenario. Undo the change.

`--differential-only` runs just the chain replay, so a deliberately broken
contract still gets compared instead of stopping at the failing suite.

---

## 5. What the checks have shown

### The two implementations agree on real data

| | |
|---|---|
| Settled days compared | 1,880 across six scenarios |
| Policy writes checked | 15 |
| Disagreements | **0** |
| On-chain spend vs the simulator's own cost | within 0.5 milli-USD on every day — the most one rounding per day allows |
| Annual totals vs the simulator | within 1.3 cents |

### The differential can see a broken chain

A clean comparison is only worth something if it can fail, so the contracts were
broken on purpose, one mutation at a time, and the whole differential re-run.
Of twelve mutations, ten were detected straight away — rounding truncated,
exports ignored, a raise applied immediately, the oldest window day dropped,
and so on. The other two taught something:

- **Refusing equality at the cap** went unseen because no real day's window
  landed exactly on the cap. That is why `B2atCap` exists.
- **A lowering that leaves the cancelled raise in storage** changes no answer at
  all — the lookup meets the lowering first — so no comparison of results can
  see it. A Solidity test checks the stored history instead.

Across all stages 74 distinct mutations have been run — against the Solidity
tests, and through the differential. Every gap they found was closed before the
stage was committed; the details are in each
commit message and in `docs/earlier-design/design-decisions.md`.

### Gas

Measured on the local chain. Printed by the tests whose names start
`test_reportGas`.

| Operation | Gas |
|---|---|
| Publish one day of 96 prices | 137,266 |
| Check a meter signature over one day of readings | 44,751 |
| Settle one day — both checks, the spend, the record, the window | 310,888 |
| Ledger write, first use of a ring slot | 95,226 |
| Ledger write, once the one-year ring has filled | 7,218 |

These are execution gas only. On Base the cost of calldata posted to Ethereum
comes on top, and a settlement carries 96 readings and 96 prices.

---

## 6. Current state

| Finding | Status |
|---|---|
| F1 — agent could change its own cap | **Fixed.** Separate keys, permission table asserted. |
| F2 — no independent verifier | **Fixed.** Blind verifier, differential clean on real data and mutation-tested. |
| F3 — negative days had no credit path | **Fixed.** Signed end to end. |
| F4 — rounding claimed but untested | **Fixed.** Once, on-chain, half away from zero, tested at the exact half both sides. |
| F5 — agent could empty the window alone | **Fixed.** The agent no longer settles days; days are consecutive and meter-signed. |
| F6 — validated and recorded numbers differ | **Fixed.** Spend is metered; transfers are gated, not counted. |
| F7 — policy event lacked the submission day | **Fixed.** Deferral now checked, not trusted. |
| F8 — agent reported its own spend | **Fixed.** Spend computed from meter readings and oracle prices. |

**Open, needing decisions (roadmap Phase B):**

- **Q8** — a raise waits for a window boundary, but the window rolls and never
  resets, so the wait does not keep new capacity out of a partly spent window
- **Q9** — shortening the window without changing the cap loosens at once
- **Q10** — next-day authorisation is conservative by one day
- **Q5** — owner key rotation

**Open, later:** Q11, cross-checking each policy write's submission day
against block time in an external evidence tool; cap recalibration (Q3);
deployment; adversarial evaluation.

**What is fair to say now:** contract implemented; spend computed from measured
inputs rather than reported by the agent; test suite present; an independent
verifier agreeing on real data; defects found and specified.

**Not yet fair to say:** that enforcement is validated.
