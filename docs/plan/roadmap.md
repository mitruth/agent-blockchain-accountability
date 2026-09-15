# Roadmap

Where the enforcement work stands and what comes next, in dependency order.
Update this file as phases close. For why each choice was made, see
`docs/decisions/design-decisions.md`.

---

## Where we are

The handoff defined six sequential steps. Status as of `9d181ce`:

| Step | Status |
|---|---|
| 1. Key separation | **Done.** Three keys; permission table asserted row by row (F1, F5 closed). |
| 2. Config/ledger split | **Done.** `PolicyConfig`, `SpendLedger` (bounded one-year ring), `SpendValidator`. |
| 3. Independent verifier | **Done, one defect open.** Blind Python verifier; differential agrees on 1,095 real days; 28 disagreements traced to F7. |
| 4. Mutation suite | **Not started as a suite.** Ad-hoc negative controls only (12 mutations run by hand, one hole found and closed). |
| 5. F3 / F4 | **F3 done.** F4 half-done: rounding correct in `export_records.py`, asserted in the verifier, never tested on the export side. |
| 6. Adversarial evaluation | **Not started.** |

Test counts: 73 Solidity, 58 verifier. Differential: 28 known disagreements.

---

## Phase A — Settle the contracts

**Why first.** Everything after this measures the contracts. Mutating or
evaluating code that is about to change wastes the work. The ledger is also
deployed once and never again, so its layout has to be final before any
deployment.

| # | Item | Who decides | Size |
|---|---|---|---|
| A1 | **Q1 — paused-agent day.** `submitDay` reverts when the agent is paused, so the day is missing rather than a zero. Recommended: record a forced zero with `paused = true`. | Dan | Small |
| A2 | **Q2 — F6.** `execute` validates a value it never records. Either `execute` records, or it is relabelled as the transaction-level counterfactual and stops being described as enforcement. | Dan | Small–medium |
| A3 | **F7 — add `submittedOnDay` to `PolicyUpdated`.** Specified in `docs/spec/enforcement-rule.md` §10. | Decided | Small |
| A4 | **Record schema freeze.** Before A0/A1 run: does a record carry only the daily aggregate, or also a strategy/plan hash or justification? Both workstreams write this schema, and after deployment it cannot change. | Dan | Decision + small |
| A5 | **Q5 — owner key rotation.** Keep `owner` immutable (a lost key ends the deployment), or add a two-step transfer. | Dan | Small |

**Done when:** all five resolved, contracts final, suite green.

---

## Phase B — Close the verifier loop

**Depends on:** A3, and A1 (the paused-day rule changes the spec).

| # | Item | Size |
|---|---|---|
| B1 | Revise the spec: fold in A1, A3, and the three defects the verifier author raised (Q7): §6.2 compares caps where it means version identity; §7 never names where rounding applies; §5 says nothing about days before the first policy write. | Small |
| B2 | Send the verifier author back, again blind to the Solidity, to implement the revised spec. | Medium (agent) |
| B3 | Re-run the differential. Target: 0 disagreements on `churn`. Any disagreement that remains is a finding, not something to patch until green. | Small |
| B4 | Add differential scenarios for everything §5 never exercised on real data: a raise on a boundary day, a `windowDays` change mid-window, ring eviction, a paused agent. | Medium |

**Done when:** the differential is clean on scenarios built to break it, and
every remaining disagreement is written up.

---

## Phase C — Mutation suite (handoff step 4)

**Depends on:** A and B. Mutating unstable code measures nothing.

| # | Item | Size |
|---|---|---|
| C1 | A script that applies one mutation at a time, reports **three states** (caught / not caught / invalid mutant, per D5.4), and names the catching tests. Restores the file on any exit. | Medium |
| C2 | The ten handoff mutations: `<=`→`<`; boundary shifted a day; oldest day excluded; half-even rounding; `abs()` on netSpend; credit clamped to zero; `capAt` returns latest; raise immediate; paused day treated as missing; ledger writer derived from install status. | Medium |
| C3 | Add the ring-buffer mutations R1–R5 and the accumulation mutation. | Small |
| C4 | Run each mutation against **both** implementations. A mutation the verifier catches and the Solidity tests miss, or the reverse, is the most informative result this phase can produce. | Medium |
| C5 | Widen coverage where a mutation dies to a single test (Q6: boundary shift, `capAt`-latest, raise-immediate). | Small |

**Done when:** every mutation is caught by at least two independent tests, or
the gap is written down as a known limitation.

---

## Phase D — Finish F4 (handoff step 5)

**Depends on:** nothing technical; can run in parallel with B or C.

| # | Item | Size |
|---|---|---|
| D1 | Tests for `export_records.py` rounding: `+2.5 → 3`, `-2.5 → -3`, and neighbours, in the HEMS repo. | Small |
| D2 | A cross-check: the same float-to-integer conversions through the export script and the verifier must agree bit for bit. | Small |
| D3 | Confirm no float reaches the contract boundary on the replay path. | Small |

**Done when:** half-away-from-zero is asserted on both sides, and the `.5`
cases are tested in both signs.

---

## Phase E — Recalibrate the caps (Q3)

**Depends on:** D. Caps are computed from the rounded records.

The current permissive cap is B0's own rolling maximum, so it binds on zero
days for every arm. It is not a policy. Strict binds on 54/50/51 days, and
nothing sits between them.

| # | Item | Who decides | Size |
|---|---|---|---|
| E1 | Choose the calibration principle, for example percentiles of B0 or B2 rolling sums, or a fraction of annual cost. | Dan | Decision |
| E2 | Produce a small grid of caps, not two, so the evaluation can show enforcement cost against cap tightness. | — | Small |

---

## Phase F — Deploy

**Depends on:** A. Can run in parallel with C–E.

| # | Item | Size |
|---|---|---|
| F1 | A deploy script for the rebuilt contracts using three keys: deploy, install, select validator, allowlist the ledger writer, then verify each role on-chain. No such script exists now. | Medium |
| F2 | Deploy to Base Sepolia, and record addresses, commit hash and bytecode match. | Small |
| F3 | Measure gas per record and per check. Local measurements are sufficient for gas. State the block-time assumption with a citation; do not measure wall time. | Small |

---

## Phase G — Adversarial evaluation (handoff step 6)

**Depends on:** A–E. On a mechanism that is not yet final, adversarial results
say nothing.

| # | Item | Size |
|---|---|---|
| G1 | **Over-cap agent.** An agent that actively tries to exceed the window. | Medium |
| G2 | **Prompt injection.** Scenarios aimed at `setPolicy`, module uninstall, allowlist changes and pause. Recover the Groq wiring from `1f49b7e` (`scripts/agent/llm_agent.js`) rather than rewriting it. | Medium |
| G3 | **Duty-cycling.** Sit just under the bound across windows, including around boundary-day raises. | Medium |
| G4 | **The counterfactual.** Run the same sequences against per-transaction limits alone and report what sequence-level enforcement catches that per-transaction checks structurally cannot. | Medium |
| G5 | **LLM arms.** Run A0/A1 through enforcement, and score against B2, not B1. About 48 of the 70 USD/year gap is forecast error. A1 has not been run. | Large |

---

## Phase H — Write-up

| # | Item | Folder |
|---|---|---|
| H1 | Security analysis: threat model, trust assumptions, the bounded `moduleList` iteration, pause and griefing analysis, and ring eviction. | `docs/security/` |
| H2 | Evaluation: mutation results, differential results, gas, adversarial results, and the counterfactual. | `docs/evaluation/` |

**Reporting discipline, until G is done:** what is defensible is *contract
implemented, test suite present, independent verifier agreeing on real data,
defects found and specified.* Not "enforcement validated".

---

## Dependency picture

```
A (settle contracts) ──┬── B (verifier loop) ── C (mutation suite) ──┐
                       │                                             ├── G (adversarial) ── H (write-up)
                       ├── F (deploy)                                │
D (F4) ── E (caps) ────┴─────────────────────────────────────────────┘
```

A and D can start now. A needs decisions from Dan; D does not.
