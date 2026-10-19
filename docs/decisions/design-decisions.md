# Design decisions

Every decision taken while building Policy Spec v0.1, in build order, with the
reason, what was rejected and what follows from it.

How this log relates to the spec:

- `docs/spec/policy-spec-v0.1.md`**, Section 7** lists the design decisions as a
table, D1 to D21. D1 to D14 were settled in the brief before any code. D15 to
D21 were taken while building step 1 and are explained here.
- **This log** is numbered by build step: decision 1.4 is the fourth decision
of step 1. Where an entry corresponds to a row of the spec's table, it says
so.

Each entry carries a status:

- **Settled:** decided by Dan, or fixed by the brief.
- **Proposed:** built this way, awaiting Dan's confirmation. Changing it is
still cheap.
- **Open:** not decided. Listed again in the last section.

This log is append-only. A reversal gets a new entry marked **Superseded**,
never an edit.

The decisions of the project that came before this one are in
`docs/earlier-design/design-decisions.md`.

---



## Step 0. Starting point and tooling

Taken between 9 and 12 October 2026, before and around the first code.

### 0.1 — Answer Section 10 of the spec before writing code

**Status.** Settled (required by the brief).

**Decision.** The repository was read first and Section 10 filled in. Work
stopped there, because the repository contradicted the brief on two blocking
points.

**What was found.**

- The account, `contracts/SmartAccount.sol`, was a custom contract: not
ERC-7579, not ERC-4337, no `executeFromExecutor`. It could not host an
executor module.
- The toolchain was Hardhat 3. There was no Foundry and no ModuleKit;
`foundry.toml` had been deleted on purpose in the earlier project.
- The Rhinestone, Pimlico and Turnkey wiring was in a sibling folder,
`ai-agent-wallet`, as scripts using Smart Sessions, which the brief forbids.
- There was no deployment script and no contract named PolicyGuard. Its role
was played by `PolicyConfig`, `SpendLedger` and `SpendValidator`.
- The simulation's slot is 30 minutes, not the 15 the brief assumed.

**Consequence.** Decisions 0.2 to 0.5 follow from these findings.

### 0.2 — Build in place, in the fork

**Status.** Settled by Dan, 2026-10-09. Spec amendment A1.

**Decision.** The v0.1 contracts are added to this repository directly. The
brief's instruction to add a separate package beside the old contracts and
never edit them in place is dropped.

**Why.** This folder is already a copy. The untouched original stays in
`agent-energy-blockchain-proiect2`, so nothing here needs protecting.

**Consequence.** Both folders share one `origin` remote. All v0.1 work is on
branch `feature/policy-gate-v0.1`, so nothing lands on the original's `master`.

### 0.3 — The earlier contracts stay until step 4

**Status.** Proposed. Dan has said the earlier project is of no interest;
whether its code should go sooner is listed under open decisions.

**Decision.** `PolicyConfig`, `SpendLedger`, `SpendValidator`, `SpendMath`,
`PriceOracle`, `MeterReadings`, `SmartAccount` and their 144 tests are left
untouched. They are removed in step 4, when sequence policy S1 covers their
function. New code lives in `contracts/gate/`; the earlier code stays at the top
of `contracts/`.

**Why.**

- The brief asks that the earlier contract keep compiling until S1 covers it.
- The 144 tests and the differential are a regression check on the tooling
changes below. After the compiler moved to 0.8.25, the differential still
showed 0 disagreements on 1,880 days.
- Two pieces are reused later: the EIP-712 checking in `MeterReadings.sol`
(step 5) and the verifier and differential structure (step 3).

**Rejected.** Deleting it now. It would save reading time and cost the
regression check while the toolchain is still moving.

**Consequence.** Spec decision D13, "PolicyGuard retired or kept as a reporting
layer", is settled in practice as retired at step 4. The earlier design's
documents were moved to `docs/earlier-design/` on 2026-10-12.

### 0.4 — Slot length is a parameter

**Status.** Settled by Dan, 2026-10-09. Spec amendment A2.

**Decision.** The slot length Δ is set at deployment. Nothing hard-codes 15
minutes.

**Why.** The HEMS dataset is 30 minutes, 48 slots a day.

**Consequence.** Every default the brief gives as "15 min" reads as one slot:
the S2 and S4 bucket, and the SoC staleness bound.

### 0.5 — Foundry and ModuleKit; Solidity 0.8.25

**Status.** Settled by Dan, 2026-10-09. Spec amendment A3.

**Decision.** Foundry 1.8.5 with ModuleKit 0.5.9. Solidity moves from 0.8.23 to
0.8.25, EVM version `cancun`, optimizer unchanged at 200 runs.

**Why.**

- The custom account could not host an executor. ModuleKit supplies real
ERC-7579 accounts: the reference implementation, Safe7579, Nexus and Kernel.
Step 1's acceptance criteria ask for at least two.
- Those accounts use transient storage, so the test chain must be `cancun`, and
Solidity 0.8.23 cannot target `cancun`. 0.8.25 is what ModuleKit itself
builds with.

**Consequence.** The gas figures recorded for the earlier design were measured
on 0.8.23 and were not re-measured.

### 0.6 — forge-std 1.9.4 → 1.9.6

**Status.** Settled (forced).

**Decision.** The test library `forge-std` is pinned at v1.9.6.

**Why.** ModuleKit 0.5.9 does not compile against 1.9.4: it calls the
cheatcode `exists` from a read-only function, and `exists` only became
read-only in 1.9.5. ModuleKit was published on 2025-03-11, when 1.9.6 was
current, so 1.9.6 is the version it was built against.

**Rejected.** The newest `forge-std` (1.17.0). A larger jump than the problem
needs.

**Consequence.** All 209 Hardhat tests were rerun after the change and pass.

### 0.7 — Two test runners

**Status.** Proposed. It is a workaround for one machine and goes away if the
block below is lifted.

**Decision.** Hardhat runs every test except `test/accounts/`. Foundry runs
everything. On the development machine Foundry runs inside its official
container, `ghcr.io/foundry-rs/foundry:v1.8.5`.

**Why.**

- On the development machine Windows Smart App Control blocks `forge.exe`. It
is a security control, so it was not worked around.
- Hardhat cannot build ModuleKit: it rejects two import remappings inside the
ModuleKit package itself, which cannot be fixed without patching a
dependency.

**Rejected.**

- Turning Smart App Control off. A Windows security setting, and Dan's to
change.
- Vendoring or patching ModuleKit so Hardhat accepts it. A patched dependency
to maintain, to save a container.

**Consequence.**

- `npm test` and `differential/run_diff.py` name their test files, so Hardhat
never tries to build `test/accounts/`.
- ModuleKit's import remappings are in `foundry.toml`, not `remappings.txt`,
because Hardhat also reads `remappings.txt`.
- The container needs a volume, `foundry-svm`, owned by user id 1000.
- Every Foundry run prints seven `error:` lines from its lint pass over an
unused ModuleKit file. They do not affect the build or the tests.

---



## Step 1. Skeleton and key model

Built 9 to 12 October 2026. Acceptance criteria met on 2026-10-12: 65 tests on
a minimal account, the same scenario on four real accounts.

### 1.1 — The gate is an executor module and imports no library

**Status.** Settled for the executor (spec D1). Proposed for "no library"
(spec D21).

**Decision.** `PolicyGate` is an ERC-7579 executor. It declares the two pieces
of the standard it needs in `contracts/interfaces/IERC7579.sol` and imports
nothing else. ModuleKit is used by the tests only.

**Why.** The gate is trusted code: a bug in it is a policy bypass. Everything
it depends on has to be audited with it. What it needs from the standard is
four module hooks and one account function.

**Rejected.** Inheriting ModuleKit's `ERC7579ExecutorBase`. It pulls in batch
and delegatecall helpers the gate must never use.

**Consequence.** The gate builds under Hardhat as well as Foundry. The
execution mode is one constant: one call, revert on failure, never a batch,
never a delegatecall.

### 1.2 — One deployment; state keyed by account and installation generation

**Status.** Proposed (spec D20).

**Decision.** One gate serves many accounts. Every mapping is keyed by account
and by a generation counter that goes up each time the account installs the
gate.

**Why.** Uninstalling cannot walk the mappings to clear them. Without the
generation, an agent registered before an uninstall would have authority again
after a reinstall.

**Consequence.** Uninstalling and reinstalling voids every agent, approval,
policy and proposal. `GateInstalled` and `GateUninstalled` carry the
generation, so a verifier replaying events knows when to reset.

### 1.3 — The owner path is "the caller is an account with the gate installed"

**Status.** Settled in substance by the brief (Section 5.6). The form is
proposed.

**Decision.** Every configuration write checks one thing: the caller has the
gate installed. The write lands in the caller's own state. There is no owner
address stored in the gate.

**Why.** The account calls the gate only when its root validator authorised
the call. Asking "is the caller the account" delegates the question "is this
the owner" to the account, where the owner's key already lives.

**Consequence.**

- The owner's key calling the gate directly is refused. It must go through the
account.
- Anyone can call `onInstall` and pass the check, but then writes state keyed
by themselves, which no other account reads. Tested.



### 1.4 — The account and the gate are never targets

**Status.** Settled in substance by the brief (step 1 acceptance: "including
nested self-calls through the gate"). The double check is proposed.

**Decision.** `submit` refuses the account, the gate and the zero address as
targets. `setDecoder` refuses to approve them. The check is made in both
places.

**Why.** These are the two nested self-calls.

- Real accounts accept `installModule` and `uninstallModule` from themselves.
`submit` makes the account call things. With the account as target, the agent
would manage modules.
- A call from the account to the gate arrives on the owner path. With the gate
as target, the agent would register agents and loosen policies.

**Why twice.** The check in `setDecoder` stops the owner opening the door by
mistake or under persuasion. The check in `submit` holds even if a registry
entry that should not exist somehow does.

### 1.5 — The allowlist is exact

**Status.** Proposed.

**Decision.** A call is allowed only when the owner registered a decoder for
exactly that target and that function selector. There is no wildcard for a
whole contract.

**Why.** An approved market may have functions the agent must not reach, such
as a withdrawal. An unregistered function on an approved market must be as
unreachable as an unknown contract.

### 1.6 — Agent entries: an inclusive expiry, immediate revocation

**Status.** Proposed.

**Decision.** An agent entry is one number, `validUntil`. The agent may submit
through that second, inclusive. `revokeAgent` deletes the entry and acts in the
same block. An account may have several agents. The account, the gate and the
zero address cannot be agents.

**Why the last rule.** The account or the gate as agent would let a call arrive
at `submit` already carrying owner-path authority.

### 1.7 — An unknown agent or call reverts; only a policy rejection does not

**Status.** Proposed (spec D15).

**Decision.** `submit` reverts for an unregistered or expired agent, a
forbidden target, an unapproved call and calldata shorter than a selector.

**Why.** The brief says policy rejection is the only non-reverting failure.
Reverting also means a stranger cannot make the gate write events about someone
else's account.

**Consequence.** These attempts leave no trace on chain. In the evaluation,
evidence that A7 and A8 hold comes from the tests, not from the event log.

### 1.8 — Registering an agent and approving a call apply at once

**Status.** **Open** (spec D16). Built this way; the least certain decision of
step 1.

**Decision.** `registerAgent` and `setDecoder` take effect in the same call.
Only policy parameters and policy removal wait 24 hours.

**Why.** The brief's timelock is on parameters. A timelock here would also
delay the first setup of every account by a day.

**The argument against.** Both calls widen what the agent can do. Extending an
agent's expiry or approving a new market function is a loosening in everything
but name.

**Options.**

- Keep as built.
- Timelock only the changes that extend: a later `validUntil`, a new approval.
First registration after install stays immediate.



### 1.9 — What `submit` does in step 1, and what it leaves out

**Status.** Proposed.

**Decision.** `submit(account, target, callData)` implements steps 1, 2, 7 and
8 of the spec's flow: check the agent, look up and run the decoder, have the
account make the call, emit the outcome.

**Left out, on purpose.**

- **Readings.** The spec's signature has a `readings[]` argument. It is not
there yet. Oracle verification is step 5, and an argument the gate accepts
without verifying is a hazard: the brief's rule is that the agent never
supplies an unsigned reference value.
- **The policy check and commit phases.** Step 4. Until then the policy list is
configured and not consulted: no order is rejected by a policy.

**Other choices made here.**

- **No value.** The account's native balance is not the agent's to move; the
call always carries zero.
- **Order hash.** Chain id, gate address, account, the account's submission
counter, target, hash of the calldata. The counter survives reinstalls, so
hashes never repeat. The hash is what an owner co-signature will sign
(`flagMode = COSIGN`, step 4).

**Consequence.** The signature of `submit` changes in step 5.

### 1.10 — One reentrancy lock for the whole gate

**Status.** Proposed.

**Decision.** `submit`, every configuration write, `onInstall` and
`onUninstall` share one lock.

**Why.** The brief asks for `nonReentrant` on `submit`. Sharing the lock with
configuration gives a stronger property: no agent, approval or parameter can
change while an order is part-way through.

### 1.11 — The policy classifies a change; the gate decides when it applies

**Status.** Proposed. Extends Section 4.2 of the spec.

**Decision.** A policy contract implements three configuration functions:

- `classifyConfig(account, policyId, config)` returns `INVALID`, `TIGHTEN` or
`WIDEN`. Read-only.
- `configure(account, policyId, config)` puts it in force. Gate only.
- `deconfigure(account, policyId)` drops the instance. Gate only.

**Why.** The direction table is per parameter: lower is tighter for a cap,
higher is tighter for `socMin`. Only the policy knows its parameters. The
timing rule is the same for every policy, so it lives once, in the gate.

**Rules fixed here.**

- A change that tightens one parameter and loosens another is `WIDEN`.
- An unchanged configuration is `TIGHTEN`.
- The first configuration of a new instance is `TIGHTEN` if valid.

**Not yet covered.** The spec's cross-parameter constraint `H_slots ≤ k` spans
two policy contracts, and structural changes need carry-over of old totals.
Both belong to steps 4 and 5.

### 1.12 — Adding a policy is immediate; removing one waits

**Status.** Proposed (spec D19).

**Decision.** `addPolicy` applies at once. Removal is `proposeRemovePolicy`,
then `applyRemovePolicy` no earlier than 24 hours later.

**Why.** Every policy can only reject. Adding one adds a constraint; removing
one lifts a constraint, which is a widening.

### 1.13 — Applying a widening is an owner call, with the same bytes

**Status.** Proposed (spec D17).

**Decision.** After the delay, the owner calls `applyConfig` with the
configuration exactly as proposed. The gate stored its hash and compares. The
policy is asked again whether the configuration is valid; the proposal is spent
whichever way that goes.

**Why an owner call.** The brief says only the owner path configures. A
permissionless apply would let the agent choose the moment a looser cap takes
effect.

**Why re-check.** Other parameters may have changed during the 24 hours.

**Rejected.** Applying automatically when the delay has passed. It needs every
read of every parameter to check for a matured proposal.

### 1.14 — One pending proposal per instance; any later write drops it

**Status.** Proposed (spec D18).

**Decision.** A policy instance has at most one pending proposal. Any later
`setConfig` or `proposeRemovePolicy` on that instance drops it and emits
`ConfigRejected` with reason `SUPERSEDED`. `cancelProposal` drops it with reason
`CANCELLED`.

**Why.** Without it, a widening queued yesterday would come back after a
tightening made today. Re-proposing also restarts the clock, so a second
proposal cannot ride on the first one's elapsed time.

### 1.15 — An invalid configuration is an event, not a revert

**Status.** Proposed.

**Decision.** When a policy classifies a configuration as `INVALID`, the gate
emits `ConfigRejected` and returns without reverting.

**Why.** The spec lists `ConfigRejected` among the events. A revert would erase
it. Enforcement has to be recomputable from the log, and that includes refused
configuration.

**Consequence.** The owner's transaction succeeds even though nothing changed.
The return value and the event say so.

### 1.16 — At most 16 policy instances per account

**Status.** Proposed. The number is a placeholder.

**Decision.** `MAX_POLICIES = 16`.

**Why a bound.** From step 4, `submit` calls every policy on the list. The
design invariant is that nothing on chain iterates a list without a bound.

**Why 16.** The spec has six policy contracts and about ten instances per
account. 16 leaves headroom. Revisit when gas per order is measured in step 4.

### 1.17 — A policy cannot make itself permanent

**Status.** Proposed.

**Decision.** When the gate removes a policy or is uninstalled, it tells the
policy to drop its state and ignores a failure.

**Why.** A policy contract that reverts in `deconfigure` would otherwise block
its own removal, or block uninstalling the gate.

**Not yet handled.** If that call fails, the policy keeps stale state for the
account. A later `addPolicy` of the same instance would find it. To settle in
step 4, when policies hold window totals.

### 1.18 — Two layers of tests

**Status.** Proposed.

**Decision.**

- `test/gate/` runs against `MiniAccount`, a minimal account written for the
tests. 65 tests, fast, under either runner.
- `test/accounts/` runs one scenario on four real accounts through ModuleKit.
Each test asserts the account's own `accountId()`.

**Why both.** The minimal account makes the permission table easy to test
exhaustively. The real accounts show the gate works where it will run, and
catch differences between implementations.

**Why** `MiniAccount` **accepts self-calls.** Real accounts accept module
management from themselves. That is the escalation route. A mock that closed it
would hide the thing being tested.

**A limit, stated plainly.** No test shows that only the owner can make the
account act. ModuleKit's default validator accepts any signature, and
`MiniAccount` trusts its `owner` address. "The root validator belongs to the
owner alone" is a deployment property, to be asserted when a deployment script
exists.

### 1.19 — Mutation check by hand

**Status.** Settled as a practice; the tooling is step 3.

**Decision.** Before step 1 was called done, the gate was broken one line at a
time and the tests rerun.

**Result.**

- 51 defects against `test/gate/`. 49 caught at first. The two that survived
were gaps in the tests: a stale list index that only breaks a later removal,
and a missing event when a removal proposal replaces a pending widening. Two
tests were added; all 51 are caught.
- 9 defects against `test/accounts/`. All caught.

**A finding.** A gate that declares itself a validator is refused by Nexus and
the reference account, and installed by Safe7579 and Kernel. Those two do not
check a module's declared type at install. For the security analysis.

**Consequence.** The scripts are outside the repository. The committed
mutation suite of step 3 should absorb both lists.

---

### 1.20 — D1 reopened after a comparison with deployed systems

**Status.** **Open.** Raised by Dan, 2026-10-14.

**What happened.** Spec decision D1, "executor module; the agent holds no key
on the account", came from the brief without a comparison with existing
systems. On review, the gate turns out to belong to an established family, the
delegation managers (MetaMask Delegation Framework, Coinbase Spend Permissions),
rather than the session-key family that Rhinestone's Smart Sessions represents.
The comparison, the argument for and against, and the options are in
`docs/analysis/delegation-architecture.md`.

**Options.**

1. Keep the bespoke gate, as built.
2. Adopt MetaMask's framework (ERC-7710), with the policies as caveat enforcers.
3. Keep the gate, and authenticate the agent with a Smart Session scoped to
   `PolicyGate.submit` alone.

Moving the policies into validation is not an option: they need the time and
external state, and a refused order would leave no record.

**Decision for now.** Continue with steps 2 and 3, which do not depend on D1.
Keep two seams so that any option stays cheap: policies do not know who calls
them, and the position ledger is written by an allowlisted address. Run the
checks in section 8 of the analysis, and re-decide D1 before step 4.

---

## Step 2. Mock market, decoder, position ledger, reconcile

Built 14 October 2026.

### 2.1 — The mock market fills through an operator, without matching

**Status.** Proposed.

**Decision.** `MockEnergyMarket` keeps a per-slot order book: orders are
placed, cancelled and modified by their owner, and filled by one `operator`
address that stands in for the market's clearing engine. There is no matching
between orders.

**Why.** The spec puts market rules (gate closure, lot size, price bounds,
matching) in the market contract and treats them as given. The enforcement
layer needs orders that fill partly or fully before gate closure, at a price
inside their limit. An operator role gives the tests and the simulation exact
control of fills, with no matching engine to write and get wrong.

**Rejected.** A continuous double auction on chain. Much more code, a sorted
book to bound, and nothing in this project measures matching.

**What the market does enforce.** Placement, cancellation, modification and
fills only before the slot's gate closes; only the owner cancels or modifies;
fills never exceed the open quantity and never cross the limit price.

### 2.2 — Slot length and gate lead are constructor parameters

**Status.** Settled by spec amendment A2.

**Decision.** The market takes `genesis`, `slotSeconds` and `gateLeadSeconds`.
A slot's gate closes `gateLeadSeconds` before the slot starts. The tests use 30
minutes and one hour.

### 2.3 — The decoder is the only adapter between the system and a market

**Status.** Proposed. Extends spec 5.1.

**Decision.** `IOrderDecoder` grows from one function to four:

- `decode(market, callData)` returns the call as legs;
- `placedOrderId(market, callData, result)` reads the new order's id from the
  market's reply;
- `fillState(market, orderId)` reads filled and remaining quantity and whether
  the order is still open;
- `gateTime(market, slot)` reads when a slot's trading closes.

**Why.** The ledger has to read fills and gate times from markets it knows
nothing about. The spec already makes the decoder the trusted reader of one
market and has it expose `gateTime`. Keeping every market-specific read in one
contract keeps the audited surface in one place.

**Consequence.** A decoder bug can now misstate fills as well as orders. It
was already a policy bypass; it remains on the list of trusted code for the
security analysis.

### 2.4 — A modification is two legs, cancel then place

**Status.** Proposed. Implements spec 5.1, "MODIFY decodes as an atomic cancel
plus place".

**Decision.** `decode` returns one leg for a placement, one for a cancellation
and two for a modification: a CANCEL leg for the old order's unfilled
quantity, then a PLACE leg for the new order. `OrderSubmitted` carries the legs
as an array. The `MODIFY` kind exists in the type but never appears in a leg.

**Why.** Every policy then sees a modification as exactly what it does, and
the price, quantity and slot changes all go through the same checks as any
placement. The order of the legs matters: the cancellation releases before the
placement adds, so a modification at the open-order bound goes through.

### 2.5 — Every approved call must be an order

**Status.** Proposed.

**Decision.** `submit` refuses a call that decodes to no leg, or to more than
two, with `PolicyGate_NotAnOrder`.

**Why.** From step 4 the policies check legs. An approved call with no leg
would pass every policy unchecked. The allowlist is for market functions only.

**Consequence.** The attack tests that approve a non-market target on purpose
use a decoder that reads any call as a 1 Wh placement.

### 2.6 — The position ledger is a separate contract with account-appointed writers

**Status.** Proposed. Implements one of the two seams of entry 1.20.

**Decision.** `PositionLedger` is its own contract. The account appoints its
writers with `setWriter`, on the owner path; every write names the account and
must come from one of them. The gate is given the ledger at construction and
must be appointed by each account, or every submission reverts.

**Why.** The spec places the ledger inside the gate. As a separate contract
written by appointed writers, a different entry point (entry 1.20, options 2
and 3) can be appointed instead and the positions carry over.

**Consequence.**

- Positions are facts about the market, not configuration. They are keyed by
  account only, not by the gate's installation generation, and survive the
  gate being uninstalled and reinstalled.
- The ledger trusts "the caller is the account" for `setWriter`, so it joins
  the account and the gate as a forbidden target (entry 2.14).

### 2.7 — Orders are keyed by market as well as id; `reconcile` names the market

**Status.** Proposed. Changes the spec's signature `reconcile(account,
orderId)` to `reconcile(account, market, orderId)`.

**Why.** Order ids are assigned by each market. Two markets can both have an
order 1.

### 2.8 — Orders are booked after the market call

**Status.** Proposed.

**Decision.** `submit` calls the market first, then books each leg in the
ledger, in leg order, in the same transaction.

**Why.** A placement's id exists only once the market has answered. Spec 4.1
puts the commit phase before execution; that ordering is about the policies'
own state and is kept for them in step 4. The transaction is atomic either way:
if the ledger refuses a leg, the market call is undone.

### 2.9 — The ledger stores when an order was placed, not a bucket

**Status.** Proposed.

**Decision.** Each order record holds its placement time. Spec 5.2 asks for
"placement bucket per window policy".

**Why.** Each window policy has its own bucket length. From the time, each
derives its own bucket in step 4, and the ledger knows nothing about windows.

### 2.10 — Four reasons an order closes

**Status.** Proposed.

**Decision.** `FILLED`, `CANCELLED` (through a writer, normally the agent via
the gate), `EXPIRED` (the slot's gate closed with part unfilled) and
`CLOSED_ELSEWHERE` (the market no longer holds the order open, before gate
closure and not fully filled: for instance the owner cancelled it directly).

**Why.** The spec separates expiry from cancellation: expiries never count
toward the cancel quota S6. The fourth reason keeps an outside cancellation
from being counted as either.

### 2.11 — A fill counts only once it is booked

**Status.** Proposed.

**Decision.** The ledger books fills when an order is reconciled or cancelled.
Until then a filled quantity is committed but not cleared.

**Why this is the safe side.** The deliverability policy S3 credits only
cleared buys (spec D3). An unbooked fill can only make a check stricter, never
looser.

**Consequence.** Keepers should reconcile regularly, or honest orders will be
refused for lack of credit. That is a liveness cost, measured in the
evaluation.

### 2.12 — At most 64 open orders per account; for now a refusal reverts

**Status.** Proposed. The number is a placeholder.

**Decision.** `MAX_OPEN_ORDERS = 64`, enforced by the ledger when a placement
is booked. A placement beyond it reverts the whole submission.

**Why revert.** There is no policy layer yet to record a refusal. Whether the
bound becomes a policy result with a `Rejected` event is decided with the
check phase in step 4.

### 2.13 — The agent acts only on orders it placed

**Status.** Proposed.

**Decision.** Cancelling or modifying an order the ledger does not hold
reverts, even though the market would accept it from the account.

**Why.** An order the owner placed directly is the owner's. The agent's
authority covers what it placed through the gate.

### 2.14 — The ledger is a forbidden target

**Status.** Proposed. Extends entry 1.4.

**Decision.** `submit` refuses the ledger as a target, alongside the account,
the gate and the zero address.

**Why.** The ledger appoints writers on the word of the account. A call routed
to it through the gate would let the agent appoint itself.

### 2.15 — An impossible fill stops reconciliation

**Status.** Proposed.

**Decision.** If the market reports a filled quantity lower than already
booked, or higher than the order, the ledger reverts.

**Why.** Either the market or its decoder is broken. Booking such a number
would corrupt the positions every policy reads.

**Consequence.** That order can no longer be reconciled until the market or
decoder is fixed. A liveness cost, chosen over a wrong position.

### 2.16 — `reconcile` is open to anyone through the gate

**Status.** Settled by the spec (5.2).

**Decision.** `PolicyGate.reconcile` has no caller check. It calls the ledger,
where the gate is an appointed writer, and emits `Reconciled`. Calling the
ledger directly is reserved to writers.

**Why.** Nothing reconcile does depends on its caller: every quantity comes
from the market through the decoder. The credits to policies for released
volume are added here in step 4.

### 2.17 — Value at the limit price, rounded up, overflow refused

**Status.** Settled by spec D12.

**Decision.** value = qtyWh × price / 1000, rounded up. A value beyond
`uint64` reverts.

### 2.18 — What step 2 leaves out

- Matching, lot sizes and market price bounds: market rules, out of scope.
- True-up of committed value to the clearing price: optional in spec 5.2 and
  off by default.
- A horizon ring for positions: the ledger keys positions by absolute slot. The
  ring of k entries belongs to S3, in step 5.

### 2.19 — Mutation check by hand

**Status.** Settled as a practice; the tooling is step 3.

**Result.** 51 single defects in the ledger, the gate's booking, the mock
market and its decoder, against `test/gate/`. 41 caught at first. Seven of the
ten survivors were gaps in the ledger and gate tests: the bound read from the
contract instead of asserted, duplicate and non-placement bookings, a zero
quantity, the impossible-fill check, a withdrawn writer, a call decoded as no
order. `test/gate/PositionLedger.t.sol` and one gate test were added; all seven
are caught. The other three are in the mock market: the gate closing at slot
start, anyone cancelling, a modification keeping the wrong side. The mock market
is to be replaced by a port of the P2P market, and the same rules are to be
tested on the port.

Foundry, with the four real-account tests: 250 passed.

---

## Step 2, continued. Porting the P2P market

Decided with Dan on 14 October 2026. The reading of the two source projects,
the mapping and the reasons are in `docs/analysis/market-structure.md`.

### 2.20 — The mock market is replaced by a port of Dan's P2P market

**Status.** Settled by Dan.

**Decision.** The market behind the gate follows the structure and logic of the
P2P energy flexibility market of Dan's thesis, as built in the BRIGHT and
DEDALUS projects: registration, market session, off-chain matching, commitments
per prosumer, settlement against monitored values.

**Why.** It is a design with a record, the subject of Dan's PhD, and familiar to
him and to the reviewers who know his work. The mock market of entry 2.1 was a
stand-in.

**Consequence.** `MockEnergyMarket` and its decoder are retired once the port
passes the same order-lifecycle tests. The rules three of the step 2 mutants
targeted (gate closure before slot start, only the owner cancels, a
modification keeps its side) are to be tested on the port.

### 2.21 — The ERC-1155 template, without encryption

**Status.** Settled by Dan.

**Decision.** The port follows DEDALUS's token design: one lockable ERC-1155
contract holds the fungible payment token and the energy tokens, whose ids
encode the minter, the slot and the energy type. DEDALUS's encryption is not
ported.

### 2.22 — Five roles, the manager separate from the prosumers

**Status.** Roles settled by Dan; the separation proposed.

**Decision.** Market manager, market session, prosumer contract, lockable
ERC-1155, settlement rule. The manager is its own contract, as in the thesis and
BRIGHT.

**Why the separation.** DEDALUS merges the manager into `Building`, because its
market is a building community whose building is also a buyer. That hierarchy is
not needed here (entry 2.30).

### 2.23 — Orders in batches; each order names its slot and its price

**Status.** Batching settled by Dan; per-order price proposed.

**Decision.** The prosumer contract places a batch of orders in one call: up to
the session's slot count, each order for one slot of the session, with its own
quantity and limit price. A batch is all bids or all offers.

**Why per-order price.** The thesis gives a day-ahead order one price; DEDALUS
gives each hour its own, and an intraday strategy will want to price slots
differently. One price for the batch is the special case of equal prices.

**Consequence.** For the gate a batch is several legs, one per order, so the
gate's limit of two legs per call is raised (entry 2.31).

### 2.24 — Slots per session and slot length are parameters

**Status.** Settled by Dan. Extends entry 2.2 and spec amendment A2.

**Decision.** A session is configured with its first slot, its number of slots
and the slot length. 24 hourly slots is the starting case, a day-ahead market.
A 6-hour intraday session, or 30-minute slots, is a configuration, not a code
change.

### 2.25 — Cancel and modify, until the session closes

**Status.** Settled by Dan. New relative to both source projects.

**Decision.** The prosumer contract can cancel an order or replace it with a new
quantity, price or slot until the session's trading closes. A cancellation
releases the order's collateral and burns an offer's unmatched energy tokens; a
modification is a cancellation and a placement in one call.

**Why.** Without cancellation there is no spoofing attack, and the cancellation
quota S6 and the spec's modification tests would have nothing to act on.

### 2.26 — Matching off chain, by a registered matcher

**Status.** Settled by Dan.

**Decision.** An off-chain service, linked to the chain through an oracle,
reads the session's orders, matches them and registers the trades. Only the
matcher address the manager registered may call `registerTrades`. A trade names
the bid, the offer, the quantity and the price; an order can be matched by
several trades, which is how partial fills arise.

**Consequence.** The matcher is a trust anchor, like the sensors. It is listed
with them in the security analysis.

### 2.27 — Settlement by trusted sensors

**Status.** Sensors settled by Dan; delivery from the sensor's own address
proposed.

**Decision.** Each prosumer has a sensor address, registered by the manager.
Only that address submits monitored values. Settlement compares each slot's
monitored value with the prosumer's commitment for that slot by
`ClassicSettlement`: within 10% the collateral is released; beyond it the
penalty, deviation × `realTimePrice`, goes to the manager.

**Why not the owner.** In both source projects the prosumer owner submits the
values. Here the owner is the smart account the agent acts through, so the
agent would report its own deliveries.

**The alternative.** Readings signed by the sensor and relayed by anyone, using
the EIP-712 check already in this repository (`MeterReadings.sol`). Useful if a
sensor cannot hold a funded key. Not built now.

### 2.28 — Commitments per prosumer and slot

**Status.** Settled by Dan.

**Decision.** Each prosumer contract holds, per slot, the committed quantity
bought and sold and their value, updated by every registered trade. Settlement
reads them.

### 2.29 — Every function that moves funds, tokens or commitments checks its caller

**Status.** Proposed. The reason is in section 4 of the analysis.

**Decision.** Each state-changing function of the port names who may call it:
the manager's operator, the session, the matcher, the sensor or the prosumer's
owner. The token moves funds and energy only for its owner or for the market
contracts the owner approved.

**Why.** Reading BRIGHT, several such functions are open to any caller: the
energy token's transfer checks the sender's rights instead of the caller's,
trades and commitments can be registered by anyone, and commitments pay out to
an address the caller supplies. In this project the agent is an ordinary address
and would call those functions directly, around the gate.

### 2.30 — What is not ported

**Status.** Settled by Dan.

**Dropped.** Encryption, the Chainlink comparison, the VPP or community mode,
behind-the-meter asset modelling, the building-and-apartment hierarchy, the
ERC-721 token of BRIGHT. Each can return later; none is needed by the
enforcement layer.

### 2.31 — How the gate sees the ported market

**Status.** Proposed.

**Decision.**

- The prosumer contract's owner is the prosumer's smart account. The agent
  places, cancels and modifies through the gate, as calls from the account to
  the prosumer contract.
- A decoder for the prosumer contract reads a batch as one PLACE leg per order,
  a cancellation as one CANCEL leg, a modification as a CANCEL leg and a PLACE
  leg.
- The gate's limit on legs per call becomes a parameter covering the largest
  batch (the session's slot count) instead of two.
- The session's closing time is the gate time: unmatched orders expire there.

### 2.32 — The token is built on OpenZeppelin's ERC-1155

**Status.** Proposed.

**Decision.** `contracts/market/LockableERC1155.sol` inherits OpenZeppelin
5.6.1's `ERC1155`. OpenZeppelin is an explicit, pinned dependency.

**Why.** DEDALUS's `ERC1155.sol` is a copy of OpenZeppelin 5.0 with its
utilities. Using the audited original keeps the market's own code to what is
specific to the market.

### 2.33 — An energy token's id holds the slot's start time

**Status.** Proposed. Adapts DEDALUS's `ERC1155TokenIdMasks`.

**Decision.** Bit 255 marks an energy token; then the minter's address, the
slot's start time in Unix seconds (40 bits), the energy type (4 bits) and a
counter (51 bits). Id 0 is the payment token.

**Why.** DEDALUS stored the hour of the day in five bits, enough for one
24-hour session. Sessions now have any number of slots of any length (entry
2.24).

### 2.34 — Locks are tied to their owner, and an allowance is used once

**Status.** Proposed. Fixes a flaw in the source (analysis, section 4).

**Decision.** A lock is keyed by owner, locker and unlocker. Locking is an
external function only: the owner locks its own balance, or a locker locks it
within an allowance the owner granted, and each lock uses that much of the
allowance up.

**Why.** In DEDALUS `_lock` is public: anyone can lock anyone's balance with
themselves as the unlocker, which also grants them an allowance, then release it
to themselves. Allowances there are never used up, so one approval can be spent
again and again.

### 2.35 — Locked payment cannot move, by any route

**Status.** Proposed. Fixes a flaw in the source.

**Decision.** After every transfer, mint and burn, the token checks that the
sender still holds at least its locked payment balance. Only `unlock`, which
reduces the lock first, can move locked value.

**Why.** In DEDALUS the owner's own transfers skip the locked-balance check, so
collateral could be moved away while it was supposed to be locked. The check
sits in `_update`, the one function every movement goes through, so no route
around it exists.

### 2.36 — Who mints

**Status.** Proposed. Fixes a flaw in the source.

**Decision.** The issuer, the deployer, mints payment tokens; in this project it
stands for the settlement currency. The market manager, named once as the
registrar, appoints energy minters: the registered prosumer contracts. Energy
ids always have the top bit set, so no minter can mint payment.

**Why.** In DEDALUS every mint function is public and accepts any id, id 0
included: anyone could mint money.

### 2.37 — The block-count timelock on locks is dropped

**Status.** Proposed.

**Decision.** A lock has no "releasable after block n" field.

**Why.** Both source projects pass zero blocks (`blockNrForADay = 0`). When a
lock may be released is decided by the market contracts that hold it.

### 2.38 — A call may decode to a batch of legs; the limit is a parameter

**Status.** Proposed. Supersedes the "one or two legs" rule of entry 2.5.

**Decision.** `PolicyGate` takes `maxLegs` at construction, at least 2 so a
modification fits. A call that decodes to no leg, or to more than `maxLegs`, is
refused. The tests use 48: a day-ahead batch of 24 hourly orders, twice over.

**Why.** In the ported market one call places a batch of orders (entry 2.23),
and each order is a leg. The bound still exists because the gate books every
leg in a loop.

### 2.39 — The decoder returns every placed id at once

**Status.** Proposed. Changes the interface of entry 2.3.

**Decision.** `placedOrderId` becomes `placedOrderIds(market, callData, result)`,
returning the ids of all orders the call placed, in the order of its PLACE legs.
The gate checks that there are exactly as many ids as PLACE legs, and refuses
the call otherwise.

### 2.40 — Expiry is the market's word, not the clock's

**Status.** Proposed. Changes entry 2.10's rule for `EXPIRED`.

**Decision.** `FillState` gains `expired`: the market reports that an order
ended because its session or slot closed with part of it unmatched. The ledger
closes an order as `EXPIRED` when the market says so, instead of when the
decoder's gate time has passed.

**Why.** In Dan's market trading closes first and matching comes after: the
off-chain matcher reads the closed session and registers trades later. Under
the old rule the ledger would have released every unmatched order at gate
closure, before the matcher had reported anything. The market knows when an
order is over; the clock does not.

**Consequence.** `gateTime` stays in the decoder for the policies of step 4
(the target-slot horizon A6, the near-gate weighting of S6), but the ledger no
longer reads it.

### 2.41 — The slot length belongs to the market, not to a session

**Status.** Proposed. Refines entry 2.24.

**Decision.** `MarketManager` takes the slot length at deployment. Slot n
starts at n × slot length, on one grid for the whole market. A session is its
energy type, its first slot on that grid, its number of slots (1 to 96) and the
time its trading closes, which must be in the future and no later than the start
of its first slot.

**Why.** The position ledger keys positions by slot. With one grid, a slot
number means one interval of time whichever session it came from; with a slot
length per session, two sessions could give the same number to different
intervals. A 24-slot day-ahead session and a 6-slot intraday one are both a
first slot and a count.

### 2.42 — Collateral rounds up; payments out of it round down

**Status.** Proposed.

**Decision.** Collateral is quantity × price rounded up (spec D12). A payment
from collateral to a seller, and the value booked on a commitment, round down.

**Why.** A bid can be matched by several partial trades. Rounded up, their
payments could add up to a few units more than the bid locked, and the last
trade would fail. Rounded down, they can never exceed it: the sum of the parts
is at most the whole, which is at most the whole rounded up. The seller loses
less than one smallest unit per trade.

### 2.43 — A trade must respect both limit prices; an account cannot trade with itself

**Status.** Proposed. Closes a gap in both source projects.

**Decision.** `registerTrades` refuses a trade above the bid's limit or below
the offer's, a trade between two orders of the same account, a trade across
slots, a trade beyond either order's open quantity, and a trade on an order that
is not open. Buyer, seller, slot and energy token are read from the stored
orders; the matcher supplies only the two order ids, a quantity and a price.

**Why.** Neither source checked the limits, and BRIGHT took the payment
addresses from the trade the caller supplied (analysis, section 4). The matcher
is trusted to match well, not trusted with where money goes.

### 2.44 — Orders expire one at a time, after finalisation

**Status.** Proposed. Changes the source's end-of-session loop.

**Decision.** After trading closes the matcher registers trades, then calls
`finalise`; the operator may finalise instead if the matcher never does. From
then on every order with an unmatched remainder has expired, and anyone may call
`expire(order)` to release its collateral and burn an offer's unmatched energy.

**Why.** Both source projects refunded and burned in one loop over every order
at the end of the session. That loop's cost grows with the number of orders,
which participants control. One order per call keeps every call bounded. The
ledger already treats expiry as the market's word (entry 2.40), so it needs no
one to have called `expire`.

### 2.45 — Order ids are unique across sessions

**Status.** Proposed.

**Decision.** An order's id is the hash of its session's address and its
number in the session.

**Why.** The position ledger keys orders by prosumer contract and id. A
running number per session would repeat across sessions.

### 2.46 — Settlement compares measured net export with committed net export

**Status.** Proposed. **Open:** it departs from the thesis, which measures
flexibility against a baseline. Listed as open decision 9.

**Decision.** For one slot, committed net export is sold − bought; measured net
export is exported − imported, as the sensor reports. `ClassicSettlement` prices
the difference: nothing within 10% of the committed net, the whole deviation at
the real-time price beyond it. The penalty is paid to the manager from the
slot's delivery collateral first, then from the owner's unlocked balance as far
as the allowance reaches; the rest is reported as a shortfall, never a revert.
Remaining collateral is released.

**Why not the baseline.** In BRIGHT the prosumer sets its own baseline
(`setBaseline`), and flexibility is measured against it. Here the prosumer
contract is driven by the agent, so a self-set baseline could be chosen to make
any delivery look compliant. Measured net export needs no baseline. If the
baseline formulation is wanted, the baseline has to come from the operator or a
signed forecast, not from the prosumer.

**Why no revert.** A settlement that reverts when the penalty cannot be
collected would let a prosumer escape settlement by withdrawing its allowance.

### 2.47 — The collateral model of the source projects

**Status.** Settled in substance by the source; details proposed.

**Decision.**

- A bid locks quantity × its limit price. A match pays the seller at the trade
  price out of it. When the bid is fully matched, what the limit over-reserved
  comes back at once; otherwise at expiry or cancellation.
- An offer locks quantity × the real-time price, a delivery guarantee. The
  matched part's share moves to the slot's commitment and is held until
  settlement; the rest comes back at expiry or cancellation.

This is DEDALUS's model (bids at their price, offers at the real-time price).
BRIGHT locked both sides at the real-time price.

### 2.48 — Tokens stay in the owner's account

**Status.** Proposed.

**Decision.** Payment and energy tokens are held by the prosumer's smart
account, as both source projects hold them with the prosumer's owner. Once, on
the owner path, the account grants its prosumer contract a payment allowance
(to lock collateral) and approval over its tokens (to deliver and burn energy).

**Consequence.** The account must accept ERC-1155 tokens. Real ERC-7579
accounts do so through a fallback handler; the test account `MiniAccount` now
implements the two receiver hooks.

### 2.49 — The prosumer contract places orders in the session directly

**Status.** Proposed.

**Decision.** The prosumer contract calls the current session itself; the
session asks the manager whether the caller is a registered prosumer and who its
account is.

**Why.** BRIGHT routed every order through the manager, DEDALUS through
`Building`. The check the manager performed (is this prosumer registered) is
kept; the extra hop is not.

### 2.50 — Bounds on a session

**Status.** Proposed. The numbers are placeholders.

**Decision.** At most 96 slots per session (two days of half-hours) and 2048
orders per session.

**Why.** The matcher reads the session's order lists in one call; both bounds
keep every call of the session bounded.

### 2.51 — The mock market stays, as a test double

**Status.** Proposed. Refines entry 2.20.

**Decision.** `MockEnergyMarket` and `MockMarketDecoder` move from
`contracts/market/` to `test/gate/mocks/`, with `OrderLifecycle.t.sol` kept as
the ledger's tests against them. The deployable market is the port alone.

**Why.** The mock fills orders before trading closes and allows a cancellation
after a partial fill. The ported market never does either: trades come after
closing, cancellations only before. The ledger is meant to serve other markets
too, and only the mock reaches those paths. The step 2 acceptance criteria are
now met on the port by `test/market/GatedMarket.t.sol`.

### 2.52 — How the decoder reads the ported market

**Status.** Proposed. Implements entry 2.31.

**Decision.** `ProsumerDecoder`:

- `placeBids`, `placeOffers`: one PLACE leg per order of the batch, bid as BUY,
  offer as SELL, on the market's slot grid (the session's first slot plus the
  slot within it).
- `cancelOrder`: one CANCEL leg for what the session says is still unmatched.
- `modifyOrder`: a CANCEL leg, then a PLACE leg on the same side.
- An order is **open** while its status is open, its session is not finalised
  and it is not fully matched. After trading closes it stays open, because that
  is when matching happens.
- An order has **expired** once its session is finalised with part of it
  unmatched, whether or not anyone has called `expire` on the market.
- `gateTime(slot)` is the closing time of the current session, of either energy
  type, that covers the slot; zero if none does. The ledger no longer reads it
  (entry 2.40); the policies of step 4 will.

**Consequence.** `GatedMarket.t.sol` checks after random trading and matching
that the ledger and the prosumer contract agree, slot by slot, on what was
bought and sold.

### 2.53 — Mutation check of the market port, by hand

**Status.** Settled as a practice; the tooling is step 3.

**Result.** 54 single defects across the token, the session, the prosumer
contract, the manager, the settlement rule and the decoder, against
`test/market/` and the gate tests. 48 caught at first. The six survivors were
all tests that stopped short of an edge: no test called the session's `cancel`
directly, none over-matched a bid (only an offer), none sat at exactly 10% or
between 10% and 20%, and every price gave whole units, so no rounding was ever
visible. `test/market/ClassicSettlement.t.sol` and three market tests were
added; all 54 are caught.

Hardhat 328 passing; Foundry, with the real-account tests, 332 passed.

---

## Running the system locally

Built 14 October 2026, at Dan's request: a running system before step 3.

### 2.54 — From an account to its prosumer contract, on chain

**Status.** Proposed.

**Decision.** `MarketManager.prosumerOf(account)` returns the account's
prosumer contract. It is set when the operator registers the prosumer contract
and cleared when it is deregistered. An account can have one prosumer contract;
a second registration is refused.

**Why.** The earlier projects kept a database of contracts, owners and user
names. Every link is now on chain: `prosumerOf` from account to prosumer
contract, `Prosumer.owner()` back, the manager's registry for the sensor, the
gate's registry for the agent, and indexed events for each. An agent needs only
its account's address. A database or indexer would be a cache of these, never
the source.

**Not used.** ERC-8004 (agent identity, reputation and validation registries)
answers a different question: discovering an agent and its track record across
organisations. The spec leaves it out of this build.

### 2.55 — The minimal account moves to `contracts/demo/`

**Status.** Proposed.

**Decision.** `MiniAccount` moves from the test doubles to
`contracts/demo/MiniAccount.sol`, so the local system can deploy it. It is
marked as an account for tests and local demonstrations only.

**Why.** Deploying Safe7579, Nexus or Kernel on a local node needs their
factories and an EntryPoint: worth doing, not needed to run the market.

### 2.56 — The off-chain programs are JavaScript, on a local Hardhat node

**Status.** Settled by Dan.

**Decision.** `scripts/demo/`: `deploy.js`, `matcher.js`, `flow.js` and
`lib.js`, in JavaScript with viem, against `npx hardhat node`. Prosumers come
from `prosumers.json`, as the earlier projects read apartments from a CSV. The
deployment is written to `deployments/local.json` (git-ignored), which holds
addresses and key indexes only. Every role uses a key of Hardhat's public test
mnemonic, by index.

**Consequence.** A transaction is simulated before it is sent, and a revert is
decoded against every contract of the project, so a refusal deep in the call
chain reads as the contract's own error.

### 2.57 — The demo matcher: a double auction, best bid against best offer

**Status.** Settled by Dan for the demo; the rule is meant to be replaced.

**Decision.** Per slot, bids from the highest price, offers from the lowest,
earlier first at equal price. The best bid trades with the best offer from a
different account while the bid's price is at least the offer's, for the
smaller remaining quantity, at the midpoint of the two prices rounded down.
`matchOrders` is a pure function of the open orders; replacing it changes
nothing else.

**Why not the earlier Java matcher as it was.** `MatchingAlgorithmGreedy`
sorted bids and offers by quantity and never compared prices. The session
refuses a trade outside either limit price (entry 2.43), so those trades would be
rejected. Its structure is kept: sort, then match one pair at a time for the
smaller quantity.

**Result.** See entry 2.58 for the day the flow now runs.

### 2.58 — The demo day: closing at 12:00 Brussels time, an order every hour

**Status.** Settled by Dan ("close at 12:00, place orders for every hour of the
next day for both alice bob and carol and match all").

**Decision.** `flow.js` opens a day-ahead session as the European day-ahead
market does:

- **Delivery** is a whole day on the Brussels clock, 00:00 to 24:00.
- **Trading closes** at 12:00 Brussels time the day before.
- **The day chosen** is the first delivery day whose closing time is still
  ahead. Run after 12:00, the script trades the day after tomorrow.
- **Summer and winter time.** The script converts with the time zone
  `Europe/Brussels`, so CET and CEST are both handled. A clock-change day is a
  session of 23 or 25 slots. The contracts see only UTC slot numbers; the time
  zone exists only in the script.

Every prosumer places an order for every hour, in one call per side:

| Prosumer | How | Orders |
| -------- | --- | ------ |
| Alice | Agent, through the gate | Bids every hour: 0.6 kWh at night, 1.2 in the morning, 0.8 by day, 1.5 in the evening; 0.24 EUR/kWh, 0.27 from 17:00 to 21:00 |
| Bob | Directly, no agent | Offers every hour: PV 2.0 kWh at 0.18 from 08:00 to 17:00, the battery 0.8 kWh at 0.22 otherwise |
| Carol | Agent, through the gate | Offers 0.7 kWh at 0.17 from 09:00 to 16:00; bids 0.4 kWh at 0.23 otherwise |

Alice's agent then modifies her 19:00 bid. The cancel step of the earlier flow
is dropped so that every hour keeps its orders.

**Why these numbers.** Each prosumer has a part in every hour's matching:

- Carol's PV is cheaper than Bob's, so she sells first at midday.
- Bob covers the rest of the day.
- Alice's evening price is the highest, so the matcher serves her before Carol.

**Result.**

- **Matching.** 41 trades and 20.4 kWh, with a trade in all 24 hours. Alice's
  24-order batch is one call of 24 legs, about 7.2 million gas, well under the
  48-leg limit and the block gas limit.
- **Ledger.** It agrees with the prosumer contracts in every hour, for both
  agents.
- **Settlement.**
  - Bob delivers 80% at 19:00 and pays 0.048 EUR.
  - Every other hour settles without penalty.
  - Every lock is released.
  - The payments sum to exactly the penalty the manager collected.

---

## Step 3. WindowLib, verifier, mutation suite

Started 14 October 2026.

### 3.1 — The repository is grouped by function; the earlier design moves aside

**Status.** Settled by Dan ("organize the project better, create subfolders
as packages, not all scripts in the same folder, group them by logic and
function").

**Decision.** Every file has a folder that says what it is for:

| Was | Is now | Why |
| --- | ------ | --- |
| `scripts/demo/lib.js` | `offchain/chain/`, split into `client.js`, `contracts.js`, `time.js`, `deployment.js`, `units.js` | One concern per file; every package imports `chain/index.js` |
| `scripts/demo/deploy.js`, `prosumers.json` | `offchain/deploy/` (`index.js` exports `deploySystem`, `cli.js` runs it) | Deployment is a function another program can call |
| `scripts/demo/matcher.js` | `offchain/matcher/`: `rule.js` (the pure rule), `index.js` (the service), `cli.js` | The rule can be replaced without touching the service |
| The keeper's and the sensors' code inside `flow.js` | `offchain/keeper/`, `offchain/sensor/` | They are roles of the system, not of one scenario |
| `scripts/demo/flow.js` | `offchain/scenarios/day-ahead.js`, with `calendar.js` for the Brussels clock | A scenario only tells the story; the roles do the work |
| `contracts/demo/MiniAccount.sol` | `contracts/harness/` | A stand-in, not part of the system; the window verifier's probe joins it |
| The 7 earlier contracts at the top of `contracts/`, and `IModule`, `IValidator` | `contracts/earlier-design/` | Out of the way of the current system |
| The 7 earlier test files at the top of `test/` | `test/earlier-design/` | Same |
| `verifier/`, `differential/`, `records_B*.csv`, `scripts/keys/` | `earlier-design/verifier/`, `…/differential/`, `…/records/`, `…/keys/` | Same; the records' description moved from the root README to `earlier-design/records/README.md` |

Each `offchain/` folder is a package in the sense of a module with one entry
point, `index.js`; it is not a separate npm package. Packages import `chain/`
and nothing else, except `scenarios/`, which uses them all. The `npm run`
command names are unchanged.

**Why not npm workspaces.** Each folder would need its own `package.json` and
the root would link them into `node_modules`. That buys versioning and
publishing, which nothing here needs.

**What changed besides paths.**

- The artifact lookup walks `artifacts/contracts/` instead of three named
  folders, so a new contract folder needs no change in the scripts.
- The earlier design's Python files compute the repository root two levels up
  instead of one. Its Solidity differential test, both configs' file
  permissions, and its runner's test paths point at
  `earlier-design/differential/data`.

**Checked.** The same 329 Hardhat tests pass. The earlier design's 53 Python
verifier tests pass from the new folder. `demo:deploy` and `demo:flow` give
the same day as before, figure for figure (entry 2.58).

**Earlier entries keep their paths.** The entries above name files where they
were when the decision was taken. This table maps them to where they are now.

### 3.2 — WindowLib: five classes behind one interface

**Status.** Proposed.

**Decision.** `contracts/policies/WindowLib.sol`, a library of internal
functions on a `Window` in the policy's storage:

| Function | Meaning |
| -------- | ------- |
| `used(t)` | What the window counts as consumed at time t |
| `limit(t)` | What it allows at time t |
| `fits(t, amount)` | `used(t) + amount <= limit(t)`, the cap inclusive |
| `add(t, amount)` | Consume; does not check the limit |
| `credit(t, placedAt, amount)` | Give back an amount consumed at `placedAt`; returns what was given back |

Every class fits this shape:

- **SLIDING, TUMBLING, LIFETIME:** the limit is the cap.
- **REFILL:** reports cap − balance as its use.
- **STREAM:** reports everything consumed as its use and what has unlocked as
  its limit.

A policy therefore runs the same check whatever class is configured. That is
what the evaluation needs: the same attacks, the same decoder, only the
class changed (spec 5.3).

**Why time is a parameter.** The policy passes `block.timestamp`. A check
and its commit are then evaluated at the same instant, and the tests can
probe any time without the chain.

**Why `add` does not check.** The policy decides, with soft and hard
bounds and flags (spec 5.5), and only then commits. A library that refused
would take that decision away from it.

### 3.3 — SLIDING: a ring of packed buckets, a running total, a lazy reset

**Status.** Proposed.

**Decision.**

- **Storage.**
  - n buckets of 64 bits, four to a storage word.
  - A running total.
  - `mark`, the last bucket the ring was advanced to.
  - A generation number. The ring is keyed by it, so a word of an old
    generation is simply never read again.
- **Advancing** from `mark` to the current bucket c subtracts and zeroes the
  positions of buckets mark + 1 ... c, which held the buckets that left the
  window. It reads each storage word once.
- **Lazy reset.** If c − mark ≥ n, everything has left the window: the
  generation goes up and the total is zero, in constant gas.
- **Bounds.** At most 2016 buckets, a week of 5-minute buckets.

**Measured.** The worst case for S1's default week of hourly buckets is a
write after 167 buckets, where every position is swept. It costs 339,872 gas
for the whole `tryAdd` through the probe
(`test_theWorstCaseSweepOfAWeekOfHourlyBucketsIsBounded`). S2 and S6
windows (48 and 12 buckets) cost proportionally less.

**Rejected.**

- *One storage word per bucket:* four times the reads for the same sweep.
- *Clearing the ring on reset:* gas proportional to n after any long idle
  period, the case the lazy reset exists for.
- *No running total, summing on every check:* O(n) on every order rather
  than only on a sweep.

### 3.4 — Where the spec is silent: the edges of each class

**Status.** Proposed.

**Decision.**

- **Credits (all classes).** A credit gives back at most what the window
  still counts for that moment, and nothing for a moment in the future. It
  never takes a bucket below zero.
- **SLIDING.** A credit goes to the bucket of `placedAt`, and only while that
  bucket is in the window (spec 5.3).
- **TUMBLING.**
  - Before the anchor, time counts in the first period.
  - A credit applies only within the period of the consumption.
- **REFILL.** A credit applies only within the same refill interval as the
  consumption. After a refill the amount may already have come back, and
  crediting it again would refund it twice. The spec's rule "only if that
  bucket is still in the window" has no direct meaning for a token bucket;
  this is the reading that keeps the bound.
- **STREAM.** Before the anchor only `initial` has unlocked. Credits always
  apply, since nothing is ever given back by time.
- **Overflow.** A count beyond 64 bits reverts; it never wraps.

### 3.5 — Configuration: a new cap keeps the count, a new shape starts afresh

**Status.** Proposed.

**Decision.**

- **Same shape.** Changing the cap, the rate or the initial amount keeps what
  has been counted.
- **New shape.** Changing the class, the step, the number of buckets or the
  anchor starts the window afresh, because the old buckets mean nothing in
  the new shape.
- **Malformed configurations are refused:**
  - a zero step;
  - a sliding window with no buckets, or more than 2016;
  - a stream starting above its cap.

**Consequence for step 4.** Starting afresh forgets consumption, so it
loosens the window. A policy must classify a change of shape as `WIDEN`, so
that it waits the 24 hours (spec 5.6). This joins the carried-forward item
"structural configuration changes need carry-over of old totals".

### 3.6 — WindowProbe: the library on its own, for tests and the verifier

**Status.** Proposed.

**Decision.** `contracts/harness/WindowProbe.sol` holds windows by id and acts
as the smallest possible policy:

- It admits an amount if it fits, and consumes it.
- A credit refers to an earlier admission, at most once and at most its
  amount, as an order would.
- Every call emits an event with the block time: `Configured`, `Admitted`,
  `Refused`, `Credited`, `Observed`.

It lives in `contracts/harness/`, with `MiniAccount`, because it is not part of
the system. The verifier needs it deployed, which a contract under `test/`
could not be.

### 3.7 — The verifier is JavaScript, and recomputes by different algorithms

**Status.** Settled by Dan (JavaScript, not the Python the spec names).

**Decision.** `offchain/verifier/` rebuilds every window from the probe's
event log alone (spec 8), then compares every figure the chain reported:

- the count and the limit at each decision and observation;
- the decision itself;
- the amount each credit gave back.

It reports the first disagreement.

**Different algorithms, on purpose.** The spec says "never port the
Solidity". Each class is computed from its definition:

| Class | Chain | Verifier |
| ----- | ----- | -------- |
| SLIDING | Ring, running total, lazy reset | Sums every admission made at or after the window's start time; no buckets, no ring |
| TUMBLING | Resets the count at a boundary | Groups admissions by period |
| REFILL | Subtracts refills since a stored mark | Closed form: the most any run of recent intervals consumed beyond what was refilled meanwhile (a reflected random walk) |
| STREAM, LIFETIME | Running counters | Sums from the log |

A unit test checks REFILL's closed form against a step-by-step simulation
over 200 random runs (`offchain/verifier/verifier.test.js`).

**The guarantees, over every interval.** Spec 5.3's bounds are measured by
brute force over all intervals between events, not only bucket-aligned ones:

- **G1:** any interval of length ≤ W − b admits at most the cap.
- **G2:** an interval of length ≤ W admits at most the cap plus what it holds
  of the one bucket that has just left the window.
- For TUMBLING, the most admitted within one period's length is reported.

**It can disagree.** A self-test tampers with one figure at a time in every
history it accepted and checks the verifier rejects each:

- an admission reported as a refusal, and the reverse;
- a count one unit off;
- a credit wrongly given or withheld;
- an observation one unit off.

**On its own chain.** The fuzz runs use Hardhat's in-process chain
(`useInProcessChain` in `offchain/chain/`), so `npm run verify:window` needs
no node and touches none.

**Result.**

- **Random histories:** 30 seeds × 5 classes × 80 steps, about 12,000
  transactions. 152 windows and 33,945 figures compared, no disagreement.
- **G1:** reached 1.00 × cap in the random histories and was never exceeded.
- **Self-test:** 720 of 720 tamperings caught.
- **Scripted boundary burst:** the cap in the last second before midnight and
  again just after. SLIDING admits 1.00 × cap; TUMBLING admits 2.00 × cap
  within 3 seconds. This is the step 3 criterion, also asserted in
  `test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding`.

### 3.8 — The mutation suite is committed tooling

**Status.** Proposed.

**Decision.** `offchain/mutation/`. A mutant is a find-and-replace in one
file. The runner:

1. applies the mutant in place, keeping the original as
   `<file>.mutation-backup`;
2. runs the catalogue's tests, and the verifier for the window catalogue;
3. restores the original.

It reports each mutant as caught (and by what), not caught, did not build,
or bad pattern.

| Catalogue | Mutants | From |
| --------- | ------- | ---- |
| `gate` | 51 | The step 1 list, unchanged |
| `ledger` | 51 | The step 2 list. "Expiry one second late" is dropped: expiry is no longer a clock comparison but the market's report (2.40). Three patterns move to the code the market port changed. "Empty decode accepted" splits into that and "leg limit ignored". `GatedMarket.t.sol` joins its tests |
| `market` | 55 | The market-port list, plus spec 8's "rounding switched": valuation to nearest instead of up |
| `window` | 35 | New: the window mutants of spec 8 and the defects specific to WindowLib |
| `accounts` | 9 | The step 1 list on real accounts. Foundry only, so it runs in Docker, and only when asked: `npm run mutate -- accounts --docker` |

**Spec 8 mutants for code not yet written.** These are listed in
`catalogs/pending.js` and shown by `npm run mutate -- --list`:

- the cap comparison of a policy, S6's expiry, and the reading timestamp:
  steps 4 and 5;
- the H_slots ≤ k check and the S3 floor: step 5.

**Safety.** Contracts are changed in place, so only one run may be alive:

- a lock file holds the running process's id;
- a run that finds a dead lock restores the backups first;
- `--list` and `--check` touch no file.

This was added after a `--check` run, made while a mutation run was going,
restored a file under it (14 October). That run's verdicts were discarded and
the catalogue was run again.

`npm run mutate -- --check` reports any pattern a later code change has
moved, without running anything.

**Accepted survivors.** A mutant may carry an `accepted` reason. A survivor
with one is reported as accepted, not as a hole. This is for faults in test
doubles, which are not part of the system.

**Result** (`docs/reports/mutation-2026-10-15.md`). The four Hardhat
catalogues ran in 113 minutes: 192 mutants, 187 caught, 4 not caught, 1 that
no longer built. Each was then dealt with:

- **"Restart does not bump the generation" (window).** A real gap. The next
  write's lazy reset usually hides it; it shows only while the time is in
  bucket 0. `test_aRestartLeavesNothingOfTheOldRing` was added; caught.
- **"Market call skipped" (gate).** It no longer built, because since the
  market port the line it removed assigns the call's results. It now replaces
  the call with an empty result; caught.
- **Three in the mock market and its decoder** ("modify keeps BUY whatever the
  side", "gate closes at slot start", "anyone cancels"). The same three that
  survived in step 2. They are faults in test doubles, now marked accepted.

Final: **189 caught, 3 accepted, 0 not caught.** In the window catalogue, 34 of
35 were caught by the tests and the verifier both. The other, the restart, was
caught by the tests only: the verifier's histories never change a window's
shape.

### 3.9 — D1 decided: a Smart Session for the agent, the policies in the gate

**Status.** Settled by Dan on 15 October, on condition that the checks of
`docs/analysis/delegation-architecture.md` section 8 work out. They did. This
closes the question reopened in 1.20.

**Decision.** Option 3:

- The agent holds a Rhinestone Smart Session on the account. Its only action is
  `PolicyGate.submit`, and it has no ERC-7739 content and no ERC-1271 policy.
- The account calls `submit`, and the gate checks and executes as built.
- Step 4 makes the change: the gate's agent registry is replaced by the
  session, and `submit` takes the account as its caller.

**The checks** (analysis, section 10):

| Check | Found |
| ----- | ----- |
| 2. Can a MetaMask caveat refuse without reverting? | No. The manager's hooks are plain calls; any failure reverts the whole redemption. Option 2 would lose the refusal record the evaluation counts |
| 4. What do the deployed period limits enforce? | Tumbling windows: MetaMask's `ERC20PeriodTransferEnforcer` and Coinbase's `SpendPermissionManager`. The boundary burst of step 3 is a property of both |
| 3. Can a session be held to one function, and sign nothing? | Yes, from the source (v1.0.0, main, and the 2024 build ModuleKit bundles), and on four real accounts in `test/accounts/SessionGate.t.sol` |

**The prototype.** `test/accounts/SessionGate.t.sol` runs on the reference
account, Safe7579, Nexus and Kernel. It shows four things:

1. A session limited to `submit` reaches the market through the gate: the
   account is re-entered through `executeFromExecutor` mid-execution, and the
   market sees the account.
2. A refusal leaves its event in a successful user operation.
3. The session reaches nothing else. A session given one more action makes the
   test fail at that assertion.
4. The session cannot sign. On Nexus a session configured to sign does sign,
   with the same signature: that is the positive control.

The gate there is a test double (`SessionGateProbe`). The real gate does not
change until step 4.

**Found on the way, for the deployment and the security analysis:**

- **Kernel** must have the Smart Sessions validator installed without a hook.
  Its hooked path, `executeUserOp`, is refused by Smart Sessions.
- **ERC-1271 on three accounts.** On Kernel, Safe7579 and the reference account
  as deployed, no session can sign at all. Kernel wraps the hash itself; the
  other two lack `eip712Domain()`.
- **Use Smart Sessions v1.0.0 or later.** ModuleKit 0.5.9's bundled build of
  September 2024 guards session signing with the content allowlist alone.
  v1.0.0 also requires an ERC-1271 policy.

**Given up.** The gate sees the account, not which agent, as the submitter. The
owner's own `submit` is checked like the agent's.

**Rejected.**

- *Option 1, as built:* the weakest answer to "why not the standard tools".
- *Option 2, ERC-7710:* revert-only refusal, and signed delegations have no
  equivalent of "tighten now, widen after 24 hours".
- *Policies in validation:* ERC-7562 forbids reading the time, and a refusal
  leaves no record (analysis, section 3).

---

## Step 4. The session entry point, StaticOrderPolicy, S1, S2, S6

Started 15 October 2026.

### 4.1 — The agent's entry point is a session on the account

**Status.** Settled by Dan (D1, entry 3.9); built.

**Decision.**

- **`submit(target, callData)`** is called by the account itself. The gate
  checks "the caller is an account with the gate installed", the check every
  owner-path function already makes.
- **The gate's agent registry is removed**, with `registerAgent`,
  `revokeAgent` and `isAgentActive`. Who may act, until when and whether
  revoked is the session's business: on a real account a Smart Session with a
  time-frame policy and `removeSession`.
- **`OrderSubmitted`** names the account, the target and the selector; it no
  longer names an agent, which the gate cannot see.
- **Tests on `MiniAccount`.** Its session stand-in (`enableSession`,
  `removeSession`, `executeAsSession`) lets a key have the account call one
  function of one contract, until a time. The Hardhat tests use it.
- **Tests on real accounts.** `test/accounts/` uses real Smart Sessions on the
  four real accounts, now with the real gate. The session helpers moved to
  `test/accounts/SessionFixture.sol`.
- **Off-chain.** `deploy` gives each agent its session, and the day-ahead
  scenario sends the agent's orders through it.

**What the tests now show.**

- **The key model.** `KeyModel.t.sol` grew from 36 to 38 tests. The "who may
  submit" group now covers the session:
  - it reaches `submit` and nothing else;
  - it is valid through its last second;
  - removing it acts at once;
  - it gives no authority on another account.
  A second fuzz test sends arbitrary calls through the session; each reaches
  `submit` or nothing.
- **Re-entry.** The hostile-target test now re-enters `reconcile`, which anyone
  may call. A target can no longer call `submit`, since it is not an account
  with the gate installed. A re-entered `reconcile` would release volume
  half-way through a submission once credits exist (step 4.2). The lock
  refuses it.
- **Real accounts.** On all four, through a real Smart Session, the agent's
  order reaches the market and every route around the session is refused.

**Rejected.** *Keeping `submit(account, target, callData)` with a check that
`account == msg.sender`*: a parameter that can only take one value.

**Results.** `npm test`: 363 passing. Foundry, `test/accounts/`: 8 passing.
The day-ahead scenario gives the same day, figure for figure.

**Also.** `DEPLOYMENT_FILE` in the environment points the off-chain programs at
another deployment file, so a second node can run without touching
`deployments/local.json`.

### 4.2 — The check, commit and credit phases

**Status.** Proposed.

**Decision.** `IPolicy` gains the order half of spec 4.2:

| Function | Called | Does |
| -------- | ------ | ---- |
| `check(account, policyId, legs, ctx)` | On every instance, for every submission, all legs at once | A view: the policy's quantity before and after, its soft and hard bounds, and a verdict, EXECUTE, FLAG or REJECT |
| `commit(account, policyId, legs, ctx)` | On every instance, only when none rejected, before the market call | Records the submission |
| `credit(account, policyId, release)` | On every instance, when volume is released | Gives back what was charged for it |

`ctx` carries the market, the call's decoder and the block time. Readings join
it in step 5. A `Release` carries the order's record from the ledger: side,
slot, placement time, quantity, price and filled part, plus what was released.

**The gate's flow.** `submit` decodes, then runs the phases:

1. **Check.** Every instance is checked, and every result is emitted as
   `PolicyResult`.
2. **Reject.** If any instance rejects, `Rejected` is emitted and `submit`
   returns normally. Nothing is committed, booked or sent.
3. **Flag.** A FLAG emits `PolicyFlag` and goes ahead: spec 5.5's flag mode
   EMIT. COSIGN is not built; the spec uses EMIT for the evaluation.
4. **Commit and execute.** Every instance commits; then the account calls the
   market and the ledger books the legs.

**Credits** come from two places:

- **A cancellation through the gate,** as soon as the ledger has released it.
- **`reconcile`,** when it closes an order with part of it unfilled: an expiry,
  or an order the market closed for another reason.

**Choices the spec leaves open.**

- **All legs checked together.** A batch cannot be cut into pieces small enough
  to pass a cap one by one: the split-leg drain of step 4's criteria.
- **A modification's new order needs room before the old one is credited.**
  The check sees a cancel leg and a place leg. The cancel's volume is credited
  only after the market has taken the call and the ledger has released it.
  - Counting the credit in the check would let a modification that the market
    then refuses free headroom for nothing.
  - The price is a false refusal near the cap: a modification that would end
    below the cap is refused if old plus new exceed it. Cancelling, then
    placing, is the way round.
  - `test_aModificationNeedsRoomForTheNewOrderBeforeTheOldIsCredited` shows
    both sides.
- **A reverting `check` or `commit` reverts the submission.** The spec makes a
  policy's rejection the only failure that does not revert; a broken policy is
  not a rejection.
- **A failing `credit` is caught.** `CreditFailed` is emitted and the policy
  keeps the charge, the safe side. Otherwise a broken policy could block
  `reconcile` and keep orders open in the ledger for ever. `deconfigure` was
  already treated this way.
- **Every result is emitted, even after a rejection,** so the attack matrix and
  the verifier see every policy's view of every submission.
- **The lock covers the phases.** A policy that calls `reconcile` while the
  gate commits is refused, and the submission fails. A view `check` cannot
  write anything.

**Test doubles.** `CapPolicy`, used by the configuration tests, now always
answers EXECUTE, so those tests keep testing configuration. `QtyPolicy`, in
`test/gate/mocks/PhaseMocks.sol`, counts the Wh placed against soft and hard
bounds and can be made to fail at any phase.

**Tests.** `test/gate/PolicyPhases.t.sol`, 15 tests. `npm test`: 378 passing.


### 4.3 — StaticOrderPolicy: the per-action bounds

**Status.** Proposed.

**Decision.** `contracts/policies/StaticOrderPolicy.sol` checks every PLACE leg
on its own (spec 6.1):

| Bound | Check | Parameter |
| ----- | ----- | --------- |
| A1 quantity | `qtyWh <= maxQtyWh` | The owner sets `maxQtyWh` to min(qMax, P_rated × slot length) |
| A2 value | `value <= maxValue`, at the limit price, rounded up (D12) | Token units |
| A3 price | SELL: `price >= sellFloor`; BUY: `price <= buyCeiling` | Absolute; tariff-relative waits for the tariff oracle of step 5 |
| A4 time of day | The slot does not start in a blocked hour for that side | `buyBlockedHours`, `sellBlockedHours`: one bit per UTC hour |
| A6 horizon | The slot starts after now and no later than `now + horizonSeconds` | Seconds |

A5 is S3 at horizon 1 (step 5); A7 and A8 are the allowlist and the session.

**How it reports.** A per-action bound holds or it does not, so there is no
soft bound and no flag. The result's `valueAfter` is a bitmask of the bounds
broken across all legs: A1 = 1, A2 = 2, A3 = 4, A4 = 8, A6 = 16. Zero is
EXECUTE; anything else is REJECT, and the log says exactly which bounds failed.

**Choices the spec leaves open.**

- **A4 in UTC hours.** The contracts know only UTC times; a Brussels-time
  window is the owner's tool translating it, and moves by an hour at the clock
  change. One bit per hour is enough for the time-of-use tariffs of the HEMS
  data.
- **A6 in seconds rather than slots.** The spec's "currentSlot < slot ≤
  currentSlot + H_slots" needs the slot length, which belongs to the market.
  Seconds from the slot's start, read from the decoder, say the same for any
  slot length.
- **A slot already started is out of horizon.** "currentSlot < slot" excludes
  the slot in delivery.
- **The decoder gives the start.** `IOrderDecoder` gained `slotStart(market,
  slot)`. Each decoder answers from its market: `ProsumerDecoder` from the
  manager's grid.
- **Direction table.** Tighter is: a lower `maxQtyWh`, `maxValue` or
  `buyCeiling`; a higher `sellFloor`; more blocked hours; a shorter horizon.
  Any looser parameter makes the change a WIDEN.

**Shared.** `contracts/policies/PolicyBase.sol`: the gate's address and the
"only the gate" check every policy uses.

**Tests.** `test/policies/StaticOrderPolicy.t.sol`, 15 tests:

- every bound at its edge;
- several broken bounds reported together;
- one bad leg rejecting a batch, and a cancellation never checked;
- a rejection through the gate, with the bitmask in the log;
- a modification checked as its new order;
- the direction table, parameter by parameter;
- only the gate writing the policy.

`test/policies/PolicyFixture.sol` is the setup the policy tests share.
`npm test`: 393 passing.


### 4.4 — WindowPolicy: S1 and S2 on WindowLib

**Status.** Proposed.

**Decision.** `contracts/policies/WindowPolicy.sol` hosts any number of
instances per account. Each counts one quantity on a `WindowLib` window:

| Quantity | Policy | Counts | Credited on release |
| -------- | ------ | ------ | ------------------- |
| `BUY_VALUE` | S1, the owner's budget | The value of BUY legs at their limit price, as the decoder computed it, rounded up | The value charged less the value of the filled part, both rounded up |
| `SELL_WH` | S2, the export cap | Wh of SELL legs | The released Wh |
| `BUY_WH` | S2, the import cap | Wh of BUY legs | The released Wh |

- **The bounds.** The window's cap is the hard bound H; the instance's `soft`
  is S. A submission whose total goes above S is flagged; one that would go
  above H is rejected (`WindowLib.fits`); one that adds nothing is executed
  (D10).
- **Placement-time indexing (D9).** An order counts in the bucket of the
  submission's time, whatever its delivery slot. A credit goes to the bucket
  of the order's placement time, read from the ledger's record.
- **Gross, never net.** S1 ignores sales: a sale neither counts nor makes room,
  so sell-and-rebuy cannot refill the budget (audit finding F3). S2's export
  and import are two instances and are never netted.

**The S1 credit never exceeds the charge.** A partly filled order was charged
ceil(qty × price) and keeps ceil(filled × price) charged; their difference is
credited. Recomputing ceil(released × price) instead could round up twice and
give back one unit more than was ever charged.

**The direction table.**

- **INVALID:** malformed, a window `WindowLib` refuses, or S above H. "b
  divides W" holds by construction, since W is n × b.
- **WIDEN:** a higher cap, soft bound, refill or stream rate, or stream start.
  A higher S is looser: fewer flags.
- **WIDEN, as restarts:** a change of shape (class, bucket length, bucket
  count, anchor) or of the quantity counted. The window starts afresh, which
  forgets what was counted.

**Deviation from spec 5.6: no carry-over.** The spec applies structural changes
"with carry-over: the old total stays charged until it would have expired".
Here a structural change waits the 24 hours of any widening and then starts the
window afresh. An agent that spent the cap just before the change could spend
it again just after. The owner accepts that by making the change, with a day's
notice in the log. Carry-over stays a carried-forward item.

**Baselines.** The same contract with a TUMBLING, REFILL, STREAM or LIFETIME
window is the evaluation's baseline for each attack (spec 9.1): same decoder,
same gate, only the class changes. Step 4.6 runs them.

**Tests.** `test/policies/WindowPolicy.t.sol`, 10 tests:

- S1 through execute, flag at the soft bound and reject above the cap, with
  the logged values;
- S1 gross: a sale neither counts nor refills;
- S2 export and import separate and never netted;
- the window sliding to the second;
- credits on a cancellation and on an expiry;
- S1's credit for a partly filled order with rounding prices;
- a release after its bucket left the window giving nothing back;
- the direction table;
- a tighter cap applying at once and keeping the count.


### 4.5 — CancelQuotaPolicy: S6

**Status.** Proposed.

**Decision.** `contracts/policies/CancelQuotaPolicy.sol` keeps three
`WindowLib` windows of one shape per instance. The spec default is an hour of
five-minute buckets.

| Window | Grows on | Rule |
| ------ | -------- | ---- |
| Cancelled Wh, weighted | Every CANCEL leg: w_g × its quantity within δ_g of the slot's gate closure, once otherwise, rounded up | cancelled ≤ C_max |
| Placed Wh | Every PLACE leg | cancelled × 100 ≤ ρ × placed + c0 × 100 |
| Messages | Every accepted submission | messages ≤ M_max |

**Choices the spec leaves open.**

- **Units.** w_g and ρ are integer percentages: w_g = 300 weighs a cancellation
  near the gate three times. w_g below 100% is INVALID, since it would make a
  late cancellation cheaper than an early one.
- **The gate window.** It starts exactly δ_g before the gate time the decoder
  reports for the cancelled order's slot.
- **This submission's placements count as placed.** A modification's new order
  counts towards the ratio it is checked against. Churning by modification
  still costs cancelled volume one for one, so a ρ below 100% bounds it.
- **A refused submission is not a message.** Only commits count. A refused
  submission changes nothing, and its sender pays its gas.
- **Expiries never count.** An order the market expires is never checked, and
  `credit` does nothing (spec 6.7).
- **D10 does not exempt a cancellation from S6.** A cancellation adds to S6's
  own quantity, which is what S6 bounds.
- **Reporting.** The `CheckResult` reports the cancelled-Wh window, with S
  equal to H since S6 has no soft bound. `reasons(legs, ctx)` is a view giving
  the rules a submission breaks as a bitmask (cancelled cap 1, ratio 2,
  messages 4), for the tests and the evaluation.
- **Direction table.**
  - **Looser:** a higher C_max, M_max, ρ or c0; a lower w_g; a shorter δ_g.
  - **Restarts, so WIDEN:** a change of window shape.

**Tests.** `test/policies/CancelQuotaPolicy.t.sol`, 9 tests:

- the cancelled cap, inclusive;
- the near-gate weight, and the exact second it starts;
- the ratio against what the policy saw placed;
- the free allowance for a first cancellation;
- the message count, which a refused submission does not use;
- an expiry using none of the quota;
- the quota renewing after an hour;
- the direction table.


### 4.6 — The acceptance attacks, and gas

**Status.** Proposed: the reading of "the same attacks must pass under the
baseline classes".

**Decision.** Each attack runs against the baseline the attack matrix (spec
9.1) names for it, on the ported market through the gate, in
`test/policies/Step4Acceptance.t.sol`. The spec's sentence read literally, every
attack passing under every baseline, cannot hold: any capped window stops a
split-leg drain, and a boundary burst is a weakness of tumbling windows, not of
token buckets.

| Attack | Under SLIDING | Under its baseline |
| ------ | ------------- | ------------------ |
| Split-leg drain: 24 orders of 1000 Wh, each within A1 | S1, a 5 kWh day, refuses the 24-leg batch, and the sixth order when spread over calls: 1,250,000 units at most | Per-action bounds only: all 24 placed, 6,000,000 units |
| Boundary burst: the budget at 23:59:59 and 00:00:01 UTC | 1,250,000 units | TUMBLING, daily from midnight UTC: 2,500,000 units within two seconds |
| Idle-then-burst: a week idle, then an hour of orders | One day's budget, H | REFILL (H/24 an hour, up to 7H) and STREAM (H/24 an hour, up to 30H): 7H each |
| Place-and-cancel near the gate: four reservations of 1500 Wh, cancelled 20 minutes before the gate | S6 with a threefold weight within 30 minutes: one withdrawn, three must stand | S6 without the weight: all four withdrawn |

**The baselines are matched.**

- **Idle-then-burst.** REFILL and STREAM run at the same long-run rate as the
  sliding window, H a day. What differs is only that they keep unused
  allowance.
- **Boundary burst.** TUMBLING has the same cap and period as the sliding
  window.

These are the comparisons the paper makes.

**Gas** (`docs/reports/gas-2026-10-16.md`). Steady state, the agent's whole
submission:

- **One bid:** 304,906 gas bare; all five instances add 100,072.
- **A 24-leg batch:** 6,509,320 bare; all five add 465,979, about 19,400 a leg.
- **A cancellation:** 73,681 bare; all five add 128,228, since each instance is
  credited and S6 counts it.

Per policy, on one bid:

| Policy | Adds |
| ------ | ---: |
| `StaticOrderPolicy` | 15,571 |
| S1 | 21,769 |
| S2, two instances | 36,183 |
| S6 | 26,778 |

A monolithic variant (spec D14) was not measured.

**Tests.** 15: nine for the attacks, each blocked and passing under its
baseline, and six for gas. `npm test`: 427 passing.


### 4.7 — Wrap-up: mutation, the earlier design removed, the demo under policies

**Status.** The removal settles open decision 3 by its default; the rest
proposed.

**Mutation.**

- **The new `policies` catalogue**, 43 mutants:
  - the gate's phases (10): a rejection that does not stop, a flag taken for a
    rejection, the check stopping at the first rejection, skipped commits and
    credits, a failing credit blocking reconcile, wrong release fields;
  - `StaticOrderPolicy` (10);
  - `WindowPolicy` (12);
  - `CancelQuotaPolicy` (11).
- **Two of spec 8's pending mutants are now in it:** "≤ becomes < on a
  policy's cap comparison" and "expiry counted as cancel in S6". The three
  left in `pending.js` belong to step 5.
- **Each mutant runs the tests of the contract it breaks.** The first run, with
  all five test files per mutant, took about 6.5 minutes a mutant; with the
  contract's own tests, 1. A survivor is re-run with `--all-tests` before it is
  called a gap. The runner takes an optional `tests` per mutant.
- **Result:** 42 caught at first. The survivor, "another quantity keeps the old
  count", was a gap: a 24-hour window had always expired by the time a 24-hour
  widening applied. `test_countingAnotherQuantityStartsAfresh` uses a 48-hour
  window; 43 of 43 caught (`docs/reports/mutation-policies-2026-10-16.md`).
- **The older catalogues after 4.1 and 4.2:**
  - the eight mutants of the removed agent registry are dropped;
  - "agent check removed" is now "submit open to any caller";
  - "cancel legs not booked" targets the new line.
  Both changed mutants were re-run and caught.

**The earlier design is removed** (spec D13; open decision 3, default "at
step 4").

- **Deleted:** its seven contracts, 144 tests, Python verifier, differential and
  key scripts. S1 covers what it did, before the fact and on each order.
- **Kept:**
  - its documentation, in `docs/earlier-design/`;
  - the HEMS records, moved to `data/hems/`, which step 6 needs to calibrate
    the caps and measure false positives.
- **Recoverable.** Git keeps everything; step 5 may take `MeterReadings.sol`'s
  EIP-712 checking from history.
- **Config.** Both configs lose the file permissions the differential needed.

**The demo trades under policies.**

- **Deploy.** `npm run demo:deploy` gives every agent's account the five step 4
  instances, from `prosumers.json`'s `agentPolicies`; `offchain/deploy/policies.js`
  encodes the configurations.
- **The day.**
  - Alice's modification takes S1 from 5.58 to 6.08 EUR, past the 6 EUR soft
    bound, and is flagged.
  - A further 2 EUR bid would take it to 7.68, past the 7 EUR hard bound, and is
    refused without reverting. The script prints every policy's result on it.
  - The rest of the day is unchanged, figure for figure.

**Checked.**

- `npm test`: 284 passing.
- `npm run test:offchain`: 12 passing.
- `demo:deploy` and `demo:flow` on a fresh node.
- **Foundry, `test/accounts/`: not re-run.** Docker was not running, and it is
  not started without Dan. The real-account tests last passed after 4.2. Their
  shared mocks have changed since (the decoders' `slotStart`) and compile under
  Hardhat.


### 4.8 — The rest of the earlier project removed

**Status.** Settled by Dan ("remove old project files, the project we started on
and modified for these custom policies"; scope chosen 16 October: the leftovers
in this repository, keeping the HEMS data).

**Decision.**

- **Removed:**
  - `docs/earlier-design/`, the earlier project's six documents;
  - the earlier `.env.example`, with the old contract addresses, the GUARDIAN
    role and scripts that no longer exist;
  - the GUARDIAN key from `hardhat.config.js`.
- **Rewritten.** A new `.env.example` names the two keys of the current key
  model: the owner's, and the agent's session key. The tests and the demo need
  neither.
- **Kept:**
  - `data/hems/`, the HEMS records, which step 6 needs;
  - Dan's Cursor rule;
  - the sibling folder `agent-energy-blockchain-proiect2`, the original copy,
    which lies outside this repository.
- **Recoverable.** Git keeps everything removed: `git show 3c4d84e:<path>`.

**Entries above still name these files.** The decision log is a history, and
those names were right when written.

**Checked.**

- Foundry, the whole suite in Docker: 292 passed, the step 4 gate included on
  the four real accounts. This closes the check left open at 4.7.
- After a clean rebuild: `npm test` 284 passing.


### 4.9 — Dan's answers to the open decisions

**Status.** Settled by Dan, 16 October, item by item.

| # | Question | Answer |
|---|---|---|
| 1 | Timelock on approving a market call (spec D16) | Keep it immediate |
| 2 | The six step 1 choices (1.1, 1.2, 1.7, 1.12, 1.13, 1.14) | Confirmed, all six |
| 4 | USD data, mock EUR token | **Use USD everywhere**: the token is a mock USD |
| 5 | At most 16 policies per account (1.16) | Keep 16 |
| 6 | A real owner validator in the tests (1.18) | Not now |
| 8 | Market port (2.22, 2.23, 2.27, 2.29) | Manager separate from the prosumers: yes. A price per order, and the sensor's own address: either is fine, so they stay as built. Caller checks in every function: yes |
| 9 | Settlement basis (2.46) | Net export, as built |
| 10 | Window edges (3.4, 3.5) | As built |
| 11 | Step 4's choices (4.2 to 4.6) | Keep all |

Items 3 and 7 were already settled. Every entry above marked **Proposed** that
one of these items names is settled with it. The other entries marked
**Proposed** were not listed in the table and not reviewed one by one; they
stand as built.

**The currency (item 4).** Dan chose "convert and use only USD everywhere". The
HEMS data is already in USD, so nothing needs converting: the token, the policy
configurations and the scripts' output are relabelled to USD, and no exchange
rate is assumed anywhere.

- **The contracts do not change.** `LockableERC1155` has no symbol; token id 0
  is the payment token, 6 decimals, now read as USD.
- **The off-chain code:**
  - `offchain/chain/units.js` exports `USD` and `usd()` in place of `EUR` and
    `eur()`;
  - `prosumers.json`'s fields are `fundsUSD`, `maxValueUSD`, `sellFloorUSD`,
    `buyCeilingUSD`, `softUSD` and `capUSD`;
  - the deploy script, the matcher and the day-ahead scenario print USD.
- **The documents:** spec D7 and amendment A4 are amended, and the guide's demo
  amounts are relabelled. Entries above that say EUR are history and keep it.
- **The amounts stay the same,** read as USD: the demo's budget is still 6 soft
  and 7 hard.


### 4.10 — The HEMS dataset: the raw files outside git, an extract in `data/homes/`

**Status.** Settled by Dan for the two rules ("put it in gitignore", "take some
data out of there with a script and put it nicely in a different folder with
csv files with representative names"). What is extracted, and how, is proposed.

**The raw dataset.** Dan placed it at the root, in `A Four-Year 30-Minute
Simulated Residential HEMS D/`: six simulated homes in Sacramento, 2020 to
2023, 30-minute slots, 75 MB.

- It is git-ignored by a pattern that matches the folder's name, which is cut
  short on disk.
- It is to be published on its own (Mendeley Data, reserved DOI
  10.17632/5rrc4787hv.1), so the repository keeps only what the project uses.

**The extract,** by `npm run data:extract` (`offchain/dataset/`, JavaScript),
into `data/homes/`:

- `homes.csv`: per home, PV capacity, battery capacity and power, initial,
  minimum and maximum state of charge, and the two efficiencies;
- for 2022: one 30-minute file per home, named for the household, with load in
  three parts, PV and net load; the prices once, since all six homes share them
  (checked); daily totals;
- `days/`: seven representative days, each with why it was picked: summer
  sunny, winter cloudy, spring and autumn typical, the heating peak, and one
  day that is both the cooling peak and the year's price spike (6 September,
  1.998 USD/kWh).

**Why 2022.** It is the dataset's evaluation year, and the year of the arms'
records in `data/hems/`. `--year` takes another.

**Integers only, read exactly.**

- The values are Wh, W, basis points and micro-USD per kWh, the units the
  contracts use; a price goes to the market unchanged.
- `decimal.js` reads the CSV text as an exact decimal, including the
  exponent form the files sometimes use (`4.88e-06`), and rounds once, half
  away from zero.
- Floating point would turn 0.1945 kWh into 194 Wh instead of 195.

**Rejected.**

- **Committing the raw dataset:** 75 MB, and not ours to republish ahead of
  its own release.
- **All four years:** step 5 needs parameters and a few days, and step 6 one
  year to compare with the arms. About 1.2 MB a year per home.
- **Converting the timestamps to UTC.** The files' clock is a plain local grid
  with no daylight-saving jumps, so a conversion would make up times the data
  never had. A slot is its position in the day.

**Two things noticed.**

- **Rounding drift.** Rounding to whole Wh drifts a little: the HVAC's two
  fixed draws both sit a fraction above a whole Wh. Home_01's 2022 load is
  668 Wh low out of 9.76 MWh.
- **A SoC mismatch for step 6.** The arms' records reach 10 % state of charge,
  while the dataset gives 20 % as every home's minimum. The arms ran with their
  own battery settings. Step 6 has to use the arms' settings, from their step
  logs.

**Checked.**

- Two runs give byte-identical files.
- Home_01's 2022 PV comes to 7,379,598 Wh, against 7,379,593 summed from the
  raw decimals.
- `npm run test:offchain`: 15 passing, the three new tests included.
- After the USD relabel (4.9), the demo on a fresh node prints the same day
  in USD.


### 4.11 — The honest arms' step logs in `data/arms/`

**Status.** Settled by Dan for the rule ("I want the data for step 6 here, in
the data folder"; scripts may read `Demo_PlanApplyEvaluate/data/`). What is
extracted is proposed.

**Source.** `Demo_PlanApplyEvaluate/data/`, the HEMS simulation's outputs for
home_01 in 2022. Only that folder is read; the simulation's scripts are not.

**The extract,** by `npm run data:extract` (`offchain/dataset/arms.js`), into
`data/arms/home_01/2022/`:

- **`settings.csv`:** the battery, grid and price settings the arms ran with.
- **`appliance-tasks.csv`:** the 128 appliance jobs.
- **One 30-minute file per arm:** state of charge, charge, discharge,
  appliances, import, export, prices, cost.
- **`daily-results.csv` and `annual-results.csv`:** the simulation's own
  figures.

**Which arms.** The seven that ran for real: B_null, B0, B0star, B1, B2, B2r,
B2nn. The spec names B0 and B2 and scores against B2; B1 is the best case; the
others are cheap to keep, about 1.2 MB each.

- **Left out: A0 to A2.** Their runs are mock echoes, with results equal to
  B0's and B2's; `--arms A0,A1` adds them once they have really run.
- **Left out: the smoke-test runs** of a few days.

**Rounding.** The logs print floats in full (`1.4999999952631584`,
`2.42e-09`, `-0.0`). `decimal.js` now reads every digit and rounds once, at
any precision, where it used to refuse more than nine decimals.

- The homes' output is unchanged by this: byte for byte, checked.

**Slots count from 0,** as in `data/homes/`; the source's steps count from 1.
A task's deadline is the last slot it may run in: no arm ran a task past it,
and many ended exactly on it.

**Checked before writing:**

- every arm has the same dates and prices;
- the export price is 30 % of the import price, within a micro-USD;
- the state of charge stays within the settings;
- each day's import and export, summed from the slots, matches the
  simulation's daily figures within rounding;
- slot by slot against `data/homes/`: PV, prices, and the fixed load, which is
  base load and HVAC, or all the load for B_null, within 1 Wh.

Also:

- B0, B1 and B2's annual import and export agree with the sum of their daily
  records in `data/hems/` within 14 Wh in a year: one rounds the year, the other each
  day;
- two runs give byte-identical files;
- `npm run test:offchain`: 15 passing.

**Noticed, for step 6:**

- **Imports and exports, not market orders.** How an honest plan becomes bids
  and offers is a step 6 choice.
- **The battery settings differ from the dataset's.** The arms ran with 10 % to
  100 % state of charge, starting at 50 %; the dataset gives 20 % to 90 %. A
  replay uses the arms' settings.
- **Only home_01 was simulated.**
- **The simulation's sanity report fails one check:** B1 improves on B0 by
  9.07 %, outside its expected 10 % to 30 %. Its other nine checks pass.


---

## Step 5. Oracle verification, the relays, S3, S4, S5

Before starting, Dan chose (16 October), on the proposals:

- **No tariff oracle in step 5.** None of its acceptance criteria needs one; A3
  stays absolute (spec A8).
- **The demo moves to 30-minute slots,** like the data.
- **The demo prosumers' batteries:** Alice gets home_01 with the arms' settings
  (`data/arms/home_01/2022/settings.csv`), Bob home_03 and Carol home_05 with
  the dataset's.
- **The PV forecast:** the demo posts the actual PV, a perfect forecast; the
  tests also use forecasts with errors.

### 5.1 — The oracle verifier

**Status.** Proposed.

**Decision.** `contracts/oracle/OracleVerifier.sol`, one deployment beside
the gate, all state keyed by account:

- **Two kinds of reading.**
  - A **BMS reading**: account, timestamp (a slot start), stored energy in Wh,
    and the discharge odometer in Wh.
  - A **PV forecast**: account, issue time, the start of its first slot, the
    slot length, and Wh per slot, at most 96.
  - Both are EIP-712 typed data. The domain binds the chain and the verifier;
    the reading names its account.
- **The signer registry.** `setDevice(kind, signer, maxAge)` is called by the
  account itself, on the owner path. One signer per kind, and the oldest a
  reading may be when accepted: up to 7 days. A zero signer removes it.
- **`accept`, open to anyone.** A reading is accepted when:
  - its signature recovers to the registered signer (65 bytes, low-s only);
  - it is not in the future, and no older than the maximum age;
  - it is not older than the last accepted from that device.

  The same reading again is a no-op. A different reading with the same
  timestamp is refused, so one signer cannot be made to choose. A BMS
  odometer that goes down is refused. Each accepted reading is emitted in full
  (`ReadingAccepted`) and stored as the latest.
- **Views for the policies.**
  - `bmsOf(account)` gives the latest battery reading and whether it is fresh.
  - `pvAt(account, slotStart)` gives the forecast for that slot, and whether
    it is usable: covered exactly, and fresh.
- **The gate.**
  - `submit(target, callData, readings)` hands each reading to the verifier
    after decoding and before the check phase (spec 4.1, step 3), at most four
    per submission. A refused reading reverts the submission, and so does a
    reading for another account.
  - `CheckContext` gains `oracle`, so a policy can read the verifier.
  - The verifier is a forbidden target, like the ledger, so the agent cannot
    register a signer.

**Why a separate contract.** The gate is at 16.9 KB of the 24 KB limit, and
the PV relay posts to the verifier directly, not through the gate. The pattern
is the ledger's: keyed by account, owner path by `msg.sender`, and out of the
agent's reach because `submit` refuses it as a target.

**Why times, not slot numbers.** A BMS and a forecast provider know clocks,
not a market's slot numbering. The policies map a slot to its start through
the decoder's `slotStart`, already in place since step 4.

**Why anyone may hand in a reading.** Authenticity is in the signature.
Monotonicity means a reading handed in can only move the device's clock
forward, and the maximum age means only the current slot's reading is fresh.
So letting the agent choose when to hand one in gives it nothing.

**Why the maximum age is per account and applies at once.** τ_soc is one slot
and the slot length is a deployment parameter (A2), so it cannot be a
constant. Registering a signer and setting its age is like approving a decoder:
it needs the owner's key, and Dan chose immediate application for that (4.9,
item 1).

**Changing the signer drops the stored reading.** What a replaced or
compromised device said no longer counts. The device's last timestamp is kept,
so the account's clock still only moves forward.

**Rejected.**

- **Inside the gate:** the size, and a relay would then post through the gate.
- **Readings only through `submit`:** the PV forecast is pushed hourly by a
  relay (D11), not by the agent.
- **Readings without `submit`, posted beforehand by the agent:** the spec puts
  them in `submit`, and a reading that comes with its order is recorded in
  the same transaction as the decision.
- **A staleness rule fixed in the verifier:** the slot length varies by
  deployment.
- **ERC-1271 signers** (a contract as the device): the trust anchor is a key in
  a secure element (spec 3). Not needed now.

**Changed with it.**

- **Every test that calls `submit` passes an empty `readings`,** and every
  gate is built with a verifier. The edit was mechanical, by script.
- **The gate's `submit` is split into `_decode` and `_checkAndCommit`.** The
  extra calldata argument took it past the stack limit; behaviour is
  unchanged.
- **The `ledger` mutation catalogue's "ledger allowed as target"** follows the
  new line. Re-run: caught.
- **Off-chain:** the deploy script deploys the verifier and the scenario
  passes an empty `readings`.

**Checked.**

- `npm test`: 333 passing: the 284 before, 35 verifier tests
  (`test/oracle/OracleVerifier.t.sol`) and 14 through the gate
  (`test/gate/GateReadings.t.sol`).
- `npm run test:offchain`: 15 passing.
- The demo on a fresh node: the same day, figure for figure.
- `npm run mutate -- --check`: every pattern found.
- **Foundry: not re-run.** It needs Docker; `test/accounts/` was updated for
  the new `submit` by the same script, but only Foundry builds it, so it is
  not yet compiled.

**Gas, execution only, into empty storage:**

- a BMS reading: 87,468;
- a day's forecast (48 slots): 395,306.

Re-posting over a stored forecast costs far less, since the storage is no
longer empty. Per-transaction figures come with the gas report of 5.6.


### 5.2 — The oracles off-chain, played from the data

**Status.** Proposed. Uses Dan's choices made before step 5: Alice's battery
from the arms, Bob home_03, Carol home_05; the demo forecast is the actual PV,
the tests also use one with errors.

**Decision.** A package, `offchain/oracle/`:

- **`typed.js`:** EIP-712 signing with viem, with the types and domain of the
  verifier. A reading travels as `{ kind, data, signature }`, `data` being
  the ABI-encoded struct, ready for `accept` or for `submit`'s readings.
- **`battery.js`:** a battery as its BMS sees it, in whole Wh. Two ways to
  drive it:
  - a simple model, `step(netWh)`: a surplus charges, a shortfall
    discharges, within the slot's power, the charge limits and the
    efficiencies;
  - an honest arm replayed, `replayArm`: the arm's state of charge and
    discharge, from its step log.
- **`forecast.js`:** the PV forecast, in two modes:
  - **actual:** the PV that then came;
  - **yesterday:** the same slots a day earlier, a naive forecast whose errors
    are those of real weather.
- **`data.js`:** reads `data/homes/` and `data/arms/`, and sums half-hours to
  the market's slot length.
- **`relay.js`:** posts a forecast and hands in a reading, from a funded relay
  key; signs a BMS reading for the agent; reads back what the verifier holds.
- **`cli.js`:** `npm run oracle:post`, for trying it on the local node.

**The deploy script** registers, for each account with an agent, its BMS key
and the forecast provider. The maximum ages are one slot for the BMS (τ_soc)
and one hour for the forecast (τ_pv). The deployment file records:

- the oracle keys;
- each prosumer's home;
- whether its battery replays an arm (Alice: `"battery": "B2"` in
  `prosumers.json`) or follows the model.

**Choices inside it.**

- **The odometer counts energy drawn from the cells,** the house's discharge
  over the discharge efficiency. The arms count cycles the same way: their
  wear cost is that figure over the capacity. So S4 can be set from the arms'
  cycle counts.
  - Replaying B0, B1 and B2 gives 343.56, 446.79 and 452.42 cycles a year,
    against the arms' 343.31, 446.38 and 452.07.
  - The replay is a little higher because each slot's draw rounds up.
- **Rounding errs towards a battery holding less.** What is stored rounds
  down, what is drawn rounds up: a reading never shows energy the battery does
  not have.
- **The forecast with errors is yesterday's PV,** not random noise. Its errors
  are real ones, and it needs no seed.
- **Keys.**
  - The provider signs with one key (index 19) and the relay sends from
    another (18), so the signer needs no gas.
  - Each prosumer's BMS key is index 40 plus its position: unfunded, since it
    only signs.
  - These are all keys of the public test mnemonic, as everywhere in the
    project.
- **The data's day on the market's.** The relay takes data slots in sequence:
  slot k of a market day is slot k of the chosen date, running into the next
  date when a day has more than 48 slots. The command lines up the current
  slot by its UTC time of day. The scenario will use the market day (5.7).
- **`deploy/` keeps depending on `chain/` only.** It chooses the oracle keys
  and records them; `oracle/` reads them from the deployment.

**Rejected.**

- **A seeded random forecast error:** artificial, and it must be justified.
  Yesterday's PV is the usual naive baseline.
- **The odometer on the house side:** it would not match the arms' cycles.
- **A long-running relay process posting every hour:** the scenarios move the
  node's clock by hand, so they call the relay when they need it.

**Changed with it.** `npm run test:offchain` now builds first: the signing
test deploys the verifier on a chain inside the process.

**Checked.**

- **Foundry, the whole suite in Docker: 341 passed.** This closes the check
  left open at 5.1: `test/accounts/` compiles and passes with the new
  `submit`.
- **`npm run test:offchain`: 29 passing.** The 14 new ones include viem's
  EIP-712 hash equal to the contract's digest, off-chain signatures accepted,
  and a reading changed after signing refused.
- **On a fresh node,** `demo:deploy` then `oracle:post -- --attacks`:
  - Alice's battery reading (B2 replayed) and Carol's (home_05 at 42 %) are
    accepted, with 24 hours of forecast;
  - an older reading is refused (`Oracle_Reordered`), and so is one signed by
    another key (`Oracle_WrongSigner`);
  - `--mode yesterday` posts a different forecast;
  - `demo:flow` then runs the same day as before.


### 5.3 — S3: DeliverabilityPolicy

**Status.** Proposed.

**Decision.** `contracts/policies/DeliverabilityPolicy.sol`, spec 6.4.

- **Two projections over the horizon,** from the battery's signed energy at
  the start of the current slot:
  - **floor:** PV forecast × α and **filled** bids in; committed sells and the
    reserve load out; the battery must stay at or above its minimum;
  - **ceiling:** every placed bid in, PV left out; the reserve load out; the
    battery must stay at or below its maximum.

  Per slot, sells may not exceed the discharge power plus the PV credit, and
  bids beyond the reserve load may not exceed the charge power.
- **One value, in Wh:** the energy short of the floor, plus every excess over
  the ceiling and the two power limits.
  - **Rejected** when the submission leaves a value above zero and makes it
    larger than without it.
  - **Passes** when it keeps it or reduces it: a cancellation always, and a
    smaller modification or a bid while the floor is short (D10).
  - No soft bound.
- **Refused when it cannot be judged:** a placement with no fresh battery
  reading, or for a slot outside the horizon. `valueAfter` is then 2^256 − 1.
  A submission of cancellations only never needs judging.
- **The horizon** is k slots from the one holding the reading's timestamp. The
  slot length is read from the market through the decoder (`slotStart` of two
  consecutive slots); slots are taken to be of equal length.
- **No state of its own;** `commit` and `credit` do nothing. Positions come
  from the ledger and the battery and forecast from the verifier. Two batch
  views were added for it:
  - `PositionLedger.positionsOf(account, firstSlot, count)`;
  - `OracleVerifier.pvSeries(account, firstSlotStart, slotSeconds, count)`,
    which reads zero for any slot the forecast cannot serve.
- **Configuration:**
  - the parameters: horizon, capacity, floor and ceiling, charge and
    discharge power, both efficiencies, PV credit α, reserve load;
  - **any other horizon widens,** as a change of shape (spec 5.6);
  - **widens:** more capacity, a lower floor, a higher ceiling, more power,
    higher efficiencies, more PV credit, less reserve;
  - the horizon is at most 96 slots, the longest forecast the verifier holds.

**The physics of the projection.**

- **Rounding.** The floor rounds gains down and losses up; the ceiling the
  other way.
- **The floor projection:**
  - what rises above the maximum is spilled;
  - what falls below the minimum is counted as short, and the battery stops
    there.

  So the shortfall is energy promised but not deliverable, and it only grows
  with every extra sale.
- **The ceiling projection** never goes below the minimum, and counts what
  rises above the maximum.

**Why "leaves a shortfall and makes it larger".** A battery reading can show
less than the plan assumed: the house used more, or the sun was weaker. A rule
of "no shortfall after" would then refuse even orders that help. The value
grows with every sale and every bid, so "larger" is exactly what adds
exposure.

**H_slots ≤ k by construction.** A placement outside S3's horizon is refused by
S3 itself. So every slot the agent can reach is one S3 covers, whatever A6
allows. The spec's configure-time check would have tied two policy contracts'
configurations together through the gate; it is not needed. The spec's
mutant "H_slots ≤ k check removed" becomes "S3 accepts a placement outside its
horizon" (5.7).

**The horizon in a day-ahead market.** The spec's default, k = 8, suits a
continuous market. In Dan's market, orders are for tomorrow and trading closes
at noon, so the horizon must run from now to the end of tomorrow: about 72 to
96 half-hour slots. Gas grows with it.

| Horizon | Gas of the check (one sale, in the test) |
|---:|---:|
| k = 8 | 119,827 |
| k = 16 | 188,342 |
| k = 48 | 531,372 |
| k = 96 | 1,008,918 |

About 10,500 a slot, most of it the two projections, not the storage reads. To
be measured on whole submissions, and cut if it can be, in 5.6.

**Simplifications, to say in the paper.**

- **socMin is one constant.** The spec allows a floor that varies with time.
- **The reserve load is one constant per slot (D4).**
- **The per-slot discharge limit leaves out the reserve load,** as the spec
  writes it.

**Rejected.**

- **A ring of k entries in the policy:** the ledger already keeps positions
  per slot.
- **Reverting when a reading is missing:** a refusal is recorded without
  reverting, like every policy rejection.
- **Crediting placed bids in the floor:** D3, the phantom-buy attack;
  `test_anUnfilledBidCannotJustifyASale` shows it.

**Checked.**

- `npm test`: 359 passing, 26 of them for S3.
- `npm run mutate -- --check`: every pattern found.
- Not re-run: Foundry and the demo, which do not use S3 yet.

---

## Open decisions

None left. Dan answered every item on 16 October (log 4.9); the table keeps the questions and records the answers.


| #   | Question                                                                                                                                                                                                                    | Where                | Answer                                        |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | --------------------------------------------- |
| 1   | Should registering an agent and approving a call be timelocked when they extend authority?                                                                                                                                  | 1.8, spec D16        | Keep it immediate (4.9) |
| 2   | Confirm the six other step 1 choices: revert on unknown agent or call (1.7), owner applies a widening (1.13), one pending proposal (1.14), add now and remove later (1.12), generations (1.2), no library in the gate (1.1) | spec D15, D17 to D21 | Confirmed, all six (4.9) |
| 3   | ~~Remove the earlier design's code now, or at step 4?~~ **Removed at step 4.7**                                                                                                                                             | 0.3, 4.7             | Settled                                       |
| 4   | The honest-arm data is in USD and the settlement token is a mock EUR. A 1:1 relabel, or a conversion?                                                                                                                       | spec amendment A4    | **Mock USD everywhere** (4.9, spec A4) |
| 5   | Is 16 the right bound on policies per account?                                                                                                                                                                              | 1.16                 | Keep 16 (4.9) |
| 6   | Add a real owner validator to the tests, so "only the owner can make the account act" is asserted?                                                                                                                          | 1.18                 | Not now (4.9) |
| 7   | ~~D1: keep the bespoke gate, move to MetaMask's ERC-7710 framework, or authenticate the agent with a Smart Session?~~ **Decided 15 October: option 3, the Smart Session** | 1.20, 3.9, spec D1 and A7, `docs/analysis/delegation-architecture.md` section 10 | Decided |
| 8   | Market port: manager separate from the prosumers (2.22), a price per order in a batch (2.23), the sensor submitting from its own address (2.27), caller checks everywhere (2.29) | 2.22, 2.23, 2.27, 2.29, `docs/analysis/market-structure.md` | Confirmed; caller checks in every function (4.9) |
| 9   | Settlement basis: measured net export against committed net export (as built), or flexibility against a baseline (thesis), with the baseline set by the operator or a signed forecast | 2.46 | Net export, as built (4.9) |
| 10  | Window edges the spec leaves open: REFILL credits only within the same interval (3.4); a change of a window's shape starts it afresh and must be a WIDEN (3.5) | 3.4, 3.5 | As built (4.9) |
| 11  | Step 4's choices: a modification needs room before the old order is credited (4.2); A4 in UTC hours, A6 in seconds (4.3); no carry-over on structural changes (4.4); S6's units, and only accepted submissions as messages (4.5); each attack against its own baseline (4.6) | 4.2 to 4.6 | Keep all (4.9) |


