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
| F8 | *(raised by Dan after step 3)* The agent reports its own daily spend, so the cap bounds *reported* spend. An agent that wants to overspend reports less. |
| F7 | *(found by the step 3 differential)* `PolicyUpdated` does not carry the day the write was submitted, so an independent verifier can either avoid false positives or detect a broken deferral rule, but not both. |

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

### D3.1 — `DayRecord` is a frozen schema  **[Superseded by D3.7]**

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

### D3.3 — Existence is tracked outside the frozen struct  **[Superseded by D3.7]**

**Decision.** `isRecorded` is a separate mapping, not a field on `DayRecord`.

**Why.** An unrecorded day and a genuinely zero day both read `netSpend == 0`.
The distinction is needed, but adding an `exists` field would change a schema
that is meant to be frozen. Keeping it outside leaves the record schema exactly
as specified.

### D3.7 — Storage is a bounded one-year ring; events are the archive

**Supersedes D3.1 and D3.3.** Taken before deployment, which is the only moment
the ledger's layout can change at all.

**Decision.** `SpendLedger` keeps the most recent `RETENTION_DAYS = 365` days in
a fixed-size ring keyed by `dayIndex % RETENTION_DAYS`. Older days are evicted
from storage and survive only in the `DayRecorded` event log. `DayRecord` is
repacked and gains a `recorded` flag; the separate `isRecorded` mapping is gone.

**Why bound it.** The previous mapping grew by a slot every day, forever, while
the rule never looks back further than `windowDays`. Storage only has to hold
what the contract needs to enforce the rule on itself. The claim that matters —
that a third party can recompute compliance from the event log alone — is
untouched, because the log is unbounded and complete.

**Why a ring rather than pruning.** Pruning needs a loop, a deletion, and refund
mechanics that EIP-3529 caps anyway. A ring is O(1), has no loop to bound, and
has a fixed footprint from the first day. `dayIndex` was already in the schema,
where it duplicated the mapping key; in a ring it becomes the thing that
distinguishes a live slot from a wrapped leftover.

**Measured.** First write to a virgin slot 95,753 gas; overwrite once the ring
has filled 7,700. A 92% reduction in steady state, reported by
`test_reportGasFirstWriteVersusOverwrite` so the evaluation quotes a measured
figure rather than a cold-start one.

**Repacking.** `dayIndex`, `paused` and `recorded` share one slot, so a record
costs 3 slots against the 4 the specification's declaration order cost. D3.1
paid that slot for fidelity to a frozen schema; the schema is being reopened
regardless, so the reason no longer applies.

**Why `recorded` exists at all.** For every day but one, `slot.dayIndex == d`
settles whether a slot is live. Day 0 is the exception: an untouched slot also
reads `dayIndex == 0`. The flag costs nothing — it packs into the same slot —
and removes the special case instead of documenting it.

**The failure this could have introduced.** A wrapped slot holds a real record
from exactly a year earlier. Read as current, it produces a wrong window sum
with no error anywhere. `test_windowIgnoresWrappedLeftovers` and
`test_writeExactlyOneRetentionLaterEvictsTheOlderDay` exist for that, and two
mutations confirm they bite: dropping the `dayIndex` check in either
`netSpendOf` or `isRecorded` fails 3 tests each.

**Not adopted: writing an explicit zero for days the agent never reported.**
It would change no arithmetic — an absent day already contributes zero to every
window — while asserting that the agent reported a day on which it reported
nothing. In a system whose product is evidence, the gap is the evidence: it
separates an offline agent from one reporting a genuinely zero day. It would
also make an outage expensive, since only the session key can write and it would
have to backfill every missed day at roughly 20,000 gas each before reporting
today. Paused days remain the exception and are written as explicit zeros with
`paused = true`, because a pause is a real event rather than an absence.

### D3.8 — `windowDays` is bounded above by the retention period

**Decision.** `PolicyConfig.MAX_WINDOW_DAYS = 365`, enforced in the constructor
and in `setPolicy`, and required to equal `SpendLedger.RETENTION_DAYS`.

**Why.** Two reasons, and the second is the serious one.

Before the ring, `windowDays` had only a non-zero check on a `uint32`. An owner
typo of a few hundred thousand would make `windowSum` loop that many times and
every submission run out of gas. Owner-set rather than agent-set, so not an
attack path, but a permanent stall until the owner noticed and lowered it.

After the ring it stops being a liveness problem and becomes a correctness one.
A window longer than retention reaches past the wrap, reads evicted days as
zero, and understates the sum — quietly, with nothing erroring. The bound is
what makes that unreachable.

**Kept in step by a test.** The two constants live in different contracts, so
`test_retentionAndMaxWindowAgree` asserts they are equal. Shrinking retention to
364 fails it, plus one more.

### D3.4 — Same-day resubmission accumulates  **[Superseded on the live path by D7.9]**

**Decision.** A second submission for a day already recorded adds to it.

**Why.** Preserved from the audited implementation, where it was confirmed
sound. Several settlements may land on one calendar day and each must count.

**Was untested until D3.7's mutation run.** Replacing the accumulation with an
overwrite passed all 70 tests. The audited version had covered it, but only in
a live-testnet script that was deleted with the rest of that tooling, and the
behaviour was never carried into the local suite. Three tests now cover it. The
gap mattered: without accumulation an agent can split a breach across two
submissions in one day.

Worth recording precisely, because the obvious test is not the one that catches
it. `test_agentCannotSplitABreachAcrossOneDay` still passes under the overwrite
mutation, because the cap is checked against the stored value *before* the write
— the corruption only shows in what is stored afterwards. The two tests that
assert the stored total are what discriminate.

### D3.5 — Day index is UTC, derived on-chain, never supplied  **[Superseded by D7.8]**

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

### D5.7 — Removed the audited tooling rather than leaving it broken

**Decision.** Deleted 14 scripts and `foundry.toml`. `scripts/` now holds only
the two key-generation helpers. The `openai` dependency went with them.

**Why.** Nine of the scripts loaded `SpendingLimitModule`, which the rebuild
deleted, so they crashed on their first line with a missing-artifact error.
Three more targeted `SmartAccount` through the old single-module `MODULE_ADDRESS`
flow, which no longer describes how the contracts wire together — the new
arrangement needs three keys, a validator selection step and an explicit ledger
allowlist entry the old flow had no concept of. `common/chain.js` built its
wallet client from a single `PRIVATE_KEY`, which is the F1 pattern itself.

Broken code that looks runnable is worse than absent code. Someone reading
`scripts/tests/` reasonably concludes the project has a test suite there; it has
not since step 1, and the real one is in `test/`.

**`generate_key.js` went too**, though it worked. It generates one key, and
keeping a "generate the key" helper beside a "three keys, never one" doctrine is
a trap rather than a convenience. `generate_destination.js` stays: it carries no
assumption about the architecture.

**`foundry.toml` deleted**, which resolves Q4. Foundry was never installed, and
the file set `optimizer = false` while `hardhat.config.js` sets it on at 200
runs. A second build configuration that nothing runs and that silently
contradicts the one that does is a trap for anyone later checking deployed
bytecode against a build artifact.

**Nothing is lost.** All of it is at `1f49b7e`, the audited baseline, and that
commit is cited in the finding list.

**What was worth keeping and was not kept.** `agent/llm_agent.js` wired an LLM
through Groq to propose new spending limits, with a system prompt that tried to
resist prompt injection. The premise is obsolete — the whole point of the
rebuild is that the agent cannot propose limits at all — but the wiring and the
prompt are a reasonable starting point for step 6's adversarial evaluation.
Recover it from `1f49b7e` rather than writing it again.

**Consequence, stated plainly.** There is now no deployment path for the
rebuilt contracts. There was not one before either — the old scripts deploy a
contract that no longer exists — but the gap is now visible instead of hidden
behind files that look like they would work.

### D5.6 — Documentation lives in `docs/`, one folder per category

**Decision.** All documentation moved out of the repository root into `docs/`,
with a subfolder per category: `guide/`, `decisions/`, `spec/`, `verifier/`.
Only the project `README.md` stays at the root. New documents go in a category
folder; a new folder is added when a genuinely new category appears.

**Why.** Four documents at the root was already hard to scan, and the work still
to come adds a security analysis, an evaluation write-up, a mutation-suite
report and a record-schema note. Deciding the shape once, while there are four
files rather than ten, costs nothing; deciding it later means moving every file
and rewriting every reference again.

**Cost paid once.** 68 lines across 8 files referenced these documents by path,
including 39 inside the verifier's own source and tests. All were rewritten, and
`git mv` preserved history. Cross-references now use the full repository path so
they read identically from source, commit message or another document.

**Naming.** Files are named for what they are, not where they sit:
`enforcement-rule.md` rather than another `SPEC.md`, `implementation-notes.md`
rather than another `README.md`. Four files called `README.md` in four folders
is not an improvement on four files at the root.

### D5.5 — Build scripts committed where they actually live

**Decision.** `export_records.py` and `calibrate_policy.py` are committed in the
`Demo_PlanApplyEvaluate` repo at `9b8f1d2`.

**Why.** Both were untracked, and this repo's README pointed at
`scripts\export_records.py` inside itself, where neither exists. The numbers
were never wrong: rebuilding from the step logs reproduces all three arms
byte-identically and validation passes. The defect was broken cross-repo
provenance, not arithmetic.


---

## 6. Findings from the differential (step 3)

### D6.1 — `PolicyUpdated` must carry the submission day (F7)

**Status.** Open. Requires a contract change.

**What the differential found.** Both implementations agree on all 1,095 days of
real arm data (B0, B1, B2) and on the pause scenario — 1,116 of 1,137 day-rows.
All 28 disagreements come from a single scenario and a single root cause.

The verifier, on a write it classifies as a raise, computes the effective day as
`nextWindowBoundary(effectiveFromDay, incumbentWindowDays)`. But
`effectiveFromDay` in the event has *already* been deferred by the chain, so the
boundary function is applied twice and the raise slips an extra window.

**Why this is the specification's fault, not the verifier's.** enforcement-rule.md §2.2 says
`effectiveFromDay` is always explicit and must never be inferred. §5.4 says a
raise takes effect at the next window boundary. With no submission day in the
event, those two instructions cannot both be followed, and each reading fails in
an opposite direction:

| chain | verifier reading | disagreeing days | outcome |
|---|---|---|---|
| correct | trusts `effectiveFromDay` | 0 | clean |
| correct | re-derives the boundary | 7 | false positives |
| mutated (raise applied immediately) | trusts `effectiveFromDay` | 0 | **mutation missed** |
| mutated (raise applied immediately) | re-derives the boundary | 9 | mutation caught |

A verifier that trusts the field cannot detect a chain that stopped deferring
raises — it simply believes whatever effective day it is handed. A verifier that
re-derives the field reports breaches on a correct chain. Neither is usable, and
no wording change to §5 fixes it: the information required is not in the event.

**The fix.** Add the submission day to the event:

```
event PolicyUpdated(
    uint256 indexed policyVersion,
    int256  cap,
    uint32  windowDays,
    uint64  submittedOnDay,     // new: todayIndex() at the time of the write
    uint64  effectiveFromDay,
    address setBy
);
```

The verifier then checks the deferral rule rather than assuming it, by
recomputing the expected effective day from `submittedOnDay` and comparing:

```
expected = isRaise ? nextWindowBoundary(submittedOnDay, incumbent.windowDays)
                   : submittedOnDay
assert expected == effectiveFromDay
```

That keeps §2.2's rule intact — the effective day is still read, never inferred
— while making the deferral independently checkable, which is the whole point of
having a second implementation.

**Why this counts as a real result.** The exercise was set up so the two sides
could disagree, and it produced a defect in the evidence schema that neither
side could have found alone. The chain cannot notice that its event is missing a
field a verifier would need; the verifier cannot tell a deferral it disagrees
with from one it merely cannot check.

### D6.2 — Agreement on the arms is a weak signal, and is treated as one

**Decision.** The 1,095 matching day-rows across B0, B1 and B2 are recorded as a
volume check on window arithmetic and signed handling, not as evidence that the
rule is right.

**Why.** Those three scenarios have a single genesis policy and no cap changes,
so they exercise §4 and §6 but almost none of §5 — which is where every
disagreement actually was. A differential is only as strong as the scenarios fed
to it, and agreement on the easy region says nothing about the hard one.

### D6.3 — Records are written directly to the ledger in the differential

**Decision.** `test/Differential.t.sol` writes through an owner-allowlisted test
writer rather than through `submitDay`.

**Why.** `submitDay` reverts on a breach, which would halt a replay at the first
one and make a disagreement *set* impossible to collect. The quantity being
compared is the rule — `windowSum` and `capAt` on every day — not the revert.
Enforcement behaviour is covered separately in `Enforcement.t.sol`.

---

## 7. Measured inputs: the agent no longer reports its spend

Decided 2026-09-15 with Dan, before deployment. This section replaces the
agent-reported spend path that steps 1–3 were built on. The earlier decisions
stay in the log as history; the ones this section overrides are marked.

### D7.1 — Spend is computed on-chain from measured inputs (F8)

**Decision.** The agent no longer submits a daily spend figure. Daily spend is
computed by the contract from two inputs the agent does not control: per
half-hour grid import and export, signed by a meter, and per half-hour prices,
published by a price oracle.

**Why.** Every enforcement result so far bounded a number the agent supplied.
The rule could be implemented perfectly, twice, by independent authors, and an
agent could still overspend by under-reporting. That breaks the project's
governing principle — the proposer is never trusted — at the one input that
matters most.

**Why moving the arithmetic alone was not enough.** Had the agent posted raw
quantities for the contract to multiply, it would under-report imports instead
of spend. What closes the gap is who supplies each input, not where the
multiplication happens.

**Why per half-hour, not daily totals.** Prices vary up to 3.3× within a day.
Daily import and export totals multiplied by the day's mean price mis-state
spend by 393 mUSD/day on average and 19,801 mUSD on the worst day of 2022 —
larger than the entire 7-day strict cap of 18,096.

**Remaining trust assumptions, stated rather than hidden.** Enforcement is sound
provided the meter reports honestly and the price publisher publishes honestly.
Neither is the agent, and a real deployment would have exactly these two parties
in a smart meter and a market data feed. The security analysis must say so.

### D7.2 — Prices come from a price oracle with its own publisher key

**Decision.** A `PriceOracle` contract. A fourth key, the price publisher,
publishes one UTC day of 48 import prices and 48 export prices, once per day,
never amended. The oracle stores a hash commitment to the day's prices and emits
the prices in full; settlement passes the prices in and the contract checks them
against the commitment.

**Why not the owner.** Posting 96 prices a day is operational work an owner key
should not be doing, and it would put a hot key in charge of a policy-critical
input. Dan's call.

**Why a commitment rather than stored prices.** Storing 96 prices is 24 slots a
day; a commitment is one. The prices still reach the chain, in the event, and
the event log is already the archive (D3.7). Prices and meter readings then have
the same shape: authenticated once, carried as calldata.

**Simulated.** A script holding the publisher key reads `rtp_usd_per_kwh` from
the dataset — the real CAISO TH_NP15 real-time series — and publishes it. The
publisher never runs in the agent's process. The contract interface is narrow so
a real feed can replace the simulated one.

**Changed from what was proposed in conversation.** The proposal was an
owner-set export multiplier φ in `PolicyConfig`. Rejected on implementation
review: raising φ lowers measured spend, so it would be a cap raise that
bypasses the boundary deferral of D4.1. Export tariffs are also set by the
utility, not the household. The publisher therefore publishes export prices
directly; the simulated publisher derives them with the simulator's existing
rule, `price_exp = max(0, 0.3 × price_imp)`.

**Signed.** Prices are signed integers. CAISO real-time prices can go negative;
none do in 2022, but the contract must not assume it.

### D7.3 — Grid import and export come from a meter; anyone may relay the readings

**Decision.** The meter key signs a day's 48 import and 48 export readings. Any
address may submit the signed payload; the contract checks the signature against
the meter address the owner registered in `PolicyConfig`.

**Simulated.** The dataset contains no meter data at all — it is simulated, and
grid import and export are not in it. The HEMS simulator computes them from load,
PV and the agent's own battery and appliance decisions. The simulator, not the
agent, therefore plays the meter and holds its key.

**Why anyone may relay.** It removes a withholding attack that exists today: an
agent that reports its own days can simply not report a bad one, and a missing
day counts as zero. When authenticity comes from the meter's signature rather
than from who sends the transaction, the owner or the guardian can post a day
the agent withheld.

**What the signature binds.** Chain id, the `SpendLedger` address, the day, and
all 96 readings. The ledger rather than the validator, because the ledger is
never redeployed: signatures stay valid across a validator upgrade, and cannot
be replayed onto another ledger or chain.

### D7.4 — Battery degradation is excluded from the enforced spend

**Decision.** Enforced spend is energy cost only:
`Σ import × import_price − export × export_price`. The simulator's `c_deg` term
stays a reported metric off-chain and stays in the controllers' objective.

**Why.** Degradation is modelled battery wear, not money paid, and the owner
delegated spending authority. Decisively, it is computed from battery discharge,
which sits behind the meter and would have to be reported by the agent —
re-introducing exactly the agent-reported input D7.1 removes. It is 1.8% of
annual cost.

**Consequence.** `export_records.py` validates against published annual costs
that include degradation; it needs energy-only reference figures. Caps are
recalibrated anyway (Phase E).

### D7.5 — Record the measured day, then restrict the agent

**Decision.** A settled day is always recorded, whatever its spend. When the
rolling window is over the cap, the agent's authorisation is withdrawn until the
window falls back under it. Supersedes the revert-on-breach behaviour of
`submitDay`.

**Why.** Reverting an over-cap report left a hole: the rejected day was never
written, so it counted as zero in the next six windows, and a breach gave the
agent *more* headroom afterwards. With self-reported spend that could be read as
"authorisation denied". With meter readings describing energy already consumed,
refusing to record them makes the ledger show less spend than occurred. The
ledger must record what happened; enforcement acts on what the agent may do
next.

**Consequence for F6 (Q2).** `SmartAccount.execute` becomes the gated action.
Transfer values are not spend — spend is metered — so the validator stops
treating them as spend and checks the agent's authorisation instead.

### D7.6 — Pause gates actions, not accounting (resolves Q1)

**Decision.** A pause blocks the agent's actions. It no longer changes a day's
recorded spend.

**Why.** "A paused day is a zero-spend day" made sense when the agent reported
spend: a pause could force the report to zero. A pause cannot make metered
energy not have been consumed. Q1 — whether an agent-paused day is recorded —
dissolves: the meter's day is recorded regardless.

**Supersedes a rule from the handoff document itself**, which said a paused day
is a zero-spend day. Recorded explicitly because the handoff was authoritative
where it conflicted with code; this is a deliberate change of premise, approved
by Dan, not a drift.

### D7.7 — The day boundary is UTC; the dataset clock is treated as fixed UTC−8

**Decision.** Prices and readings are grouped into UTC days of 48 half-hours. The
dataset's `America/Los_Angeles` timestamps, which run a regular 48-step grid on
every day including daylight-saving transitions, are mapped to UTC as a fixed
UTC−8 offset. The two partial UTC days at the edges of the 2022 evaluation year
are dropped, leaving 364 complete days.

**Why.** On-chain day index is UTC (D3.5). A local day and a UTC day are eight
hours apart, so the two sides would otherwise put different half-hours into the
same day. The dataset's grid has no gaps or duplicates at DST transitions, so it
is not true local time; a fixed offset preserves a one-to-one mapping to UTC.
The cost is a one-hour misalignment between the grid and wall-clock time during
summer, identical on both sides because both read the same readings.

### D7.8 — Settled days are consecutive and strictly in the past (supersedes D3.5)

**Decision.** A day may be settled only after it has ended, and only as the day
immediately following the last settled day.

**Why it supersedes D3.5.** The day index is now supplied by whoever relays the
readings, not derived from block time. F5 — an agent emptying its window by
jumping the day index forward — stays closed for three reasons: the agent does
not settle days, the meter signs the real day, and settlement cannot skip.

**Why consecutive.** Without it, a stranger holding two valid signed days could
settle the later one first. The ledger's non-decreasing rule would then make the
earlier day permanently unrecordable, and it would count as zero — handing the
agent headroom. A permissionless relay has to be ordered.

### D7.9 — One settlement per day, no corrections (supersedes D3.4 on the live path)

**Decision.** A meter day is settled once and is final. The ledger still supports
same-day accumulation for its writers, but the live path never uses it.

**Why.** The meter reports a complete day, not a stream of settlements, so there
is nothing to accumulate. A correction mechanism is a real need for a deployment
with real meters and is out of scope here; recorded so it is a known gap rather
than a surprise.

### D7.10 — Integer units, and rounding happens once, on-chain (moves F4)

**Decision.** Readings are unsigned milliwatt-hours; prices are signed integers
in 10⁻⁸ USD/kWh. The contract sums the day exactly as an integer numerator and
rounds once, half away from zero, to milli-USD.

**Why these units.** The dataset's prices carry 8 decimal places, so 10⁻⁸
USD/kWh is exact. The simulator's energy values carry up to 20 decimal places of
floating-point noise, so the simulated meter must round to a resolution the way
a real meter does; at 1 mWh the rounding moves a day's spend by far less than
one milli-USD.

**Why round once.** Rounding each half-hour would compound 48 rounding errors
into the day. Keeping the exact numerator and rounding the total matches how the
existing records are built — once per field per day.

**Consequence.** F4 is no longer a float-to-integer step in the export script.
It is signed integer division in Solidity, and the verifier must reproduce it
independently.

### D7.11 — The agent is unauthorised when settlement falls behind

**Decision.** If the last settled day is more than two days before today, the
agent is unauthorised, exactly as if it were over the cap.

**Why.** Enforcement can only see settled days. If settlement stalls — a meter
outage, a missing price day, deliberate withholding — the agent would otherwise
keep acting against a window that no longer reflects what it spends. The failure
has to be closed: no fresh measurement, no authority. Two days allows a day to
end, prices and readings to be signed, and a relay to land.


### D7.12 — The meter may never be the agent's session key, enforced on-chain

**Decision.** `PolicyConfig.setMeter` refuses the current session key, and
`setSessionKey` refuses the current meter. Revoking the session key to zero is
unaffected.

**Why.** The same lesson as F1. If one key both acts as the agent and signs the
meter readings, the agent is back to reporting its own spend, and nothing else
in the system would notice. One misconfiguration at deployment is enough, so the
rule is enforced rather than trusted to a deployment script.

**Not extended to the price publisher.** The publisher lives in `PriceOracle`,
and the oracle's admin can change it at any time without `PolicyConfig` seeing
the change, so a check at registration would be partial and could give false
comfort. Keeping the publisher distinct from the agent is a deployment
obligation, and the security analysis must list it as one.

### D7.13 — Meter readings are EIP-712 typed data, checked against an independent encoder

**Decision.** The meter signs `MeterReadings(uint64 dayIndex, uint64[48]
importMWh, uint64[48] exportMWh)` under domain `HouseholdMeter`, version `1`.
One test pins the Solidity digest to a value computed separately with viem's
`hashTypedData`.

**Why typed data.** A standard encoding means an ordinary signer produces the
signature — the simulated meter signs with viem, and a hardware signer could do
the same — rather than a bespoke hash only this contract understands.

**Why the pinned reference.** Every other signature test compares the contract
against itself, so an error in how fixed-size arrays are encoded would pass all
of them and then fail every genuine signature in deployment. The pinned test
caught four of the twelve A2 mutations, and was the only test to catch the
removal of the EIP-712 `\x19\x01` prefix.

**One equivalent mutant, recorded as such.** Removing the check that `v` is 27
or 28 changes nothing observable: the recovery precompile already returns the
zero address for any other `v`, and the zero-signer check rejects it with the
same error. The explicit check stays for readability; it is not a test gap.


### D7.14 — The ledger record holds raw data only: no pause flag, no breach flag

**Decision.** `DayRecord` is `dayIndex`, `recorded`, `policyVersion`,
`netSpend`. The `paused` field is removed and not replaced.

**Why no pause flag.** A pause no longer changes a day's spend (D7.6), so the
flag would describe nothing about the record.

**Why not reuse the slot as an over-cap flag.** It was considered, and would
have cost nothing in storage. Rejected because whether a day breached is derived
— from the window and the cap in force — rather than measured. It is already in
the validator's `DaySettled` event and recomputable from the log. The ledger is
never redeployed, so a derived value stored there would make any validator bug
in computing it permanent. D1.2 already committed the ledger to raw days; this
keeps to it.

### D7.15 — The agent calls `execute`; the validator decides; the owner is unconstrained

**Decision.** `SmartAccount.execute` accepts the owner or the current session
key and refuses anyone else. `SpendValidator.validateTransaction` returns true
for the owner, the agent's authorisation state for the session key, and false
for anyone else. A spend pause still stops the owner at the account.

**Why the agent is now a caller.** Enforcement has to act on something the agent
does. With spend metered rather than reported, the agent no longer submits
anything, so its transfers through the account are the action enforcement
gates.

**Why the owner is not gated by the cap.** The cap is delegated authority. The
owner is the principal delegating it, and the household's own money is not
subject to the agent's budget.

**Two layers, both tested.** The account refuses strangers before any validator
runs, and the validator refuses them too. A mutation showed the second layer was
untested — a validator admitting anyone passed every test, because the account
stopped strangers first — so the validator's refusal is now asserted directly.
A validator is a module, and must not rely on the account it happens to be
installed on.

**Authorisation reasons are reported, not only a boolean.** `authorization()`
returns `NoSessionKey`, `AgentPaused`, `SettlementStale`, `OverCap` or
`Authorized`. The evaluation needs to say *why* an agent was refused, and a
bare `false` would hide whether it was the cap or a stale meter.

---

## Open questions

Not yet decided. Listed so they are not silently resolved.

- **Q7 — Three further defects the verifier author raised**, none yet acted on.
  §6.2 prescribes a *cap* comparison to detect a *version identity* failure, so
  a write changing only `windowDays` produces two versions sharing a cap and
  passes a check aimed at exactly that case. §7's rounding rule has no
  application inside §2's data model, since every §2 field is already an
  integer — if it is meant to apply at a specific conversion step, §7 should
  name it. And §5 never says what governs a recorded day falling before the
  first effective write. The full list of 22 ambiguities is in
  `docs/verifier/implementation-notes.md`.

- **Q1 — Does an agent-paused day get recorded at all?** *(resolved by D7.6)* `submitDay` currently
  reverts when the agent is paused, so no record is written and the day becomes
  a *missing* day rather than a zero day. Arithmetically the window still
  advances (an unrecorded day reads as zero), but the record set has a hole, and
  "paused day treated as missing rather than zero" is an explicit mutation in
  the suite. Options: record a forced zero with `paused = true` instead of
  reverting, or accept the hole and document it.

- **Q2 — Is F6 closed, or deliberately out of scope?** *(resolved by D7.5)* `validateTransaction`
  checks the window but `execute` records nothing; `submitDay` records but is a
  separate path. The two are still different numbers from different keys. This
  may be correct — `execute` is the transaction-level counterfactual the paper
  compares *against*, and `submitDay` is the sequence-level enforcement — but if
  so, `execute` should stop being described as enforcing the window.

- **Q3 — Recalibrate the caps.** The permissive cap (107567 milli-USD) is the
  maximum of B0's own rolling sum, so it binds on zero days for every arm and
  cannot function as a policy. Strict (18096) binds on 54/50/51 days. A 6× gap
  with nothing between them.

- **Q4 — Two build configurations disagree.** *(resolved: `foundry.toml`
  deleted, see D5.7)*

- **Q6 — Three mutations are caught by exactly one test each.** M3 (window
  boundary shifted a day), M6 (`capAt` returning the latest cap rather than the
  cap in force) and M7 (raise applied immediately) each die to a single
  assertion. That is above zero but thin: any edit to that one test silently
  removes the only thing measuring the rule. Step 4 should widen coverage on
  these three specifically.

- **Q5 — Owner key rotation.** `PolicyConfig.owner` is `immutable` with no
  transfer path. Simple and attack-surface-free, but a lost owner key is
  terminal for the deployment.
