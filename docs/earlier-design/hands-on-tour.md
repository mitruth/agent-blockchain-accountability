# Hands-on tour

> **Earlier design.** This document describes the daily spend rule that came before
> Policy Spec v0.1 (`PolicyConfig`, `SpendLedger`, `SpendValidator`). It is kept for
> reference and is no longer maintained. The current project is described in
> `docs/guide/project-guide.md`.

A guided way to learn this project by running it, looking at real data, and
breaking it on purpose. About an hour. Every command and every expected result
below was run on the current code before being written down.

Nothing here touches a network, a wallet or money. Every change you make is
undone with one `git restore` command.

For the reference map of files, see `docs/earlier-design/project-guide.md`. This file is
the walk-through.

---

## The idea in four sentences

An AI agent runs a household's energy, and the owner caps how much it may spend
over any 7 days. The agent does not report what it spent: a **meter** signs how
much energy crossed the grid each half-hour, a **price oracle** publishes what
each half-hour cost, and a smart contract computes the day's spend from those
two. If the last 7 days add up to more than the cap, the contract stops the
agent from spending. The same rule is also written in Python by someone who
never saw the contract, and the two are compared on a year of real data.

Keep one phrase in mind throughout: **the agent is never trusted with a number
it could benefit from changing.**

---

## Part 1 — Check your setup

Open a terminal in the repository folder. Each of these should print a version
without an error:

```bash
node --version
```

```bash
npx hardhat --version
```

```bash
python --version
```

```bash
python -c "import pandas; print(pandas.__version__)"
```

Expected: Node 22, Hardhat 3.15, Python 3.14, pandas 3.x. If `node_modules` is
missing, run `npm install` first. If pandas is missing, run
`python -m pip install pandas`.

---

## Part 2 — Run all three checks

The project is checked three ways. Run them in this order.

**The Solidity tests.** These test the smart contracts on a simulated local
chain. Takes about a minute; the first run downloads the compiler.

```bash
npm test
```

Look at the bottom: **`144 passing`**. Scroll up and you will see the tests
grouped by file, each name reading like a sentence —
`test_agent_mayNotWritePolicyConfig`, `test_overCapWithdrawsAuthority`.

**The Python verifier's tests.**

```bash
python -m unittest discover -s verifier -p "test_*.py"
```

Expect **`Ran 53 tests`** and **`OK`**.

**The differential** — both implementations on the same real data. The first run
also builds the input data from the simulator, so give it a minute or two.

```bash
python differential/run_diff.py
```

Expect a table ending in **`total disagreements and deferral findings: 0`**.
Each row is a scenario; `breaches` and `unauth` are not errors, they are days
where the cap was genuinely exceeded. The column that matters is `disagree`.

---

## Part 3 — Follow one real day

The differential compares 1,880 days at once, which is hard to picture. This
tool shows a single day end to end.

```bash
python differential/show_day.py B2 19158
```

Day 19158 is 15 June 2022; B2 is one of the simulated home-energy controllers.
What you are looking at:

- **Each row is a half-hour.** `import Wh` is energy bought from the grid,
  `export Wh` is solar energy sold back. A half-hour does one or the other,
  never both.
- **The last column is that half-hour's cost.** Imports are positive; exports
  are negative — the household was paid. Look at slot 5: prices spiked to
  0.595 $/kWh, so exporting just 0.67 kWh earned about as much (−120) as
  importing 2.5 kWh cost an hour earlier (+108, slot 3). That is why spend has
  to be computed per half-hour, not from daily totals.
- **`exact total`** adds all 48 as an exact integer, then **`rounded once`**
  rounds the whole day to a milli-dollar. Rounding each half-hour instead would
  let 48 small errors pile up.
- **The table at the bottom** is the point. This script, the simulator that
  produced the data, the smart contract, and the independent verifier all
  arrive at **26 milli-USD**.

Now three more days, each showing one idea.

**A day the household earned money** — spend can be negative, and that credit
reduces the 7-day total:

```bash
python differential/show_day.py B1 19130
```

Spend: −1,493 milli-USD.

**The first day over a tight cap.** The `B2strict` scenario caps the week at
18,096 milli-USD:

```bash
python differential/show_day.py B2 19240 --scenario B2strict
```

```bash
python differential/show_day.py B2 19241 --scenario B2strict
```

On 19240 the 7-day window is 12,941: compliant, and the agent may act the next
day. On 19241 a single expensive day pushes the window to 31,624: not compliant,
and **the agent is blocked** on the following day. Note the day was still
recorded in full — the contract records what the meter measured, then restricts
the agent.

**Exactly at the cap.** In `B2atCap` the cap equals the largest window of the
year, reached on exactly one day:

```bash
python differential/show_day.py B2 19349 --scenario B2atCap
```

Window 107,036, cap 107,036: **equal still passes**. This scenario exists
because an early version of the comparison never had a day exactly on the cap,
so a bug in that one comparison could not have been noticed.

---

## Part 4 — Read and run a single test

Run just the test behind Part 3's first day:

```bash
npx hardhat test solidity --grep test_realDayMatchesSimulatorEnergyCost
```

Now open `test/Settlement.t.sol` and search for that name. You will see the 48
readings and 48 prices typed out, the contract asked to settle the day, and an
assertion that the stored spend is 26. That is the whole pattern of a test here:
**set something up, do one thing, assert the outcome.**

Three helpers from the test library appear everywhere:

| Helper | Means |
|---|---|
| `vm.prank(agent)` | The next call is made *as* the agent |
| `vm.expectRevert(...)` | The next call must be refused, with this error |
| `vm.warp(...)` | Move the local chain's clock, e.g. to a later day |

Now read a security test in the same file:
`test_readingsSignedByTheAgentAreRejected`. It builds genuine readings, has the
**agent** sign them instead of the meter, and expects the contract to refuse.
Run it:

```bash
npx hardhat test solidity --grep test_readingsSignedByTheAgentAreRejected
```

---

## Part 5 — Break it on purpose

This is the most useful part. A test suite that passes proves nothing unless it
can fail, so here you introduce a real bug and watch what catches it.

Each experiment is the same five steps:

1. Open the file in your editor.
2. Find the exact line shown, and change it as shown.
3. Run the command, and compare the failures to the list.
4. Run `git diff` to see your change.
5. Run the `git restore` command to undo it. **Do this before the next
   experiment.**

### Experiment 1 — Let the agent change its own spending cap

This was the original project's fatal flaw (finding F1).

In `contracts/PolicyConfig.sol`, find:

```solidity
        require(msg.sender == owner, "PolicyConfig: only owner");
```

Change it to:

```solidity
        require(msg.sender == owner || msg.sender == sessionKey, "PolicyConfig: only owner");
```

(`sessionKey` is the agent.) Run:

```bash
npm test
```

**Expect 5 failing:**
`test_agent_mayNotWritePolicyConfig`, `test_agent_mayNotChangePauseTiming`,
`test_agent_mayNotReassignRoles`, `test_nobodyElseRegistersThePriceOracle`,
`test_nobodyElseRegistersTheMeter`.

The last two are the interesting ones. The agent could now appoint *itself* as
the meter or pick its own price feed — and put itself back in charge of the
number it is capped on. The permission tests catch the escalation, not just the
obvious case.

```bash
git restore contracts/PolicyConfig.sol
```

### Experiment 2 — Round the wrong way

In `contracts/SpendMath.sol`, find:

```solidity
        if (2 * absR >= d) {
```

Change it to:

```solidity
        if (false) {
```

This turns "round half away from zero" into plain truncation. Run `npm test`.

**Expect 3 failing:** `test_roundingRuleDirectly`,
`test_settledHalfRoundsAwayFromZeroPositive`,
`test_settledHalfRoundsAwayFromZeroNegative`.

Now, **with the bug still in place**, run the differential in its mutation mode
— it runs only the chain replay, so a broken contract is still compared:

```bash
python differential/run_diff.py --differential-only
```

**Expect about 2,800 disagreeing values**, in every scenario. The independent
verifier, which rounds correctly, now disagrees with the broken contract on
every day whose total landed on the upper half of a milli-dollar — and each
such day also shifts that day's 7-day window, so one wrong day shows up as
several disagreeing values.

```bash
git restore contracts/SpendMath.sol
```

### Experiment 3 — Ignore exported energy

In `contracts/SpendMath.sol`, find:

```solidity
            total -= int256(uint256(exportMWh[i])) * int256(exportPrices[i]);
```

Put `// ` at the start of the line to disable it. Run `npm test`.

**Expect 5 failing**, including `test_realDayMatchesSimulatorEnergyCost` — the
day from Part 3 — and `test_exportCreditRestoresHeadroom`. Without export
credit the household looks more expensive than it is, and the cap bites too
early. That error flatters the mechanism — it looks stricter — which is exactly
why it matters to catch.

```bash
git restore contracts/SpendMath.sol
```

### Experiment 4 — Never block the agent

In `contracts/SpendValidator.sol`, find:

```solidity
            if (windowSum(ledger.lastRecordedDay()) > config.capAt(today)) return Authorization.OverCap;
```

Put `// ` at the start. The agent can now keep spending however far over the cap
it goes. Run `npm test`.

**Expect 8 failing**, all about authority: `test_overCapWithdrawsAuthority`,
`test_aBreachDoesNotCreateHeadroom`, `test_authorityReturnsWhenTheWindowRecovers`
and others.

Then run the differential with the bug in place:

```bash
python differential/run_diff.py --differential-only
```

**Expect 78 disagreeing values**, all in the `authorisedNextDay` column, on exactly
the days the cap was exceeded — 51 of them in `B2strict`. `B2atCap` shows none,
because nothing is ever over its cap.

```bash
git restore contracts/SpendValidator.sol
```

### Experiment 5 — Stop checking the meter's signature

In `contracts/SpendValidator.sol`, find:

```solidity
        if (signer != meter) revert SpendValidator_NotSignedByMeter(signer);
```

Put `// ` at the start. Now anyone could submit readings, including the agent.
Run `npm test`.

**Expect 3 failing:** `test_readingsSignedByTheAgentAreRejected`,
`test_tamperedReadingIsRejected`, `test_readingsSignedForAnotherLedgerAreRejected`.

Now run the differential with the bug in place:

```bash
python differential/run_diff.py --differential-only
```

**Expect 0 disagreements.** This is not a failure of the differential — it is
the lesson. The differential feeds both sides *honest*, genuinely signed data,
and on honest data a missing signature check changes nothing. It only matters
when someone submits *forged* readings, and only the Solidity tests do that.

```bash
git restore contracts/SpendValidator.sol
```

### What the experiments show

| Kind of bug | Caught by the Solidity tests | Caught by the differential |
|---|---|---|
| Wrong arithmetic (2, 3) | Yes | Yes, in every scenario |
| Wrong enforcement decision (4) | Yes | Yes, on every over-cap day |
| Wrong permission (1) | Yes | No — permissions are not in the data it compares |
| Missing security check (5) | Yes | No — it only sees honest input |

Neither check is enough alone. The Solidity tests know the attacks; the
differential knows the real data and was written by someone who could not copy
the contract's mistakes.

Confirm you are back to a clean state:

```bash
git status
```

It should list no modified contracts. Then `npm test` should show 144 passing
again.

---

## Part 6 — Use the verifier yourself

The verifier takes three files — meter readings, prices, and the owner's policy
changes — and says whether each day complied.

Run it on a real year with the example policy (a 50,000 milli-USD cap):

```bash
python verifier/verify.py --readings differential/data/inputs/B2.readings.csv --prices differential/data/inputs/prices.csv --policy verifier/fixtures/policy_genesis_w7.csv --out my_run.csv
```

The summary line says 26 breaches. Open `my_run.csv` in a spreadsheet: one row
per day, with spend, window, cap, and the two verdicts.

**Now set your own cap.** Copy the policy file:

```bash
python -c "import shutil; shutil.copy('verifier/fixtures/policy_genesis_w7.csv', 'my_policy.csv')"
```

Open `my_policy.csv` in an editor. It has one row — the initial policy. Change
the `cap` value (the third column) from 50000 to, say, 30000, save, and run:

```bash
python verifier/verify.py --readings differential/data/inputs/B2.readings.csv --prices differential/data/inputs/prices.csv --policy my_policy.csv --out my_run.csv
```

The breach count rises from 26 to 38. Try a few values and you will feel how tight a cap
has to be before it bites — which is exactly the open question of how the caps
should be calibrated.

**A policy that changes over time:**

```bash
python verifier/verify.py --readings differential/data/inputs/B2.readings.csv --prices differential/data/inputs/prices.csv --policy verifier/fixtures/policy_multi_event.csv --out my_run.csv --policy-report my_policy_report.csv
```

Open `my_policy_report.csv`. For each policy change it shows the day it was
made, the day the rules say it takes effect, and the day the contract recorded.
A **lowering** applies the same day. A **raise** waits for a window boundary.

**A contract that got a date wrong.** This fixture has one policy change whose
recorded effective day breaks the rules:

```bash
python verifier/verify.py --readings differential/data/inputs/B2.readings.csv --prices differential/data/inputs/prices.csv --policy verifier/fixtures/policy_deferral_mismatch.csv --out my_run.csv
```

The verifier prints `ANOMALY [deferral_mismatch]` for policy change 7: a raise
made on day 19250 that the contract applied the same day, when the rule says it
waits until 19260. It is reported as a finding about the contract, separately
from any breach by the agent.

Clean up the files you made:

```bash
python -c "import os; [os.remove(f) for f in ('my_run.csv', 'my_policy.csv', 'my_policy_report.csv') if os.path.exists(f)]"
```

---

## Part 7 — Read the code, in this order

Short files first; each builds on the one before. For each, try to answer the
question before moving on.

| File | Lines | Question to answer |
|---|---|---|
| `contracts/SpendMath.sol` | 69 | Why is the day's total rounded once, instead of each half-hour? |
| `contracts/PriceOracle.sol` | 115 | Why does it store a hash of the prices instead of the prices themselves? |
| `contracts/MeterReadings.sol` | 110 | What stops a genuine signature for one household being used for another? |
| `contracts/SpendLedger.sol` | 271 | How does a one-year ring tell a real record from last year's leftover? |
| `contracts/SpendValidator.sol` | 325 | In `settleDay`, which check stops the agent skipping an expensive day? |
| `contracts/PolicyConfig.sol` | 441 | Why does lowering the cap apply at once, but raising it waits? |
| `contracts/SmartAccount.sol` | 176 | What happens if nobody selects a validator? |

The answers are in the comments above each function, and the reasoning behind
them is in `docs/earlier-design/design-decisions.md`, section 7.

---

## Part 8 — Where to go next

- **`docs/earlier-design/design-decisions.md`** — why every choice was made, and what
  was rejected. Start with section 7, "Measured inputs".
- **`docs/earlier-design/enforcement-rule.md`** — the rule written as behaviour. It is the
  only document the verifier's author saw.
- **`docs/earlier-design/verifier-implementation-notes.md`** — the verifier author's list of
  every place the spec was unclear. It is where the rules were challenged.
- **`docs/earlier-design/roadmap.md`, Phase B** — four open questions about the rules
  themselves. After this tour you have enough context to decide them.
