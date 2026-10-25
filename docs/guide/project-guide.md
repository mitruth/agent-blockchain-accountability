# Project guide

What the project contains today, what every file does, what the tests prove,
and how to run everything. Current as of 2026-10-22: v0.1 steps 1 to 5 are
built, and v0.2 step 1 of 8 (`docs/spec/policy-spec-v0.2-gap-policies.md`,
Section 11.6): A1's rated-power term and minimum order, S3's floor by hour of
day, positions summed on one slot grid across markets, the tariff, meter,
envelope and grid-state oracles, and distinct trust anchors. Step 2 adds the session circuit
breaker G1 and the recipient lock A9, both in the gate. Step 3 adds the
tariff-relative price band A3T and the dominated-trade budget S7.


| For                                     | Read                                 |
| --------------------------------------- | ------------------------------------ |
| What must be built, all six steps       | `docs/spec/policy-spec-v0.1.md`      |
| What v0.2 adds, and its build order     | `docs/spec/policy-spec-v0.2-gap-policies.md`, Section 11 |
| Why each thing was built the way it was | `docs/decisions/design-decisions.md` |
| Status and what comes next              | `docs/plan/roadmap.md`               |


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


| Step | Content                                                                     | Status                |
| ---- | --------------------------------------------------------------------------- | --------------------- |
| 1    | The gate, the key model, the registries, configuration                      | **Built and passing** |
| 2    | Position ledger, reconcile, the P2P market port and its decoder             | **Built and passing** |
| 3    | `WindowLib`, independent verifier, mutation suite                           | **Built and passing** |
| 4    | The session entry point, the policy phases; per-action policies, S1, S2, S6 | **Built and passing** |
| 5    | Oracle verification, PV relay, S3, S4, S5                                   | **Built and passing** |
| 6    | Evaluation                                                                  | Folded into v0.2 step 8 |

v0.2 (Section 11.6 of its spec), one branch per step:

| Step | Content | Status |
| ---- | ------- | ------ |
| 1 | C1–C5, the four new oracle kinds, signer distinctness | **Committed** `7b4c8d7` (`v0.2/1-oracles-aggregation`) |
| 2 | G1 session circuit breaker, A9 recipient lock | **Committed** `9bc3c52` (`v0.2/2-breaker-recipient`) |
| 3 | Tariff-relative price band A3T, dominated-trade budget S7 | **Built and passing** (`v0.2/3-tariff-band`) |
| 4 | Same-slot round-trip quota S8 | Not started |
| 5 | Delivery reconciliation S9, `poke`, calibration | Not started |
| 6 | Operating envelope S10 | Not started |
| 7 | Grid-state direction gate A10 | Not started |
| 8 | Evaluation | Not started |




### What exists today, precisely

- `PolicyGate`**:** an ERC-7579 executor module. It is the only way the agent
can make the account do anything.
- **The agent's session** (decision D1): a Rhinestone Smart Session on the
account, or its stand-in in `MiniAccount`, that lets the agent have the account
call the gate's `submit` and nothing else, until it expires or is removed.
- **A call allowlist:** which function of which market contract the agent may
call.
- **A configuration manager:** the list of policies per account, with the
rule "tighten now, widen after 24 hours".
- **The policy phases** (step 4.2): every policy instance checks every
submission before it reaches the market, all legs at once. A rejection is
recorded on chain without reverting and leaves nothing behind; a soft-bound
crossing is flagged and goes ahead; released volume is credited back.
- **The policies of step 4**, in `contracts/policies/`:
  - `StaticOrderPolicy`, the per-action bounds A1 to A4 and A6: quantity
  (at most min(maxQtyWh, rated power × slot length), at least minQtyWh),
  value, price floor and ceiling, blocked hours, horizon; and, when the owner
  turns it on, A3T, a band around the signed tariff of the order's slot (v0.2
  step 3).
  - `DominatedTradePolicy`, S7 (v0.2 step 3): over a sliding week, the value
  given away by buying above retail or selling below feed-in.
  - `WindowPolicy`, S1 (the owner's budget, BUY value) and S2 (the export and
  import caps, Wh), on `WindowLib`.
  - `CancelQuotaPolicy`, S6: cancelled volume weighted near the gate, the
  cancel-to-place ratio and the message count.
  - `DeliverabilityPolicy`, S3 (step 5.3): the battery, from its signed
  reading, must be able to deliver every sale over the next k slots, counting
  only certain energy: the PV forecast and filled bids. Its floor may differ
  by UTC hour (v0.2, C3).
  - `CyclePolicy`, S4 (step 5.4): the battery's discharge over a sliding day,
  from its signed odometer, plus what the sales placed will draw, against
  N_max cycles.
  - `RampPolicy`, S5 (step 5.5): the net position may not jump by more than
  R_max from one slot to the next.
  Section 3 explains what each checks; section 6 shows four attacks blocked.
- **The session circuit breaker G1** (v0.2 step 2, `SessionBreaker`): too many
rejected or flagged submissions within a sliding window suspend the account's
`submit` to cancel-only, until the owner reinstates it or a cooldown runs out.
Opt-in; configured on the owner path, tighten now and widen after 24 hours.
- **The recipient lock A9** (v0.2 step 2): every approved call has a kind. A
call that moves funds must pay the account, an approval must name a market of
the account, and a call that can move funds to someone the decoder cannot name
(the token's `lock`) can never be approved.
- **A position ledger:** every order the agent placed, and per delivery slot
the account's committed and cleared volume, buy and sell, summed over every
market (v0.2, C4). Each account has one slot grid, fixed by its first market; a
market on another grid cannot be registered.
- **An oracle verifier** (step 5.1, v0.2 step 1): the signed readings the
policies rely on: the battery's state from its BMS, the PV forecast, the tariff,
the meter, the DSO's envelope and the grid state. It checks each reading's
signature against the signer the account registered and refuses a stale, future,
reordered or conflicting reading. Meter readings are kept one per slot, in a
ring of 128, in any order once the slot is over. A meter or envelope signer may
not be the BMS or PV signer, and no signer may be a key the owner declared as
the agent's. The agent hands in readings with its order; it cannot register a
signer.
- **The oracles, played from the data** (step 5.2, `offchain/oracle/`): a PV
forecast relay and a BMS for each agent's house. The forecast is the home's
PV from `data/homes/`, actual or yesterday's; the battery replays an honest
arm from `data/arms/` (Alice) or follows a simple battery model. Both sign
EIP-712 readings the verifier accepts. `npm run oracle:post` tries them on
the local node.
- **The P2P energy market, ported from Dan's BRIGHT and DEDALUS projects:** a
market manager, market sessions, one prosumer contract per prosumer, a lockable
ERC-1155 token for payment and energy, and the 10% settlement rule. Section 3
ends with how it works.
- **A decoder for the prosumer contract:** the adapter through which the gate
reads the market's order calls and fills.
- `reconcile`**:** brings an order up to date with the market. Anyone may
call it.
- `WindowLib`**:** counting over time for the sequence policies, in five
classes: sliding (what the policies use), tumbling, refill, stream and
lifetime (the baselines). Section 6 shows a daily tumbling window admitting
twice its cap across midnight, where a sliding one admits it once.
- **An independent verifier** (`offchain/verifier/`): rebuilds every window,
and the ledger's per-slot totals across markets, from the event log, recomputes
them by a different algorithm, then compares every figure the chain reported.
- **A mutation suite** (`offchain/mutation/`): 201 deliberate defects, each of
which must make a test fail. The last full run caught 189 of the 192 that run
under Hardhat; the other 3 are faults in test doubles.



### What does not exist yet

The tariff oracle exists (v0.2 step 1), but no policy reads it yet: A3's price
bounds stay absolute until A3T (v0.2 step 3). Likewise the meter, envelope and
grid-state oracles wait for S9, S10 and A10. Nothing is deployed to a network. The false-positive rate on honest agents, the full attack
matrix and the monolithic gas variant are step 6.

Two roles of the market are outside the repository by design: the off-chain
matching service, linked to the chain by an oracle, which registers trades; and
the trusted sensors that report measured energy. The tests play both.

**Decision D1 is settled and built (step 4.1):** the agent holds a Rhinestone
Smart Session scoped to the gate's `submit`, and the policies stay in the gate.
See `docs/analysis/delegation-architecture.md`, section 10.

---



## 2. The key model

The agent holds no key that can sign for the prosumer account. That is the
foundation. Step 1 established it with an agent registry in the gate; step 4.1
replaced the registry with a session on the account (decision D1, option 3).

```
OWNER PATH (configuration)

  owner key ── signs a user operation ──▶ account's root validator
                                              │
                                              ▼
                                          the account ── calls ──▶ PolicyGate
                                                                   approve a market call
                                                                   add or configure a policy
                                          the account ── enables ──▶ the agent's session

AGENT PATH (orders)

  agent key ── signs a user operation ──▶ the agent's Smart Session
                                              │  allows one call: PolicyGate.submit
                                              ▼
                                          the account ── calls ──▶ PolicyGate.submit(target, callData)
                                                                     │  checks the target, the function
                                                                     ▼
                                          account.executeFromExecutor ── calls ──▶ market
```

On both paths the gate's caller is the account. What separates them is **what
each key may make the account call**:

- **The owner's key** passes the account's root validator, which may make the
account call anything.
- **The agent's key** passes only its session, which lets it make the account
call the gate's `submit` and nothing else: no other function of the gate, not
the market, not the account itself. The session expires at a set time and the
owner can remove it at once.
- **Signing.** The session has no ERC-7739 content and no ERC-1271 policy, so
the agent cannot sign anything for the account, a token permit for instance.

So `submit` accepts any account with the gate installed, and every other
function the gate guards the same way is, in effect, the owner path.

**Given up by this design.** The gate sees the account, not which key asked.
The owner's own `submit` is booked, and from step 4.2 checked, like the
agent's.

### Who may do what


| Actor           | May                                                                                                                                                                                                                                    | May not                                                                                                                                                                                                                                                                             |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Owner**       | Install and uninstall the gate; give and remove the agent's session; approve and withdraw market calls; add, configure and remove policies; appoint who writes the account's positions; submit orders itself, checked like the agent's | Approve the account itself, the gate or the ledger as a target. Loosen a policy or remove one without the 24-hour wait                                                                                                                                                              |
| **Agent**       | Through its session, while it is valid, have the account call `submit` on approved calls; cancel or modify the orders placed through the gate                                                                                          | Call anything but `submit` through its session; sign for the account; install or uninstall a module; write any registry or the ledger; configure a policy; widen its own session; touch an order not placed through the gate; reach any of those by routing a call through the gate |
| **Anyone else** | Nothing on this account                                                                                                                                                                                                                | Everything                                                                                                                                                                                                                                                                          |




### The four doors, and how each is closed

An agent that wanted more authority would aim at one of four things.


| Target of the attack                                  | Why it would work if open                                                                                                                                                     | How it is closed                                                                                                                  |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| The account's own module management, and its sessions | Real accounts accept `installModule` and session changes from themselves. `submit` makes the account call things. So `submit` with the account as target would be a self-call | The agent's session does not name the account. `submit` refuses the account as a target, and the allowlist refuses to register it |
| The gate's registries                                 | A call from the account to the gate arrives on the owner path                                                                                                                 | The agent's session names `submit` only. `submit` refuses the gate as a target, and the allowlist refuses to register it          |
| A policy's parameters                                 | A looser cap is as good as no cap                                                                                                                                             | A policy accepts `configure` from the gate only, and the gate calls it only on the owner path                                     |
| The ledger's list of writers                          | The ledger appoints writers on the word of the account. A call from the account to the ledger would let the agent appoint itself                                              | `submit` refuses the ledger as a target                                                                                           |


---



## 3. How an order flows today

Through its session, the agent has the account call
`PolicyGate.submit(target, callData, readings)`. The spec's full flow has eight steps
(Section 4.1). This is what is built of it.


| Spec step | What it is                                                                                           | Built?                                                                                                    |
| --------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 1         | The agent is authorised, unexpired and unrevoked                                                     | Yes, by its session on the account; the gate checks that the caller is an account with the gate installed |
| 2         | The pair (target, function selector) is on the allowlist; its decoder turns the call into an `Order` | Yes, as one or two legs                                                                                   |
| 3         | Verify signed oracle readings                                                                        | Yes (step 5.1): each reading handed in is accepted by the oracle verifier, or the submission reverts      |
| 4         | Check phase: every policy inspects the order                                                         | Yes (step 4.2): every instance, all legs at once                                                          |
| 5         | Aggregate: execute, flag or reject                                                                   | Yes: any REJECT stops the submission without reverting; a FLAG is logged and goes ahead                   |
| 6         | Commit phase: update policy state and the position ledger                                            | Yes: policies before the market call, the ledger after it                                                 |
| 7         | The account calls the market                                                                         | Yes                                                                                                       |
| 8         | Emit the outcome                                                                                     | Yes: `OrderSubmitted`, a `PolicyResult` per instance, `PolicyFlag`s, then `Executed` or `Rejected`        |


In order, `submit` does this:

1. Reverts with `Gate_NotInstalled` unless the caller is an account with the
  gate installed. The agent reaches this only through its session.
2. Reverts with `PolicyGate_CallDataTooShort` if the call has no selector.
3. Reverts with `PolicyGate_ForbiddenTarget` if the target is the account, the
  gate, the ledger, the oracle verifier or the zero address.
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
7. **Readings.** Hands each signed reading the call brought, at most four, to
  the oracle verifier. A reading it refuses (wrong signer, stale, from the
  future, older than the last from that device) reverts the submission, and so
  does a reading for another account. The policies then read the latest from
  the verifier, whether it came with this order or an earlier one.
8. **Check.** Asks every policy instance of the account to check all the legs
  at once, and emits each one's `PolicyResult`: its quantity before and after,
  its soft and hard bounds, and its verdict. A FLAG also emits `PolicyFlag`.
  If any instance says REJECT, emits `Rejected` and **returns without
  reverting**: nothing is committed, booked or sent, and the refusal stays in
  the log. A policy whose check reverts reverts the submission.
9. **Commit.** Asks every instance to commit.
10. Asks the account to make the call: one call, zero value, never a batch and
  never a delegatecall. If the market reverts, everything reverts, the commits
  included.
11. Books each leg in the position ledger, in order. A CANCEL leg books any fill
  not yet booked and releases the rest, and the released volume is **credited**
  back to every instance; a PLACE leg reads the new order's id from the
  market's reply and books the order. If the ledger refuses a leg (an order it
  does not hold, or a 65th open order), everything reverts.
12. Emits `Executed`.

A modification is checked as its two legs: the new order needs room before the
old one is credited, which happens only once the market has taken the call.

### What happens to an order after it is placed

In the ported market, trading in a session closes before delivery. The
off-chain matcher then registers trades, which fill orders partly or fully, and
finalises the session. The ledger learns of fills when the order is
**reconciled**: `PolicyGate.reconcile(account, market, orderId)`, which anyone
may call. Every quantity comes from the market through the order's decoder.

Per account and delivery slot the ledger keeps four numbers, in Wh:


| Number                        | Counts                                        | Changes when                                                     |
| ----------------------------- | --------------------------------------------- | ---------------------------------------------------------------- |
| Committed buy, committed sell | Placed and not released, filled part included | Up on placement; down by the unfilled rest when the order closes |
| Cleared buy, cleared sell     | Filled                                        | Up when a fill is booked                                         |


When `reconcile` closes an order with part of it unfilled, an expiry or an
order the market closed for another reason, the released volume is credited
back to every policy instance. A policy whose credit fails keeps the charge,
and `CreditFailed` says so; it cannot block the reconciliation.

A fill counts as cleared only once booked. Until then it stays committed and
is not credited, which is the safe side: the deliverability policy of step 5
credits cleared buys only.

An order closes for one of four reasons, each its own event:


| Reason             | When                                                                                                | Released          |
| ------------------ | --------------------------------------------------------------------------------------------------- | ----------------- |
| `FILLED`           | Fully filled                                                                                        | Nothing           |
| `CANCELLED`        | Cancelled by the agent through the gate                                                             | The unfilled rest |
| `EXPIRED`          | Its session was finalised with part of it unmatched, as the market reports                          | The unfilled rest |
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

### The policies an order meets

An account adds policy instances on the owner path (section 4). Each is one
contract and an id; one contract can serve several instances, for example the
export and the import cap. For every submission, each instance returns a
`CheckResult`: its quantity before and after, its soft and hard bounds, and a
verdict.

`StaticOrderPolicy`**: each order on its own** (spec 6.1). Every PLACE leg is
checked; a cancellation never is.


| Bound          | Rule                                                                             |
| -------------- | -------------------------------------------------------------------------------- |
| A1 quantity    | qtyWh ≤ `maxQtyWh`                                                               |
| A2 value       | value at the limit price, rounded up, ≤ `maxValue`                               |
| A3 price       | SELL at least `sellFloor`; BUY at most `buyCeiling`                              |
| A4 time of day | the slot does not start in an hour blocked for that side (UTC, one bit per hour) |
| A6 horizon     | the slot starts after now and at most `horizonSeconds` ahead                     |


There is no soft bound. The result's `valueAfter` is a bitmask of the bounds
broken: A1 = 1, A2 = 2, A3 = 4, A4 = 8, A6 = 16.

`WindowPolicy`**: the budget S1 and the caps S2** (spec 6.2, 6.3). Each instance
counts one quantity on a `WindowLib` window; the window's cap is the hard bound
H, the instance's `soft` the soft bound S.


| Instance   | Counts                                                                    | Given back on a release                    |
| ---------- | ------------------------------------------------------------------------- | ------------------------------------------ |
| S1, budget | BUY value at the limit price, gross: a sale neither counts nor makes room | Value charged less the filled part's value |
| S2, export | SELL Wh                                                                   | Released Wh                                |
| S2, import | BUY Wh                                                                    | Released Wh                                |


- **Counting.** An order counts when it is placed, in the bucket of that time.
- **Credits.** A release goes back to that bucket, if the window still counts it.
- **Verdicts.** Above S, flagged; above H, rejected.

`CancelQuotaPolicy`**: S6, against spoofing** (spec 6.7). Three windows of one
shape, by default an hour of five-minute buckets:


| Window       | Rule                                                                              |
| ------------ | --------------------------------------------------------------------------------- |
| Cancelled Wh | Weighted w_g within δ_g of the slot's gate closure, once otherwise; at most C_max |
| Placed Wh    | Cancelled at most ρ × placed + c0                                                 |
| Messages     | Every accepted submission; at most M_max                                          |


An expiry is never a cancellation. `reasons()` says which rule a refused
submission broke.

`DeliverabilityPolicy`**: S3, can the battery deliver what was sold** (spec
6.4). From the battery's signed state at the start of the current slot, it
projects the battery over the next k slots, with the submission and without:


| Projection | Comes in                                     | Goes out                       | Must stay                         |
| ---------- | -------------------------------------------- | ------------------------------ | --------------------------------- |
| Floor      | PV forecast × α, and **filled** bids only    | committed sells, reserve load  | at or above the minimum charge    |
| Ceiling    | every placed bid; PV left out (curtailable)  | reserve load                   | at or below the maximum charge    |


Per slot, sells may not exceed the discharge power plus the PV credit, and
bids beyond the reserve load may not exceed the charge power.

- **The value** is what the projection cannot deliver, in Wh: the energy short
  of the floor plus every excess over the ceiling and the power limits.
- **The verdict.** Rejected when the submission leaves a shortfall and makes it
  larger. One that keeps it or reduces it passes, a cancellation always (D10).
  There is no soft bound.
- **What it cannot judge, it refuses:** a placement with no fresh battery
  reading, or for a slot outside the horizon. `valueAfter` is then 2^256 − 1.
  The horizon starts at the reading's slot, so every slot the agent can reach
  is covered.
- **No state of its own.** It reads the ledger's positions and the verifier's
  reading and forecast, one call each (`positionsOf`, `pvSeries`).
- **`assess()`** gives the projection's four parts before and after.

`CyclePolicy`**: S4, how hard the battery cycles** (spec 6.5). Its value, in Wh
drawn from the cells, has three parts:

- **the window:** at every submission the gate accepts, the discharge since
  the last one, from the BMS odometer, goes into a sliding day;
- **what the odometer shows beyond it;**
- **pending:** what the sales placed over the horizon will draw, beyond the PV
  credit, over the discharge efficiency.

The cap is N_max × C_bat. Only a sale is judged: a bid or a cancellation never
is. A sale that takes the value past the soft bound is flagged, past the cap
refused, when the value grew. Discharge enters the window no earlier than it
happened, so the window can only overstate it.

`RampPolicy`**: S5, no spike in the net position** (spec 6.6). netPos(t) is
committed buy minus committed sell. For every slot a submission changes, the
steps to both neighbours are compared, with and without the submission. A step
above R_max is a refusal, above S a flag, but only if the submission made it
larger. An order that smooths a profile already too steep passes, and so does
a cancellation that does not open a steep step.

**Windows other than sliding.** `WindowPolicy` and `CancelQuotaPolicy` accept
any of `WindowLib`'s five classes. Sliding is what the owner should use; the
other four are the evaluation's baselines, and section 6 shows what each lets
through.

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


| Contract            | Role                                                                                                                                                                                                                       |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MarketManager`     | Registers prosumer contracts with their sensors and makes them energy minters; registers the matcher; sets the real-time price; opens sessions. Slot length is fixed at deployment, so every session sits on one slot grid |
| `MarketSession`     | One session: a first slot, a number of slots (24 for day-ahead, 6 for an intraday run) and a closing time before delivery. Holds the orders; takes trades from the matcher after it closes; finalised by the matcher       |
| `Prosumer`          | One per prosumer, owned by its smart account. Places batches of bids or offers, cancels and modifies until the session closes, locks collateral, holds commitments per slot, is settled                                    |
| `LockableERC1155`   | Id 0 is the payment token; every other id an energy token, minted per offer. Payment balances can be locked, and only the named unlocker releases them                                                                     |
| `ClassicSettlement` | Within 10% of the commitment, no penalty; beyond it, the whole deviation at the real-time price                                                                                                                            |


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

1. Install the gate; appoint it ledger writer; give the agent a session whose
  only action is the gate's `submit`.
2. On the token: a payment allowance for the account's prosumer contract, and
  approval over its energy tokens.
3. On the gate: approve the four order functions of the prosumer contract
  (`placeBids`, `placeOffers`, `cancelOrder`, `modifyOrder`) with the
   `ProsumerDecoder`. The token is never approved as a target.

---



## 4. How configuration changes

Everything in this section is on the owner path.

### The agent's session and the approvals

The agent's session is the account's, not the gate's. On a real account it is
a Smart Session, enabled and removed through the Smart Sessions module; on
`MiniAccount`, `enableSession` and `removeSession`. Either acts at once.


| Call (on the gate)                      | Effect                                       | When    |
| --------------------------------------- | -------------------------------------------- | ------- |
| `setDecoder(target, selector, decoder)` | Approves one function of one market contract | At once |
| `removeDecoder(target, selector)`       | Withdraws that approval                      | At once |


The account, the gate, the ledger and the zero address can never be targets.

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


| File                  | What it does                                                                                                                                       |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PolicyGate.sol`      | The executor module. `onInstall`, `onUninstall`; `submit`, the agent's one entry point; `reconcile`, open to anyone. Inherits the four parts below |
| `GateBase.sol`        | Which accounts have the gate installed, the installation generation, the owner-path check (`onlyAccount`), the reentrancy lock                     |
| `DecoderRegistry.sol` | `setDecoder`, `removeDecoder`, `decoderOf`, `kindOf`, `isMarket`; the rule that the account and the gate are never targets; each call's kind (A9) and the slot-grid check (C4) |
| `SessionBreaker.sol`  | G1: the rejected and flagged windows, suspension, reinstatement, and G1's timelocked configuration. Deployed by the gate; only the gate writes it |
| `ConfigManager.sol`   | The policy list, proposals, and the tighten-now, widen-later rule                                                                                  |
| `PositionLedger.sol`  | Every booked order and the per-slot positions. Written only by writers the account appointed                                                       |
| `GateTypes.sol`       | The `Order` and `FillState` structs and the enums `OrderKind`, `Side`, `CallKind`, `ConfigChange`                                                  |




### `contracts/oracle/`: signed readings


| File                 | What it does                                                                                                                                                                                                                        |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OracleVerifier.sol` | One deployment for every account. `setDevice`, on the owner path: the account's BMS and PV signers and how old a reading may be. `accept`, open to anyone: checks a signed reading (EIP-712, low-s), its age, its order, and keeps it. `bmsOf` and `pvAt`: the latest, and whether it is fresh |
| `OracleTypes.sol`    | What the oracles sign: `BmsReading` (state of charge and discharge odometer at a time), `PvForecast` (Wh per slot from a start time), and `SignedReading`, how either travels                                                     |




### `contracts/market/`: the P2P market


| File                    | What it does                                                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `MarketManager.sol`     | The operator's contract: prosumers and their sensors, the matcher, the real-time price, sessions, the slot length |
| `MarketSession.sol`     | One session's orders, cancellations, trades, finalisation and expiry                                              |
| `Prosumer.sol`          | One prosumer's orders, collateral, commitments per slot and settlement                                            |
| `LockableERC1155.sol`   | Payment (id 0) and energy tokens, with locks                                                                      |
| `EnergyTokenIds.sol`    | The energy token id: minter, slot start time, energy type, counter                                                |
| `ClassicSettlement.sol` | The 10% settlement rule, and the interface a settlement rule implements                                           |
| `MarketTypes.sol`       | Session configuration, order requests, orders, trades, valuation                                                  |
| `ProsumerDecoder.sol`   | The gate's adapter to `Prosumer`: calls as legs, fills and expiry from the sessions                               |




### `contracts/policies/`: what the policies share


| File                    | What it does                                                                                                                                                                                                                                           |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `WindowLib.sol`         | A quantity counted over time, in five classes behind one interface: `used`, `limit`, `fits`, `add`, `credit`. Sliding windows are a ring of 64-bit buckets packed four to a storage word, with a running total and an O(1) reset after a long idle gap |
| `PolicyBase.sol`        | What every policy shares: the gate's address and the "only the gate" check                                                                                                                                                                             |
| `StaticOrderPolicy.sol` | A1 to A4 and A6, each order on its own; the result reports the bounds broken as a bitmask                                                                                                                                                              |
| `DominatedTradePolicy.sol` | S7: the value given away against the tariff, per placement at its limit price, on a `WindowLib` window; keeps each placement's excess for its credit |
| `RoundTripPolicy.sol` | S8: Wh bought and sold in the same slot, min(committed buy, committed sell) from the ledger across every market, counted when created on a `WindowLib` window; no credits |
| `GridStatePolicy.sol` | A10: while the grid operator's signed state is an alert, no trading against the grid's need in the slots it covers (DEFICIT: no buying, no withdrawing a sale; SURPLUS the mirror; EMERGENCY: no placing); fails open when the state is stale; stateless |
| `OperatingEnvelopePolicy.sol` | S10: the committed net position per slot, across every market, within the DSO's signed envelope, or the connection's rating when none applies; refuses what makes an excess larger; stateless |
| `DeliveryReconciliationPolicy.sol` | S9: per settled slot, the sale the ledger cleared against the export the meter measured; a CUSUM on the shortfall raises alarms, which narrow selling (level 1 caps it, level 2 stops it); fails closed on a missing reading; moved on by `PolicyGate.poke` |
| `WindowPolicy.sol`      | S1, the budget (BUY value), and S2, the export and import caps (Wh), on a `WindowLib` window per instance                                                                                                                                              |
| `CancelQuotaPolicy.sol` | S6: cancelled Wh weighted near the gate, the cancel-to-place ratio, the message count                                                                                                                                                                  |
| `DeliverabilityPolicy.sol` | S3: the battery projected over the horizon from its signed reading, against the floor, the ceiling and the power limits                                                                                                                             |
| `CyclePolicy.sol`       | S4: discharge from the odometer in a sliding window, plus the pending sales' draw, against N_max × C_bat                                                                                                                                              |
| `RampPolicy.sol`        | S5: the steps of the net position next to every slot a submission changes                                                                                                                                                                             |
| `HorizonLib.sol`        | What S3 and S4 share: the horizon of k slots from the battery reading's slot, and the ledger they read                                                                                                                                                |




### `contracts/harness/`: stand-ins, not part of the system


| File              | What it is                                                                                                                                                                                                                                                                                                                                            |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MiniAccount.sol` | The smallest account that behaves like an ERC-7579 account where the gate needs it, with sessions that stand in for Smart Sessions: a key may have the account call one function of one contract, until a time. For tests and the local system only: it stands in for a real account (Safe7579, Nexus, Kernel) and validates no signatures of its own |
| `ProbeMarket.sol`, `ProbeDecoder.sol`, `ScriptedPolicy.sol` | For the G1 verifier: a market that takes any order, its decoder, and a policy whose verdict a script sets, so a script can make the gate reject, flag or execute at will |
| `LedgerProbeDecoder.sol` | For the ledger verifier: a decoder whose fills a script sets |
| `WindowProbe.sol` | `WindowLib` on its own, as the smallest possible policy: admits an amount if it fits, takes credits for earlier admissions, and emits an event for every call, so the verifier can rebuild each window from the log                                                                                                                                   |




### `offchain/`: the programs around the contracts

All JavaScript, with viem. Unit tests sit beside the code as `*.test.js` (`npm run test:offchain`). Each folder is one package with one job; its
`index.js` is what the others import, and a `cli.js`, where there is one, is
what `npm run` starts. Packages depend on `chain/` and on nothing else, except
`scenarios/`, which uses them all. `dataset/` needs no chain at all; `oracle/`
reads the data that `dataset/` writes.


| Package      | What it does                                                                                                                                                                                                                                                                                               | Started by                          |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `chain/`     | The connection to the local node, the test keys by index, the compiled contracts (deploy, send, read), transactions that report the contract's own error when they revert, the node's clock, `deployments/local.json`, and the units Wh and USD                                                            | imported by every other package     |
| `deploy/`    | Deploys the market and the gate, then one smart account and prosumer contract per prosumer in `prosumers.json`; registers them, funds them, sets every approval, installs the gate and gives the agent its session where there is one. Writes `deployments/local.json`                                     | `npm run demo:deploy`               |
| `matcher/`   | The matching service. `rule.js` is the rule, a pure function you can replace; `index.js` reads a closed session, registers the trades and finalises it                                                                                                                                                     | `npm run demo:match`, or a scenario |
| `keeper/`    | Expires the orders a finalised session left unmatched and reconciles the gate's ledger. Anyone may do both                                                                                                                                                                                                 | a scenario                          |
| `sensor/`    | A prosumer's meter reporting what it measured in a slot, which settles that slot. Where a real meter feed would be connected                                                                                                                                                                               | a scenario                          |
| `scenarios/` | `day-ahead.js`, one market day from opening the session to settlement; `calendar.js`, the Brussels clock and the day-ahead closing time                                                                                                                                                                    | `npm run demo:flow`                 |
| `verifier/`  | The independent check of the windows: `windows.js` defines each class, `guarantees.js` measures spec 5.3's bounds over every interval, `verify.js` replays a history and compares, `fuzz.js` runs random and scripted histories through `WindowProbe`, `selftest.js` tampers with histories it must reject; `ledger.js` replays the ledger's events and sums each slot over every order on every market, `ledger-fuzz.js` drives the ledger through `LedgerProbeDecoder`, `ledger-cli.js` compares and tampers | `npm run verify:window`, `npm run verify:ledger` |
| `mutation/`  | The mutation suite: `catalogs/` holds the defects per part of the system, `index.js` applies one at a time and runs the tests                                                                                                                                                                              | `npm run mutate`                    |
| `oracle/`    | The trusted devices, played from the data: `typed.js` signs EIP-712 BMS readings and PV forecasts as the verifier expects; `battery.js` is a battery as its BMS sees it, a simple model or an honest arm replayed; `forecast.js` gives the PV forecast, actual or yesterday's; `relay.js` posts and reads them on the chain; `play.js` gives one house's battery and forecast at a point in market time, for the scenario | `npm run oracle:post`, a scenario |
| `dataset/`   | Writes `data/homes/` from Dan's raw HEMS dataset (`index.js`: the six homes' PV and battery, a year of 30-minute slots per home, prices, daily totals, representative days) and `data/arms/` from `Demo_PlanApplyEvaluate` (`arms.js`: the honest controllers' step logs, settings, tasks and results), checking one against the other. Integers only; `decimal.js` reads every digit of the CSVs' decimals exactly, without floating point | `npm run data:extract`              |


`prosumers.json` says who takes part: each prosumer's name, whether an agent
trades for it, its starting funds; the slot length, real-time price, leg limit
and agent validity; and `agentPolicies`, the policies every agent trades under
(`deploy/policies.js` encodes them).

### `contracts/interfaces/`


| File                | What it declares                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `IERC7579.sol`      | The two pieces of the ERC-7579 standard the gate needs: the module hooks and `executeFromExecutor`. Declared locally so the gate imports no external library |
| `IOrderDecoder.sol` | The adapter to one market: `decode` into legs, `placedOrderIds`, `fillState`, `gateTime`, `slotStart`. One decoder per approved market contract              |
| `IPolicy.sol`       | A policy contract: its configuration (`classifyConfig`, `configure`, `deconfigure`) and its order phases (`check`, `commit`, `credit`), spec 4.2             |




### `test/`


| Path                                | Tests                                                 | Runs under          |
| ----------------------------------- | ----------------------------------------------------- | ------------------- |
| `gate/KeyModel.t.sol`               | 38                                                    | Hardhat and Foundry |
| `gate/ConfigManager.t.sol`          | 33                                                    | Hardhat and Foundry |
| `gate/OrderLifecycle.t.sol`         | 26                                                    | Hardhat and Foundry |
| `gate/PositionLedger.t.sol`         | 8                                                     | Hardhat and Foundry |
| `gate/PolicyPhases.t.sol`           | 15                                                    | Hardhat and Foundry |
| `gate/GateReadings.t.sol`           | 14                                                    | Hardhat and Foundry |
| `oracle/OracleVerifier.t.sol`       | 35                                                    | Hardhat and Foundry |
| `oracle/OracleFixture.sol`          | Signing helpers for the oracle tests                  |                     |
| `market/LockableERC1155.t.sol`      | 23                                                    | Hardhat and Foundry |
| `market/MarketFlow.t.sol`           | 41                                                    | Hardhat and Foundry |
| `market/GatedMarket.t.sol`          | 12                                                    | Hardhat and Foundry |
| `market/ClassicSettlement.t.sol`    | 6                                                     | Hardhat and Foundry |
| `policies/WindowLib.t.sol`          | 32                                                    | Hardhat and Foundry |
| `policies/StaticOrderPolicy.t.sol`  | 15                                                    | Hardhat and Foundry |
| `policies/WindowPolicy.t.sol`       | 10                                                    | Hardhat and Foundry |
| `policies/CancelQuotaPolicy.t.sol`  | 9                                                     | Hardhat and Foundry |
| `policies/DeliverabilityPolicy.t.sol` | 29                                                  | Hardhat and Foundry |
| `policies/CyclePolicy.t.sol`        | 16                                                   | Hardhat and Foundry |
| `policies/RampPolicy.t.sol`         | 12                                                    | Hardhat and Foundry |
| `policies/Step5Acceptance.t.sol`    | 21: the attacks and gas as a function of k            | Hardhat and Foundry |
| `policies/Step4Acceptance.t.sol`    | 15: the attacks and gas                               | Hardhat and Foundry |
| `policies/PolicyFixture.sol`        | Shared setup for the policy tests, on the mock market |                     |
| `market/MarketFixture.sol`          | Shared setup for the market tests                     |                     |
| `accounts/PolicyGateAccounts.t.sol` | 4                                                     | Foundry only        |
| `accounts/SessionGate.t.sol`        | 4                                                     | Foundry only        |
| `gate/GateFixture.sol`              | Shared setup for `KeyModel` and `ConfigManager`       |                     |
| `gate/mocks/`                       | Test doubles, described in section 6                  |                     |




### Configuration


| File                | What it is                                                                                                                                                                                                                                                                                                                       |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `foundry.toml`      | Foundry build settings: Solidity 0.8.25, EVM `cancun`, optimizer 200 runs. Holds the import remappings ModuleKit needs                                                                                                                                                                                                           |
| `hardhat.config.js` | Hardhat build settings, same compiler settings. For Base Sepolia, loads the owner's key and the agent's session key from `.env`, never one for both                                                                                                                                                                              |
| `remappings.txt`    | One line, for `forge-std`. Both tools read it                                                                                                                                                                                                                                                                                    |
| `package.json`      | `npm test` runs the Hardhat suite and `test:offchain` the JavaScript tests; `verify:window` runs the verifier, `mutate` the mutation suite; `npm run node`, `demo:deploy`, `demo:flow`, `demo:match` run the local system; `data:extract` writes `data/homes/` and `data/arms/`; `oracle:post` posts readings on the local node; `build` compiles. Dependencies: Hardhat 3, viem, OpenZeppelin 5.6.1, forge-std 1.9.6, ModuleKit 0.5.9 |




### `docs/`


| Path                            | Holds                                                                                    |
| ------------------------------- | ---------------------------------------------------------------------------------------- |
| `guide/project-guide.md`        | This file                                                                                |
| `spec/policy-spec-v0.1.md`      | The specification: all six steps, the policies, the decisions table, the build order     |
| `decisions/design-decisions.md` | Every decision taken while building, step by step, with the reason and what was rejected |
| `plan/roadmap.md`               | Status per step and the open decisions                                                   |
| `reports/`                      | Dated results: the mutation runs and the gas measurements                               |




### The project this one started from

This repository began as a copy of the earlier project, which enforced a
rolling cap on daily energy spend after the fact. S1 now does that before the
fact, on each order. Nothing of the earlier project is left in the tree:

- **Its code:** contracts, 144 tests, Python verifier, differential and key
  scripts. Removed at step 4.7 (spec D13).
- **Its documentation, environment template and Base Sepolia keys:** removed
  afterwards (decision 4.8).

Git keeps all of it: `git show 3c4d84e:<path>` reads any file as it was.

Only its data is kept: the HEMS simulation's daily records of the three
controller arms, in `data/hems/`, for step 6's calibration and false-positive
rate.

### `data/`: the data the project uses

| Folder | Holds | From |
|---|---|---|
| `data/homes/` | The six homes of the HEMS dataset: `homes.csv` (PV, battery capacity, power, state-of-charge limits, efficiencies), and for 2022 a 30-minute file per home (load in parts, PV, net load), the prices, daily totals, and seven representative days in `days/`. Integers: Wh, W, basis points, micro-USD per kWh. Its README gives every column | `npm run data:extract`, from the raw dataset |
| `data/arms/` | What each honest controller did for home_01 in 2022, every 30 minutes: state of charge, charge, discharge, appliances, import, export, prices, cost. Seven arms (B_null, B0, B0star, B1, B2, B2r, B2nn), the settings they ran with, the appliance tasks, daily and annual results. What step 6 replays | `npm run data:extract`, from `Demo_PlanApplyEvaluate/data/` |
| `data/hems/` | The three honest controller arms' daily records for home_01 in 2022 | The arms' step logs, in `Demo_PlanApplyEvaluate` |

**The raw dataset** is in `A Four-Year 30-Minute Simulated Residential HEMS D/` at
the root: six homes, 2020 to 2023, 75 MB. It is git-ignored; only the extract
is committed. Running the extraction twice gives the same files.

Step 5 may reuse the EIP-712 signature checking of its `MeterReadings.sol`, from
git, as the base for oracle verification.

---



## 6. What the tests prove



### `test/gate/KeyModel.t.sol`: 38 tests

The permission table of section 2, one row at a time, then every escalation
route.


| Group                                    | Tests | What it establishes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The path that must work                  | 2     | Through its session, the agent's approved call is made by the account: the market sees the account as caller, not the agent and not the gate. The two events carry the decoded order and the order hash. Two identical calls get different hashes                                                                                                                                                                                                                                                                                                                                       |
| Who may submit (A8)                      | 7     | Only an account with the gate installed may call `submit`: not the agent from its own key, not a stranger. The owner's own submission is the account's, like the agent's. A key without a session cannot make the account submit. The session is valid through its last second and refused one second later. Removing it acts at once. It reaches `submit` and nothing else: not the market, the account, another gate function or the ledger. A session on one account has no authority on another                                                                                     |
| What may be submitted (A7)               | 7     | An unapproved function of an approved market is rejected. An unapproved market is rejected. Withdrawing an approval acts at once. Calldata shorter than a selector is rejected. A call its decoder reads as no order, or as more than `maxLegs` legs, is rejected; `maxLegs` is at least 2. A market call that reverts reverts the whole submission                                                                                                                                                                                                                                     |
| Escalation: module management            | 6     | The agent cannot call `installModule`, `uninstallModule`, `execute` or `executeFromExecutor` on the account, nor widen its own session. The account is never accepted as a target, whatever the call, a session change included. The owner cannot approve the account, the gate or the ledger as a target either, nor register a zero decoder                                                                                                                                                                                                                                           |
| Escalation: registries and configuration | 8     | Each of the gate's eight owner-path functions refuses the agent directly. The gate is never accepted as a target for any of them, nor is the ledger. The agent cannot write the ledger directly. The policy refuses `configure` from the agent, and from the account itself. Two fuzz tests, 256 runs each: arbitrary bytes submitted to the account, the gate, the market, the policy and the ledger; and arbitrary calls through the session, which reach `submit` or nothing. Afterwards modules, sessions, approvals, ledger writers, policies and parameters are exactly as before |
| Hostile targets                          | 2     | A target that forwards calls, like a multicall contract, carries no authority: what it forwards arrives from the forwarder. A target that calls back into the gate's `reconcile` while the account is calling it is stopped by the lock                                                                                                                                                                                                                                                                                                                                                 |
| Install and uninstall                    | 6     | The gate reports itself as an executor and nothing else. Installing it grants nobody anything. A stranger who calls `onInstall` gets a private namespace, where nothing is approved, and no hold on the account. Installing twice is refused. After an uninstall the session reaches nothing, and a reinstall starts empty. Uninstall succeeds even when a policy refuses to drop its state                                                                                                                                                                                             |




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


| Group                       | Tests | What it establishes                                                                                                                                                                                                                                                                                                                                                    |
| --------------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Place                       | 4     | A placement books committed volume on its side and slot, with the order's decoder, placement time, quantity and price; the market holds the order under the account. Value is at the limit price, rounded up; a value beyond the type is refused                                                                                                                       |
| Fills                       | 3     | A partial fill is booked on reconcile and not before; a full fill closes the order and releases nothing; reconciling with nothing new changes nothing                                                                                                                                                                                                                  |
| Cancel                      | 2     | A cancellation releases the unfilled order. A fill nobody has booked yet is booked by the cancellation itself, so only the unfilled rest is released                                                                                                                                                                                                                   |
| Modify                      | 5     | A modification decodes as a cancel leg then a place leg. Modifying price, quantity and slot each books correctly; a slot change moves the commitment. The filled part of a modified order stays                                                                                                                                                                        |
| Expiry                      | 3     | One second before gate closure a reconcile books fills and the order stays open; at closure the unfilled rest expires and is released. An order cancelled outside the gate closes with its own reason                                                                                                                                                                  |
| Reconcile is permissionless | 3     | Any address can reconcile through the gate (fuzz test, 256 callers). The ledger itself accepts only the account's writers. A closed or unknown order cannot be reconciled                                                                                                                                                                                              |
| The open-order bound        | 1     | The 65th open order is refused and the market never sees it. A modification at the bound goes through. Closing one order makes room for one                                                                                                                                                                                                                            |
| The agent's own orders      | 1     | The agent cannot cancel an order the owner placed directly                                                                                                                                                                                                                                                                                                             |
| The market's rules          | 3     | No placement at or after gate closure; no cancel or fill after it; fills respect the limit price and the open quantity, and only the operator fills                                                                                                                                                                                                                    |
| The books balance           | 1     | A fuzz test, 256 runs of 24 random steps over three slots: placements, fills, cancellations, modifications, reconciliations and time jumps. After every step, committed equals open quantity plus filled quantity of closed orders, cleared equals booked fills, and the open count matches. Past every gate, reconciling everything leaves committed equal to cleared |




### `test/gate/PolicyPhases.t.sol`: 15 tests

The gate's check, commit and credit phases, on the mock market, with a test
double, `QtyPolicy`, that counts the Wh placed against a soft and a hard bound.


| Group            | Tests | What it establishes                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ---------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Check and commit | 9     | An accepted submission is committed, then executed, with the instance's result in the log. A soft bound crossed is flagged and executed; the hard bound is inclusive. A rejection returns normally and leaves nothing committed, booked or sent; one instance's rejection stops every instance, and every result is logged. The owner's own submission is checked too. A reverting check or commit reverts the submission. A policy cannot reconcile while the gate commits: the lock refuses it |
| Credits          | 6     | A cancellation passes even at the hard bound and is credited, with the order's placement time, side, slot, quantity and price. A partly filled cancellation credits only the unfilled part. An expiry is credited on reconcile; nothing is credited while the order is still open. A failing credit is recorded and cannot block reconciliation. A modification needs room for the new order before the old is credited                                                                          |




### `test/gate/GateReadings.t.sol`: 16 tests

Readings handed in with an order, through the gate, with a test double,
`FreshBatteryPolicy`, that rejects unless the account's battery reading is
fresh and shows enough stored energy.


| Group                         | Tests | What it establishes                                                                                                                                                                                                                                                          |
| ----------------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Accepted                      | 6     | A reading that comes with an order is accepted and emitted before the policies check, and the policy sees its values. Without a fresh reading the policy rejects. A reading serves later orders until it goes stale; the same reading may come with every order of the slot. A rejected order keeps the genuine reading it brought |
| Refused                       | 6     | A stale, reordered or forged reading reverts the whole submission, and nothing is placed. So does a genuine reading for another account, and a grid state, which names no account. At most four readings per submission                                                    |
| The signer list is out of reach | 4   | The agent cannot have the gate call the verifier -- not to register a signer or a meter, nor to declare or withdraw an agent key -- and the owner cannot approve a decoder for it either. The agent's session cannot call the verifier directly                              |


### `test/gate/SessionBreaker.t.sol`: 22 tests

v0.2, G1, on the mock market under S1 (1 USD a day, flagged above 0.10).

| Group | Tests | What it establishes |
| ----- | ----- | ------------------- |
| Probing and on-off | 5 | **The probing campaign** (spec §7): a binary search for S1's cap finds it to the Wh in 30 probes without G1, and is suspended at the 11th rejection with it, after which it learns nothing. **The on-off agent:** two flagged bids and ten slots of rest are suspended in the third burst at F_max 5; the same bursts a day apart never are. A clean submission never suspends |
| Cancel-only | 4 | While suspended a cancellation passes; a placement and a smaller modification are refused; S6 still judges a cancellation; nothing is counted |
| Reinstatement | 3 | The owner's reinstatement clears both windows; reinstating an active account reverts; a cooldown reinstates at its end, to the second |
| Configuration | 7 | Unconfigured G1 never suspends. Every tightening applies at once; every loosening waits, and applies after the timelock only; a later write drops it; malformed configurations are refused; a reinstall clears the breaker |
| Reach, gas | 3 | The agent cannot reach the breaker or its owner functions; only the gate writes it. Gas with G1 off and on |


### `test/gate/RecipientLock.t.sol`: 16 tests

v0.2, A9 (§11.2), on the mock market's `withdraw` and the market token.

| Group | Tests | What it establishes |
| ----- | ----- | ------------------- |
| Funds moves | 6 | A withdrawal to the agent or a stranger is refused and not made; to the account it is made. The refusal names what was asked. A token transfer to the agent is refused. A refused move trips G1, and while suspended even a withdrawal to the account waits |
| Approvals | 5 | An allowance or approval for a market of the account is made, for anyone else refused. A target stops being a market when its order calls are withdrawn; a call is counted once however often it is registered |
| Registration | 3 | `lock` (a funds move with no decodable recipient), `burnEnergy`, `mintPayment` and the market's `fill` cannot be registered; each call keeps its kind |
| Decoder, gas | 2 | Every recipient the token decoder exposes; gas of a withdrawal made and refused |


### `test/gate/MultiMarket.t.sol`: 13 tests

v0.2, C4: one account on two mock markets.

| Group | Tests | What it establishes |
| ----- | ----- | ------------------- |
| The grid | 8 | The first market fixes the account's grid. A market with another slot length (D15), another origin, an origin shifted by whole slots, or no grid at all is refused. The grid survives a reinstall of the gate. Only a writer fixes a grid, and never one of zero length |
| Positions across venues | 5 | A slot's totals hold both markets' orders. S5 and S3 each pass a sale on either market alone and reject the same sales together |


### `test/oracle/OracleVerifierV2.t.sol`: 35 tests

v0.2, section 4: the four new oracle kinds and signer distinctness.

| Group | Tests | What it establishes |
| ----- | ----- | ------------------- |
| Type strings | 1 | The contract hashes what the EIP-712 type strings say, for all four kinds |
| Tariff | 7 | Accepted and served per slot, only for the slots it covers, until its maximum age. Malformed, future, stale, reordered, conflicting, wrongly signed and high-s tariffs are refused; the same one again is a no-op |
| Envelope | 3 | Served per slot; malformed or stale refused; a new signer drops the schedule held, the tariff's too |
| Meter | 9 | Accepted once its slot has ended, to the second, and in any order. Conflicting, off-grid, too old (one slot past the ring) and wrongly signed readings are refused; the ring evicts a slot one ring later; a new meter drops the old readings |
| Grid state | 6 | Holds until `validUntil`, to the second; inert from another operator or with none registered; bad, future, expired, reordered and conflicting states refused; it takes no maximum age |
| Distinctness | 9 | Meter and envelope signers are neither the BMS nor the PV signer, in both registration orders. No signer of any kind is a declared agent key, and no agent key a registered signer. At most 8 agent keys; withdrawal; removing a signer is always allowed; the tariff may share a signer |




### `test/oracle/OracleVerifier.t.sol`: 35 tests

The verifier on its own. The test fixture computes every EIP-712 digest from
the type strings rather than asking the contract, so a wrong type hash shows up
as a refused signature.


| Group        | Tests | What it establishes                                                                                                                                                                                                                                                                                           |
| ------------ | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Accepted     | 5     | A signed, fresh reading is accepted, emitted in full and stored, whoever hands it in. A reading exactly as old as the maximum is accepted. A newer reading replaces the last. The contract's digests match the type strings                                                                                  |
| Who signed   | 8     | Another key and the PV key are refused for the battery; so are an account with no signer, a tampered reading, the high-s twin of a valid signature, a malformed signature, and a reading signed for another verifier or another chain                                       |
| When         | 9     | A stale reading and one from the future are refused. A reordered reading is refused (the favourable-reading attack). The same reading again changes nothing and emits nothing; a different reading with the same timestamp is refused. The odometer cannot go down. A stored reading goes stale with time. Fuzz: in any order, only newer readings get through |
| The registry | 4     | A new signer drops the old device's reading, and the old key is refused. Removing the signer makes its reading unusable. The maximum age is bounded. Each account has its own registry                                                                                                                       |
| PV forecast  | 8     | A forecast is served slot by slot, and only for slots it covers exactly. It is emitted in full, goes stale after its maximum age, and a newer one replaces it whole. An older one, a malformed one (no slots, slot length zero, more than 96) and one signed by the battery key are refused; 96 slots fit                                       |
| Gas          | 1     | What `accept` costs, printed: a battery reading, a day's and two days' forecast                                                                                                                                                                                                                              |




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

### `test/market/MarketFlow.t.sol`: 41 tests

The market on its own, owners as plain addresses, phase by phase.


| Group                   | Tests | What it establishes                                                                                                                                                                                                                                                                                                 |
| ----------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Orders and collateral   | 6     | A batch of bids locks each at its limit price; an offer mints its energy and locks at the real-time price; order ids are unique across sessions; orders outside the session, of zero quantity or price, after closing or beyond the balance are refused                                                             |
| Cancel and modify       | 5     | A cancellation releases collateral and burns an offer's energy; only the order's own prosumer contract can cancel it in the session; none after closing; a modification replaces price, quantity and slot, and an offer's energy token with it                                                                      |
| Matching                | 11    | A trade pays the seller at the trade price, delivers the energy and commits both; a fully matched bid releases its over-reservation; only the matcher, only after closing; limits, the quantities of both orders, slots, self-trades and cancelled orders are checked; partial payments never exceed the collateral |
| Finalisation and expiry | 5     | Expiry releases the unmatched part and burns unmatched energy; nothing before finalisation; nothing for a fully matched order; no trade after finalisation; only the matcher or operator finalises                                                                                                                  |
| Settlement              | 7     | Within 10%, no penalty; a short delivery is penalised from the collateral; a buyer's penalty comes from its balance; an uncollectable penalty is a shortfall, not a revert; only the sensor, only after the slot, only once, only with a commitment                                                                 |
| Sessions                | 2     | An intraday session of six slots; a session must close before delivery and have 1 to 96 slots                                                                                                                                                                                                                       |
| Who may call what       | 4     | Only the owner orders; only the order's session calls back; only registered prosumers place; only the operator runs the manager                                                                                                                                                                                     |
| Finding things          | 1     | `prosumerOf` leads from an account to its prosumer contract, is cleared on deregistration, and allows one contract per account                                                                                                                                                                                      |




### `test/market/GatedMarket.t.sol`: 15 tests

The whole system: an agent trades for Alice through PolicyGate on the ported
market; Bob is the counterparty. A day-ahead batch of 24 bids is 24 legs and 24
booked orders; a leg's value rounds up; a batch beyond `maxLegs` is refused; offers book as sells;
cancel and modify through the gate; fills are booked on reconcile and the rest
expires at finalisation; a fully matched order closes as filled; the ledger
expires without the market's `expire` call; an order the owner cancels directly
is closed elsewhere; the agent has no direct route into the market or the
token. A fuzz test, 256 runs of random trading and matching, checks after every
step that the ledger's books balance, and at the end that the ledger and Alice's
prosumer contract agree slot by slot on what she bought and sold. v0.2, C5: a
filled bid takes from Alice the trade's value and nothing more, and S1 has
counted at least that; the market charges no fee. v0.2, A9: Alice's agent may
let her own prosumer contract lock her payment tokens, not Bob's; the sensor's
`settle` cannot be approved for an agent.

### `test/market/ClassicSettlement.t.sol`: 6 tests

The settlement rule at its edges: the threshold is 10%; exactly 10% costs
nothing; one Wh beyond costs the whole deviation; 16% is penalised; a penalty
rounds up; a commitment that nets to zero tolerates no deviation.

### `test/policies/WindowLib.t.sol`: 32 tests

Each window class at its edges, through `WindowProbe`. Times are exact to the
second.


| Group                 | Tests | What it establishes                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sliding               | 5     | 24 hourly buckets: a bucket counts until the first second of the 24th bucket after it, not a second more or less; the cap is inclusive; the stored state catches up bucket by bucket and agrees with the view; after an idle gap of n buckets the generation goes up and nothing of the old ring returns, even where a new bucket reuses its position; the worst-case sweep of a week of hourly buckets stays under 600,000 gas (339,872 measured) |
| Credits               | 6     | A credit returns to the bucket the amount was counted in, and leaves the window with it; a partial credit returns only its part; nothing once the bucket has left the window; everything in the window's last second; never below zero; nothing for a time in the future                                                                                                                                                                           |
| Tumbling              | 3     | The count restarts at the period boundary, to the second, from any anchor; time before the anchor counts in the first period; credits only within the period                                                                                                                                                                                                                                                                                       |
| The boundary burst    | 1     | The cap spent in the last second before midnight and again in the first second after: the daily tumbling window admits twice its cap within two seconds, the 24-hour sliding window once. Step 3's criterion                                                                                                                                                                                                                                       |
| Refill                | 3     | The rate comes back each whole interval, and no more than the capacity after any idle time; a credit only within the interval of the consumption, so nothing is refunded twice                                                                                                                                                                                                                                                                     |
| Stream                | 3     | The initial amount, then the rate per interval, up to the cap; only the initial amount before the anchor; credits give the allowance back                                                                                                                                                                                                                                                                                                          |
| Lifetime and overflow | 2     | The count never resets; a count beyond 64 bits reverts rather than wraps                                                                                                                                                                                                                                                                                                                                                                           |
| Configuration         | 4     | Malformed configurations are refused, and 2016 buckets is the most; a new cap keeps the count, a new shape starts afresh and leaves nothing of the old ring, even where every write lands in bucket 0; `clear` forgets everything                                                                                                                                                                                                                  |
| Fuzz, one per class   | 5     | 256 random sequences of waits, admissions, credits and observations each, against a reference model written from the definitions: every decision, count and limit agrees; for sliding windows the running total equals the buckets summed one by one (step 3's invariant)                                                                                                                                                                          |




### `test/policies/StaticOrderPolicy.t.sol`: 19 tests

Each per-action bound at its edge, by calling `check` directly, then through
the gate.


| Group            | Tests | What it establishes                                                                                                                                                                                                                          |
| ---------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The bounds       | 8     | A1 and A2 inclusive; A3's ceiling for BUY and floor for SELL, each for its side only; A4 blocking an hour for one side, half-hours included; A6 bounded on both sides, a slot starting now excluded; several broken bounds reported together |
| Legs             | 1     | One bad leg rejects the whole submission; a cancellation is never checked                                                                                                                                                                    |
| Through the gate | 2     | A broken bound stops the order, with the bitmask in the logged result; a modification is checked as its new order, and cancelling stays possible when nothing may be placed                                                                  |
| Configuration    | 5     | Every looser parameter is a widening, a mixed change included; every tighter one a tightening; a malformed configuration is invalid, including a zero rated power or a minimum above the maximum; a lower minimum widens; only the gate writes the policy |
| v0.2 C1, C2      | 3     | The rated-power term binds at its edge and rounds down; the minimum order size binds at its edge, and a small order can still be cancelled                                                                                                  |




### `test/policies/TariffBand.t.sol`: 13 tests

v0.2, A3T, on the mock market against a signed tariff (retail 0.20, feed-in
0.08): each bound at its edge and its rounding (β 3.33 %), a β per side, A3
alongside, no tariff, a stale one to the second, a slot beyond the schedule, a
cancellation never checked, and every configuration direction. **The price
walk** (spec §7): twelve bids each 3 % above the last; the band stops the
fifth, and under A3 alone all twelve pass.


### `test/policies/DominatedTradePolicy.t.sol`: 21 tests

v0.2, S7, against the same tariff, a 1 USD week: the amount per side, rounded
up, zero inside the corridor; the soft bound (at it, unflagged; above it,
flagged) and the cap; D10; credits on
cancel, partial fill and expiry, to the placement's bucket, unchanged by a new
tariff, kept apart for two orders in one block; the week sliding; no tariff
refused; configuration; gas. **The collusive transfer** (spec §7): sales just
inside A3T's band but under feed-in; S7 stops the 26th, and with S7 removed
all 30 pass.


### `test/policies/GridStatePolicy.t.sol`: 17 tests

v0.2, A10, under the account's grid operator: no state, a stale state, a
stranger's; DEFICIT and SURPLUS; the declared exception to D10 (in DEFICIT a
sale may not be withdrawn); modifications judged per slot; EMERGENCY with and
without a direction; the horizon's edge; the minimum level; configuration;
gas. **Counter-grid trading under ALERT** (spec §7): six actions against a
DEFICIT, all refused; without A10 all six go through.


### `test/policies/OperatingEnvelopePolicy.t.sol`: 16 tests

v0.2, S10, on two markets and a 9 kW connection: the static limit both ways;
the envelope's limits each way; σ; the net position; a stale or short
envelope falling back to static; a tightening update; crossing to the other
limit; a modification judged as one; rounding and a zero limit;
configuration; gas. **An envelope breach split across orders and two
markets** (spec §7): each venue at half the limit, the third sale refused;
without S10 all four pass.


### `test/policies/DeliveryReconciliationPolicy.t.sol`: 29 tests

v0.2, S9, with the house's meter on the market's grid: the shortfall and the
CUSUM; when a slot is taken in (settled, reconciled, at most 8 a call); the
alarm, level 1's cap (inclusive, with credits), level 2, the penalty's end and
the level's decay; D16 to the second, with buys and cancellations passing;
a refused submission persisting nothing; `poke` persisting an alarm without a
market call; the owner's reset; configuration; gas. **Spec §7:** chronic
oversell (a compromised BMS; S3 passes; S9's alarm on the second slot, then
level 1 refuses the next sale; without S9 it is placed) and meter withholding
(selling stops two hours after the first sold slot settles).


### `test/policies/RoundTripPolicy.t.sol`: 16 tests

v0.2, S8, a 1 kWh day of half-hour buckets, flagged above 0.5 kWh: the
overlap per slot, only the smaller side, nothing across slots; a modification
counts only what it adds; the soft bound and the cap; D10; no credit, and the
same volume traded again counts again; the day sliding; configuration; gas.
**Churn split across two markets** (spec §7): buy on one, sell the same slot
on the other, cancel, repeat; S8 stops the sixth round, and with S8 removed
all ten pass. **A single correction passes** (spec §11.6): 400 Wh sold back
into a slot that bought 3 kWh.


### `test/policies/WindowPolicy.t.sol`: 10 tests

S1 and S2 through the gate, on sliding windows of 24 one-hour buckets.


| Group         | Tests | What it establishes                                                                                                                     |
| ------------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------- |
| S1            | 2     | Execute, flag at the soft bound, reject above the hard one, with the logged values; gross: a sale neither counts nor refills the budget |
| S2            | 1     | Export and import are separate instances and never netted                                                                               |
| The window    | 4     | It slides to the second; a cancellation and an expiry are credited back; a release after its bucket left the window gives nothing back  |
| Credits       | 1     | S1's credit for a partly filled order, at a rounding price, leaves the filled part's value charged and never less                       |
| Configuration | 2     | The direction table, shape and quantity changes included; a tighter cap applies at once and keeps the count                             |




### `test/policies/CancelQuotaPolicy.t.sol`: 9 tests

S6 through the gate: the cancelled cap inclusive; the near-gate weight, and the
second it starts; the ratio against what the policy saw placed; the free
allowance; the message count, which a refused submission does not use; an
expiry using none of the quota; the quota renewing after an hour; the direction
table.

### `test/policies/DeliverabilityPolicy.t.sol`: 32 tests

S3 through the gate on the mock market, with home_01's battery as the arms
ran it: 5 kWh, 3 kW, 95 % each way, 10 % to 100 %; a horizon of 16
half-hour slots.


| Group                   | Tests | What it establishes                                                                                                                                                                                                                                                                                                   |
| ----------------------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The floor               | 6     | A deliverable sale passes. **Cross-slot over-commitment is blocked** (spec step 5): two sales that each fit, together 448 Wh short, wherever the second falls; the boundary is to the Wh. The PV forecast makes room, but only its credited share. **An unfilled bid cannot justify a sale** (spec 9.1, D3); once filled, it can |
| Power and ceiling       | 7     | A sale beyond the discharge power is blocked, and PV raises its slot's limit. A second sale in a slot shares its power with the first. A bid beyond the charge power, or one that would overfill the battery, is blocked. PV alone never causes a rejection, and PV above a full battery is spilled, not stored                                                                                                                          |
| Reserve load            | 1     | The owner's reserve stays covered, to the Wh                                                                                                                                                                                                                                                                             |
| Only reducing passes    | 4     | A cancellation passes with an empty battery, and with no reading at all. A smaller modification passes while the plan is short. A bid passes while the floor is short; a sale does not                                                                                                                                |
| What cannot be judged   | 5     | With no fresh reading, or once it goes stale, a placement is refused; a stale forecast gives no PV credit. A slot beyond the horizon is refused, and the horizon moves with the reading                                                                                                                                                                       |
| An independent bound    | 1     | Fuzz: whatever sales the agent tries, those executed never draw more from the cells than the energy above the floor                                                                                                                                                                                                    |
| Gas                     | 1     | The check at k = 8, 16, 48, 96, printed                                                                                                                                                                                                                                                                                 |
| Configuration           | 4     | Malformed configurations are invalid, a floor above the ceiling in one hour included; each looser parameter, a floor lower in one hour, and any other horizon, widens; tighter ones tighten; only the gate configures                                                                                                    |
| v0.2 C3                 | 3     | A reserve from noon on rejects a morning sale a flat floor allows (974 Wh short at 12:00). A slot takes the floor of the hour it starts in. A fractional floor rounds up (10.01 % of 5 kWh is 501 Wh)                                                                                                                                                                               |




### `test/policies/CyclePolicy.t.sol`: 16 tests

S4 through the gate on the mock market: a 5 kWh battery allowed one cycle a day,
5,000 Wh from the cells over a sliding 24 hours, flagged above 4,000.


| Group                 | Tests | What it establishes                                                                                                                                                                                                                                   |
| --------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The budget of cycles  | 5     | A sale within it passes, with its draw reported. **Excess cycling is blocked** (spec step 5): flagged at 4,948, the cap itself allowed to the Wh, one Wh more refused. Discharge enters the window at the next accepted submission and leaves it a day later. The PV credit nets the pending draw |
| What adds no cycling  | 8     | A bid needs no reading and is never judged. A cancellation passes over the cap; a smaller sale does too. Over the cap any further sale is refused. A sale with no reading, on a reading gone stale, or beyond the horizon, is refused. A new BMS starts again without counting |
| Configuration         | 3     | Malformed configurations are invalid; what loosens widens; only the gate configures                                                                                                                                                                   |




### `test/policies/RampPolicy.t.sol`: 12 tests

S5 through the gate on the mock market: steps of at most 1,500 Wh between
slots, flagged above 1,000.


| Group                       | Tests | What it establishes                                                                                                                                                                                                       |
| --------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Steps                       | 7     | Within the soft bound, passes; above it, flagged. **A position spike is blocked** (spec step 5), built in two orders. A buy spike too; a swing from +800 to −800; the step to the right as much as to the left. A ramp built slot by slot passes |
| What smooths passes (D10)   | 3     | Over a profile already too steep, a smoothing bid and a sale beside the spike pass, a steepening sale does not. Cancelling the spike passes, and so does spreading it                                                    |
| Configuration               | 2     | The bounds, and only the gate configuring                                                                                                                                                                                 |




### `test/policies/Step5Acceptance.t.sol`: 21 tests

Step 5's criteria on the ported P2P market through the gate, with home_01's
battery as the arms ran it and hourly slots. Each attack is shown blocked, and
passing under per-action bounds only.


| Group                              | Tests | What it establishes                                                                                                                                                                                                                                                                        |
| ---------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cross-slot over-commitment         | 2     | Three offers of 1.5 kWh, 4.7 from the cells against 3.5 above the floor: S3 refuses the batch, and the third when spread                                                                                                                                                                   |
| Phantom-buy justification          | 2     | A bid that will never fill cannot justify an offer; what the battery holds itself can                                                                                                                                                                                                      |
| Excess cycling                     | 3     | Four offers would draw 6.3 kWh in a day against one cycle, 5 kWh: S4 refuses the fourth, and with 3.5 kWh already discharged, the second                                                                                                                                                  |
| Position spike                     | 2     | 3 kWh in one hour is refused by S5; more energy, spread as a ramp, passes                                                                                                                                                                                                                 |
| Stale or favourable reading        | 4     | An older, fuller reading handed in after the current one is refused (`Oracle_Reordered`), so is a stale one (`Oracle_Stale`), and a stored reading gone stale serves no more. Under per-action bounds the reading plays no part                                                     |
| A cancellation always passes       | 1     | Fuzz, 256 runs: under A1–A6, S1, S2, S3, S4, after random orders and a battery found nearly empty and heavily cycled, every open order is cancelled, with a reading or without                                                                                                            |
| Gas as a function of k             | 7     | One offer and one bid at k = 8, 16, 24, 48, 96, policy by policy; a 24-offer day-ahead batch with and without every policy. Report: `docs/reports/gas-step5-2026-10-19.md`                                                                                                              |




### `test/policies/Step4Acceptance.t.sol`: 15 tests

Step 4's acceptance criteria, on the ported market through the gate. Each
attack runs under SLIDING and under the baseline the spec's attack matrix
names for it (decision 4.6):


| Attack                                                                        | Under SLIDING                                            | Under its baseline                                    |
| ----------------------------------------------------------------------------- | -------------------------------------------------------- | ----------------------------------------------------- |
| Split-leg drain: 24 orders, each within A1                                    | S1 refuses the batch; spread over calls, the sixth order | Per-action bounds only: all 24 placed                 |
| Boundary burst: the budget at 23:59:59 and at 00:00:01                        | The budget once                                          | TUMBLING: twice within two seconds                    |
| Idle-then-burst: a week idle, then an hour of orders                          | One day's budget                                         | REFILL and STREAM at the same long-run rate: a week's |
| Place-and-cancel near the gate: four reservations cancelled 20 minutes before | S6 lets one be withdrawn; three must stand               | Without the gate weight: all four withdrawn           |


Six more tests measure gas per order, per policy and combined; the figures are
in `docs/reports/gas-2026-10-16.md`.

### The independent verifier: `offchain/verifier/`

Not a test file but a second opinion. It rebuilds each window from the
probe's events and computes it from the definitions, by a different algorithm
from the contract's (decision 3.7). Then it compares every count, limit,
decision and credit the chain reported.

`npm run verify:window` runs, on a chain inside the process:

- the boundary burst, scripted;
- 8 random histories per class.

Then it measures spec 5.3's guarantees over every interval of every history,
and tampers with the histories one figure at a time to show it notices.

The largest run so far was 30 seeds × 80 steps:

- 152 windows and 33,945 figures compared, no disagreement;
- the sliding bound reached exactly 1.00 × cap and never more;
- the scripted burst gave 2.00 × cap under tumbling, within 3 seconds;
- all 720 tamperings were caught.

**The ledger (v0.2, C4).** `npm run verify:ledger` places, fills, cancels,
expires and closes orders at random for two accounts on two markets, reads the
chain's position after every write, and compares it with the verifier's replay
of the ledger's events, which sums each slot afresh over every order. Four
tampered logs must be rejected. Default run (4 seeds × 80 writes): 1,280 totals
compared, no disagreement, all four tamperings caught.

`npm run test:offchain` (33 tests) checks the verifier's definitions without a
chain, including REFILL's closed form against a step-by-step simulation, and
the matcher's rule.

### `test/accounts/PolicyGateAccounts.t.sol`: 4 tests

The two files above run against a minimal account written for the tests. This
file repeats the essentials on four real account implementations, built by
Rhinestone's ModuleKit: the ERC-7579 reference account, Safe7579, Nexus and
Kernel. One test per account, same scenario:

1. Create the account and assert which implementation it is, by its own
  `accountId()`. A test that silently ran on the wrong account type would
   otherwise still pass.
2. The owner installs the gate, appoints it as the account's ledger writer,
  approves the market function and adds a policy, all through the account,
  and gives the agent a real Smart Session whose only action is `submit`.
3. Through the session, the agent's approved order is executed, and the market
  sees the account.
4. A stranger calling `submit` directly, and an unapproved function through
  the session, are rejected.
5. The session cannot reach the market directly, the gate's owner path, or
  `installModule` and `uninstallModule`; nor can it reach the account through
  `submit`. Afterwards no rogue module is installed and the gate still is.
6. Nor can the owner open those doors: approving the account or the gate as a
  target is refused, and nothing ends up approved; the owner's own `submit` of
  an unapproved function fails as `PolicyGate_UnknownCall`. The reference
  account and Nexus pass the gate's error up as it is; Safe7579 and Kernel wrap
  it in their own, so there the test checks only that the call failed.
7. The owner proposes a widening. It is not in force at once. After 24 hours
  the agent's session still cannot apply it, and the owner can.
8. The owner uninstalls the gate, and the session reaches nothing.



### `test/accounts/SessionGate.t.sol`: 4 tests

The prototype that decided D1. On the same four accounts, the agent holds a
Rhinestone Smart Session whose only action is the gate's `submit`, with no
signing content. The gate here is a test double, `SessionGateProbe`, standing
in for the gate as step 4 will change it: the account calls `submit`. On each
account:

1. Through the session, `submit` runs, and the gate makes the account call the
  market from inside the same execution. The market sees the account.
2. A refusal by the gate leaves its event in a successful user operation.
3. The session reaches nothing else: not the market directly, not the gate's
  owner function, not `installModule` or `uninstallModule`, not the account's
   own `execute`.
4. The session cannot sign for the account. On Nexus a session configured to
  sign does sign, with the same signature: the positive control.

Giving the session a second action, the market's `placeOrder`, makes all four
tests fail at point 3, so the test can tell a session that is too wide. What it
found about the accounts is in decision 3.9: Kernel needs Smart Sessions
installed without a hook, and on Kernel, Safe7579 and the reference account no
session can sign at all.

### The test doubles in `test/gate/mocks/`


| Double                                  | Stands for                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MiniAccount`                           | The smallest account that behaves like an ERC-7579 account where it matters. Its `owner` stands in for "a user operation the owner signed". It accepts module management from itself, as real accounts do: that self-call is the escalation route the gate must close, so the mock keeps it open on purpose. It accepts ERC-1155 tokens, as real accounts do through a fallback handler |
| `StubMarket`                            | A market that only records who called, for the key-model tests. It has one approved function and one the owner never approves                                                                                                                                                                                                                                                           |
| `MockEnergyMarket`, `MockMarketDecoder` | A per-slot order book whose operator fills orders before trading closes, and its decoder. For the ledger tests of `OrderLifecycle` (decision 2.51)                                                                                                                                                                                                                                      |
| `StubDecoder`                           | Reads `StubMarket.placeOrder` as one placement leg                                                                                                                                                                                                                                                                                                                                      |
| `NullDecoder`                           | Reads any call as a 1 Wh placement. For targets that are not markets, in the attack tests: every approved call must be an order                                                                                                                                                                                                                                                         |
| `CapPolicy`                             | A policy with a soft and a hard cap, lower is tighter. Enough to drive every branch of the configuration manager                                                                                                                                                                                                                                                                        |
| `RelayTarget`                           | A forwarding contract, the kind the spec says is never approved                                                                                                                                                                                                                                                                                                                         |
| `ReentrantTarget`                       | A target that calls back into the gate                                                                                                                                                                                                                                                                                                                                                  |




### Do the tests fail when the code is wrong?

A passing suite means nothing if it cannot fail. Each of the following was run
by breaking one line of the gate, running the tests, and restoring the line.


| Run                                                                                                                              | Defects | Result                                                                                                                                                                                                                                                                                                                                               |
| -------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Against `test/gate/`                                                                                                             | 51      | 49 caught at first. The 2 that survived were gaps in the tests; two tests were added and all 51 are caught                                                                                                                                                                                                                                           |
| Against `test/accounts/`                                                                                                         | 9       | 9 caught at step 1. Re-run against the step 5 gate on 19 October, the first time since step 4.1 replaced the agent registry by the session: 6 caught at first. Three gaps (the account and the gate approved as targets, an unknown call), each a second lock the test never tried: three checks added, 9 caught. Report: `docs/reports/mutation-accounts-2026-10-19.md` |
| Step 2 code (ledger, gate booking, mock market, decoder) against `test/gate/`                                                    | 51      | 41 caught at first. Seven survivors were gaps in the ledger and gate tests; nine tests were added and all seven are caught. The other three are in the mock market, now a test double                                                                                                                                                                |
| The market port (token, session, prosumer contract, manager, settlement rule, decoder) against `test/market/` and the gate tests | 54      | 48 caught at first. The six survivors were tests that never reached an edge: a direct cancel on the session, a bid over-matched, exactly 10%, a 16% deviation, rounding of a penalty and of a leg's value. Six tests were added and all 54 are caught                                                                                                |
| Step 4: the `policies` catalogue (the gate's phases, `StaticOrderPolicy`, `WindowPolicy`, `CancelQuotaPolicy`), on 16 October | 43 | 42 caught at first; one gap (a 24-hour window always expired by the time a 24-hour widening applied): a test was added, caught. Report: `docs/reports/mutation-policies-2026-10-16.md` |
| Step 5: the `physical` catalogue (the oracle verifier, readings through the gate, `HorizonLib`, S3, S4, S5), on 19 October | 42 | 38 caught at first. Three gaps (a stale forecast given to S3, the ledger's batch view off by one slot, S4 on a reading gone stale): three tests added, caught. One mutant did not build and was corrected: caught. The clean run: 42 of 42 caught. Report: `docs/reports/mutation-physical-2026-10-19.md` |
| Step 3: all four Hardhat catalogues of the committed suite, `npm run mutate`, on 15 October                                      | 192     | 187 caught at first. One gap in the window tests (a restart, visible only in bucket 0): a test was added, caught. One mutant no longer built after the market port and was corrected: caught. Three survive in the mock market, a test double, and are marked accepted. Final: 189 caught, 3 accepted. Report: `docs/reports/mutation-2026-10-15.md` |


One of the nine is worth knowing. When the gate declares itself a validator
instead of an executor, Nexus and the reference account refuse to install it.
Safe7579 and Kernel install it anyway: they do not check a module's declared
type. That is a difference between account implementations to carry into the
security analysis.

Since step 3 the runs are committed as the mutation suite, `offchain/mutation/`.
The step 1, step 2 and market lists are its `gate`, `ledger` and `market`
catalogues, and the nine real-account defects its `accounts` catalogue; steps
3, 4 and 5 added `window`, `policies` and `physical`. Spec 8's mutants are all
in a catalogue now: none is pending. The
runbook says how to run it.

### What the tests do not show

- **That only the owner can make the account act.** ModuleKit's default
validator accepts any signature, and `MiniAccount` simply trusts its `owner`
address. "Root validator belongs to the owner alone" is a property of how the
account is deployed, and no test here asserts it.
- **Policies on real accounts.** The policies are tested on `MiniAccount`; the
real-account tests of `test/accounts/` check the session and the gate, with a
configuration-test policy.
- **The policies against honest trading.** How often a sliding cap refuses an
honest agent is step 6's false-positive rate, on the HEMS records.
- **Matching and metering, for real.** The matcher in `offchain/matcher/` is a
simple double auction, and the sensors report values the day-ahead scenario makes up.
No real meter is connected.
- **The market on real accounts.** The market tests use `MiniAccount`; the
real-account tests of `test/accounts/` do not yet trade.
- **Behaviour on a network.** There is no deployment script and nothing is
deployed.
- **Gas on a real account.** The step 4 figures are on `MiniAccount`; a Smart Session user operation adds the account's own validation cost.

---



## 7. Runbook



### Setup, once

```bash
npm install
```



### The Hardhat suite

Expect **627 passing** in about three minutes:

- the gate: 38 key model, 33 configuration, 26 order lifecycle on the mock
  market, 8 ledger, 15 policy phases, 16 readings, 13 multi-market, 22 circuit breaker, 16 recipient lock;
- the oracle verifier: 35, and 35 for the v0.2 kinds;
- the market: 23 token, 41 market flow, 15 gated market, 6 settlement rule;
- the windows and the policies: 32 `WindowLib`, 19 `StaticOrderPolicy`, 13
  tariff band, 21 `DominatedTradePolicy`, 16 `RoundTripPolicy`, 29 `DeliveryReconciliationPolicy` (2 of them the oversell attack), 16 `OperatingEnvelopePolicy`, 17 `GridStatePolicy`, 11 `WindowPolicy`, 9 `CancelQuotaPolicy`, 32 `DeliverabilityPolicy`, 16
  `CyclePolicy`, 12 `RampPolicy`, 15 step 4 acceptance, 27 step 5 acceptance
  (attacks and gas).

```bash
npm test
```

`npm test` names its test files, so it leaves out `test/accounts/`. ModuleKit
does not build under Hardhat.

### Everything, under Foundry

Expect **635 passed**: the 627 above plus the eight real-account tests (four for the gate, four for the Smart Session prototype). Last run on 25 October, at the end of v0.2 step 7: 635 passed.

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

### The JavaScript tests

Expect **68 passing** in a few seconds, after a build:

- the verifier's definitions, the matcher's rule and the dataset's decimal
  reading, with no chain;
- the oracles' battery model, arm replay, forecasts and data (10), with no
  chain;
- the oracles' signatures against the contract (4), on a chain inside the
  process.

```bash
npm run test:offchain
```



### Extracting the data

With the raw dataset at the root (see `data/` in section 5):

```bash
npm run data:extract
```

It writes `data/homes/` and `data/arms/` in a few seconds, lists every file,
and checks the arms against the homes. The arms are read from
`../Demo_PlanApplyEvaluate/data/`, beside this repository.

- One part only: `--only homes` or `--only arms`.
- Another year of the homes: `--year 2023`.
- Other arms: `--arms A0,A1`, once they have really run.
- Other places: `--source <dir>`, `--arms-source <dir>`, `--out <dir>`.

### The independent verifier

Builds the contracts, then runs the scripted boundary burst and 8 random
histories per window class on a chain inside its own process. It needs no
node and touches none. About a minute; it ends with one line, which must say
"no disagreement, every guarantee holds".

```bash
npm run verify:window
```

More histories, or other seeds:

```bash
node offchain/verifier/cli.js --seeds 30 --steps 80 --first-seed 1000
```

The ledger across two markets (v0.2, C4), the same way; it must end "no
disagreement":

```bash
npm run verify:ledger
```

G1 (v0.2 step 2): the breaker's suspensions and reinstatements, against the
verifier's replay of the event log; it must end "no disagreement":

```bash
npm run verify:breaker
```

A3T and S7 (v0.2 step 3): the band, the dominated amounts and every credit,
against the verifier's own arithmetic; it must end "no disagreement":

```bash
npm run verify:price
```

S8 (v0.2 step 4): the round trips, from the ledger's own events, on two
markets; it must end "no disagreement", with six of six tamperings caught:

```bash
npm run verify:roundtrip
```

S9 (v0.2 step 5): the slots taken in, the alarms, the penalties and the
verdicts, from the ledger, the meter and S9's own events; it must end "no
disagreement", with six of six tamperings caught:

```bash
npm run verify:delivery
```

S10 (v0.2 step 6): every verdict and use, from the ledger and the accepted
envelopes; it must end "no disagreement", with five of five tamperings
caught:

```bash
npm run verify:envelope
```

A10 (v0.2 step 7): every verdict, from the accepted grid states and the
decoded legs; it must end "no disagreement", with four of four tamperings
caught:

```bash
npm run verify:gridstate
```

S9's calibration (k and h, D19) from the delivery simulator, over every 2022
day; writes a report:

```bash
node offchain/eval/calibrate-s9.js --report docs/reports/calibration-s9.json
```

The honest arm through the gate, every data day (v0.2 step 2: G1 must never
suspend it). About two hours per arm; `--days` shortens it, `--full` keeps S3
and S4:

```bash
node offchain/eval/honest-day-ahead.js --arm B2
```

```bash
node offchain/verifier/ledger-cli.js --seeds 10 --steps 200
```



### The mutation suite

Puts one defect at a time into a contract, runs that part's tests, and puts
the contract back. Every defect must make a test fail. While it runs, the
contract files change on disk: do not edit contracts or run other builds
until it ends. Only one run can be alive at a time.

The tests run in Foundry's Docker image, so Docker Desktop must be running;
the runner never starts it, and stops with a message if it is down. About 20
seconds a defect, against 70 to 90 under Hardhat 3, which spends about a
minute on any run with a failing test, and every caught defect has one
(measured on 24 October 2026).

First, check that every defect still points at real code (instant, no
Docker):

```bash
npm run mutate -- --check
```

One catalogue, for example `price`; `--only` takes the defects whose name
contains a string. The window catalogue is also run against the verifier:

```bash
npm run mutate -- price --only "S7 "
```

Every catalogue, including the real accounts, with a written report:

```bash
npm run mutate -- --report docs/reports/mutation.md
```

Without Docker, `--hardhat` runs the tests under Hardhat instead, about five
times slower; the real-account catalogue needs Foundry and is then skipped:

```bash
npm run mutate -- price --hardhat
```

`npm run mutate -- --list` shows the catalogues, and the spec's defects that
wait for steps 4 and 5. If a run is killed, the next one restores the files
it left changed.

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
  - Delivery is a whole day, 00:00 to 24:00 Brussels time, in 48 half-hour
  slots (46 or 50 when the clocks change).
  - Trading closes at 12:00 the day before.
  - The script takes the first day whose trading is still open, and first
  moves the clock to 09:00 the day before, if it is earlier: from there the
  physical policies' horizon, 96 slots, reaches the end of the delivery day.
2. **The oracles report.** For Alice and Carol:
  - the PV relay posts a forecast of 96 slots, the PV of `prosumers.json`'s
  `dataDate` (13 June 2022) laid on the delivery day;
  - each BMS signs its battery's state: Alice's replays the honest arm B2 of
  home_01, Carol's is home_05's battery at its initial charge.
3. **Every prosumer places an order for every half hour**, at most 24 orders a
  call: a whole day in one call would pass the 16.8M gas a transaction may
  use (EIP-7825).
  - **Alice's agent** sends 48 bids in two calls; its first call brings the
  battery reading.
  - **Carol's agent** sends her midday offers and the rest of her day's bids.
  - **Bob** offers every half hour himself, through his account, with no agent.
  - The day's profiles are in `offchain/scenarios/day-ahead.js` (`profiles`):
  an hour's energy, halved for each half hour.
4. **Alice's agent modifies her 19:00 bid,** 0.75 kWh at 0.27 to 0.9 kWh at
  0.28. This is two legs: a cancel, then a place. It takes her budget, S1,
  past its soft bound of 5.6 USD: the modification is **flagged** and goes
  ahead.
5. **Alice's agent tries to go past her budget**: one more bid of 5 kWh, worth
  2 USD. **S1 refuses it**, and so do S3 (no 5 kWh into her battery in half an
  hour) and S5 (a 5 kWh step). The call does not revert; the script prints
  every policy's result from the log.
6. **Carol's agent offers 10 kWh between 21:00 and 23:00**, after sunset.
  **S3 refuses it:** nearly 10 kWh could not be delivered. 0.4 kWh at the same
  hours passes: the horizon reaches into the night after, when the battery
  must also cover Carol's reserve.
7. **Carol's agent hands in an older, fuller battery reading**: genuine, a
  minute older than the one held. The verifier refuses it,
  `Oracle_Reordered`, and the call reverts.
8. **Time jumps to the close.** An agent order is now refused by the gate: its
  battery reading is no longer fresh, so S3 cannot judge it. Bob's own order is
  refused by the market itself: `MarketSession_Closed`.
9. **The matcher reads the session, matches it and finalises it.** The trades
  are printed slot by slot: who bought from whom, how much, at what price.
10. **A keeper expires every unmatched remainder and reconciles the ledger.**
  Then, for every slot, the ledger is compared with the prosumer contracts'
  commitments.
11. **Time jumps past delivery, and each prosumer's sensor settles its slots.**
  - Bob delivers 80% at 19:00 and 19:30 and pays a penalty.
  - The others deliver within 10% and pay none.
12. **Final balances:** who paid whom, and what the manager collected.

Each agent trades under the policies of `prosumers.json`'s `agentPolicies`,
added to its account at deployment:

- per-action bounds: at most 5 kWh and 5 USD an order, prices between 0.05 and
  0.50, three days ahead;
- the budget S1: 5.6 USD soft and 7 USD hard over a sliding day;
- the caps S2: 30 kWh of export and 40 kWh of import a day;
- the cancellation quota S6: 10 kWh an hour, threefold in the last 30 minutes
  before the gate, and 20 messages an hour;
- set from each prosumer's `battery`: deliverability S3 over 96 slots with the
  whole PV forecast credited; cycles S4, two a day, flagged above 1.5; the ramp
  S5, steps of at most 3 kWh, flagged above 2.

**Alice's S3 value is never zero.** Her reserve load, 0.5 kWh a half hour, is
more than her 5 kWh battery and her PV can cover over two nights. S3 reports
that shortfall before and after every order. Her bids pass, as they do not add
to it, but she could sell nothing: Alice is a consumer. Carol's reserve is
0.3 kWh, and her battery 10 kWh.

Edit them there and deploy again.

The node's clock starts at the real time. The flow moves it forward, so a
second run on the same node trades a later day. Restart the node to come back
to today. Readings are tied to the clock too: the BMS's is fresh for one slot,
the forecast for an hour; the flow signs new ones each run.

Each run opens a new session, so the flow can be run again on the same
deployment. A run that stops half-way leaves its session's orders locked;
deploy again for a clean slate.

**The oracles** (step 5.2). The deployment registers, for each agent's account,
its BMS key and the PV forecast provider in the oracle verifier. To have them
sign and post:

```bash
npm run oracle:post -- --attacks
```

For Alice and Carol it posts a PV forecast for the next 24 slots and hands in
a battery reading for the current slot, then prints what the verifier holds.
With `--attacks` it also tries an older reading, 1 kWh fuller, and a reading
signed by another key: both are refused, with the reason. Other options:

- `--date 2022-06-13`: the day of the data the slots are taken from;
- `--mode yesterday`: the previous day's PV as the forecast, instead of the
  actual;
- `--slots 24`: how many slots ahead.

Alice's battery replays arm B2 of home_01 (`prosumers.json`: `"battery":
"B2"`); Carol's is home_05's battery at its initial charge. Run it again
within the slot and the battery reading is the one already held. The flow does
not use the readings yet.

The matcher can also be run on its own, for the current session once it has
closed:

```bash
npm run demo:match
```

Finding things without a database: from an account,
`MarketManager.prosumerOf(account)` gives its prosumer contract;
`Prosumer.owner()` goes back; `MiniAccount.sessionOf(agent)` says what an
agent's session allows and until when; the events `ProsumerRegistered` and
`SessionEnabled` are indexed by account and by agent.

---



## 8. What comes next


| Step | Adds                                                                                 |
| ---- | ------------------------------------------------------------------------------------ |
| 6    | The full attack matrix against all baselines; the false-positive rate on the honest arms of `data/arms/`, scored against B2; gas as a function of n and k, the policies as separate contracts against one monolithic contract |


Dan answered every open decision on 16 October (log 4.9): the decisions of
steps 1 to 4 stand as built, and the payment token is a mock USD. The table at
the end of `docs/decisions/design-decisions.md` records each answer.