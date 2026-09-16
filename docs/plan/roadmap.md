# Roadmap

Where the enforcement work stands and what comes next, in dependency order.
Update this file as phases close. For why each choice was made, see
`docs/decisions/design-decisions.md`.

---

## Where we are

Phase A is complete. The agent no longer reports its own spend: daily spend is
computed on-chain from meter readings and oracle prices, every settled day is
recorded, and the agent's authority is withdrawn while it is over the cap.

| Handoff step | Status |
|---|---|
| 1. Key separation | **Done.** Owner, agent, guardian, plus the meter and price publisher; the meter can never be the agent's key. |
| 2. Config/ledger split | **Done.** `PolicyConfig`, `SpendLedger` (one-year ring, raw data only), `SpendValidator`, `PriceOracle`. |
| 3. Independent verifier | **Done.** Blind verifier rewritten for spec version 2; differential clean on 1,880 real settled days and 15 policy writes, and itself mutation-tested (D7.16). |
| 4. Mutation suite | **Run by hand, not yet tooling.** About 95 mutations across all stages; every gap found was closed. Scripts live outside the repo. |
| 5. F3 / F4 | **Done in substance.** Signed spend end to end; rounding happens once, on-chain, half away from zero, tested at the exact half in both signs on both sides. |
| 6. Adversarial evaluation | **Not started.** |

Test counts: 144 Solidity, 53 verifier. Differential: 0 disagreements.

---

## Phase A — Measured inputs — **done**

Decided with Dan on 2026-09-15; `docs/decisions/design-decisions.md` section 7.

| #  | Stage | Commit |
| -- | ----- | ------ |
| A1 | **Price oracle.** Publisher key; one day of 96 prices, committed by hash, emitted in full. | `356170a` |
| A2 | **Meter.** EIP-712 signed readings, anyone relays; meter never the session key. | `42689ed` |
| A3 | **On-chain spend.** `settleDay`: exact integer total, one rounding, consecutive past days only; degradation excluded. | `e10733d` |
| A4 | **Record, then restrict.** `submitDay` removed; `execute` gated by `authorization()`; F6 closed. | `e938192` |
| A5 | **Verifier.** F7 (`submittedOnDay`), real-data inputs, spec version 2, blind verifier rewrite, differential on real days. | `869f5b4` … |

Resolved on the way: F6, F7, F8, Q1, Q2, Q4, Q7. The old Phase B (close the
verifier loop) was absorbed into A5.

---

## Phase B — Decide the open rule questions

**New.** The version 2 verifier author challenged the rules themselves, not only
their wording. Both implementations follow the spec; these ask whether the spec
is right. Each changes the spec, both implementations and the differential
together, so they are decided before the mutation suite freezes the rules.

| #  | Question | Who decides | Size |
| -- | -------- | ----------- | ---- |
| B1 | **Q8.** A rolling window never resets, so deferring a raise to a multiple of `windowDays` does not keep new capacity out of a partly spent window. Keep it, or defer to `submittedOnDay + windowDays`? | Dan | Decision, then medium |
| B2 | **Q9.** A write that keeps the cap and shortens the window loosens at once. Treat a shorter window as a raise? | Dan | Decision, then small |
| B3 | **Q10.** Next-day authorisation is conservative by one day. State it as a choice, or change it? | Dan | Decision |
| B4 | **Q5.** Owner key: immutable, or a two-step transfer? | Dan | Decision, then small |

**Done when:** each is decided and recorded, and any rule change has gone
through spec, both implementations and the differential.

---

## Phase C — Mutation suite as tooling (handoff step 4)

**Depends on:** B. Mutating rules that are about to change measures nothing.

| #  | Item | Size |
| -- | ---- | ---- |
| C1 | Commit the mutation runner and its lists: one mutation at a time, three outcomes (caught / not caught / invalid), catching tests named, file restored on any exit. Two runners already exist in scratch form — one against the Solidity suite, one against the differential. | Small |
| C2 | Fold in every mutation already run (oracle, meter, settlement, authorisation, ring, differential) and the handoff's list, updated for measured inputs. | Small |
| C3 | Run each mutation against **both** implementations and report the cross-table. A mutation one side catches and the other misses is the most informative result. | Medium |
| C4 | Widen coverage where a mutation dies to a single test. | Small |

**Done when:** a single command reproduces the mutation table, and every
non-equivalent mutation is caught by at least one test on each side or written
down as a known limitation.

---

## Phase D — Rounding (handoff step 5) — **largely done**

Rounding moved on-chain in A3 (D7.10). Half away from zero on the exact daily
total is tested at the exact half in both signs in `Settlement.t.sol` and in the
verifier, and a real day is checked against the simulator.

| #  | Item | Size |
| -- | ---- | ---- |
| D1 | `build_settlement_inputs.py` rounds readings and prices at the meter and publisher. Add a unit test for its `.5` cases, since that script now stands in for two real devices. | Small |

---

## Phase E — Recalibrate the caps (Q3)

**Depends on:** B (the rule), D.

The old caps were computed from spend that included degradation, on local days.
Spend is now energy cost only, on UTC days, with more negative days (12/31/20
across B0/B1/B2, up from 9/16/10). The old permissive cap bound on zero days for
every arm.

| #  | Item | Who decides | Size |
| -- | ---- | ----------- | ---- |
| E1 | Choose the calibration principle, for example percentiles of B0 or B2 rolling sums, or a fraction of annual cost. | Dan | Decision |
| E2 | Produce a small grid of caps from the settled chain output, so the evaluation can show enforcement cost against cap tightness. | — | Small |

---

## Phase F — Deploy

**Depends on:** B. Can run in parallel with C–E.

| #  | Item | Size |
| -- | ---- | ---- |
| F1 | Deploy script for the rebuilt system: price oracle, config, ledger, account, validator; register oracle and meter; install and select the validator; allowlist the ledger writer; verify each role on-chain. None exists. | Medium |
| F2 | Simulated meter and publisher processes for testnet: sign and publish from `differential/data/inputs/`, relay settlements daily. | Medium |
| F3 | Deploy to Base Sepolia; record addresses, commit hash and bytecode match. | Small |
| F4 | Gas per record and per check. Measured locally so far: publish a day 137,266; meter signature check 44,751; settle a day 311,284; ring write 95,753 cold, 7,700 steady. State the block-time assumption with a citation. | Small |

---

## Phase G — Adversarial evaluation (handoff step 6)

**Depends on:** B–E.

| #  | Item | Size |
| -- | ---- | ---- |
| G1 | **Over-cap agent.** An agent that tries to exceed the window, and what `authorization()` does to it. | Medium |
| G2 | **Prompt injection.** Scenarios aimed at `setPolicy`, module uninstall, allowlist changes, pause, and now meter and oracle registration. Recover the Groq wiring from `1f49b7e` (`scripts/agent/llm_agent.js`). | Medium |
| G3 | **Withholding and duty-cycling.** Stop settlement, sit just under the bound, act around boundary-day raises. | Medium |
| G4 | **The counterfactual.** Same sequences against per-transaction limits alone. | Medium |
| G5 | **LLM arms.** Run A0/A1 through the simulated meter and oracle; score against B2, not B1. A1 has not been run. | Large |

---

## Phase H — Write-up

| #  | Item | Folder |
| -- | ---- | ------ |
| H1 | Security analysis: threat model, and the trust assumptions now explicit — honest meter, honest price publisher, publisher distinct from the agent (D7.12) — plus pause and griefing, ring eviction, withholding. | `docs/security/` |
| H2 | Evaluation: mutation cross-table, differential, gas, adversarial results, counterfactual. | `docs/evaluation/` |

**Reporting discipline, until G is done:** what is defensible is *contract
implemented; spend computed from measured inputs rather than reported by the
agent; test suite present; independent verifier agreeing on real data; defects
found and specified.* Not "enforcement validated".

---

## Dependency picture

```
A (done) ── B (rule questions) ──┬── C (mutation tooling) ──┐
                                 ├── F (deploy)             ├── G (adversarial) ── H (write-up)
D (rounding) ── E (caps) ────────┴──────────────────────────┘
```

B needs decisions from Dan. D1 and C1 can start without them.
