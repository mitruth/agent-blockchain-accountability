# Brief: the policies implemented in Policy Spec v0.1

A self-contained summary, written to be handed to a reviewer (human or AI) who
has not seen the code. It describes what is built and verified as of
21 October 2026 (branch `feature/policy-gate-v0.1`, commit `1259622`), what was
narrowed or left out compared with the spec, and the open questions.

---

## 1. The setting

- **Market.** A peer-to-peer energy market on an EVM chain. Prosumers (homes
  with PV and a battery) buy and sell energy for 30-minute delivery slots,
  settled in a stablecoin (USD). Orders are limit orders per slot. A slot's
  trading closes at its gate time, and its unfilled orders then expire.
- **Agent.** Each prosumer can delegate trading to an autonomous agent, such
  as an LLM-based planner. The agent is **untrusted**: it may be buggy,
  prompt-injected or malicious.
- **Goal.** Owner-defined policies, enforced **on-chain**, limit what the
  agent can do. They hold whatever the agent's reasoning, and the agent cannot
  turn them off.

### Key model

- The prosumer's account is an ERC-7579 smart account (tested on the
  ERC-7579 reference account, Safe7579, Biconomy Nexus and ZeroDev Kernel).
- The owner installs **PolicyGate**, an ERC-7579 *executor* module.
- The agent gets a Rhinestone Smart Session. Its **only** permitted action is
  `PolicyGate.submit(target, callData, SignedReading[] readings)`, with no
  signing rights.
- `submit` treats its caller as the account. In order, it:
  1. checks that the target and function are on the owner's allowlist;
  2. decodes the call into normalized order "legs" through a per-market
     decoder;
  3. verifies any signed oracle readings attached;
  4. runs every policy;
  5. only then has the account make the market call;
  6. books every leg in a PositionLedger.
- The agent can never reach these, by construction:
  - the account's module management;
  - the gate's registries;
  - the oracle's signer registry;
  - any policy's configuration.
- The account, the gate, the ledger and the oracle are forbidden as targets,
  even when the owner tries to approve them.
- Policy checks run in **execution**, not in `validateUserOp`. ERC-7562 bans
  TIMESTAMP and most storage reads during validation, so no window or oracle
  check could live in a validator.

### The policy interface (`IPolicy`)

Each policy contract is stateful, keyed by `(account, policyId)`. One account
can have several instances of the same contract, and at most 16 policies.

- **`check(account, id, legs[], ctx)`** is a view. It sees **all legs of the
  call at once**, so a batch cannot be split to slip under a cap. It returns
  `{valueBefore, valueAfter, soft, hard, verdict}`.
  - The verdict is one of `EXECUTE`, `FLAG` or `REJECT`.
  - `ctx = {market, decoder, time, oracle}`.
- **`commit`** is called on every instance if none rejected, before the market
  call and in the same transaction.
- **`credit(release)`** gives back what was charged when volume is released
  unfilled: a cancellation, an expiry, or an order the market closed.
  - A failing credit is logged (`CreditFailed`) and the charge stays, which
    errs on the safe side.
- **Verdict handling.**
  - If any instance returns `REJECT`, the gate emits `Rejected` plus every
    instance's `PolicyResult`, then commits nothing, books nothing, sends
    nothing, and **returns normally**. A rejection is logged, not reverted.
  - `FLAG` (between the soft and the hard bound) emits `PolicyFlag`, and the
    order proceeds. This is "flag mode EMIT".

### Cross-cutting rules (spec decision IDs)

| ID | Rule |
|---|---|
| D2 | Released volume is credited back to the bucket it was counted in, if the window still counts that bucket |
| D3 | Exposure is charged on *committed* volume (placed, not yet released). Only *cleared* (filled) buys may be credited as incoming energy, so an unfilled bid can never justify a sale |
| D9 | Window policies count an order when it is placed, in the bucket of the submission time, whatever its delivery slot |
| D10 | A submission that only reduces a policy's own quantity (a cancellation, a smaller modification) is never rejected by that policy. Exception: S6, where cancelling *is* the counted quantity |
| D12 | Value = qtyWh × price / 1000, **rounded up**, so caps never undercount |

### Configuration changes (ConfigManager)

- Each policy classifies a proposed configuration as `INVALID`, `TIGHTEN` or
  `WIDEN`. It knows which direction each of its parameters loosens.
- `TIGHTEN` applies immediately.
- `WIDEN` (any parameter looser, even if others are tighter) becomes a
  proposal. It can be applied only after **WIDEN_DELAY = 24 h**, and only on
  the owner path.
- Adding a policy is immediate. Removing one counts as a widening, so it
  waits.
- Any later write to the same instance drops its pending proposal, so an old
  widening cannot resurface after a tightening.
- The timelock protects parameter edits only. The owner's root validator can
  uninstall the whole gate at once.

### Window library (WindowLib), shared by S1, S2, S4 and S6

Five counting classes behind one interface (`used`, `limit`, `fits`, `add`,
`credit`):

| Class | How it counts |
|---|---|
| **SLIDING** | n buckets of b seconds, W = n·b. Used in production |
| **TUMBLING** | Fixed periods; resets at each boundary |
| **REFILL** | Token bucket |
| **STREAM** | Linear unlock |
| **LIFETIME** | Never resets |

- The other four classes are baselines for the evaluation.
- **SLIDING guarantees:**
  - any interval ≤ W − b admits at most the cap;
  - an interval of exactly W admits at most the cap plus one bucket.
- **TUMBLING** admits 2 × cap within an arbitrarily short interval around a
  boundary.

---

## 2. Per-action policies: `StaticOrderPolicy` (A1–A6)

Stateless. Each PLACE leg is checked on its own. CANCEL legs are never
checked. There is no soft bound. `valueAfter` is a bitmask of the bounds that
were broken.

| ID | Bound | Rule |
|---|---|---|
| A1 | Quantity | `qtyWh ≤ maxQtyWh` |
| A2 | Value | `value ≤ maxValue` (at the limit price, rounded up) |
| A3 | Price | SELL: `price ≥ sellFloor`; BUY: `price ≤ buyCeiling`. **Absolute** USD/kWh |
| A4 | Time of day | Rejects a slot whose start falls in a blocked UTC hour, with separate 24-bit masks for BUY and SELL |
| A6 | Horizon | `now < slotStart ≤ now + horizonSeconds` |

- **A5** (per-slot physical feasibility) is covered by S3 rather than
  implemented separately.
- **A7** (the allowlist of targets and functions) is enforced by the gate's
  DecoderRegistry.
- **A8** (the agent's scope and expiry) is enforced by the Smart Session.

---

## 3. Sequence policies (state across orders)

### S1 and S2: `WindowPolicy`, one quantity per instance

| Quantity | What it counts |
|---|---|
| `BUY_VALUE` (S1, budget) | Gross value of BUY orders at their limit price |
| `SELL_WH` (S2, export cap) | Wh offered |
| `BUY_WH` (S2, import cap) | Wh bid |

- **No netting in S1.** Sales never refill the budget, so a sell-and-rebuy
  loop cannot recycle it (audit finding F3).
- **Bounds.** The window's cap is the hard bound H; `soft` is S.
- **Verdicts.** `FLAG` above S; `REJECT` if the submission would exceed H and
  increases the count.
- **Counting** follows D9 (at placement); **credits** follow D2.

### S6: `CancelQuotaPolicy`, against spoofing and reserving headroom

Three SLIDING windows of one shape (spec default: 1 h of 5-min buckets):

- **Cancelled Wh, weighted.** A cancellation within δ_g of the slot's gate
  closure counts w_g × qty (for example 300%). Rule:
  `cancelled ≤ C_max`.
- **Placed Wh.** Rule: `cancelled ≤ ρ × placed + c0`. The free allowance c0
  lets a first cancellation through.
- **Messages,** one per submission. Rule: `messages ≤ M_max`.

Expiries never count. `credit` is a no-op. `valueAfter` reports the cancelled
window, and a bitmask says which of the three rules broke.

---

## 4. Physical policies (step 5), which need the signed oracle

### Oracle: `OracleVerifier`

Two EIP-712 types under the domain `PolicyOracle`, version "1", chainId and
verifier address:

- `BmsReading{account, timestamp, socWh, dischargeOdometerWh}`, signed by the
  battery's BMS key;
- `PvForecast{account, issuedAt, firstSlotStart, slotSeconds, uint64[] pvWh}`,
  up to 96 slots, posted by a relay.

**Registry.** Each account registers one signer per kind, and a max age (at
most 7 days). This is on the owner path; the agent can't reach it, because the
verifier is a forbidden target.

**Refused readings:**
- a bad signature, or a high-s signature;
- future-dated;
- older than the max age (stale);
- older than the device's last accepted reading (reordered: the agent can't
  cherry-pick a favourable old reading);
- the same timestamp with different content (conflicting);
- an odometer that decreased.

**Delivery.** The agent attaches up to 4 readings to `submit`. The gate
verifies them first, then the policies read the latest accepted values. Anyone
can post a reading, since authenticity comes from the signature.

### S3: `DeliverabilityPolicy`, cross-slot deliverability. Stateless.

From the BMS state of charge, it projects the battery slot by slot over k
slots (k ≤ 96), starting at the reading's slot, in two ways:

- **Floor projection** (pessimistic). Must stay ≥ socMin·C_bat.
  - In: α × PV forecast, plus *cleared* buys.
  - Out: committed sells, plus a constant reserve load per slot.
- **Ceiling projection.** Must stay ≤ socMax·C_bat.
  - In: *committed* buys.
  - Out: the reserve load.
  - PV is excluded because it can be curtailed, so PV alone never causes a
    rejection.
- **Power limits per slot.**
  - Sells ≤ discharge power × Δ + PV credit.
  - Buys beyond the reserve ≤ charge power × Δ.
- **Efficiencies.** η_ch and η_dis apply. Rounding errs toward less energy on
  the floor and more on the ceiling.

**Value and verdict.**
- The value is the total undeliverable Wh: floor shortfall, plus discharge
  excess, plus ceiling excess, plus charge excess.
- `REJECT` iff `after > 0 && after > before`, so a submission that doesn't
  worsen things passes (D10).
- There is no soft bound.

**Refused when unjudgeable:** no fresh BMS reading, or a slot outside the
horizon. As a result, "every reachable slot is covered by S3" (the spec's
H_slots ≤ k) holds by construction.

**Config:** k, C_bat, socMin, socMax, P_ch, P_dis, η_ch, η_dis, α, reserveLoadWh.

### S4: `CyclePolicy`, battery cycles per sliding window

The value is Wh drawn from the cells, made of three parts:

1. **Window.** At each accepted submission, the discharge since the last one
   (from the BMS discharge odometer) is added to a SLIDING window at that
   time. It is never counted earlier than it happened, so the window can only
   overstate.
2. **Unattributed odometer.** Discharge shown by the odometer beyond the last
   addition.
3. **Pending.** Committed sales over the horizon, minus the α × PV credit,
   divided by η_dis.

**Bounds.** Cap H = N_max × C_bat; soft S in Wh.

**Verdicts.**
- Only sales are judged: bids and cancellations never are.
- `FLAG` above S.
- `REJECT` above H when the value grew.

**Refused** without a fresh reading or outside the horizon. The first reading
an instance sees sets the baseline of its odometer.

### S5: `RampPolicy`, no spikes in the net position

- netPos(t) = committed buy − committed sell, from the ledger.
- For each slot t the submission changes, it compares the steps to both
  neighbours, |netPos(t) − netPos(t−1)| and |netPos(t+1) − netPos(t)|, before
  and after.
- **Verdicts.**
  - A step above R_max that the submission *made larger* is a `REJECT`.
  - One above S is a `FLAG`.
  - Smoothing orders and cancellations pass, even on an already-steep
    profile.
- No oracle is needed.

---

## 5. Demo configuration (`offchain/deploy/prosumers.json`)

**Market:** 30-min slots, at most 52 legs per call, data day 2022-06-13
(a real HEMS dataset).

**Per-prosumer parameters** (agents: Alice and Carol; Bob trades manually):

| Policy | Parameters |
|---|---|
| A1–A6 | maxQty 5,000 Wh; maxValue $5; sellFloor $0.05/kWh; buyCeiling $0.50/kWh; horizon 72 h |
| S1 | soft $5.60, cap $7, 24 h sliding |
| S2 | export 30 kWh, import 40 kWh, 24 h |
| S6 | 60 min of 5-min buckets; C_max 10 kWh; M_max 20; w_g 300% within 30 min of the gate; ρ 100%; c0 2 kWh |
| S3, S4, S5 | k = 96; α = 100%; N_max 2 cycles a day (soft 1.5); ramp soft 2 kWh, hard 3 kWh |

**Batteries:**

| | C_bat | Power | socMin–socMax | η | Reserve per slot |
|---|---|---|---|---|---|
| Alice | 5 kWh | 3 kW | 10–100% | 95% | 500 Wh |
| Carol | 10 kWh | 5 kW | 20–90% | 95% | 300 Wh |

**Gas.**
- The per-transaction cap is 16,777,216 (EIP-7825), so the demo sends at most
  24 orders per call.
- S3, S4 and S5 together add about 146k gas per offer at k = 8, 405k at
  k = 48, and 723k at k = 96.
- S3 is about 30.5k plus 4,050 per slot; S4 about 38k plus 2,500 per slot;
  S5 about 24k.

---

## 6. Evidence

| Check | Result |
|---|---|
| Hardhat Solidity tests | 411 passing |
| Off-chain tests | 29 passing |
| Foundry suite | 419, including real-account tests on 4 account implementations via ModuleKit |
| Mutation testing | Every mutant caught: gate, ledger, market, window, policies, physical 42/42, accounts 9/9 |

**Acceptance attacks demonstrated as blocked**, and shown to pass under
per-action bounds alone:
- cross-slot over-commitment (three 1.5 kWh offers against 3.5 kWh usable);
- phantom-buy justification (an unfillable bid used to justify a sale);
- excess cycling;
- a position spike (3 kWh in one slot);
- a stale reading, and an older but fuller reading replayed after a newer
  one;
- a fuzz test: a cancellation always passes.

---

## 7. Known deviations from the spec, and things not built

| Item | Status |
|---|---|
| **A1 rated-power term** | The spec says qty ≤ min(qMax, P_rated × Δ). The code checks only `maxQtyWh`, and the owner must fold P_rated × Δ into it by hand. S3's power limits also catch it when S3 is enabled |
| **A3 tariff-relative bounds** | The spec allows price bounds as a percentage of the retail or feed-in tariff for the slot. Only absolute bounds are built: there is no tariff oracle yet (the owner has approved building one) |
| **A5** | Not a separate check; subsumed by S3 |
| **S3 socMin** | One constant. The spec allows a time-varying socMin(t), for example a higher night reserve |
| **S3 reserve load** | One constant per slot (D4), not a load forecast |
| **S4 mechanism** | The spec describes bucket-boundary snapshots of the odometer. The code adds discharge into the window at each accepted submission, plus the unattributed odometer delta. Equivalent in intent, and conservative (overstates), but different |
| **COSIGN flag mode** | The spec offers two modes between soft and hard: EMIT (log a flag) or COSIGN (require the owner's EIP-712 co-signature on the order hash). Only EMIT is built |
| **Carry-over on structural changes** | Changing a window's *shape* (W, b, class, k, H_slots) starts the new window empty once the 24 h timelock passes. So the agent could spend the cap just before and again just after the switch. The spec wants the old window's usage to carry until it would have expired. Accepted as a stated v0.1 limitation (decision 4.4) |
| **Monolithic gas variant (D14)** | Not built yet; part of step 6, the evaluation |
| **Network deployment** | Local only |

---

## 8. Questions for the reviewer

1. **Completeness of the threat model.** Is there an attack that is
   economically harmful to the owner, or physically harmful to the battery or
   grid, that none of A1–A6 or S1–S6 blocks? Consider:
   - wash trading with a colluding counterparty;
   - adverse selection at the price bounds;
   - griefing through the 64-open-order ledger bound;
   - draining via fees, if the market has any.
2. **S1 at gross value.** Is counting the gross buy value the right budget, or
   does it over-restrict honest arbitrage? Would a net budget with a separate
   anti-wash rule be better?
3. **The S3 floor model.** Is it sound to credit PV at α while excluding PV
   from the ceiling, given a stale forecast? Are cleared buys the right
   inflow, given settlement risk?
4. **The S4 approximation.** Can an agent game the "added at submission"
   attribution, for example by submitting rarely so that discharge enters the
   window late and leaves it later? The claim is that this only overstates.
   Is that right?
5. **S5 "only if made larger".** Can an agent reach a steep profile by many
   small steps that each pass? (Each step is bounded by R_max between
   neighbours, so the profile stays within the bound, but check the
   two-sided update.)
6. **S6 parameters.** Are ρ, c0 and the gate weight a sound defence against
   spoofing in a thin P2P market?
7. **Timelock.** Is 24 h with drop-on-write proposals enough? Does the
   missing carry-over matter in practice?
8. **Non-reverting rejects.** Any downside to returning normally on
   `REJECT`, for example in ERC-4337 bundler accounting, gas griefing, or an
   agent probing the bounds cheaply?
9. **Trust in the oracle.** BMS and PV signers are trusted devices. What
   happens if one is compromised or colludes with the agent? Is
   per-account registration enough?
