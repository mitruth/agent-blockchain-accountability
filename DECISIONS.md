# Design decisions

Every non-obvious choice in the enforcement layer, and why it was taken.

A decision belongs here when a reasonable engineer could have chosen otherwise
and the reason is not visible from the code. Entries are append-only: when a
decision is reversed, mark the old one **Superseded** and add a new one rather
than editing history. Each entry names the finding or constraint that forced it,
so a reader can tell a considered choice from an accident.

Findings referenced throughout:

| ID | Finding |
|----|---------|
| F1 | `owner == agent` on-chain; the agent's wallet could call `setLimits`. A self-imposed policy is not delegated authority. |
| F2 | No independent verifier. The off-chain pre-check was a transliteration of the Solidity, so the two could not disagree informatively. |
| F3 | Signed daily records forced into an unsigned chain. Negative net-spend days had no credit path; clamping biases the rolling sum upward. |
| F4 | Half-away-from-zero rounding claimed but not asserted on both sides. |
| F5 | *(found during the rebuild survey, not in the original audit)* The agent could empty the rolling window alone by advancing `dayIndex`. |
| F6 | *(found during the rebuild survey)* The validated quantity and the recorded quantity were different numbers written by different keys. |

Baseline commit, as audited: `1f49b7eb70634e4e3cd2f910d57c8d2d60621f5e`.

---

## 1. Architecture

### D1.1 — Config, ledger and validator are three contracts, not one

**Decision.** `PolicyConfig` holds caps, window length, pause state and roles.
`SpendLedger` holds per-day accounting. `SpendValidator` holds the rule and no
durable state. The validator is upgradeable; the ledger is never redeployed.

**Why.** A single contract makes every upgrade a migration of live accounting
state, and every migration is an opportunity to reset or mint spend capacity. A
validator that owns no state can be swapped without touching the window.

**Consequence.** The ledger's storage schema is permanent from day one, which is
why the record schema freeze arrives early (D3.1).

### D1.2 — The ledger stores raw per-day records, not a running total

**Decision.** `SpendLedger` stores one signed record per day. It does not store
a rolling sum.

**Why.** A validator upgrade that changes `windowDays` must still carry the
window across the upgrade. That is only possible by recomputing from raw days; a
stored rolling sum computed under the old window length cannot be recomputed
under the new one.

**Cost.** The window sum is recomputed on every check — `windowDays` storage
reads instead of one. Accepted: correctness across upgrades is the property
being claimed, and `windowDays` is 7.

### D1.3 — Ledger write authority is an explicit owner allowlist

**Decision.** `SpendLedger.isWriter` is a mapping the owner sets directly. It is
deliberately **not** derived from module install status on the account.

**Why.** If write authority followed install status, then permission to install
a module would silently become permission to write the ledger, and the upgrade
path would become the attack path — F1 in a different shape.

**Asserted by.** `test_installingModuleGrantsNoLedgerWriteAuthority` and
`test_allowlistRevocationStopsWritesWhileStillInstalled`. The second is the
sharper of the two: it revokes the allowlist entry while the module stays
installed and confirms writes stop.

### D1.4 — `PolicyConfig` and `SpendLedger` are immutable on the account

**Decision.** `SmartAccount` takes both at construction as `immutable`. There is
no setter.

**Why.** A repointable account could be aimed at a fresh, empty ledger, which
mints a clean window at zero cost. Making the pair sticky removes that move
entirely rather than guarding it.

### D1.5 — `execute` refuses to run with no spend validator selected

**Decision.** `SmartAccount.execute` reverts when `spendValidator` is unset or
uninstalled. Uninstalling the hook is not a silent bypass; it is a stop.

**Why.** The failure mode of an enforcement hook must be closed, not open. An
account that keeps spending after its validator is removed enforces nothing at
exactly the moment enforcement matters.


### D1.6 — The validator holds no durable state, and its account binding is immutable

**Decision.** `SpendValidator` stores nothing that survives a swap. `config`,
`ledger` and `smartAccount` are all `immutable`; `onInstall` and `onUninstall`
are `view` and only verify the caller.

**Why.** `smartAccount` was originally set by whoever called `onInstall`, which
was unpermissioned. A stranger could call it, become the recorded account, and
then `onUninstall` — which requires `msg.sender == smartAccount` — would revert
for the real account, pinning the enforcement module in place permanently. The
owner's upgrade path is the one thing that must not be griefable by a stranger.

**Alternative rejected.** Guarding `onInstall` with `require(smartAccount == 0)`
moves the same denial-of-service one step earlier: a stranger front-runs the
first install and the owner can then never install at all. Binding at
construction removes the mutable slot rather than guarding it.

**Asserted by.** `test_strangerCannotBlockUninstall`.

---

## 2. Keys and authority

### D2.1 — Three keys, never two

**Decision.** Owner EOA, agent session key, guardian. Separate keys, asserted
distinct in a test rather than assumed from a deployment script.

**Why.** F1. The audited deployment passed `account.address` as the agent while
`owner = msg.sender`, and the deploy script said so in its own log line:
`"Deployer (owner + agent, pentru test)"`. An agent that can raise its own cap is
not operating under delegated authority, so nothing measured on that deployment
says anything about enforcement.

### D2.2 — The session key's denials are enumerated, not inferred

**Decision.** One test per row of the authorisation map, including every
escalation path: `setPolicy`, `setPauseTiming`, `setSessionKey`, `setGuardian`,
`installModule`, `uninstallModule`, direct ledger writes, allowlist changes,
and pausing.

**Why.** Restricting `setLimits` is the easy half. If the session key can
uninstall the validator, the cap is gone and the `setLimits` restriction never
mattered. The escalation path is the part that gets missed, so it is the part
written down.

### D2.3 — Pause blocks neither owner lowering nor session-key revocation

**Decision.** `setPolicy` and `setSessionKey` are reachable while paused.

**Why.** A pause is exactly the circumstance in which a compromised key most
needs removing and a cap most needs lowering. A pause that blocks the owner's
remedies is an attack, not a safety feature.

**Asserted by.** `test_owner_mayRevokeSessionKeyWhilePaused`,
`test_owner_mayLowerCapWhilePaused`.

### D2.4 — Guardian pauses; only the owner unpauses, after a delay

**Decision.** Guardian may pause spends and the agent, and may do nothing else.
The owner unpauses, but not before `unpauseDelaySeconds` have elapsed since the
pause began.

**Why.** Splitting pause from unpause means neither key alone controls
availability. The delay stops a compromised owner key from instantly undoing a
legitimate guardian pause.

### D2.5 — Pause expires on its own

**Decision.** A pause lifts itself after `pauseExpirySeconds` with no owner
action. `clearExpiredPause` is callable by anyone, and merely tidies flags that
are already inert.

**Why.** Expiry is the anti-griefing path against a malicious guardian. Without
it, a guardian key alone can strand the household indefinitely.

### D2.6 — Pause expiry 72h, unpause delay 6h

**Decision.** `pauseExpirySeconds = 72 hours`, `unpauseDelaySeconds = 6 hours`.
Both live in `PolicyConfig` and are versioned like every other config value. The
constructor requires the delay to be strictly below the expiry.

**Why.** Expiry sits below one 7-day window, so a hostile guardian cannot strand
the household for a whole accounting period. The delay is short enough not to
matter in normal operation and long enough that an instant owner-key compromise
does not immediately neutralise a pause. The constructor invariant keeps expiry
from becoming unreachable — if the delay exceeded the expiry, the owner could
never unpause at all, and only expiry would ever lift a pause.

**Status.** Values chosen by us, not derived from anything. Revisit if the
deployment context suggests otherwise.

---

## 3. Records

### D3.1 — `DayRecord` is a frozen schema

**Decision.** The struct is fixed as specified: `dayIndex uint64`,
`netSpend int256`, `policyVersion uint256`, `paused bool` — in that field order.

**Why.** `SpendLedger` is never redeployed, so its storage layout is permanent.
Field order is kept exactly as specified rather than repacked, because fidelity
to a frozen schema is worth more than the storage slot the repacking would save.

**Known cost.** Declaration order costs one slot: `dayIndex` (8 bytes) cannot
share with `netSpend` (32 bytes). Reordering to `dayIndex, paused, netSpend,
policyVersion` would pack into 3 slots instead of 4. Recorded as a deliberate
choice, not an oversight.

### D3.2 — `netSpend` is signed

**Decision.** `int256`. A day where export revenue exceeds import cost is a real
negative and reduces the rolling window sum.

**Why.** F3. Clamping negative days to zero biases the rolling sum upward, so
the cap binds earlier than it should — an error in the direction that flatters
the mechanism. Discarding export credit was rejected for the same reason.

**Scale.** 35 negative-spend days exist across the three arms over 2022
(B0 9, B1 16, B2 10), most negative −428 milli-USD on B1 day 167. This is not a
hypothetical path.

### D3.3 — Existence is tracked outside the frozen struct

**Decision.** `isRecorded` is a separate mapping, not a field on `DayRecord`.

**Why.** An unrecorded day and a genuinely zero day both read `netSpend == 0`.
The distinction is needed, but adding an `exists` field would change a schema
that is meant to be frozen. Keeping it outside leaves the record schema exactly
as specified.

### D3.4 — Same-day resubmission accumulates

**Decision.** A second submission for a day already recorded adds to it.

**Why.** Preserved from the audited implementation, where it was confirmed
sound. Several settlements may land on one calendar day and each must count.

### D3.5 — Day index is UTC, derived on-chain, never supplied

**Decision.** `dayIndex = block.timestamp / 86400`, computed by the contract.
The submitter passes only `netSpend`.

**Why.** F5. The audited `reportDay` required only `dayIndex >= lastReportedDay`
and then set `lastReportedDay = dayIndex`, while `validateTransaction` read the
window off `lastReportedDay`. The agent's own key could therefore call
`reportDay(lastReportedDay + 7, 0)`, empty the window, and free the cap — with no
owner action, no module install and no `setLimits`. Splitting the keys does not
close this, because the session key legitimately needs that call. Deriving the
day on-chain does.

**Cost, accepted.** The live path can only ever record today. Backfilling a
missed day is impossible on-chain by construction.

**Consequence.** Historical replay of the 2022 CSVs is a separate path, run
against a local chain where block time is controlled directly. The mutation
suite needs that local chain regardless, so this costs nothing we were not
already building. Enforcement and replay are deliberately two paths.

### D3.6 — Ledger day index is non-decreasing

**Decision.** `recordDay` reverts if `dayIndex < lastRecordedDay`.

**Why.** Defence in depth. The validator already derives the day from block
time, so a backward write should be unreachable; the ledger enforces it anyway
because it outlives every validator that will ever write to it.

---

## 4. Cap semantics

### D4.1 — Lowering is immediate, raising waits for a window boundary

**Decision.** A cap decrease takes `effectiveFromDay = today`. An increase takes
effect at the next window boundary.

**Why.** An immediate raise would hand the agent fresh capacity part-way through
a window it has already partly spent, which is the exact sequence-level exposure
this layer exists to prevent. Lowering has no such problem and should be
available instantly.

### D4.2 — Window boundaries sit at multiples of `windowDays` from the Unix epoch

**Decision.** `nextWindowBoundary(day, w) = ((day / w) + 1) * w`.

**Why.** A rolling window has no natural boundary, but a raise needs one. Fixing
the schedule to the epoch makes it deterministic and reconstructible by a third
party without reference to when any transaction was mined.

**Alternative rejected.** Boundaries measured from the first recorded day would
make the schedule depend on ledger history, so the cap in force on a day could
not be reconstructed from `PolicyUpdated` events alone.

### D4.3 — A lowering cancels any pending raise

**Decision.** `setPolicy` with a lowering pops every epoch whose
`effectiveFromDay` is still in the future.

**Why.** Without it, a raise queued yesterday resurrects itself after a lowering
made today: `capAt(today)` would show the lowering, and `capAt(boundary)` would
show the stale raise. The owner's most recent instruction must win.

**Verifier note.** This rule is not derivable from the window arithmetic. The
independent verifier must implement it from the specification, and it is a
legitimate place for the two implementations to disagree.

### D4.4 — Two writes for the same effective day: last write wins

**Decision.** If a new epoch's `effectiveFromDay` equals the newest existing
epoch's, it replaces rather than appends.

**Why.** Two raises before the same boundary would otherwise leave two epochs
with identical effective days, and `capAt` would have to pick. Replacing makes
the on-chain array unambiguous. The event log still carries both writes, so the
verifier replaying events must apply last-write-wins per effective day.

### D4.5 — Lowering below the current window sum is not a retroactive breach

**Decision.** It blocks further spend. Days already recorded stay compliant
against the cap in force when they were recorded, which is why each record binds
its `policyVersion`.

**Why.** The alternative makes an owner's prudent tightening retroactively
convict the agent of a violation it could not have avoided. Written down
explicitly so the two implementations do not each infer it independently.

### D4.6 — `capAt` walks backward through epochs

**Decision.** `regimeAt` scans from the newest epoch and returns the first with
`effectiveFromDay <= dayIndex`.

**Why.** The array grows by one per owner policy write and never by anything the
agent controls, so the iteration is bounded by owner behaviour. Constructor
epoch 0 has `effectiveFromDay = 0`, so no day can fall before the first regime.

### D4.7 — Comparison is `<=`; the oldest day is included

**Decision.** `windowSum(day) <= capAt(day)` passes. The window is the inclusive
range `[day - windowDays + 1, day]`.

**Why.** Specified. Both are classic off-by-one sites, and both are in the
mutation suite (`<=` → `<`, oldest day excluded) precisely because a test suite
that misses them is not measuring the rule.

---

## 5. Tooling

### D5.1 — Local Hardhat 3 Solidity tests with forge-std

**Decision.** Tests are `.t.sol` files run by `hardhat test solidity`, on a local
chain, with `vm.warp` and `vm.prank`.

**Why.** The audited repo had no local tests. All five "tests" ran against Base
Sepolia: they spent gas, waited on RPC sync (one retried reads four times), and
printed results rather than asserting them. A mutation suite requires compiling
ten deliberately broken variants and confirming a test fails on each, which is
impossible against a public testnet. Controlling `block.timestamp` is also how
historical replay works now (D3.5).

### D5.2 — Removed `@nomicfoundation/hardhat-toolbox` v7

**Decision.** Uninstalled.

**Why.** It was the deprecated Hardhat 2 ethers bundle, installed with no
dependencies resolved, imported nowhere, sitting next to a Hardhat 3 runtime it
is not compatible with.

### D5.3 — `git init` on the enforcement repo, baseline committed unmodified

**Decision.** The repo had no version control at all. The audited state is
committed as-is at `1f49b7e` before any rebuild work.

**Why.** Every later claim needs a tree to point at, and the findings need a
fixed state to be findings *about*. `.env` holds `PRIVATE_KEY` and
`GROQ_API_KEY`; it is gitignored and stays that way.

### D5.4 — A mutation harness must prove the mutant compiled

**Decision.** Every mutation run records compilation status separately from the
test result. A mutation that fails to build is reported as an invalid mutant,
never as an uncaught one.

**Why.** Found the hard way while running step 2's negative controls. A
malformed patch left the contract syntactically invalid; no tests ran, the
harness saw zero failures, and the mutation was reported as **not caught** —
which reads as a hole in the test suite. It was a hole in the harness. Re-run
correctly, the same mutation was caught. "Not caught" and "did not build" are
opposite conclusions and must never share an output.

**Consequence for step 4.** The mutation suite reports three states, not two:
caught, not caught, and invalid mutant.

### D5.5 — Build scripts committed where they actually live

**Decision.** `export_records.py` and `calibrate_policy.py` are committed in the
`Demo_PlanApplyEvaluate` repo at `9b8f1d2`.

**Why.** Both were untracked, and this repo's README pointed at
`scripts\export_records.py` inside itself, where neither exists. The numbers
were never wrong: rebuilding from the step logs reproduces all three arms
byte-identically and validation passes. The defect was broken cross-repo
provenance, not arithmetic.

---

## Open questions

Not yet decided. Listed so they are not silently resolved.

- **Q1 — Does an agent-paused day get recorded at all?** *(still open)* `submitDay` currently
  reverts when the agent is paused, so no record is written and the day becomes
  a *missing* day rather than a zero day. Arithmetically the window still
  advances (an unrecorded day reads as zero), but the record set has a hole, and
  "paused day treated as missing rather than zero" is an explicit mutation in
  the suite. Options: record a forced zero with `paused = true` instead of
  reverting, or accept the hole and document it.

- **Q2 — Is F6 closed, or deliberately out of scope?** `validateTransaction`
  checks the window but `execute` records nothing; `submitDay` records but is a
  separate path. The two are still different numbers from different keys. This
  may be correct — `execute` is the transaction-level counterfactual the paper
  compares *against*, and `submitDay` is the sequence-level enforcement — but if
  so, `execute` should stop being described as enforcing the window.

- **Q3 — Recalibrate the caps.** The permissive cap (107567 milli-USD) is the
  maximum of B0's own rolling sum, so it binds on zero days for every arm and
  cannot function as a policy. Strict (18096) binds on 54/50/51 days. A 6× gap
  with nothing between them.

- **Q4 — Two build configurations disagree.** `hardhat.config.js` enables the
  optimizer at 200 runs; `foundry.toml` sets `optimizer = false`. Whichever is
  not used produces different bytecode, which matters for any claim that
  deployed bytecode matches the build artifact. Foundry is not currently
  installed, so `foundry.toml` is aspirational either way.

- **Q6 — Three mutations are caught by exactly one test each.** M3 (window
  boundary shifted a day), M6 (`capAt` returning the latest cap rather than the
  cap in force) and M7 (raise applied immediately) each die to a single
  assertion. That is above zero but thin: any edit to that one test silently
  removes the only thing measuring the rule. Step 4 should widen coverage on
  these three specifically.

- **Q5 — Owner key rotation.** `PolicyConfig.owner` is `immutable` with no
  transfer path. Simple and attack-surface-free, but a lost owner key is
  terminal for the deployment.
