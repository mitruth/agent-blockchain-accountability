# Project guide

What the project contains today, what every file does, what the tests prove,
and how to run everything. Current as of 2026-10-14: steps 1 and 2 of 6 are
built, step 2 on a port of Dan's P2P energy flexibility market.


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
| 2    | Position ledger, reconcile, the P2P market port and its decoder | **Built and passing** |
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
- **The P2P energy market, ported from Dan's BRIGHT and DEDALUS projects:** a
market manager, market sessions, one prosumer contract per prosumer, a lockable
ERC-1155 token for payment and energy, and the 10% settlement rule. Section 3
ends with how it works.
- **A decoder for the prosumer contract:** the adapter through which the gate
reads the market's order calls and fills.
- `reconcile`**:** brings an order up to date with the market. Anyone may
call it.



### What does not exist yet

**No policy checks an order yet.** Today an order from a registered agent to an
approved market function is executed and booked in the ledger. Policies can be
added and configured, but `submit` does not consult them until step 4. There
is no oracle and no sequence policy. Nothing is deployed to a network.

Two roles of the market are outside the repository by design: the off-chain
matching service, linked to the chain by an oracle, which registers trades; and
the trusted sensors that report measured energy. The tests play both.

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

In the ported market, trading in a session closes before delivery. The
off-chain matcher then registers trades, which fill orders partly or fully, and
finalises the session. The ledger learns of fills when the order is
**reconciled**: `PolicyGate.reconcile(account, market, orderId)`, which anyone
may call. Every quantity comes from the market through the order's decoder.

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
| `EXPIRED` | Its session was finalised with part of it unmatched, as the market reports | The unfilled rest |
| `CLOSED_ELSEWHERE` | The market no longer holds it open for another reason, for instance the owner cancelled it directly | The unfilled rest |

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

### The market behind the gate

The market is a port of the P2P energy flexibility market of Dan's thesis,
chapter 3, as built in BRIGHT and DEDALUS: same roles, same phases, ERC-1155
template, no encryption. `docs/analysis/market-structure.md` says what was kept,
changed and dropped; decisions 2.20 to 2.52 say why.

```
agent ──submit──▶ PolicyGate ──▶ smart account ──▶ Prosumer ──▶ MarketSession
                                 (owner of Prosumer)
matcher ──registerTrades, finalise──▶ MarketSession ──▶ both Prosumers
sensor ──settle──▶ Prosumer ──penalty──▶ MarketManager
operator ──register prosumers, matcher, prices, open sessions──▶ MarketManager
```

| Contract | Role |
| -------- | ---- |
| `MarketManager` | Registers prosumer contracts with their sensors and makes them energy minters; registers the matcher; sets the real-time price; opens sessions. Slot length is fixed at deployment, so every session sits on one slot grid |
| `MarketSession` | One session: a first slot, a number of slots (24 for day-ahead, 6 for an intraday run) and a closing time before delivery. Holds the orders; takes trades from the matcher after it closes; finalised by the matcher |
| `Prosumer` | One per prosumer, owned by its smart account. Places batches of bids or offers, cancels and modifies until the session closes, locks collateral, holds commitments per slot, is settled |
| `LockableERC1155` | Id 0 is the payment token; every other id an energy token, minted per offer. Payment balances can be locked, and only the named unlocker releases them |
| `ClassicSettlement` | Within 10% of the commitment, no penalty; beyond it, the whole deviation at the real-time price |

Money and energy:

- **A bid** locks quantity × its limit price. A match pays the seller at the
  trade price out of it. What is left comes back when the bid is fully matched,
  cancelled or expires.
- **An offer** mints its energy token to the account and locks quantity × the
  real-time price as a delivery guarantee. A match moves the energy token to
  the buyer; the matched part's collateral is held until the slot is settled.
- **A trade** names two order ids, a quantity and a price. Buyer, seller, slot
  and token are read from the stored orders. Both limit prices must hold, and
  an account cannot trade with itself.
- **Expiry**: once the session is finalised, anyone calls `expire(order)` to
  release an unmatched remainder and burn an offer's unmatched energy.
- **Settlement**: after a slot ends, the prosumer's sensor reports measured
  export and import. Committed net export (sold − bought) is compared with
  measured net export. The penalty goes to the manager from the delivery
  collateral first, then from the account's balance; what cannot be collected
  is reported, never reverted.

Setting up an account for the agent, all on the owner path:

1. Install the gate; appoint it ledger writer; register the agent.
2. On the token: a payment allowance for the account's prosumer contract, and
   approval over its energy tokens.
3. On the gate: approve the four order functions of the prosumer contract
   (`placeBids`, `placeOffers`, `cancelOrder`, `modifyOrder`) with the
   `ProsumerDecoder`. The token is never approved as a target.

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




### `contracts/market/`: the P2P market

| File | What it does |
| ---- | ------------ |
| `MarketManager.sol` | The operator's contract: prosumers and their sensors, the matcher, the real-time price, sessions, the slot length |
| `MarketSession.sol` | One session's orders, cancellations, trades, finalisation and expiry |
| `Prosumer.sol` | One prosumer's orders, collateral, commitments per slot and settlement |
| `LockableERC1155.sol` | Payment (id 0) and energy tokens, with locks |
| `EnergyTokenIds.sol` | The energy token id: minter, slot start time, energy type, counter |
| `ClassicSettlement.sol` | The 10% settlement rule, and the interface a settlement rule implements |
| `MarketTypes.sol` | Session configuration, order requests, orders, trades, valuation |
| `ProsumerDecoder.sol` | The gate's adapter to `Prosumer`: calls as legs, fills and expiry from the sessions |

### `contracts/demo/`

| File | What it is |
| ---- | ---------- |
| `MiniAccount.sol` | The smallest account that behaves like an ERC-7579 account where the gate needs it. For tests and the local system only: it stands in for a real account (Safe7579, Nexus, Kernel) and validates no signatures of its own |

### `scripts/demo/`: the system on a local node

| File | What it does |
| ---- | ------------ |
| `prosumers.json` | Who takes part: each prosumer's name, whether an agent trades for it, its starting funds; and the slot length, real-time price, leg limit and agent validity |
| `deploy.js` | Deploys the market and the gate, then one smart account and prosumer contract per prosumer; registers them, funds them, sets every approval, installs the gate and registers the agent where there is one. Writes `deployments/local.json` |
| `matcher.js` | The off-chain matching service. `matchOrders` is the rule, a pure function you can replace; `runMatcher` reads a closed session, registers the trades and finalises it |
| `flow.js` | One market day, from opening the session to settlement, printing each stage |
| `lib.js` | Connection to the node, test keys by index, compiled contracts, transactions that report the contract's own error when they revert |

### `contracts/interfaces/`


| File                            | What it declares                                                                                                                                             |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `IERC7579.sol`                  | The two pieces of the ERC-7579 standard the gate needs: the module hooks and `executeFromExecutor`. Declared locally so the gate imports no external library |
| `IOrderDecoder.sol`             | The adapter to one market: `decode` into legs, `placedOrderIds`, `fillState`, `gateTime`. One decoder per approved market contract |
| `IPolicy.sol`                   | The configuration side of a policy: `classifyConfig`, `configure`, `deconfigure`. The order-checking side arrives in step 4                                  |
| `IModule.sol`, `IValidator.sol` | Earlier design                                                                                                                                               |




### `test/`


| Path                                | Tests                                  | Runs under          |
| ----------------------------------- | -------------------------------------- | ------------------- |
| `gate/KeyModel.t.sol`               | 36                                     | Hardhat and Foundry |
| `gate/ConfigManager.t.sol`          | 33                                     | Hardhat and Foundry |
| `gate/OrderLifecycle.t.sol`         | 26                                     | Hardhat and Foundry |
| `gate/PositionLedger.t.sol`         | 8                                      | Hardhat and Foundry |
| `market/LockableERC1155.t.sol`      | 23                                     | Hardhat and Foundry |
| `market/MarketFlow.t.sol`           | 40                                     | Hardhat and Foundry |
| `market/GatedMarket.t.sol`          | 12                                     | Hardhat and Foundry |
| `market/ClassicSettlement.t.sol`    | 6                                      | Hardhat and Foundry |
| `market/MarketFixture.sol`          | Shared setup for the market tests |                     |
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
| `package.json`      | `npm test` runs the Hardhat suite; `npm run node`, `demo:deploy`, `demo:flow`, `demo:match` run the local system. Dependencies: Hardhat 3, viem, OpenZeppelin 5.6.1, forge-std 1.9.6, ModuleKit 0.5.9 |




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



### `test/gate/KeyModel.t.sol`: 36 tests

The permission table of section 2, one row at a time, then every escalation
route.


| Group                                    | Tests | What it establishes                                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The path that must work                  | 2     | A registered agent's approved call is made by the account: the market sees the account as caller, not the agent and not the gate. The two events carry the decoded order and the order hash. Two identical calls get different hashes                                                                                                                                                                             |
| Who may submit (A8)                      | 7     | An unregistered caller is rejected. The owner's own key is not an agent. An agent is valid through its last second and rejected one second later. Revocation acts at once. An agent of one account has no authority on another. The account, the gate and the zero address cannot be registered as agents, and an expiry in the past is refused                                                                   |
| What may be submitted (A7)               | 7     | An unapproved function of an approved market is rejected. An unapproved market is rejected. Withdrawing an approval acts at once. Calldata shorter than a selector is rejected. A call its decoder reads as no order, or as more than `maxLegs` legs, is rejected; `maxLegs` is at least 2. A market call that reverts reverts the whole submission |
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

The ledger against the mock market in `test/gate/mocks/`, on 30-minute slots
with trading closing one hour before each slot. These were step 2's acceptance
tests before the port. They stay because the mock fills orders before trading
closes, so they reach ledger paths the ported market never does (decision
2.51).

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

### `test/market/LockableERC1155.t.sol`: 23 tests

The token on its own: who mints payment and energy; the energy id carries its
minter, slot and type; a locker uses up the owner's allowance once and a
stranger cannot lock anyone's balance; only the named unlocker releases, with or
without payment, and only up to the lock, tied to its owner; no locked payment
moves, by the owner, by an operator approved for all, or in a batch (with a
fuzz test, 256 runs); energy is burned by its holder or an approved operator,
payment never.

### `test/market/MarketFlow.t.sol`: 40 tests

The market on its own, owners as plain addresses, phase by phase.

| Group | Tests | What it establishes |
| ----- | ----- | ------------------- |
| Orders and collateral | 6 | A batch of bids locks each at its limit price; an offer mints its energy and locks at the real-time price; order ids are unique across sessions; orders outside the session, of zero quantity or price, after closing or beyond the balance are refused |
| Cancel and modify | 5 | A cancellation releases collateral and burns an offer's energy; only the order's own prosumer contract can cancel it in the session; none after closing; a modification replaces price, quantity and slot, and an offer's energy token with it |
| Matching | 11 | A trade pays the seller at the trade price, delivers the energy and commits both; a fully matched bid releases its over-reservation; only the matcher, only after closing; limits, the quantities of both orders, slots, self-trades and cancelled orders are checked; partial payments never exceed the collateral |
| Finalisation and expiry | 5 | Expiry releases the unmatched part and burns unmatched energy; nothing before finalisation; nothing for a fully matched order; no trade after finalisation; only the matcher or operator finalises |
| Settlement | 7 | Within 10%, no penalty; a short delivery is penalised from the collateral; a buyer's penalty comes from its balance; an uncollectable penalty is a shortfall, not a revert; only the sensor, only after the slot, only once, only with a commitment |
| Sessions | 2 | An intraday session of six slots; a session must close before delivery and have 1 to 96 slots |
| Who may call what | 4 | Only the owner orders; only the order's session calls back; only registered prosumers place; only the operator runs the manager |

### `test/market/GatedMarket.t.sol`: 12 tests

The whole system: an agent trades for Alice through PolicyGate on the ported
market; Bob is the counterparty. A day-ahead batch of 24 bids is 24 legs and 24
booked orders; a leg's value rounds up; a batch beyond `maxLegs` is refused; offers book as sells;
cancel and modify through the gate; fills are booked on reconcile and the rest
expires at finalisation; a fully matched order closes as filled; the ledger
expires without the market's `expire` call; an order the owner cancels directly
is closed elsewhere; the agent has no direct route into the market or the
token. A fuzz test, 256 runs of random trading and matching, checks after every
step that the ledger's books balance, and at the end that the ledger and Alice's
prosumer contract agree slot by slot on what she bought and sold.

### `test/market/ClassicSettlement.t.sol`: 6 tests

The settlement rule at its edges: the threshold is 10%; exactly 10% costs
nothing; one Wh beyond costs the whole deviation; 16% is penalised; a penalty
rounds up; a commitment that nets to zero tolerates no deviation.

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
| `MiniAccount`     | The smallest account that behaves like an ERC-7579 account where it matters. Its `owner` stands in for "a user operation the owner signed". It accepts module management from itself, as real accounts do: that self-call is the escalation route the gate must close, so the mock keeps it open on purpose. It accepts ERC-1155 tokens, as real accounts do through a fallback handler |
| `StubMarket`      | A market that only records who called, for the key-model tests. It has one approved function and one the owner never approves |
| `MockEnergyMarket`, `MockMarketDecoder` | A per-slot order book whose operator fills orders before trading closes, and its decoder. For the ledger tests of `OrderLifecycle` (decision 2.51) |
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
| Step 2 code (ledger, gate booking, mock market, decoder) against `test/gate/` | 51 | 41 caught at first. Seven survivors were gaps in the ledger and gate tests; nine tests were added and all seven are caught. The other three are in the mock market, now a test double |
| The market port (token, session, prosumer contract, manager, settlement rule, decoder) against `test/market/` and the gate tests | 54 | 48 caught at first. The six survivors were tests that never reached an edge: a direct cancel on the session, a bid over-matched, exactly 10%, a 16% deviation, rounding of a penalty and of a leg's value. Six tests were added and all 54 are caught |


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
- **Matching and metering, for real.** The matcher in `scripts/demo/` is a
simple double auction, and the sensors report values the flow script makes up.
No real meter is connected.
- **The market on real accounts.** The market tests use `MiniAccount`; the
real-account tests of `test/accounts/` do not yet trade.
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

Expect **328 passing** in about a minute: 184 for the gate and the market (36
key model, 33 configuration, 26 order lifecycle on the mock market, 8 ledger, 23
token, 40 market flow, 12 gated market, 6 settlement rule), 144 for the earlier
design.

```bash
npm test
```

`npm test` names its test files, so it leaves out `test/accounts/`. ModuleKit
does not build under Hardhat.

### Everything, under Foundry

Expect **332 passed**: the 328 above plus the four real-account tests.

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

### Running the system on a local node

Everything above is tests. This runs the whole system as separate programs on
a local Hardhat node: the operator, three prosumers with smart accounts, two of
them with agents, the matcher, a keeper and the sensors. Test keys only, from
Hardhat's public mnemonic; no network, no cost.

In one terminal, start the node and leave it running:

```bash
npm run node
```

In another, deploy. This writes `deployments/local.json` with every address:
it replaces the database of the earlier projects.

```bash
npm run demo:deploy
```

Then run one market day:

```bash
npm run demo:flow
```

What it does and prints, stage by stage:

1. **The operator opens a day-ahead session.**
   - Delivery is a whole day, 00:00 to 24:00 Brussels time.
   - Trading closes at 12:00 the day before.
   - The script takes the first day whose trading is still open, so a run after
     12:00 trades the day after tomorrow.
   - The day is 24 hourly slots, or 23 or 25 when the clocks change.
2. **Every prosumer places an order for every hour**, one call per side.
   - **Alice's agent** sends 24 bids through the gate in one call (24 legs).
   - **Carol's agent** sends her midday offers and the rest of her day's bids.
   - **Bob** offers every hour himself, through his account, with no agent.
   - The day's profiles are in `flow.js` (`profiles`) and in decision log entry
     2.58.
3. **Alice's agent modifies her 19:00 bid.** This is two legs: a cancel, then a
   place.
4. **Time jumps to the close.** An agent order is now refused, with the market's
   own error: `MarketSession_Closed`.
5. **The matcher reads the session, matches it and finalises it.** The trades
   are printed hour by hour: who bought from whom, how much, and at what price.
6. **A keeper expires every unmatched remainder and reconciles the ledger.**
   Then, for every hour, the ledger is compared with the prosumer contracts'
   commitments.
7. **Time jumps past delivery, and each prosumer's sensor settles its hours.**
   - Bob delivers 80% at 19:00 and pays a penalty.
   - The others deliver within 10% and pay none.
   - The script prints each prosumer's day: bought, sold, paid, penalties.
8. **Final balances:** who paid whom, and what the manager collected.

The node's clock starts at the real time. The flow moves it forward, so a
second run on the same node trades a later day. Restart the node to come back
to today.

Each run opens a new session, so the flow can be run again on the same
deployment. A run that stops half-way leaves its session's orders locked;
deploy again for a clean slate.

The matcher can also be run on its own, for the current session once it has
closed:

```bash
npm run demo:match
```

Finding things without a database: from an account,
`MarketManager.prosumerOf(account)` gives its prosumer contract;
`Prosumer.owner()` goes back; `PolicyGate.agentValidUntil(account, agent)`
says whether an agent may act for it; the events `ProsumerRegistered` and
`AgentRegistered` are indexed by account and by agent.

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