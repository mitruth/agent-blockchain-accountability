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
| 4 | The Smart Session entry point (D1), `StaticOrderPolicy`, S1, S2, S6 | Next. D1 decided 2026-10-15: option 3 |
| 5 | `OracleVerifier`, PV relay, S3, S4, S5 | Not started |
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

## Next: step 4

1. Replace the gate's agent registry with the session. `submit` takes the
   account as its caller; the tests move to sessions on real accounts.
2. Then the check and commit phases of `submit`, the per-action policies, S1,
   S2 and S6 on `WindowLib`.

---

## Open decisions

The questions that wait for Dan are listed, with the default that applies if
nothing is said, at the end of `docs/decisions/design-decisions.md`. None
blocks step 4. One, the currency of the honest-arm data, is needed during step
4.

---

## Carried forward to later steps

Things noticed in steps 0 and 1 that belong to a later step.

| Item | Belongs to |
|---|---|
| Safe7579 and Kernel do not check a module's declared type at install | Security analysis, step 6 |
| A policy whose `deconfigure` fails keeps stale state for the account | Step 4 |
| The cross-parameter constraint `H_slots ≤ k` spans two policy contracts | Step 5 |
| Structural configuration changes need carry-over of old totals; a change of a window's shape starts it afresh, so it must be a WIDEN (log 3.5) | Step 4 |
| `submit` gains the `readings[]` argument | Step 5 |
| Remove the earlier design's contracts, tests, verifier and differential | Step 4 |
| A deployment script, and a test with a real owner validator | Before any testnet run |
| Gas per order, per policy and combined | Step 4 |
| The agent's session: expiry by a time-frame user-op policy, revocation by removing it; events name the account, not the agent (log 3.9) | Step 4 |
| Install Smart Sessions on Kernel without a hook; deploy Smart Sessions v1.0.0 or later (log 3.9) | Before any testnet run |
| Run the `accounts` mutation catalogue (9, Foundry in Docker) against the step 4 gate | Step 4 |
