# Policy Spec v0.1: implementation brief

Owner-side sequence policies for delegated energy-trading agents. Draft, 9 October 2026.

This brief supersedes `Policy_Spec_Energy_Agent_v0.md` for implementation purposes. It folds in the review of v0 and the decisions taken on 9 October 2026. Read it fully before touching code. Section 10 must be filled in from the repo before step 1 starts.

> **Build status, 16 October 2026.** Steps 1 to 4 of 6 are built and meet their acceptance criteria (Section 9). Step 5 is in progress: 5.1, the oracle verifier, is built. The earlier design's code is removed (D13). What exists is described in `docs/guide/project-guide.md`; why it was built that way, in `docs/decisions/design-decisions.md`.
>
> The text below is the brief as written on 9 October. Where it has since been changed or implemented, a marked note says so: *Amended* points to Section 12, *As built* describes the implementation, *Status* reports a build step.

## 1. Scope

The account enforces policies on an autonomous trading agent (LLM or RL) acting for a prosumer in a P2P energy market.

- Per-action policies (A1–A6) are infrastructure.
- Sequence policies (S1–S6) are the research contribution.
- Market rules (gate closure, lot size, market price bounds, feeder headroom) belong to the market contract and are assumed, not implemented here.

Out of scope for this build: the NL policy compiler, ERC-8004 reputation integration (events are emitted for it, nothing consumes them yet), and real market integration.

## 2. Relation to the existing repo

> **Amended (A1).** The build is in place: this repository is already the copy, and the v0.1 contracts are added to it directly, in `contracts/gate/`, not as a separate package. The earlier contracts stay untouched until step 4.
>
> **Found in the repo (Section 10).** There was no Foundry config, no ModuleKit and no deployment script to reuse, and the account could not host an executor. No contract is named PolicyGuard; read it below as `PolicyConfig`, `SpendLedger` and `SpendValidator`. The Rhinestone, Pimlico and Turnkey wiring is in the sibling folder `ai-agent-wallet`.

Fork-and-add. Copy the repo and add a new contract package beside PolicyGuard. Do not edit PolicyGuard in place. Keep it compiling until S1 on orders covers its function. Whether PolicyGuard is then retired or kept as a reporting layer is open (D13).

**Reuse as is:**
- Toolchain, Foundry config, deployment scripts.
- Rhinestone ModuleKit, Pimlico and Turnkey wiring.
- HEMS simulation, `export_records.py`, `calibrate_policy.py`: honest-agent source and cap calibration.
- Window-indexing code: reference only, it is rewritten as `WindowLib`.
- Existing oracle signing and verification code, if any. Check what it does first (Section 10).

**Do not reuse:**
- PolicyGuard's data model: daily aggregate records submitted after the fact. v0.1 enforces before the fact, on each decoded order.
- The student's custom validation module as the enforcement point. ERC-7562 forbids `TIMESTAMP` and restricts storage reads during validation, so no window or oracle check can live in a validator.
- Any path where the agent signs for the prosumer account (audit finding F1).

**Audit lessons carried over:**

| Finding | How v0.1 handles it |
|---|---|
| F1: owner ≡ agent | Agent holds no key on the prosumer account (Section 4) |
| F2: no independent verifier | Off-chain verifier with a different algorithm, mutation suite (Section 8) |
| F3: negative net spend, no credit path | S1 counts gross BUY value; credits only on cancel or expiry of unfilled volume (D2) |
| F4: rounding claimed, not implemented | Rounding pinned per quantity (D12) and asserted on both sides |

## 3. Threat model and guarantees

- The agent may be buggy, prompt-injected, strategically aggressive or adversarial.
- The owner key is honest and offline most of the time.
- Oracle signers (BMS or meter, PV forecast, tariff) are trusted. Each is a named trust anchor.
- **Deployment assumption, state it in the paper:** oracle keys sit where the agent cannot reach them, for example a BMS or meter secure element or a separate process. If the agent runs on the gateway that holds the BMS key, the anchor is gone.
- **Guarantee:** every executed order satisfies all installed per-action bounds, and every sequence bound holds over its stated window, independent of the agent's model, prompt or reasoning.
- **Not guaranteed:**
  - economic quality of decisions (measured separately as regret);
  - liveness (the account blocks actions, it cannot force them);
  - protection against the owner's root validator (it can uninstall the gate at any time).

## 4. Architecture

```
Agent (EOA or own 4337 account, sponsored gas)
   │  submit(account, target, calldata, readings[])
   ▼
PolicyGate (ERC-7579 executor, single deployment, state keyed by account)
   ├─ AgentRegistry      agent ↔ account binding, validity, revocation (A8)
   ├─ DecoderRegistry    (target, selector) → IOrderDecoder (A7 allowlist)
   ├─ OracleVerifier     EIP-712 signatures, signer registry, staleness, monotonicity
   ├─ PositionLedger     open orders, per-slot committed and cleared positions
   ├─ PolicyRegistry     per-account list of (policy contract, policyId, config)
   ├─ DecisionAggregator execute / flag / reject, events
   └─ ConfigManager      owner path, tighten now, widen after timelock
   │  executeFromExecutor
   ▼
Prosumer smart account (root validator = owner only; no session keys, no other executors)
   │
   ▼
Mock market (per-slot order book, gate closure, partial fills, fill and remaining views)

Policy contracts (stateful, keyed by account, callable only by PolicyGate):
   StaticOrderPolicy (A1–A6) · WindowPolicy (S1, S2) · DeliverabilityPolicy (S3)
   CyclePolicy (S4) · RampPolicy (S5) · CancelQuotaPolicy (S6)

Off-chain: oracle relays · reconciler keeper · independent verifier (event replay)
```

**Key model.** The agent never signs for the prosumer account. Its authority is the AgentRegistry entry in PolicyGate and nothing else. The account's validator set is owner-only. Smart Sessions is not used.

> **Amended (A7), decided 15 October 2026, built in step 4.1.** The agent's authority becomes a Rhinestone Smart Session on the account. Its only action is `PolicyGate.submit`, and it has no ERC-7739 content and no ERC-1271 policy, so it can sign nothing for the account. The account calls `submit`; the gate checks and executes as before. The AgentRegistry is replaced by the session: expiry by a time-frame policy, revocation by removing the session. The agent still holds no key that can sign for the account, which is what this paragraph protects. See `docs/analysis/delegation-architecture.md` section 10, and the prototype `test/accounts/SessionGate.t.sol`.

### 4.1 `submit` flow

1. Check the agent is registered for `account`, the session is valid, and not revoked.
2. Look up the decoder for (target, selector); an unknown pair is rejected. Decode to `Order`.
3. Verify the readings: signature, registered signer, staleness, and timestamp ≥ last accepted for that device.
4. **Check phase:** call `check` on every registered policy (view). Collect per-policy results.
5. Aggregate:
   - any reject → emit `Rejected` plus per-policy results and return without reverting;
   - otherwise continue.
6. **Commit phase:** call `commit` on every policy, update the PositionLedger.
7. Call the market through `executeFromExecutor`. If it reverts, the whole transaction reverts.
8. Emit `Executed`, per-policy results and any `PolicyFlag`.

> **As built, steps 1 and 2.** Flow steps 1, 2, 7 and 8, and the ledger half of step 6. The signature is `submit(account, target, callData)`: there is no readings argument until step 5, and no policy is consulted until step 4, so no order is rejected by a policy yet. The target is never the account, the gate, the position ledger or the zero address. The ledger books each leg after the market call, because a placement's id exists only once the market has answered; the transaction is atomic. See decisions 1.4, 1.9, 2.8 and 2.14 in the log.
>
> **As built, step 4.1 (amendment A7).** The signature is `submit(target, callData)`, called by the account itself. Flow step 1 is the agent's Smart Session, which lets it have the account call `submit` and nothing else; the gate checks that its caller is an account with the gate installed. See log 4.1.
>
> **As built, step 4.2.** Flow steps 4 to 6 and 8. Every instance is checked with all the legs of the call at once, and each result is emitted as `PolicyResult`, even after a rejection. Any REJECT emits `Rejected` and returns without reverting; nothing is committed, booked or sent. A FLAG emits `PolicyFlag` and goes ahead (flag mode EMIT; COSIGN is not built). Commits run before the market call, the ledger after it. Released volume is credited to every instance on a cancellation through the gate and on `reconcile`; a credit that fails is caught and recorded (`CreditFailed`), and the policy keeps the charge. A reverting `check` or `commit` reverts the submission. See log 4.2.

Rules for the flow:
- Policy rejection is the only non-reverting failure.
- `nonReentrant` on `submit` and `reconcile`.
- Batch submission, if added, iterates this flow per call. Nested multicall or delegatecall targets are never registered.

### 4.2 Policy contract interface

- `check(account, order, ctx) → results[]` (view). Each result carries:
  - policyId;
  - value before and after the order;
  - soft bound S and hard bound H;
  - decision: EXECUTE, FLAG or REJECT.
- `commit(account, order, ctx)`: only PolicyGate may call it.
- `credit(account, orderRecord, amount)`: called on cancel or reconcile; only PolicyGate may call it.
- `configure(account, config)`: only through ConfigManager.
- `ctx` carries:
  - the verified readings;
  - the current slot;
  - the gate time of the order's slot;
  - read access to the PositionLedger (policies call PolicyGate views).

One policy contract can host several policy instances per account, each with its own policyId (for example S2 export and S2 import in one WindowPolicy).

> **As built, step 1.** The configuration side only, in `contracts/interfaces/IPolicy.sol`:
>
> - `classifyConfig(account, policyId, config) → INVALID | TIGHTEN | WIDEN` (view). The policy holds the direction table; the gate holds the timing.
> - `configure(account, policyId, config)`: only PolicyGate may call it.
> - `deconfigure(account, policyId)`: only PolicyGate may call it; used on removal and uninstall.
>
> `check`, `commit` and `credit` arrive with the first policies in step 4. See decision 1.11 in the log.
>
> **As built, step 4.2.** One result per instance rather than `results[]` per contract: the gate lists instances, not contracts.
>
> - `check(account, policyId, legs[], ctx) → CheckResult` (view): `valueBefore`, `valueAfter`, `soft`, `hard`, `verdict`.
> - `commit(account, policyId, legs[], ctx)`: only PolicyGate.
> - `credit(account, policyId, release)`: only PolicyGate. A `Release` carries the order's record (side, slot, placement time, quantity, price, filled part) and the released Wh.
> - `ctx` carries the market, the call's decoder and the block time; the readings join it in step 5, and the ledger is read through its own views.
>
> See log 4.2.

## 5. Shared components

### 5.1 Order decoder

```
Order { kind: PLACE | CANCEL | MODIFY, side: BUY | SELL, slot: uint32, qtyWh: uint64,
        price: uint64 (token units per kWh, fixed point), value: uint64, orderId: bytes32 }
```

- One decoder per approved market contract, registered through the owner path. Decoders are trusted, audited code. A decoder bug is a policy bypass, so list decoders in the security analysis.
- CANCEL reads the remaining quantity from the market's view function, never from agent-supplied data.
- MODIFY decodes as an atomic cancel plus place. Price, quantity and slot changes all re-run the checks.
- The decoder also exposes `gateTime(slot)` from the market.

> **As built, step 2.** `IOrderDecoder` has four functions: `decode(market, callData)` returns legs (one per order placed, so a batch is several; one for a cancellation; a CANCEL then a PLACE for a modification); `placedOrderIds` reads the new orders' ids from the market's reply; `fillState` and `gateTime` read the market's views, so the ledger needs no knowledge of any market. A call that decodes to no leg is refused. `OrderSubmitted` carries the legs. See decisions 2.3 to 2.5. For the ported P2P market the decoder is `contracts/market/ProsumerDecoder.sol`, reading calls to the prosumer contract; an order stays open after trading closes until the session is finalised, because matching happens then (log 2.52). The gate's limit on legs per call is the constructor parameter `maxLegs` (log 2.38).

### 5.2 PositionLedger and order lifecycle

Order states: placed → partially filled → filled, cancelled, or expired at gate closure.

- **Per open order:** orderId → (slot, side, qty, limit price, placement bucket per window policy, remaining).
- **Bound** the number of open orders per account; a new PLACE above the bound is rejected.
- **Per slot within the horizon:** committedBuy, committedSell (placed and unfilled plus filled), clearedBuy, clearedSell.
- **`reconcile(account, orderId)`:** permissionless, keeper or agent may call it.
  - Reads fill and remaining from the market.
  - Moves filled volume into cleared positions.
  - After gate closure, releases unfilled remainder and calls `credit` on the affected policies.
- **Valuation:** placement counts at limit price, which is conservative. True-up to the clearing price on reconcile is optional and off by default.
- **Expiries are not cancellations.** They never count in S6.

> **As built, step 2.** `contracts/gate/PositionLedger.sol`, a separate contract written only by writers the account appoints (the gate today). Records are keyed by account, market and order id, so `reconcile` takes the market: `reconcile(account, market, orderId)`. Each record holds its placement time rather than a bucket; window policies derive their own buckets. An order closes as FILLED, CANCELLED, EXPIRED (the market reports its session closed with part unmatched; log 2.40) or CLOSED_ELSEWHERE (the market no longer holds it open for another reason, for instance cancelled by the owner directly); only CANCELLED is a cancellation. The open-order bound is 64, and a placement beyond it reverts until the check phase exists. The agent may cancel or modify only orders booked through the gate. Positions are keyed by account only and survive a reinstall of the gate. See decisions 2.6 to 2.16.

### 5.3 WindowLib

Used by S1, S2, S4 and S6.

- **Parameters:** window W, bucket b, n = W / b. Bucket index `c = block.timestamp / b` (UTC).
- **Window classes** (enum; the non-sliding ones are the baselines, all run in the same harness behind the same decoder):

| Class | Semantics |
|---|---|
| `SLIDING` | Bucketed ring, n buckets, running total |
| `TUMBLING` | Counter reset at each period boundary, anchored at a start time |
| `REFILL` | balance = min(balance + refill · elapsedIntervals, maxRefill) |
| `STREAM` | unlocked = min(initial + rate · Δt, maxAmount) |
| `LIFETIME` | Counter, no time dimension |

- **Lazy reset.** Each window carries a generation counter. If c − lastBucket ≥ n, bump the generation and zero the total in O(1). A storage word with a stale generation reads as zero. Otherwise advance bucket by bucket, bounded by n.
- **Credits** go to the order's original bucket, only if that bucket is still in the window, and never below zero.
- **Types.** Settlement token is a mock USD with 6 decimals (D7, as amended by A4), so `uint64` holds values up to about 1.8e13 USD and buckets pack four per slot. Wh as `uint64`.
- **Allowed aggregates:** sums only (sum, count, mean as two buffers, ratio of sums as two buffers).
- **Guarantees, to state in the paper:**
  - any interval of length ≤ W − b admits at most H;
  - an interval of exactly W can span n + 1 buckets and admits at most H plus one bucket's content;
  - a tumbling window admits 2H within an arbitrarily short interval around a boundary.

> **As built, step 3.** `contracts/policies/WindowLib.sol`. One interface for the five classes: `used(t)`, `limit(t)`, `fits(t, amount)`, `add`, `credit(t, placedAt, amount)`. REFILL reports cap − balance as its use; STREAM reports its unlocked amount as its limit.
>
> **SLIDING storage.** 64-bit buckets, packed four to a storage word, plus a running total. The ring is keyed by the generation, so the lazy reset is O(1). At most 2016 buckets. The worst-case sweep of S1's default week of hourly buckets costs 339,872 gas.
>
> **Edges the spec leaves open.**
> - TUMBLING counts time before its anchor in the first period.
> - REFILL credits only within the interval of the consumption, so an amount a refill has already returned is not refunded twice.
> - A change of a window's shape starts it afresh, so a policy must classify it as WIDEN.
>
> See decisions 3.2 to 3.5.

### 5.4 Oracles

| Oracle | Data | Delivery | Staleness |
|---|---|---|---|
| BMS / meter | SoC (Wh) at slot start; monotonic discharge odometer (Wh); timestamp | EIP-712, submitted with the order | τ_soc ≤ one slot |
| PV forecast | PV energy per slot (Wh) over the horizon | Relay posts on-chain hourly (push), signed by the provider | τ_pv = 1 h |
| Tariff | Retail and feed-in tariff | Signed or on-chain feed | τ_tar = 24 h |

- Per device, store the last accepted timestamp. Reject readings older than it. This blocks selection of a favourable stale reading.
- SoC readings are defined at slot start. The S3 projection starts from that slot, so the current slot's delivery is not double-counted.
- The agent never supplies an unsigned reference value.
- Every accepted reading is emitted in full in an event (Section 8).

### 5.5 Decision tiers

- Value after order ≤ S: execute.
- S < value ≤ H: execute and emit `PolicyFlag`, or require owner co-signature (`flagMode = EMIT | COSIGN`).
- Value > H: reject.
- COSIGN is an owner EIP-712 approval over the order hash, attached by the agent. If none is attached, the order is rejected. Use EMIT in the evaluation; the owner is offline and slots are short (15 min in the brief; *amended, A2*: the dataset's slot is 30 min).
- **Monotonicity rule (D10):** an action that moves state toward the safe set is never rejected by that policy. Each policy classifies the order as exposure-increasing or exposure-reducing for its own quantity.

### 5.6 ConfigManager

- **Owner path:** `msg.sender == account`, reached only through the root validator.
- **Direction table per parameter:** caps lower is tighter; `socMin` higher is tighter; `sellFloor` higher is tighter; `buyCeil` lower is tighter; ρ lower is tighter.
- Tightening applies immediately. Widening is proposed, then applied after T_w = 24 h. A mixed-direction update counts as widening.
- **Structural changes** (W, b, k, H_slots, window class) count as widening. Apply them with carry-over: the old total stays charged until it would have expired.
- **Cross-parameter constraints**, rejected at configure time:
  - H_slots ≤ k (S3 must cover every reachable slot);
  - S ≤ H;
  - b divides W.
- **Known limit:** the root validator can uninstall PolicyGate immediately, so the timelock protects parameter edits only. State this; do not claim more.
- The account holds no token allowance the agent could route around the gate.
- Events: `ConfigProposed`, `ConfigApplied`, `ConfigRejected`.

## 6. Policies

### 6.1 Per-action (StaticOrderPolicy)

| ID | Policy | Check |
|---|---|---|
| A1 | Max quantity per order | qtyWh ≤ min(qMaxWh, P_rated · Δ) |
| A2 | Max value per order | value ≤ vMax |
| A3 | Price floor and ceiling | SELL: price ≥ sellFloor; BUY: price ≤ buyCeil (absolute or tariff-relative) |
| A4 | Time-of-day restriction | Slot start not inside a blocked interval for that side |
| A5 | Instantaneous SoC bounds | Covered by S3 at horizon 1; listed for the compiler |
| A6 | Target-slot horizon | currentSlot < slot ≤ currentSlot + H_slots |
| A7 | Session scope | DecoderRegistry allowlist (in PolicyGate) |
| A8 | Expiry and revocation | AgentRegistry (in PolicyGate) |

> **As built, step 4.3.** `contracts/policies/StaticOrderPolicy.sol`, A1 to A4 and A6 on every PLACE leg; a CANCEL leg is never checked (D10).
> - **A3** is absolute; tariff-relative bounds wait for the tariff oracle of step 5.
> - **A4** blocks whole UTC hours, one bit per hour and side.
> - **A6** is in seconds: the slot starts after now and at most `horizonSeconds` ahead, read from the decoder's new `slotStart`.
> - **No soft bound.** The result's `valueAfter` is a bitmask of the bounds broken.
> - **A7 and A8.** A7 is the gate's allowlist. A8 is now the agent's Smart Session (amendment A7).
>
> See log 4.3.

### 6.2 S1. Owner budget, sliding window (USD), in WindowPolicy

- **Quantity:** BUY value at limit price, gross. Never net, otherwise sell-and-rebuy refills the budget.
- **Credits:** on cancel and on expiry of unfilled volume, to the original bucket (D2).
- **Defaults:** W = 7 days, b = 1 h.
- **Attacks covered:** split-leg drain, boundary burst (vs `TUMBLING`), idle-then-burst (vs `REFILL`, `STREAM`).

> **As built, step 4.4.** `contracts/policies/WindowPolicy.sol`, quantity `BUY_VALUE`, on any `WindowLib` class.
> - **Bounds.** H is the window's cap; S the instance's `soft`.
> - **Credit on a release.** The value charged less the value of the filled part, both rounded up, to the bucket of the placement time; never more than was charged.
> - **Structural changes.** A change of shape or of quantity is a WIDEN and starts the window afresh. Carry-over (5.6) is not built.
>
> The three attacks are blocked under `SLIDING` and pass under their baselines (step 4 status below). See log 4.4 and 4.6.

### 6.3 S2. Export and import caps, sliding window (Wh), in WindowPolicy

- **Two instances:** SELL qtyWh (export) and BUY qtyWh (import). Never netted.
- **Defaults:** W = 24 h, b = one slot (15 min in the brief; *amended, A2*).
- **Indexing (D9):** placement time. With horizon H_slots·Δ, a delivery interval of length L receives orders placed within an interval of length L + H_slots·Δ. It therefore admits at most ⌈(L + H_slots·Δ) / (W − b)⌉ · H. State this bound in the paper.

> **As built, step 4.4.** The same `WindowPolicy`, quantities `SELL_WH` (export) and `BUY_WH` (import), as two instances, never netted. A release gives back the released Wh. See log 4.4.

### 6.4 S3. Cross-slot deliverability (physical anchor), DeliverabilityPolicy

- **Parameters:** horizon k (default 8), C_bat, socMin(t), socMax, P_ch, P_dis, η_ch, η_dis, PV credit α ∈ [0, 1], reserveLoad (owner constant, D4).
- **Inputs:** signed SoC at slot start (E_now), PV forecast per slot, PositionLedger.
- **Principle:** credit only what is cleared, charge exposure for everything placed (D3).
- **Floor check.** Use cleared buys only. For each slot j in the horizon:
  - net flow f(i) = α·PV(i) + clearedBuy(i) − committedSell(i) − reserveLoad(i);
  - battery change is η_ch·f(i) if f(i) ≥ 0, else f(i)/η_dis;
  - E(j) = E_now plus the cumulative change up to j;
  - require E(j) ≥ socMin(j) · C_bat.
- **Per-slot discharge:** committedSell(i) ≤ P_dis · Δ + α · PV(i).
- **Ceiling and charge-power check.** Use committed (placed) buys, with PV treated as curtailable so PV alone never causes a rejection:
  - require the buy-driven charge to fit under socMax · C_bat;
  - require committedBuy(i) − reserveLoad(i) ≤ P_ch · Δ.
- **Cancels:** a SELL cancel never violates S3. A BUY cancel of unfilled volume does not change the floor check, because unfilled buys were never credited.
- **Cost:** O(k) per order. The ring of k entries is tagged by slot to detect stale entries.

### 6.5 S4. Battery cycles per window, CyclePolicy

- **Source (D5):** attested BMS discharge odometer.
- **State:** the odometer snapshot at each bucket boundary. Window discharge = odometer(now) − snapshot(window start).
- **Missing snapshot:** use the nearest earlier one, which overestimates and is conservative.
- **Pending:** projected discharge from committed sells over the horizon, net of the α·PV credit.
- **Check:** (windowDischargeWh + pendingWh) / C_bat ≤ N_max, with tiers.
- **Defaults:** W = 24 h, b = one slot (15 min in the brief; *amended, A2*).

### 6.6 S5. Ramp between consecutive slots, RampPolicy

- netPos(slot) = committedBuy − committedSell. Shares the PositionLedger.
- When an order changes slot t, require |netPos(t) − netPos(t − 1)| ≤ R_max and |netPos(t + 1) − netPos(t)| ≤ R_max.
- **Exemption (D10):** an order that reduces |netPos(t) − netPos(t ± 1)| is never rejected. Cancels that reduce exposure pass.
- **Positions (D8):** committed positions.

### 6.7 S6. Cancellation and message quota, CancelQuotaPolicy

- **Windows:** cancelled Wh (gate-weighted), placed Wh, message count. Defaults: W = 1 h, b = 5 min.
- **On CANCEL:**
  - cancelledWh + w · qty ≤ C_max, where w = w_g if the cancel falls within δ_g of the slot's gate closure, otherwise 1;
  - cancelledWh ≤ ρ_max · placedWh + c0. The free allowance c0 avoids denying the first cancel in a window; the multiplication avoids division.
- **On any message:** messages + 1 ≤ M_max.
- Expiries do not count.

> **As built, step 4.5.** `contracts/policies/CancelQuotaPolicy.sol`, three `WindowLib` windows of one shape.
> - **Units.** w_g and ρ are integer percentages, and w_g is at least 100%.
> - **The gate window** starts exactly δ_g before the gate time the decoder reports for the cancelled order's slot.
> - **The ratio.** A submission's own placements count as placed for it.
> - **Messages.** Only accepted submissions count.
> - **No credit.** An expiry is never checked, and `credit` does nothing.
> - **No soft bound.** The result reports the cancelled-Wh window; `reasons()` gives the rules broken.
>
> See log 4.5.

## 7. Decisions

| ID | Decision | Status |
|---|---|---|
| D1 | Executor module; agent holds no key on the account | **Decided 2026-10-15: option 3**, a Smart Session scoped to `PolicyGate.submit` with no signing, policies in the executor (amendment A7, log 3.9, `docs/analysis/delegation-architecture.md` section 10) |
| D2 | Credit back on cancel and on expiry, to the original bucket, if still in window | Settled |
| D3 | S3 floor credits cleared buys only; ceiling charges placed buys | Settled |
| D4 | reserveLoad as owner constant; signed load forecast later | Settled for this build |
| D5 | S4 from attested BMS odometer | Settled |
| D6 | Wh as `uint64`; token value as `uint64` at 6 decimals | Settled |
| D7 | Settlement token: mock USD, 6 decimals (amended by A4; was mock EUR) | Settled |
| D8 | S5 on committed positions, with exposure-reducing exemption | Settled |
| D9 | Placement-time indexing; delivery bound stated explicitly (6.3) | Settled |
| D10 | Exposure-reducing actions are never rejected | Settled |
| D11 | PV forecast pushed on-chain hourly by a relay | Settled for this build |
| D12 | Cap quantities round up (BUY value, Wh conversions). Records outside caps keep half-away-from-zero. Same rule on both sides | Settled |
| D13 | PolicyGuard retired or kept as reporting layer | **Retired**: its code was removed at step 4.7 (log 4.7); its records are kept in `data/hems/` |
| D14 | Policies as separate contracts behind one executor; gas also reported for a monolithic variant | Settled |
| D15 | An unregistered agent and an unapproved (target, selector) revert. Only a policy rejection returns without reverting | Proposed, step 1 (log 1.7) |
| D16 | Registering an agent and approving a market call are owner-path writes that apply at once. They are not timelocked, although both grant authority | **Open**, step 1 (log 1.8) |
| D17 | Applying a widening after T_w is an owner-path call, not a permissionless one | Proposed, step 1 (log 1.13) |
| D18 | A policy instance has at most one pending proposal; any later write to the instance drops it | Proposed, step 1 (log 1.14) |
| D19 | Adding a policy applies at once; removing one waits T_w | Proposed, step 1 (log 1.12) |
| D20 | State is keyed by account and installation generation: uninstalling and reinstalling the gate voids every agent, approval, policy and proposal | Proposed, step 1 (log 1.2) |
| D21 | PolicyGate and the policy contracts import no external library; ModuleKit is a test dependency only | Proposed, step 1 (log 1.1) |

"Log" is `docs/decisions/design-decisions.md`, which gives the reason for each of D15 to D21 and what was rejected. "Proposed" means built this way and awaiting confirmation.

## 8. Recomputability, verifier, mutation suite

**Events.** Enforcement must be recomputable from the event log alone.

| Event | Payload |
|---|---|
| `ReadingAccepted` | Full reading payload and signer |
| `OrderSubmitted` | account, agent, target, selector, decoded order, orderHash |
| `PolicyResult` | One per policy per order: policyId, value before and after, S, H, decision |
| `Executed` / `Rejected` | Order outcome |
| `PolicyFlag` | Soft-bound crossings |
| `Reconciled` | orderId, filled, released, credits applied |
| `Config*` | Proposed, applied, rejected changes |

**Independent verifier.** Python, off-chain, deliberately a different algorithm.
- Rebuild state from the full event list.
- Recompute every window by brute force over **all** intervals, not bucket-aligned ones.
- Assert the guarantees in 5.3 empirically.
- Report the first disagreement with the on-chain decision.
- It must be able to disagree. Never port the Solidity.

> **Amended (A6), step 3.** The verifier is **JavaScript**, at Dan's request, not Python: `offchain/verifier/`. It is independent by algorithm, not by language.
> - **SLIDING:** sums admissions from the window's start time, with no ring.
> - **REFILL:** a closed form, the reflected random walk.
> - **Self-test:** it tampers with accepted histories and must reject every one.
>
> Run it with `npm run verify:window`. It works through `contracts/harness/WindowProbe.sol` on an in-process chain. See decision 3.7.

**Mutation suite.** Each mutant must make at least one test fail. A surviving mutant is a hole.
- `<=` → `<` on any cap comparison.
- Bucket index off by one; window start shifted one bucket.
- Credit to the current bucket instead of the original; credit applied outside the window.
- Rounding switched from up to half-even.
- Reading accepted with a decreasing timestamp.
- `H_slots ≤ k` check removed.
- Placed buys credited in the S3 floor.
- Expiry counted as cancel in S6.
- Generation counter not bumped on full reset.

> **As built, step 3.** `offchain/mutation/`, run with `npm run mutate`. One catalogue per part of the system (gate, ledger, market, window, accounts); the window catalogue is also run against the verifier. The mutants above whose code does not exist yet are listed in `catalogs/pending.js`, for steps 4 and 5. See decision 3.8.

## 9. Build order and acceptance criteria

Do not reorder. Each step has to pass before the next starts.

**Step 1. Skeleton and key model.**
- Fork-and-add package; PolicyGate executor installed on the account through ModuleKit.
- AgentRegistry, DecoderRegistry, ConfigManager.
- Accept when:
  - an unregistered agent is rejected;
  - an unknown (target, selector) is rejected;
  - the agent has no path to `installModule`, `uninstallModule`, `configure` or any registry write, including nested self-calls through the gate;
  - only the owner path configures;
  - widening waits T_w;
  - test on at least two account implementations if ModuleKit supports them.

> **Status: built; criteria met on 12 October 2026.** 65 tests in `test/gate/` on a minimal ERC-7579 account, and one scenario in `test/accounts/` on four real accounts.
>
> | Criterion | Shown by |
> |---|---|
> | An unregistered agent is rejected | `KeyModel`: `test_unregisteredAgentIsRejected`, `test_agentIsValidThroughItsLastSecondAndNotAfter`, `test_revocationTakesEffectAtOnce` |
> | An unknown (target, selector) is rejected | `KeyModel`: `test_unapprovedFunctionOnAnApprovedMarketIsRejected`, `test_unapprovedMarketIsRejected` |
> | No agent path to `installModule`, `uninstallModule`, `configure` or a registry write, nested self-calls included | `KeyModel`: `test_agentCannotInstallOrUninstallAModuleDirectly`, `test_accountIsNeverATargetWhateverTheCall`, `test_gateIsNeverATargetWhateverTheCall`, `test_agentCannotWriteAnyRegistryDirectly`, `test_agentCannotConfigureAPolicyDirectly`, `testFuzz_noSubmissionChangesAuthority` |
> | Only the owner path configures | `ConfigManager`: `test_onlyTheAccountConfigures`, `test_agentCannotApplyAnOwnerProposal`, `test_policyIsConfiguredOnlyThroughTheGate` |
> | Widening waits T_w | `ConfigManager`: `test_wideningCannotBeAppliedOneSecondEarly`, `test_wideningAppliesOnceTheDelayHasRun`, `testFuzz_noWideningTakesEffectBeforeTheDelay` |
> | At least two account implementations | `test/accounts/PolicyGateAccounts.t.sol`: the reference account, Safe7579, Nexus, Kernel |
>
> Not shown by any test: that the account's root validator belongs to the owner alone. That is a deployment property (log 1.18).

**Step 2. Mock market, decoder, PositionLedger, reconcile.**
- Market: per-slot book, gate closure, partial fills, fill, remaining and gateTime views.
- Accept when tests cover:
  - place, partial fill, full fill, cancel, modify (price, qty and slot);
  - expiry with release;
  - permissionless reconcile;
  - the open-order bound.

> **Status: built; criteria met on 14 October 2026, on the port of Dan's P2P market** (amendment A5). The market's own tests are in `test/market/MarketFlow.t.sol` and `test/market/LockableERC1155.t.sol`; the criteria below are shown through the gate by `test/market/GatedMarket.t.sol`, and for paths the port never takes (fills before closing) by `test/gate/OrderLifecycle.t.sol` against a mock market.
>
> | Criterion | Shown by |
> |---|---|
> | Place | `test_aDayAheadBatchIsTwentyFourLegs`, `test_offersThroughTheGateAreBookedAsSells` |
> | Partial fill | `test_fillsAreBookedOnReconcileAndTheRestExpiresAtFinalisation`; on the mock, `test_partialFillIsBookedOnReconcile` |
> | Full fill | `test_aFullyMatchedOrderClosesAsFilled` |
> | Cancel | `test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger` |
> | Modify price, quantity, slot | `test_aModifyThroughTheGateIsACancelThenAPlace`; in the market, `test_modifyReplacesPriceQuantityAndSlot` |
> | Expiry with release | `test_fillsAreBookedOnReconcileAndTheRestExpiresAtFinalisation`, `test_theLedgerExpiresWithoutTheMarketsExpireCall` |
> | Permissionless reconcile | on the mock, `testFuzz_anyoneCanReconcile`, `test_theLedgerItselfAcceptsOnlyTheAccountsWriters` |
> | The open-order bound | on the mock, `test_openOrdersAreBounded`; `test_theOpenOrderBoundIsSixtyFour` |
>
> Beyond the criteria: `testFuzz_theBooksBalanceAndAgreeWithTheMarket` checks the ledger after every step of random trading and matching on the port, and that it agrees with the prosumer contract's commitments.

**Step 3. WindowLib, verifier, mutation suite.**
- All five window classes, lazy reset, credits.
- Accept when:
  - invariant fuzz shows window total = sum of in-window buckets;
  - the verifier agrees with on-chain results on fuzzed sequences;
  - every mutant in Section 8 is caught;
  - a scripted boundary burst admits 2H under `TUMBLING` and at most H under `SLIDING`.

> **Status: built; criteria met on 15 October 2026.**
>
> - **Invariant fuzz.** `test/policies/WindowLib.t.sol` has five fuzz tests, one per class, 256 runs each, against a reference model. For sliding windows, after every step, the running total equals the buckets summed one by one.
> - **The verifier agrees.** `npm run verify:window` on 30 seeds × 5 classes × 80 steps compared 33,945 figures with no disagreement. It rejected all 720 tampered histories.
> - **Every mutant of Section 8 whose code exists is caught.** The window mutants, the rounding mutant and the expiry-as-cancellation mutant on the ledger side are caught. The others wait for steps 4 and 5 (`offchain/mutation/catalogs/pending.js`). Over the whole suite: 192 mutants, 189 caught, 3 accepted survivors in test doubles (`docs/reports/mutation-2026-10-15.md`).
> - **The scripted boundary burst** admits 2H within 3 seconds under `TUMBLING` and H under `SLIDING`, in the test (`test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding`) and in the verifier.

**Step 4. StaticOrderPolicy, S1, S2, S6.**
- Accept when, under `SLIDING`, these are blocked:
  - split-leg drain;
  - boundary burst;
  - idle-then-burst;
  - place-and-cancel near the gate.
- The same attacks must pass under the baseline classes.
- Report gas per order per policy and combined.

> **Status: built; criteria met on 16 October 2026.** `test/policies/Step4Acceptance.t.sol`, on the ported market through the gate.
> - **The attacks.** Under `SLIDING`, split-leg drain, boundary burst and idle-then-burst are blocked by S1, and place-and-cancel near the gate by S6.
> - **The baselines.** Each attack passes under the baseline the attack matrix (9.1) names for it: per-action bounds only; `TUMBLING`; `REFILL` and `STREAM` at the same long-run rate; S6 without the gate weight. The sentence below is read that way (log 4.6).
> - **Gas** per order, per policy and combined: `docs/reports/gas-2026-10-16.md`.

**Step 5. OracleVerifier, PV relay, S3, S4, S5.**
- Accept when:
  - cross-slot over-commitment is blocked;
  - excess cycling is blocked;
  - a position spike is blocked;
  - a stale or reordered reading is rejected;
  - an exposure-reducing cancel always passes;
  - gas is reported as a function of k.

> **Status: in progress.** 5.1, `OracleVerifier`, is built: a stale or reordered reading is refused (`test/oracle/OracleVerifier.t.sol`: `test_aStaleReadingIsRefused`, `test_aReorderedReadingIsRefused`, `testFuzz_onlyNewerReadingsAreAccepted`; through the gate, `test/gate/GateReadings.t.sol`). The relays, S3, S4 and S5 follow (log 5.1).

**Step 6. Evaluation.**
- Full attack matrix (Section 9.1), against all baselines.
- Honest arms from the HEMS simulation for the false-positive rate (B0, B2; A0 and A1 once run). Score against B2, not B1.
- Gas as a function of n and k, monolithic vs. contracts.
- State the block-time assumption with a citation; do not report anvil wall time.

> **Status: not started.**

### 9.1 Attack matrix

| Attack | Blocked by | Passes under per-action only? |
|---|---|---|
| Split-leg drain | S1, S2 | Yes |
| Boundary burst | S1, S2 (vs `TUMBLING`) | Yes |
| Idle-then-burst | S1, S2 (vs `REFILL`, `STREAM`) | Yes |
| Cross-slot over-commitment | S3 | Yes |
| Phantom-buy justification (unfilled BUY used to justify sells) | S3 with D3 | Yes |
| Excess cycling | S4 | Yes |
| Position spike | S5 | Yes |
| Spoofing / headroom reservation | S6 | Yes |
| Stale or favourable reading selection | OracleVerifier monotonicity | Yes |
| Config escalation | ConfigManager, key model | Depends on implementation |
| Prompt-injected agent | All | Yes |

**Baselines:**
- per-action only (PACE-like stateless verifier);
- the `TUMBLING`, `REFILL`, `STREAM` and `LIFETIME` window classes in the same harness;
- one sanity run against the real MetaMask `ERC20PeriodTransferEnforcer` on a plain token-transfer path;
- an off-chain HEMS validator, bypassed once the agent holds keys.

## 10. Fill in from the repo before step 1

Record each answer here and commit it with the first change.

| Item | Value |
|---|---|
| Repo path and commit hash at fork | `Custom_Policy_P2P_Energy_Trading`, a copy of `agent-energy-blockchain-proiect2` at `d9a8856c59b971fc5d2d8c619ce0b5fbab8f003c` (`master`, clean). Both share the `origin` remote, so v0.1 work is on branch `feature/policy-gate-v0.1`. |
| Solidity version, Foundry version, ModuleKit version | At fork: Solidity 0.8.23, optimizer 200 runs, Hardhat 3.15.0 with forge-std 1.9.4; no Foundry, no ModuleKit. Now: Solidity 0.8.25, EVM `cancun`, Foundry 1.8.5, ModuleKit 0.5.9, forge-std 1.9.6 (ModuleKit 0.5.9 does not compile against 1.9.4). |
| Smart account implementation in use | At fork: a custom `contracts/SmartAccount.sol`, neither ERC-7579 nor ERC-4337 (immutable owner EOA, no EntryPoint, no `executeFromExecutor`, `execute(to, value)` moves ETH only). The sibling `ai-agent-wallet` scripts build a Safe7579 account on EntryPoint 0.7. |
| Rhinestone module registry at install? Attester on testnet? | Not used in this repo. `ai-agent-wallet` lists the Rhinestone and mock attesters with `attestersThreshold: 0`, so attestation is off on testnet. |
| What the existing oracle does | `PriceOracle`: a publisher key posts 48 import and 48 export prices per UTC day in 1e-8 USD/kWh; storage keeps a hash, the event carries the prices. `MeterReadings`: EIP-712 signature by the registered meter key over a day index and 48 import plus 48 export readings in mWh, domain bound to chain id and ledger address, low-s enforced, anyone relays. No SoC, no discharge odometer, no PV forecast, no tariff feed, no per-device timestamp monotonicity. |
| HEMS simulation slot length | **30 min** (48 slots per day), not the 15 min this brief assumed. See amendment A2. |
| Battery parameters in the simulation | `home_01`: C_bat 5.0 kWh; one power limit of 3.0 kW for charge and discharge; eta_ch = eta_dis = 0.95; SoC bounds 0.10 to 1.00; initial SoC 0.50; connection limit 9 kW. |
| Existing record CSV columns | `dayIndex, agentId, spendMilliUsd, exportWh, importWh, cyclesMilli, minSocBps, maxImportW, tasksMissed`. Superseded in the repo by `differential/data/inputs/` (degradation included, local days). |
| PolicyGuard window length and calibrated caps | No contract is named PolicyGuard; its role is played by `PolicyConfig`, `SpendLedger` and `SpendValidator`. Window 7 days. Permissive 107,567 milli-USD (max of B0's rolling sum), strict 18,096 (85th percentile of B0). Both are flagged stale in the repo (Q3). |
| Deployed addresses on Base testnet | Only the audited original at `1f49b7e`: account `0xfd083d828b66cd1b892d601ba8fbd334f00d2ef9`; modules `0xffbe449b1e07c715d8ffad0617a1faae0bbe6ed0` (V1), `0x9a5b827065ca4432e88a9aa51adaa36b665b527e` (V2), `0xc1be7dc91932768fc4cc58c224a710277fc887c1` (current). Not checked on-chain. The rebuilt contracts were never deployed and the repo has no deployment script. |
| Does a clean rebuild reproduce the CSVs and the policy? | Solidity suite 144 passing and verifier 53 passing, run on 2026-10-09 and again under Foundry. The CSV rebuild and the differential were not re-run; the repo records the CSVs as reproducing byte-identically from `Demo_PlanApplyEvaluate` at `9b8f1d2` (D5.5). |

If any answer contradicts this brief (for example the account cannot host an executor, or the registry blocks installation), stop and report before building around it.

## 11. Design invariants

Check every change against these.

- The proposer is never trusted. Every check uses a reference the agent does not produce.
- The agent has no path to policy configuration, module installation or registry writes.
- No policy check runs in `validateUserOp`.
- Enforcement is recomputable from events alone.
- Integers only across the contract boundary; rounding per D12, asserted on both sides.
- Nothing on-chain iterates a participant-controllable list without a bound.
- A policy never rejects an exposure-reducing action.

## 12. Amendments after the brief

Decided with Dan on 9 October 2026, after Section 10 was filled in. Where these differ from the text above, these hold.

- **A1. Build in place.** This repo is already the fork, and the untouched original stays in `agent-energy-blockchain-proiect2`. The v0.1 contracts are added to this project directly, not as a separate package (overrides Section 2). The earlier enforcement contracts stay and keep compiling until S1 covers their function in step 4, and are then retired, which settles D13 in practice.
- **A2. Slot length is a parameter.** The HEMS dataset is 30 min. Every default this brief states as "15 min" (S2 and S4 bucket, SoC staleness of one slot) reads as one slot, with the slot length set at deployment.
- **A3. Toolchain.** Foundry 1.8.5 with ModuleKit 0.5.9 is added, on Solidity 0.8.25 and EVM `cancun`. The custom `SmartAccount` cannot host an executor; PolicyGate is installed as an executor module on real ERC-7579 accounts. Hardhat stays as a second runner for every test except the real-account ones (log 0.5 to 0.7).
- **A4. The settlement token is a mock USD.** Decided by Dan on 16 October 2026. The HEMS data is in USD, so the token, the policies' configurations and every printed amount are in USD as well, and no exchange rate enters. This amends D7, which said mock EUR. See log 4.9.
- **A5. The market is a port of Dan's P2P energy flexibility market.** Decided on 14 October 2026. Section 1's "market rules belong to the market contract and are assumed" still holds, but the market is now concrete: BRIGHT's and DEDALUS's structure (manager, session, prosumer contract, lockable ERC-1155, settlement), with batches over a configurable number of slots, cancel and modify until the session closes, off-chain matching by a registered matcher, settlement by registered sensors, and caller checks added throughout. See `docs/analysis/market-structure.md` and log 2.20 to 2.52.
- **A6. The independent verifier is JavaScript, not Python.** Decided on 14 October 2026, with the rule that every off-chain program is JavaScript. Independence comes from the algorithm: the verifier computes each window from its definition, never from the contract's data structure. See Section 8 and log 3.7.
- **A7. D1 decided: the agent holds a Smart Session, the policies stay in the gate.** Decided on 15 October 2026, by Dan, on condition that three checks passed. They did:
  - MetaMask's caveats can only refuse by reverting, so option 2 would lose the refusal record.
  - The deployed period limits, MetaMask's and Coinbase's, are tumbling windows.
  - On the reference account, Safe7579, Nexus and Kernel, a session scoped to `submit` reaches the market through the gate, has its refusals recorded, reaches nothing else, and cannot sign.

  Section 4's key model is amended there. See `docs/analysis/delegation-architecture.md` section 10 and log 3.9.
- **A8. The oracles as built (step 5.1).** Decided with Dan on 16 October 2026: no tariff oracle in step 5, since none of its acceptance criteria needs one; A3's price bounds stay absolute. Where Section 5.4 leaves the shape open:
  - `OracleVerifier` is a contract of its own beside the gate, like the position ledger, keyed by account. The gate refuses it as a target.
  - Each account registers one signer per kind (BMS, PV forecast) and the oldest a reading may be when accepted: τ_soc and τ_pv are the account's settings, set on the owner path and applied at once, like decoder approvals (log 4.9, item 1).
  - Readings carry times, not market slot numbers: a BMS reading is measured at a slot start; a forecast starts at a slot start and gives one value per slot.
  - Anyone may hand in a signed reading. The agent's go with its order, in `submit`'s `readings` argument; the PV relay posts forecasts directly. The policies read the latest fresh reading from the verifier.
  - A reading the verifier refuses reverts the submission: only a policy rejection is recorded without reverting (4.1).
  See log 5.1.
