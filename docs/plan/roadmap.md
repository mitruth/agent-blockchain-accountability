# Roadmap

Where the build stands and what comes next. Update this file as steps close.

- **What must be built:** `docs/spec/policy-spec-v0.1.md`. Its Section 9 fixes
  the order of the steps and the acceptance criteria. The order is not to be
  changed, and each step has to pass before the next starts.
- **Why things were built the way they were:**
  `docs/decisions/design-decisions.md`.
- **Branch:** `feature/policy-gate-v0.1`, started 2026-10-09.

---

## Status

| Step | Content | Status |
|---|---|---|
| 0 | Read the repository, fill in Section 10 of the spec, set up the toolchain | **Done**, 2026-10-12 |
| 1 | Skeleton and key model: `PolicyGate` executor, agent registry, decoder registry, config manager | **Done**, 2026-10-12. Acceptance criteria met |
| 2 | Position ledger, reconcile, the P2P market port and its decoder | **Done**, 2026-10-14. Acceptance criteria met on the port |
| 3 | `WindowLib`, independent verifier, mutation suite | **Done**, 2026-10-15. Acceptance criteria met |
| 4 | The Smart Session entry point (D1), the policy phases, `StaticOrderPolicy`, S1, S2, S6 | **Done**, 2026-10-16. Acceptance criteria met |
| 5 | `OracleVerifier`, PV relay, S3, S4, S5 | **Done**, 2026-10-19. Acceptance criteria met |
| 6 | Evaluation | Not started |

### What was verified for step 1

| Check | Result |
|---|---|
| `test/gate/` on a minimal ERC-7579 account | 65 passing |
| `test/accounts/` on the reference account, Safe7579, Nexus and Kernel | 4 passing |
| Whole suite under Foundry | 213 passed |
| Whole suite under Hardhat, which leaves out `test/accounts/` | 209 passing |
| Single defects injected into the gate, against `test/gate/` | 51 of 51 caught |
| Single defects injected into the gate, against `test/accounts/` | 9 of 9 caught |

### What is fair to say now

**Fair:** the executor module is implemented. The agent holds no key on the
account. The permission table is asserted test by test, including the nested
self-call routes, on four account implementations. Loosening a policy parameter
waits 24 hours.

**Not yet fair:** that any policy constrains an order. No order is checked
against a policy until step 4. Nothing is deployed, and nothing has been
measured.

---

### What was verified for step 2

| Check | Result |
|---|---|
| `test/gate/`: key model, configuration, order lifecycle, ledger | 102 passing |
| `test/accounts/` against the step 2 gate | 4 passing |
| Whole suite under Foundry | 250 passed |
| Whole suite under Hardhat | 246 passing |
| Single defects in the step 2 code, against `test/gate/` | 48 of 51 caught; the 3 left are in the mock market, which is being replaced |

---

## Done: the P2P market port

Decided with Dan on 2026-10-14 (decision log 2.20 to 2.31,
`docs/analysis/market-structure.md`) and built the same day (2.32 to 2.52): the
ERC-1155 template of DEDALUS without encryption. Market manager, sessions on one
slot grid, prosumer contracts owned by smart accounts, lockable ERC-1155 for
payment and energy, `ClassicSettlement`, and `ProsumerDecoder` for the gate.
Batches over a configurable number of slots; cancel and modify until the session
closes; trades from a registered matcher after it closes; settlement by
registered sensors. The mock market of step 2 remains as a test double for the
ledger.

| Check | Result |
|---|---|
| `test/market/`: token, market flow, gated market, settlement rule | 81 passing |
| Whole suite under Hardhat | 328 passing |
| Whole suite under Foundry, with the real-account tests | 332 passed |
| Single defects in the market port | 54 of 54 caught, after six tests were added |

---

## Done: the system runs locally

`npm run node`, `npm run demo:deploy`, `npm run demo:flow`: the market and the
gate on a local Hardhat node, with three prosumers, two agents, a matcher, a
keeper and sensors as separate programs, from opening a session to settlement.
Decision log 2.54 to 2.58; the guide's runbook has the commands.

---

## Done: step 3

| Check | Result |
|---|---|
| `test/policies/WindowLib.t.sol` | 32 passing, including one fuzz test per class against a reference model, and the scripted boundary burst: 2H under tumbling, H under sliding |
| The independent verifier, JavaScript (amendment A6) | 30 seeds × 5 classes × 80 steps: 33,945 figures compared, no disagreement; 720 of 720 tampered histories rejected |
| The mutation suite, `npm run mutate` | 192 mutants under Hardhat: 189 caught, 3 accepted survivors in test doubles |
| `npm test` | 361 passing |
| `npm run test:offchain` | 12 passing |

Before step 3 the repository was regrouped by function (decision log 3.1).
Decision log 3.2 to 3.8.

## Done: D1

Decided on 2026-10-15: **option 3**. The agent holds a Rhinestone Smart
Session scoped to `PolicyGate.submit`, with no signing; the policies stay in
the gate. The checks of the analysis came out in its favour:

- MetaMask's caveats can only refuse by reverting;
- the deployed period limits are tumbling windows;
- `test/accounts/SessionGate.t.sol` shows a scoped session working, and
  holding, on four real accounts.

Decision log 3.9, spec amendment A7, `docs/analysis/delegation-architecture.md`
section 10.

## Done: step 4

| Sub-step | What | Commit |
|---|---|---|
| 4.1 | The agent's entry point is a Smart Session on the account (D1); the gate's agent registry is gone | `b66ddda` |
| 4.2 | The check, commit and credit phases: every policy on every submission, refusals recorded without reverting | `5bedd57` |
| 4.3 | `StaticOrderPolicy`: A1 quantity, A2 value, A3 price, A4 time of day, A6 horizon | `4de5f52` |
| 4.4 | `WindowPolicy`: S1, the budget, and S2, the export and import caps, on `WindowLib` | `cbbf109` |
| 4.5 | `CancelQuotaPolicy`: S6 | `42972af` |
| 4.6 | The acceptance attacks, and gas | `16cf404` |
| 4.7 | Mutation catalogue for the policies; the earlier design removed; the demo trades under policies; docs | this commit |

| Check | Result |
|---|---|
| Split-leg drain, boundary burst, idle-then-burst, place-and-cancel near the gate | Blocked under SLIDING; each passes under the baseline the attack matrix names for it |
| Gas | All five policy instances add 100,072 to one bid and 465,979 to a 24-leg batch (`docs/reports/gas-2026-10-16.md`) |
| Mutation, `policies` catalogue | 43 of 43 caught, after one test added (`docs/reports/mutation-policies-2026-10-16.md`) |
| `npm test` | 284 passing (the earlier design's 144 removed) |
| `npm run test:offchain` | 12 passing |
| Foundry, the whole suite | 292 passed (the 284 above and the 8 real-account tests), 16 October |
| `npm run demo:flow` | The same day, figure for figure; Alice's modification flagged by S1, her extra bid refused by it |

**What is fair to say now.** On the ported market, an agent acting through a
session that can reach only the gate's `submit` is held to per-action bounds,
a budget and export and import caps over a sliding window, and a cancellation
quota. Four attacks that pass under per-action bounds or under the windows of
deployed systems are blocked. **Not yet fair:** anything about the battery or
the physical system (step 5), or how often an honest agent is refused (step
6).

## Done: step 5

| Sub-step | What | Status |
|---|---|---|
| 5.1 | `OracleVerifier`: signed BMS readings and PV forecasts, the signer registry, staleness, order; `submit` takes readings | Done, `279b139` |
| 5.2 | The oracles off-chain: EIP-712 signing, a PV forecast relay and a BMS per house, fed from `data/homes/` and `data/arms/`; `npm run oracle:post` | Done, `d1aeaed` |
| 5.3 | S3, deliverability: `DeliverabilityPolicy` | Done, `31b591d` |
| 5.4 | S4, battery cycles: `CyclePolicy`; the horizon shared in `HorizonLib`; S3's check 42 % cheaper | Done, `2fa70bd` |
| 5.5 | S5, ramp: `RampPolicy` | Done, `2fa70bd` |
| 5.6 | The acceptance tests on the ported market; gas as a function of k | Done, `5c408ad` |
| 5.7 | The `physical` mutation catalogue; the demo in half-hour slots with the oracles, S3, S4 and S5; docs | Done, this commit |

| Check, at the end of step 5 | Result |
|---|---|
| `npm test` | 411 passing (35 verifier, 14 readings through the gate, 29 S3, 16 S4, 12 S5, 21 step 5 acceptance) |
| `npm run test:offchain` | 29 passing |
| Mutation, `physical` catalogue | 42 of 42 caught (`docs/reports/mutation-physical-2026-10-19.md`) |
| `npm run demo:flow` | The day in half-hour slots under all eight policies; S3 refuses Carol's overnight oversell, the verifier her older reading |
| Foundry, the whole suite | 419 passed, 19 October |
| Mutation, `accounts` catalogue (the real-account tests, against the step 5 gate) | 9 of 9 caught, after three checks added (`docs/reports/mutation-accounts-2026-10-19.md`) |
| Step 5's acceptance criteria | All met on the ported market, `test/policies/Step5Acceptance.t.sol` |
| Gas as a function of k | `docs/reports/gas-step5-2026-10-19.md`: the three physical policies add 146k to an offer at k = 8, 405k at k = 48, 723k at k = 96 |
| Excess cycling (spec step 5) | Blocked by S4: `test_excessCyclingIsBlocked` |
| A position spike (spec step 5) | Blocked by S5: `test_aPositionSpikeIsBlocked` |
| Cross-slot over-commitment (spec step 5) | Blocked by S3: `test_crossSlotOverCommitmentIsBlocked` |
| S3 check gas | after 5.4: 85k at k = 8, 585k at k = 96 (was 120k and 1.01M) |
| `npm run test:offchain` | 29 passing (14 for the oracles, 4 of them against the contract) |
| Foundry, the whole suite | 341 passed, after 5.1 |
| `npm run oracle:post -- --attacks` | Forecasts and battery readings accepted for Alice and Carol; the reordered and the forged reading refused |
| `npm run demo:flow` | The same day, figure for figure |

Chosen by Dan before step 5 (log 5.1): no tariff oracle; the demo moves to
30-minute slots; Alice gets home_01 with the arms' battery settings, Bob
home_03 and Carol home_05; the demo's PV forecast is the actual PV, the tests'
has errors.

**What is fair to say now.** On the ported market, the agent's orders are also
held to the battery behind them, as its own BMS signs it:

- a sale must be deliverable over the next 96 half-hours, counting only the PV
  forecast and filled bids;
- the battery may not be cycled past N_max a day;
- the net position may not jump past R_max between slots.

Over-commitment across slots, phantom bids, excess cycling, a position spike
and a stale or favourable reading are blocked; each passes under per-action
bounds. **Not yet fair:** how often an honest agent is refused (step 6), and
any claim about cost on a real chain (gas at k = 96 is about twice the
market's own).

## Next: step 6

The evaluation, as spec Section 9 fixes it:

- the full attack matrix (9.1) against every baseline;
- the false-positive rate on the honest arms, B0 and B2 from `data/arms/`,
  scored against B2;
- gas as a function of n and k, the policies as separate contracts against a
  monolithic one;
- the block-time assumption, cited.

Open for it: how an honest arm's plan becomes market orders (log 4.11), and
A0 and A1 once they have really run.

### Step 5 as specified

`OracleVerifier` (signed readings: signer registry, staleness, monotonic
timestamps), the PV relay, S3 deliverability, S4 battery cycles, S5 ramp. Accept
when cross-slot over-commitment, excess cycling and a position spike are
blocked, a stale or reordered reading is rejected, an exposure-reducing cancel
always passes, and gas is reported as a function of the horizon k.

**The data is ready** (log 4.10): `data/homes/` has the six homes' battery and PV
parameters, and 2022 in 30-minute slots, with representative days. For step 6,
`data/arms/` has the honest controllers' step logs for home_01 (log 4.11). Still
open for step 6: how an honest plan becomes market orders; A0 and A1 once they
have really run.

---

## Open decisions

None left. Dan answered every open decision on 16 October; the answers are in
the table at the end of `docs/decisions/design-decisions.md` and in log 4.9.
The one change: the payment token is a mock USD, as the HEMS data is.

---

## Carried forward to later steps

Things noticed in steps 0 and 1 that belong to a later step.

| Item | Belongs to |
|---|---|
| Safe7579 and Kernel do not check a module's declared type at install | Security analysis, step 6 |
| A policy whose `deconfigure` fails keeps stale state for the account | Security analysis, step 6 |
| ~~The cross-parameter constraint `H_slots ≤ k` spans two policy contracts~~ Holds by construction: S3 refuses a placement outside its horizon (log 5.3) | Done, step 5 |
| Carry-over of old totals on a structural change: not built; a change of shape waits 24 hours and starts afresh (log 4.4) | Step 6, or later |
| ~~`submit` gains the `readings[]` argument~~ (log 5.1) | Done, step 5 |
| A deployment script, and a test with a real owner validator | Before any testnet run |
| The agent's session on a real account: expiry by a time-frame user-op policy, revocation by removing it; events name the account, not the agent (log 3.9, 4.1) | Before any testnet run |
| Install Smart Sessions on Kernel without a hook; deploy Smart Sessions v1.0.0 or later (log 3.9) | Before any testnet run |
| S3 and S4 read the same positions and forecast, each for itself; a combined policy would read them once (gas report, step 5) | Step 6, with the monolithic variant (D14) |
| A consumer's S3 value is never zero with a constant reserve load; a signed load forecast (D4) would fix it (log 5.7) | After step 6 |
