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

---

## Open decisions

Waiting for Dan. None blocks step 2.


| #   | Question                                                                                                                                                                                                                    | Where                | Default if nothing is said                    |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | --------------------------------------------- |
| 1   | Should registering an agent and approving a call be timelocked when they extend authority?                                                                                                                                  | 1.8, spec D16        | Stay immediate                                |
| 2   | Confirm the six other step 1 choices: revert on unknown agent or call (1.7), owner applies a widening (1.13), one pending proposal (1.14), add now and remove later (1.12), generations (1.2), no library in the gate (1.1) | spec D15, D17 to D21 | As built                                      |
| 3   | Remove the earlier design's code now, or at step 4?                                                                                                                                                                         | 0.3                  | Step 4                                        |
| 4   | The honest-arm data is in USD and the settlement token is a mock EUR. A 1:1 relabel, or a conversion?                                                                                                                       | spec amendment A4    | Undecided; needed by step 4                   |
| 5   | Is 16 the right bound on policies per account?                                                                                                                                                                              | 1.16                 | Revisit with gas in step 4                    |
| 6   | Add a real owner validator to the tests, so "only the owner can make the account act" is asserted?                                                                                                                          | 1.18                 | Not planned before a deployment script exists |
| 7   | D1: keep the bespoke gate, move to MetaMask's ERC-7710 framework, or authenticate the agent with a Smart Session? Decide before step 4, after the prototype checks | 1.20, spec D1, `docs/analysis/delegation-architecture.md` | Keep as built; decide before step 4 |
| 8   | Market port: manager separate from the prosumers (2.22), a price per order in a batch (2.23), the sensor submitting from its own address (2.27), caller checks everywhere (2.29) | 2.22, 2.23, 2.27, 2.29, `docs/analysis/market-structure.md` | As proposed |


