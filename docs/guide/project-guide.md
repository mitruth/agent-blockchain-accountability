# Project guide

What the project contains today, what every file does, what the tests prove,
and how to run everything. Current as of 2026-10-14: steps 1 and 2 of 6 are built.


| For                                     | Read                                 |
| --------------------------------------- | ------------------------------------ |
| What must be built, all six steps       | `docs/spec/policy-spec-v0.1.md`      |
| Why each thing was built the way it was | `docs/decisions/design-decisions.md` |
| Status and what comes next              | `docs/plan/roadmap.md`               |
| The project that came before this one   | `docs/earlier-design/`               |


---

## 1. The project in one page

A prosumer owns a smart account. An autonomous agent, an LLM or an RL
controller, trades energy for that prosumer on a peer-to-peer market. The agent
may be buggy, prompt-injected or adversarial. The account enforces the owner's
policies on every order **before** the order reaches the market, whatever the
agent's model, prompt or reasoning.

Two kinds of policy:

- **Per-action (A1 to A8):** bounds on one order. Infrastructure.
- **Sequence (S1 to S6):** bounds over a window of orders, such as a weekly
budget or a daily export cap. This is the research contribution: exposure
built from individually legal orders.

The build follows six steps, fixed by Section 9 of the spec.


| Step | Content                                                | Status                |
| ---- | ------------------------------------------------------ | --------------------- |
| 1    | The gate, the key model, the registries, configuration | **Built and passing** |
| 2    | Mock market, order decoder, position ledger, reconcile | **Built and passing** |
| 3    | `WindowLib`, independent verifier, mutation suite      | Not started           |
| 4    | Per-action policies, S1, S2, S6                        | Not started           |
| 5    | Oracle verification, PV relay, S3, S4, S5              | Not started           |
| 6    | Evaluation                                             | Not started           |




### What exists today, precisely

- `PolicyGate`**:** an ERC-7579 executor module. It is the only way the agent
can make the account do anything.
- **An agent registry:** which agent may act for which account, until when.
- **A call allowlist:** which function of which market contract the agent may
call.
- **A configuration manager:** the list of policies per account, with the
rule "tighten now, widen after 24 hours".
- **A position ledger:** every order the agent placed, and per delivery slot
the account's committed and cleared volume, buy and sell.
- **A mock energy market and its decoder:** a per-slot order book with gate
closure and partial fills, and the adapter that reads its calls and views.
- `reconcile`**:** brings an order up to date with the market. Anyone may
call it.



### What does not exist yet

**No policy checks an order yet.** Today an order from a registered agent to an
approved market function is executed and booked in the ledger. Policies can be
added and configured, but `submit` does not consult them until step 4. The
market is a mock whose fills come from an operator, not from matching. There is
no oracle and no sequence policy. Nothing is deployed to a network.

**Before step 4 starts,** spec decision D1, the agent's entry point, has to be
decided: see `docs/analysis/delegation-architecture.md`.

---



## 2. The key model

The agent holds no key on the prosumer account. That is the foundation, and
step 1 exists to establish it.

```
OWNER PATH (configuration)

  owner key ── signs a user operation ──▶ account's root validator
                                              │
                                              ▼
                                          the account ── calls ──▶ PolicyGate
                                                                   register an agent
                                                                   approve a market call
                                                                   add or configure a policy

AGENT PATH (orders)

  agent key ── calls ──▶ PolicyGate.submit(account, target, callData)
                             │  checks the agent, the target, the function
                             ▼
                         account.executeFromExecutor ── calls ──▶ market
```

The gate tells the two paths apart by **who calls it**. A configuration write
is accepted only when the caller is an account that has the gate installed, and
it lands in that account's own state. An account calls the gate only when its
root validator authorised the call, and the root validator belongs to the owner.
The agent calls the gate directly, as an ordinary address, and the only function
that accepts it is `submit`.

### Who may do what


| Actor           | May                                                                                                                               | May not                                                                                                                      |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **Owner**       | Install and uninstall the gate; register and revoke agents; approve and withdraw market calls; add, configure and remove policies; appoint who writes the account's positions | Approve the account itself, the gate or the ledger as a target. Loosen a policy or remove one without the 24-hour wait |
| **Agent**       | Submit approved calls while registered and unexpired; cancel or modify the orders it placed | Install or uninstall a module; write any registry or the ledger; configure a policy; touch an order it did not place; reach any of those by routing a call through the gate |
| **Anyone else** | Nothing on this account                                                                                                           | Everything                                                                                                                   |




### The four doors, and how each is closed

An agent that wanted more authority would aim at one of four things.


| Target of the attack                | Why it would work if open                                                                                                                                 | How it is closed                                                                              |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| The account's own module management | Real accounts accept `installModule` from themselves. `submit` makes the account call things. So `submit` with the account as target would be a self-call | `submit` refuses the account as a target. The allowlist refuses to register it too            |
| The gate's registries               | A call from the account to the gate arrives on the owner path                                                                                             | `submit` refuses the gate as a target. The allowlist refuses to register it too               |
| A policy's parameters               | A looser cap is as good as no cap                                                                                                                         | A policy accepts `configure` from the gate only, and the gate calls it only on the owner path |
| The ledger's list of writers        | The ledger appoints writers on the word of the account. A call from the account to the ledger would let the agent appoint itself | `submit` refuses the ledger as a target |


---



## 3. How an order flows today

The agent calls `PolicyGate.submit(account, target, callData)`. The spec's
full flow has eight steps (Section 4.1). This is what steps 1 and 2 implement of
it.


| Spec step | What it is                                                                                           | Built?                                                    |
| --------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| 1         | The caller is a registered, unexpired, unrevoked agent of `account`                                  | Yes                                                       |
| 2         | The pair (target, function selector) is on the allowlist; its decoder turns the call into an `Order` | Yes, as one or two legs |
| 3         | Verify signed oracle readings                                                                        | No, step 5. `submit` takes no readings yet                |
| 4         | Check phase: every policy inspects the order                                                         | No, step 4                                                |
| 5         | Aggregate: execute, flag or reject                                                                   | No, step 4                                                |
| 6         | Commit phase: update policy state and the position ledger                                            | The ledger, yes, after the market call. Policy state, step 4 |
| 7         | The account calls the market                                                                         | Yes                                                       |
| 8         | Emit the outcome                                                                                     | Yes: `OrderSubmitted`, then `Executed`                    |


In order, `submit` does this:

1. Reverts with `PolicyGate_AgentNotAuthorized` unless the caller is an active
  agent of the account.
2. Reverts with `PolicyGate_CallDataTooShort` if the call has no selector.
3. Reverts with `PolicyGate_ForbiddenTarget` if the target is the account, the
  gate, the ledger or the zero address.
4. Looks up the decoder for (target, selector). Reverts with
  `PolicyGate_UnknownCall` if the owner never approved that pair.
5. Decodes the call into **legs**, each an `Order`: kind, side, slot, quantity
  in Wh, price, value at the limit price, order id. A placement is one PLACE
  leg; a cancellation is one CANCEL leg, for the quantity the market says is
  still unfilled; a modification is a CANCEL leg then a PLACE leg. A call that
  is not one or two legs is refused with `PolicyGate_NotAnOrder`.
6. Computes `orderHash` from the chain id, the gate's address, the account, the
  account's submission counter, the target and the hash of the calldata. Emits
   `OrderSubmitted`.
7. Asks the account to make the call: one call, zero value, never a batch and
  never a delegatecall. If the market reverts, everything reverts.
8. Books each leg in the position ledger, in order. A CANCEL leg books any fill
  not yet booked and releases the rest; a PLACE leg reads the new order's id
  from the market's reply and books the order. If the ledger refuses a leg (an
  order it does not hold, or a 65th open order), everything reverts.
9. Emits `Executed`.

### What happens to an order after it is placed

The market fills orders through its operator, partly or fully, until the slot's
gate closes. The ledger learns of fills when the order is **reconciled**:
`PolicyGate.reconcile(account, market, orderId)`, which anyone may call. Every
quantity comes from the market through the order's decoder.

Per account and delivery slot the ledger keeps four numbers, in Wh:

| Number | Counts | Changes when |
| ------ | ------ | ------------ |
| Committed buy, committed sell | Placed and not released, filled part included | Up on placement; down by the unfilled rest when the order closes |
| Cleared buy, cleared sell | Filled | Up when a fill is booked |

A fill counts as cleared only once booked. Until then it stays committed and
is not credited, which is the safe side: the deliverability policy of step 5
credits cleared buys only.

An order closes for one of four reasons, each its own event:

| Reason | When | Released |
| ------ | ---- | -------- |
| `FILLED` | Fully filled | Nothing |
| `CANCELLED` | Cancelled by the agent through the gate | The unfilled rest |
| `EXPIRED` | Its slot's gate closed with part unfilled | The unfilled rest |
| `CLOSED_ELSEWHERE` | The market no longer holds it open before gate closure, for instance the owner cancelled it directly | The unfilled rest |

Expiry is never a cancellation: only `CANCELLED` will count toward the cancel
quota S6 in step 4.

Two more rules:

- **At most 64 open orders per account.** A placement beyond that reverts. A
  modification at the bound goes through, because its cancel leg is booked
  before its place leg.
- **The agent acts only on its own orders.** Cancelling or modifying an order
  the ledger does not hold reverts, even though the market would accept it from
  the account.

A reentrancy lock covers the whole function. The same lock covers every
configuration write, so nothing can be registered or reconfigured while an order
is part-way through.

---



## 4. How configuration changes

Everything in this section is on the owner path.

### Agents and approvals


| Call                                    | Effect                                               | When    |
| --------------------------------------- | ---------------------------------------------------- | ------- |
| `registerAgent(agent, validUntil)`      | The agent may submit through `validUntil`, inclusive | At once |
| `revokeAgent(agent)`                    | The agent may no longer submit                       | At once |
| `setDecoder(target, selector, decoder)` | Approves one function of one market contract         | At once |
| `removeDecoder(target, selector)`       | Withdraws that approval                              | At once |


The account, the gate and the zero address can be neither agents nor targets.

### Policies

Each account has a list of policy instances, at most 16. An instance is a
policy contract plus a `policyId`, so one contract can serve several instances,
for example an export cap and an import cap.


| Call                                           | Effect                                         | When                                                    |
| ---------------------------------------------- | ---------------------------------------------- | ------------------------------------------------------- |
| `addPolicy(policy, policyId, config)`          | Adds the instance with its first configuration | At once: a new policy only adds a constraint            |
| `setConfig(policy, policyId, config)`          | Changes the parameters                         | Depends on the direction, below                         |
| `applyConfig(policy, policyId, config)`        | Puts a proposed loosening in force             | Only after the 24-hour wait                             |
| `proposeRemovePolicy` then `applyRemovePolicy` | Removes the instance                           | Only after the 24-hour wait: removal lifts a constraint |
| `cancelProposal(policy, policyId)`             | Drops a pending proposal                       | At once                                                 |


`setConfig` asks the policy contract to compare the new configuration with the
one in force. The policy answers with one of three words, and the gate acts on
it.


| The policy says | Meaning                                                     | The gate does                                                                                                 |
| --------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `INVALID`       | Malformed, or breaks a rule such as soft bound ≤ hard bound | Changes nothing. Emits `ConfigRejected` and returns, without reverting, so the refusal stays in the event log |
| `TIGHTEN`       | No parameter is looser than before                          | Applies it in the same call. Emits `ConfigApplied`                                                            |
| `WIDEN`         | At least one parameter is looser, whatever the others do    | Records a proposal with an earliest time 24 hours ahead. Emits `ConfigProposed`                               |


Rules around proposals:

- **One at a time.** An instance has at most one pending proposal. Any later
write to that instance drops it, so a loosening queued yesterday cannot come
back after a tightening made today.
- **Byte for byte.** `applyConfig` must be given exactly the configuration that
was proposed. The gate stores its hash.
- **Checked again.** At application time the policy is asked once more whether
the configuration is valid. The proposal is spent either way.
- **The limit of the timelock.** The owner can uninstall the whole gate in one
transaction with no delay. The 24 hours protect parameter edits, nothing
more.



### Who may write the account's positions

The account appoints the ledger's writers itself: the owner has it call
`PositionLedger.setWriter(gate, true)` once, after installing the gate. Without
that, every submission reverts. The ledger is a separate contract so that a
different entry point could be appointed instead, if decision D1 changes.

### Install, uninstall, reinstall

The gate is one deployment serving many accounts. All state is keyed by account
and by an **installation generation**, a counter that goes up each time the
account installs the gate. Uninstalling and reinstalling therefore starts from
nothing: every agent, approval, policy and proposal registered before is void.
Positions in the ledger are not affected: they are facts about the market, not
configuration.

---



## 5. File map



### `contracts/gate/`: the current system


| File                  | What it does                                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `PolicyGate.sol`      | The executor module. `onInstall`, `onUninstall`; `submit`, the agent's one entry point; `reconcile`, open to anyone. Inherits the four parts below |
| `GateBase.sol`        | Which accounts have the gate installed, the installation generation, the owner-path check (`onlyAccount`), the reentrancy lock |
| `AgentRegistry.sol`   | `registerAgent`, `revokeAgent`, `isAgentActive`                                                                                |
| `DecoderRegistry.sol` | `setDecoder`, `removeDecoder`, `decoderOf`, and the rule that the account and the gate are never targets                       |
| `ConfigManager.sol`   | The policy list, proposals, and the tighten-now, widen-later rule                                                              |
| `PositionLedger.sol`  | Every booked order and the per-slot positions. Written only by writers the account appointed |
| `GateTypes.sol`       | The `Order` and `FillState` structs and the enums `OrderKind`, `Side`, `ConfigChange` |




### `contracts/market/`: the mock market

| File | What it does |
| ---- | ------------ |
| `MockEnergyMarket.sol` | A per-slot order book. Slot length and gate lead are constructor parameters. Owners place, cancel and modify before gate closure; an operator address, standing in for the clearing engine, fills within the limit price |
| `MockMarketDecoder.sol` | Reads the market's place, cancel and modify calls into legs, values them at the limit price rounded up, and reads the market's fills and gate times |

### `contracts/interfaces/`


| File                            | What it declares                                                                                                                                             |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `IERC7579.sol`                  | The two pieces of the ERC-7579 standard the gate needs: the module hooks and `executeFromExecutor`. Declared locally so the gate imports no external library |
| `IOrderDecoder.sol`             | The adapter to one market: `decode` into legs, `placedOrderId`, `fillState`, `gateTime`. One decoder per approved market contract |
| `IPolicy.sol`                   | The configuration side of a policy: `classifyConfig`, `configure`, `deconfigure`. The order-checking side arrives in step 4                                  |
| `IModule.sol`, `IValidator.sol` | Earlier design                                                                                                                                               |




### `test/`


| Path                                | Tests                                  | Runs under          |
| ----------------------------------- | -------------------------------------- | ------------------- |
| `gate/KeyModel.t.sol`               | 35                                     | Hardhat and Foundry |
| `gate/ConfigManager.t.sol`          | 33                                     | Hardhat and Foundry |
| `gate/OrderLifecycle.t.sol`         | 26                                     | Hardhat and Foundry |
| `gate/PositionLedger.t.sol`         | 8                                      | Hardhat and Foundry |
| `accounts/PolicyGateAccounts.t.sol` | 4                                      | Foundry only        |
| `gate/GateFixture.sol`              | Shared setup for `KeyModel` and `ConfigManager` |                     |
| `gate/mocks/`                       | Test doubles, described in section 6   |                     |
| `*.t.sol` at the top of `test/`     | 144, earlier design                    | Hardhat and Foundry |




### Configuration


| File                | What it is                                                                                                             |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `foundry.toml`      | Foundry build settings: Solidity 0.8.25, EVM `cancun`, optimizer 200 runs. Holds the import remappings ModuleKit needs |
| `hardhat.config.js` | Hardhat build settings, same compiler settings. Loads three separate keys for Base Sepolia, never one                  |
| `remappings.txt`    | One line, for `forge-std`. Both tools read it                                                                          |
| `package.json`      | `npm test` runs the Hardhat suite. Dependencies: Hardhat 3, forge-std 1.9.6, ModuleKit 0.5.9                           |




### `docs/`


| Path                            | Holds                                                                                    |
| ------------------------------- | ---------------------------------------------------------------------------------------- |
| `guide/project-guide.md`        | This file                                                                                |
| `spec/policy-spec-v0.1.md`      | The specification: all six steps, the policies, the decisions table, the build order     |
| `decisions/design-decisions.md` | Every decision taken while building, step by step, with the reason and what was rejected |
| `plan/roadmap.md`               | Status per step and the open decisions                                                   |
| `earlier-design/`               | The previous project's guide, tour, decision log, spec, verifier notes and roadmap       |




### The earlier design, still in the tree

The project that came before this one enforced a rolling cap on daily energy
spend, computed after the fact from meter readings and oracle prices. Its code
is untouched and its tests still pass. It stays until step 4, when sequence
policy S1 covers what it does, and is then removed.


| What                                          | Where                                                                                                                                                                                  |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Contracts                                     | `contracts/PolicyConfig.sol`, `SpendLedger.sol`, `SpendValidator.sol`, `SpendMath.sol`, `PriceOracle.sol`, `MeterReadings.sol`, `SmartAccount.sol`                                     |
| Tests, 144                                    | `test/Authorization.t.sol`, `test/Enforcement.t.sol`, `test/Settlement.t.sol`, `test/Retention.t.sol`, `test/PriceOracle.t.sol`, `test/MeterReadings.t.sol`, `test/Differential.t.sol` |
| Python verifier, 53 tests                     | `verifier/`                                                                                                                                                                            |
| Chain against verifier on real simulator days | `differential/`                                                                                                                                                                        |
| Daily records of the three simulator arms     | `records_B0.csv`, `records_B1.csv`, `records_B2.csv`                                                                                                                                   |


Two pieces of it will be reused: the EIP-712 signature checking in
`MeterReadings.sol`, as the base for oracle verification in step 5, and the
verifier and differential structure, for step 3. Everything about it is
documented in `docs/earlier-design/`.

---



## 6. What the tests prove



### `test/gate/KeyModel.t.sol`: 35 tests

The permission table of section 2, one row at a time, then every escalation
route.


| Group                                    | Tests | What it establishes                                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The path that must work                  | 2     | A registered agent's approved call is made by the account: the market sees the account as caller, not the agent and not the gate. The two events carry the decoded order and the order hash. Two identical calls get different hashes                                                                                                                                                                             |
| Who may submit (A8)                      | 7     | An unregistered caller is rejected. The owner's own key is not an agent. An agent is valid through its last second and rejected one second later. Revocation acts at once. An agent of one account has no authority on another. The account, the gate and the zero address cannot be registered as agents, and an expiry in the past is refused                                                                   |
| What may be submitted (A7)               | 6     | An unapproved function of an approved market is rejected. An unapproved market is rejected. Withdrawing an approval acts at once. Calldata shorter than a selector is rejected. A call its decoder reads as no order, or as more than two legs, is rejected. A market call that reverts reverts the whole submission |
| Escalation: module management            | 5     | The agent cannot call `installModule`, `uninstallModule`, `execute` or `executeFromExecutor` on the account. The account is never accepted as a target, whatever the call. The owner cannot approve the account or the gate as a target either, nor register a zero decoder                                                                                                                                       |
| Escalation: registries and configuration | 7     | Each of the gate's ten owner-path functions refuses the agent directly. The gate is never accepted as a target for any of them, nor is the ledger. The agent cannot write the ledger directly. The policy refuses `configure` from the agent, and from the account itself. A fuzz test sends arbitrary bytes to the account, the gate, the market, the policy and the ledger, 256 runs, and checks afterwards that modules, agents, approvals, ledger writers, policies and parameters are exactly as before |
| Hostile targets                          | 2     | A target that forwards calls, like a multicall contract, carries no authority: what it forwards arrives from the forwarder. A target that is also an agent and calls `submit` again mid-call is stopped by the lock                                                                                                                                                                                               |
| Install and uninstall                    | 6     | The gate reports itself as an executor and nothing else. Installing it grants nobody anything. A stranger who calls `onInstall` gets a private namespace and no hold on the account. Installing twice is refused. Uninstall withdraws the agent, and a reinstall starts empty. Uninstall succeeds even when a policy refuses to drop its state                                                                    |




### `test/gate/ConfigManager.t.sol`: 33 tests

Section 4, rule by rule.


| Group               | Tests | What it establishes                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Adding a policy     | 5     | It applies at once. An invalid first configuration is rejected by event and the policy is not added. The same instance cannot be added twice. The account, the gate and zero cannot be policies. The list stops at 16                                                                                                                                                                                                                                                                            |
| Tightening          | 4     | It applies in the same call. An unchanged configuration counts as tightening. An invalid or malformed configuration changes nothing                                                                                                                                                                                                                                                                                                                                                              |
| Widening            | 13    | It is proposed, not applied. The delay is 24 hours. It cannot be applied one second early and can be applied exactly on time. A change that tightens one cap and loosens the other is a widening. Application needs the proposed bytes exactly. A proposal applies once. A later tightening drops a pending widening; re-proposing restarts the clock; cancel works. A fuzz test tries any pair of caps and any wait shorter than the delay, 256 runs, and checks no looser cap is ever in force |
| Removing a policy   | 7     | Removal waits the delay. A widening proposal cannot be used as a removal proposal or the reverse. Removing one instance leaves the others findable, configurable and removable. A removal proposal replaces a pending widening and says so in the log. A policy that refuses to let go is still removed. An unknown instance cannot be configured or removed                                                                                                                                     |
| Only the owner path | 4     | The agent, a stranger and the owner's key acting directly are all refused on all six configuration functions. The agent cannot finish a widening the owner started, even after the delay. The policy takes configuration through the gate only. One account cannot configure another's instance                                                                                                                                                                                                  |




### `test/gate/OrderLifecycle.t.sol`: 26 tests

Step 2's acceptance criteria, against the real mock market, decoder and ledger,
on 30-minute slots with trading closing one hour before each slot.

| Group | Tests | What it establishes |
| ----- | ----- | ------------------- |
| Place | 4 | A placement books committed volume on its side and slot, with the order's decoder, placement time, quantity and price; the market holds the order under the account. Value is at the limit price, rounded up; a value beyond the type is refused |
| Fills | 3 | A partial fill is booked on reconcile and not before; a full fill closes the order and releases nothing; reconciling with nothing new changes nothing |
| Cancel | 2 | A cancellation releases the unfilled order. A fill nobody has booked yet is booked by the cancellation itself, so only the unfilled rest is released |
| Modify | 5 | A modification decodes as a cancel leg then a place leg. Modifying price, quantity and slot each books correctly; a slot change moves the commitment. The filled part of a modified order stays |
| Expiry | 3 | One second before gate closure a reconcile books fills and the order stays open; at closure the unfilled rest expires and is released. An order cancelled outside the gate closes with its own reason |
| Reconcile is permissionless | 3 | Any address can reconcile through the gate (fuzz test, 256 callers). The ledger itself accepts only the account's writers. A closed or unknown order cannot be reconciled |
| The open-order bound | 1 | The 65th open order is refused and the market never sees it. A modification at the bound goes through. Closing one order makes room for one |
| The agent's own orders | 1 | The agent cannot cancel an order the owner placed directly |
| The market's rules | 3 | No placement at or after gate closure; no cancel or fill after it; fills respect the limit price and the open quantity, and only the operator fills |
| The books balance | 1 | A fuzz test, 256 runs of 24 random steps over three slots: placements, fills, cancellations, modifications, reconciliations and time jumps. After every step, committed equals open quantity plus filled quantity of closed orders, cleared equals booked fills, and the open count matches. Past every gate, reconciling everything leaves committed equal to cleared |

### `test/gate/PositionLedger.t.sol`: 8 tests

The ledger on its own, written by a test address the account appointed. What it
refuses to book, and who may write it: the bound is 64; an order is booked
once; only a placement leg is booked as a placement; a zero quantity is not
booked; a fill beyond the order, or one that goes backwards, is refused; a
withdrawn writer can no longer write; a writer of one account cannot write
another.

### `test/accounts/PolicyGateAccounts.t.sol`: 4 tests

The two files above run against a minimal account written for the tests. This
file repeats the essentials on four real account implementations, built by
Rhinestone's ModuleKit: the ERC-7579 reference account, Safe7579, Nexus and
Kernel. One test per account, same scenario:

1. Create the account and assert which implementation it is, by its own
  `accountId()`. A test that silently ran on the wrong account type would
   otherwise still pass.
2. The owner installs the gate, appoints it as the account's ledger writer,
  registers the agent, approves the market function and adds a policy, all
  through the account.
3. The agent's approved order is executed, and the market sees the account.
4. An unregistered caller and an unapproved function are rejected.
5. The agent tries to install a rogue module and uninstall the gate, by calling
  the account directly and by routing through the gate. Afterwards the rogue
   module is not installed and the gate still is.
6. The agent cannot register another agent or change the configuration.
7. The owner proposes a widening. It is not in force at once. After 24 hours
  the agent still cannot apply it, and the owner can.
8. The owner uninstalls the gate, and the agent's authority is gone.



### The test doubles in `test/gate/mocks/`


| Double            | Stands for                                                                                                                                                                                                                                                                                                  |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MiniAccount`     | The smallest account that behaves like an ERC-7579 account where it matters. Its `owner` stands in for "a user operation the owner signed". It accepts module management from itself, as real accounts do: that self-call is the escalation route the gate must close, so the mock keeps it open on purpose |
| `StubMarket`      | A market that only records who called, for the key-model tests. It has one approved function and one the owner never approves. The real mock market is `contracts/market/MockEnergyMarket.sol` |
| `StubDecoder`     | Reads `StubMarket.placeOrder` as one placement leg |
| `NullDecoder`     | Reads any call as a 1 Wh placement. For targets that are not markets, in the attack tests: every approved call must be an order |
| `CapPolicy`       | A policy with a soft and a hard cap, lower is tighter. Enough to drive every branch of the configuration manager                                                                                                                                                                                            |
| `RelayTarget`     | A forwarding contract, the kind the spec says is never approved                                                                                                                                                                                                                                             |
| `ReentrantTarget` | A target that calls back into the gate                                                                                                                                                                                                                                                                      |




### Do the tests fail when the code is wrong?

A passing suite means nothing if it cannot fail. Each of the following was run
by breaking one line of the gate, running the tests, and restoring the line.


| Run                      | Defects | Result                                                                                                     |
| ------------------------ | ------- | ---------------------------------------------------------------------------------------------------------- |
| Against `test/gate/`     | 51      | 49 caught at first. The 2 that survived were gaps in the tests; two tests were added and all 51 are caught |
| Against `test/accounts/` | 9       | 9 caught                                                                                                   |
| Step 2 code (ledger, gate booking, mock market, decoder) against `test/gate/` | 51 | 41 caught at first. Seven survivors were gaps in the ledger and gate tests; nine tests were added and all seven are caught. The other three are in the mock market, which is to be replaced by a port of the P2P market |


One of the nine is worth knowing. When the gate declares itself a validator
instead of an executor, Nexus and the reference account refuse to install it.
Safe7579 and Kernel install it anyway: they do not check a module's declared
type. That is a difference between account implementations to carry into the
security analysis.

The scripts for these runs are not in the repository yet. A committed mutation
suite is part of step 3.

### What the tests do not show

- **That only the owner can make the account act.** ModuleKit's default
validator accepts any signature, and `MiniAccount` simply trusts its `owner`
address. "Root validator belongs to the owner alone" is a property of how the
account is deployed, and no test here asserts it.
- **Anything about policies limiting orders.** No order is checked against a
policy until step 4.
- **A real market.** Fills come from an operator address, not from matching
between orders.
- **Behaviour on a network.** There is no deployment script and nothing is
deployed.
- **Gas.** Not measured for the gate yet.

---



## 7. Runbook



### Setup, once

```bash
npm install
```



### The Hardhat suite

Expect **246 passing** in under a minute: 102 for the gate (35 key model, 33
configuration, 26 order lifecycle, 8 ledger), 144 for the earlier design.

```bash
npm test
```

`npm test` names its test files, so it leaves out `test/accounts/`. ModuleKit
does not build under Hardhat.

### Everything, under Foundry

Expect **250 passed**: the 246 above plus the four real-account tests.

With Foundry installed and allowed to run:

```bash
npm run test:forge
```

On the development machine Windows Smart App Control blocks `forge.exe`, so
Foundry runs in its official container instead. Start Docker Desktop, then from
the repository root in PowerShell:

```powershell
docker run --rm -v "${PWD}:/repo" -v foundry-svm:/home/foundry/.svm -w /repo --entrypoint forge ghcr.io/foundry-rs/foundry:v1.8.5 test
```

Three things to know about that command:

- **The image** is pinned to Foundry 1.8.5.
- **The** `foundry-svm` **volume** keeps the downloaded Solidity compiler between
runs. It must be owned by user id 1000, the container's user. A volume
created fresh is owned by root, and `forge` then stops with "Permission
denied".
- **Seven** `error:` **lines** appear after "Compiler run successful", all about
ModuleKit's `UserOpGasLog.sol`. They come from Foundry's lint pass over a
ModuleKit helper this project does not use. They affect neither the build nor
the tests.

To run only the real-account tests, add `--match-path "test/accounts/*"` at the
end.

### Seeing a test fail

In `contracts/gate/PolicyGate.sol`, delete this line from `submit`:

```solidity
if (_isForbiddenTarget(account, target)) revert PolicyGate_ForbiddenTarget(target);
```

Run `npm test`. **Two tests fail:** `test_accountIsNeverATargetWhateverTheCall`
and `test_gateIsNeverATargetWhateverTheCall`. Put the line back.

### The earlier design's checks

Still runnable, and they still pass: 53 verifier tests, and the differential
with 0 disagreements between chain and verifier.

```bash
python -m unittest discover -s verifier -p "test_*.py"
```

```bash
python differential/run_diff.py
```

---



## 8. What comes next


| Step | Adds                                                                                                                                                                                                            |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3    | `WindowLib` with the five window classes. A Python verifier that recomputes every window by brute force from the event log. A committed mutation suite                                                          |
| 4    | The check and commit phases of `submit`. Per-action policies, the owner budget S1, export and import caps S2, the cancellation quota S6. The earlier design is removed here                                     |
| 5    | Signed oracle readings, the PV relay, deliverability S3, battery cycles S4, ramp S5                                                                                                                             |
| 6    | The attack matrix against all baselines, the false-positive rate on honest arms, gas                                                                                                                            |


**Before step 4:** decide D1, the agent's entry point
(`docs/analysis/delegation-architecture.md`). Step 4 plugs the policies into
it, so changing it afterwards costs much more.

Decisions taken in steps 1 and 2 are proposed and not yet confirmed. The open
ones are listed at the end of `docs/decisions/design-decisions.md`.