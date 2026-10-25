# Policy Spec v0.2: gap-driven policies

Brief for Claude Code. Draft, 21 October 2026. It builds on branch `feature/policy-gate-v0.1` at commit `1259622`, described in `implemented-policies-brief.md`. Everything in `policy-spec-v0.1-implementation.md` (architecture, key model, invariants, decisions D1–D14) still holds unless stated otherwise here.

This brief adds policies that close the gaps found in the SOTA review and the P2P energy-agent analyses. Section 1 explains where each policy comes from, Section 2 maps every gap to a policy or to an explicit exclusion, Sections 3–5 specify the candidates, and Section 8 gives the original build order. Defaults marked (D15+) are open decisions with a proposed default; build with the default unless told otherwise.

**Scope for implementation: Section 11 is binding.** It records the decisions of 21 October 2026: which policies are built, the build order, and the framing. Sections 1–10 keep the full analysis and the candidates that were not selected. Where Section 11 and an earlier section disagree, Section 11 wins.

## 1. What the SOTA enforces per action, and what a sequence still does

Every reviewed system checks one action at a time, or penalizes after the fact. The right column is the policy in this repo that lifts the check to sequences or to a physical anchor.

| Work | Per-action rule | What a sequence of individually valid actions still does | Lift in this repo |
|---|---|---|---|
| PACE (arXiv 2608.17220) | Stateless per-transaction verifier | Five-leg drain, each leg under the cap | S1, S2 (built) |
| Compositional Security (ERC-8004/AP2/x402, Mode B) | Payee, asset, amount, validity predicate; one mandate per payment | No budget across payments; value lost across many in-predicate payments | S1 (built), S7 |
| Account-abstraction policy paper (REW) | Per-tx whitelist and price check against one market price oracle | Oracle manipulable; rule update path unprotected | ConfigManager (built), A3T anchored to a signed tariff |
| Coupled electricity-carbon LLM agents | Per-bid price band around the previous price | Band walks 68.9 → 110.4 CNY/t over 12 rounds | A3T (external anchor cannot walk), S7 |
| Blockchain-monitored agentic architecture (Fabric) | Per-action safety bounds; rate limits mentioned, not implemented | Unbounded repetition; executor bypass | Key model (built), G1 |
| GNN-XGBoost smart-grid dispatch | Per-transaction energy limit and tariff in chaincode | Reported measurements trusted; nothing checks delivery | S9, S10 |
| EqGrid (arXiv 2609.01918) | Validate-and-project DOE gate per decision | Silent correction, nothing recorded; 55 violations without the gate | S10 (reject and record, aggregated across orders and markets) |
| TRANSAX (arXiv 1910.12579) | DSO per-interval caps checked by one market contract | Not owner-scoped; per market only | S10 at the owner's account, across markets |
| Khorasany et al. (arXiv 2005.14520) | Payment gated on meter-signed injection | Shortfall lowers price and reputation, never the agent's authority | S9 feeds shortfall back into the agent's allowance |
| ChronosRep, reputation papers | After-the-fact reputation | Sleeper and on-off agents act until trust collapses | G1 suspends the session on rejection or flag rate |
| Blockchain-enhanced IC MARL | Per-round penalty after clearing | Harmful bid already cleared | G1, S9 change future authority |
| Consent collapse | Category scopes, re-authorization at scope extension | Scope is static while risk changes | S12 narrows scope automatically from signed grid state |
| Wallet frameworks (Smart Sessions, MetaMask, Zodiac, Coinbase) | Lifetime, tumbling, refill, stream caps in tokens | Boundary bursts; no energy units; no oracle | S1, S2 (built) |

## 2. Gap coverage map

| Gap (source) | Status |
|---|---|
| No runtime cumulative bounds in energy units (Cumulative_Policies §3) | Built: S2, S4 |
| No physically anchored policy (Cumulative_Policies §3) | Built: S3, S4 (BMS). New: S9 (meter), S10 (DSO envelope) |
| Per-step price guards are walkable (coupled study) | New: A3T, S7 |
| Silent correction without record (EqGrid, coupled study) | Built: `Rejected` events. New: S10 rejects instead of projecting |
| Trusted, unverifiable gates | Built: on-chain gate, independent verifier |
| LLMs lack physical constraints; post-hoc filtering insufficient (coupled study, EqGrid) | Built: S3. New: S10 |
| Delivery deviation never fed back to the agent's allowance (NL policy modules doc) | New: S9 |
| Sequences of valid transactions break spending intent through repetition, fragmentation, timing (A2A payments SoK §5.2) | Built: S1, S2, S6. New: S8, G1 |
| Wash trading and churn (theme J, REMIT) | New: S8, S7 |
| Adverse selection at absolute price bounds (review question 1) | New: A3T, S7 |
| Cheap probing of bounds through non-reverting rejects (review question 8) | New: G1 |
| Sleeper and on-off agents (ChronosRep; GFM adaptive on-off finding) | New: G1, S9 |
| Compromised or colluding BMS or PV signer (review question 9) | New: S9 as second, independent anchor; signer distinctness (Section 4) |
| Cross-market consistency (theme B) | Partial: C4 aggregates every policy across all registered markets. Carbon markets out of scope |
| Grid stress and correlated agent behaviour (blackout analysis: Iberia 2025, Chile 2025, GB 2019) | New, tier 2: S12 |
| No calibration against honest forecast error (Cumulative_Policies §3) | New: S9 calibration; false-positive evaluation for every policy (Section 7) |
| Owner mandate not represented | Built: the policy set. NL compiler deferred |
| Fairness and equity at market level (Jadhav, Ma, EqGrid) | Out of scope for owner-side enforcement. S7 gives per-owner individual rationality |
| Privacy of physical data (theme H) | Out of scope; homomorphic commitments over window sums planned later |
| Value transfer to a colluder inside the [feed-in, retail] corridor | Residual; stated limitation. S14 conditional (Section 6) |
| Liveness (agent withholds action) | Out of scope: the account can block actions, not force them |

## 3. Changes to implemented policies

| ID | Change | Why |
|---|---|---|
| C1 | A1: `qtyWh ≤ min(maxQtyWh, P_ratedW · slotSeconds / 3600)` | Spec term missing; owner had to fold it in by hand |
| C2 | A1: `qtyWh ≥ minQtyWh` | Dust orders can fill the 64-open-order bound |
| C3 | S3: socMin as a 24-entry hour-of-day profile (bps of C_bat); a constant profile is the default | Night reserve; spec allowed socMin(t) |
| C4 | Audit the PositionLedger: committed and cleared per slot must sum across every registered market. Reject registration of a market whose slot length differs from the account's slot grid (D15) | S3, S5, S8, S10 must see the account's total position, not one venue's |
| C5 | If the mock market charges fees, S1 counts them as BUY value. If it has none, state that | Fees are spend |

Write a test for each. C4 needs a test with two market instances where each venue alone passes and the sum fails.

## 4. New oracle kinds

Same pattern as `OracleVerifier`:
- EIP-712, domain `PolicyOracle`.
- Per-account signer per kind and a max age, registered on the owner path.
- Refused: high-s, future-dated, stale, reordered, conflicting.

| Kind | Fields | Signer | Max age (default) | Delivered by |
|---|---|---|---|---|
| `TariffSchedule` | account, issuedAt, firstSlotStart, slotSeconds, uint64[] retail, uint64[] feedIn (same fixed-point scale as order price), ≤ 96 slots | Retailer or aggregator | 24 h | Relay posts on-chain |
| `MeterReading` | account, slotStart, importWh, exportWh | DSO smart-meter key | n/a: one reading per slot, immutable once accepted | Keeper posts; the agent never supplies it |
| `Envelope` | account, issuedAt, firstSlotStart, slotSeconds, uint64[] exportLimitWh, uint64[] importLimitWh, ≤ 96 slots | DSO | 24 h | Relay posts |
| `GridState` (tier 2) | issuedAt, validUntil, level ∈ {NORMAL, ALERT, EMERGENCY}, direction ∈ {DEFICIT, SURPLUS, NONE}, horizonSlots | System or microgrid operator | validUntil | Relay posts |

**Rules for meter readings:**
- A second reading for the same slot with different content is refused.
- Readings must be kept per slot, not only the latest one: S9 processes a history.
- Store at most the last N slots in a ring (N ≥ grace + horizon).

**Signer distinctness:**
- Registration rejects a METER or ENVELOPE signer equal to the account's BMS signer, PV signer, or any registered agent address.
- No signer of any kind may equal a registered agent address.
- This makes "independent trust anchor" a checked property rather than a deployment hope.

## 5. New policies

Shared conventions for every policy below:
- Placement-time counting (D9).
- Value rounded up (D12).
- Credit on release (D2) unless stated otherwise.
- D10: a submission that only reduces the policy's quantity is never rejected, unless the policy declares an exception.
- Unjudgeable inputs reject (fail closed), unless the policy declares otherwise.

### A3T. Tariff-relative price band (extends StaticOrderPolicy; owner already approved the tariff oracle)

**Closes:** walkable per-step price guards; adverse selection at absolute bounds.

**Check, per PLACE leg,** with r(t) and f(t) the retail and feed-in tariff for the order's slot:
- BUY: `price ≤ r(t) · (10000 + β_b) / 10000`
- SELL: `price ≥ f(t) · (10000 − β_s) / 10000`
- Round each bound toward the stricter side.

**Interaction with absolute bounds:** A3 still applies. A3T is enabled per instance.

**Unjudgeable:** no tariff covers the slot → REJECT.

**Config:** β_b, β_s in bps (lower is tighter). Defaults: 1000 and 1000.

**Why it cannot walk:** the anchor is a signed external tariff, not the agent's own previous price. A sequence of bids can move at most to the band edge.

### S7. Dominated-trade budget, sliding window (USD): `DominatedTradePolicy`

**Closes:** many trades each just inside A3T's tolerance; value transfer to a colluding counterparty outside the corridor; LLM sellers overbidding or underbidding (Lotfi et al.).

**Definition.** Within slot t, a BUY above r(t) is dominated, because grid import at r(t) was available. A SELL below f(t) is dominated, because export at f(t) was available. The budget is not zero because the outside option can be unavailable, for example when the DSO envelope caps grid export.

**Quantity per PLACE leg,** at the limit price (the worst case for both sides):
- BUY: `max(0, price − r(t)) · qtyWh / 1000`
- SELL: `max(0, f(t) − price) · qtyWh / 1000`

**State:** SLIDING window, default W = 7 days, b = 1 h.

**Verdicts:**
- FLAG above soft S.
- REJECT when the submission exceeds cap L and increases the quantity.

**Credits:** released unfilled volume is credited (D2).

**Config:**
- L and S (lower is tighter). Defaults: L = $1.00, S = $0.50 per 7 days.
- Window shape changes are structural (timelocked; no carry-over, as decision 4.4).

**Unjudgeable:** no tariff for the slot → REJECT.

**Stated limitation:** a transfer to a colluder at prices inside [f(t), r(t)] is indistinguishable from legitimate bargaining without a market reference. S7 bounds the transfer outside the corridor.

### S8. Same-slot round-trip quota, sliding window (Wh): `RoundTripPolicy`

**Closes:** buying and selling the same delivery slot (wash and churn pattern, REMIT); fee drain; inflated volume used to look active.

**Per-slot round-trip volume:** rt(t) = min(committedBuy(t), committedSell(t)), summed across all markets (C4).

**Quantity of a submission:** Σ over affected slots of max(0, rt_after(t) − rt_before(t)).

**State:** SLIDING window, default W = 24 h, b = one slot.

**Verdicts:**
- FLAG above S.
- REJECT above H when the submission increases rt.

**Credits:** none. A round trip counts when created, even if later released (same convention as S6). This keeps the policy simple and conservative.

**D10:** cancellations and reductions pass.

**Config:** H, S in Wh. Defaults: H = 1,000 Wh, S = 500 Wh per 24 h. This allows an occasional correction after a forecast change.

### S9. Delivery reconciliation with allowance feedback: `DeliveryReconciliationPolicy`

**Closes:**
- No paper feeds delivery deviation back into the agent's authority.
- A compromised BMS or PV signer inflating SoC or forecast to justify oversales. S3 trusts those readings; S9 checks them against the meter, a separate signer.
- Chronic overselling by an agent that passes every per-slot check.

**Input:** accepted `MeterReading`s per slot; cleared positions from the ledger.

**Processing.** A pointer `lastProcessedSlot` advances over settled slots, up to `maxProcess` per call (default 8). A slot is settled once `now ≥ slotEnd + settlementLag`. For each slot t:
- contracted net export: cn(t) = max(0, clearedSell(t) − clearedBuy(t));
- delivered net export: dn(t) = exportWh(t) − importWh(t);
- shortfall: s(t) = min(cn(t), max(0, cn(t) − dn(t)));
- upper CUSUM: C ← max(0, C + s(t) − k);
- if C > h: alarm. Set C ← 0, raise the penalty level, set `penaltyUntil = now + T_pen`, emit `DeliveryAlarm(account, slot, level)`.

Over-delivery (s = 0) lets C decay by k per slot. Normal household import with nothing sold gives cn = 0, hence s = 0.

**Penalty, affects SELL legs only:**
- **Level 1:** a second SLIDING SELL_WH window (W = 24 h) with cap H_pen applies while the penalty is active. Default H_pen = 50% of the S2 export cap.
- **Level 2** (an alarm while level ≥ 1, or within W_esc of the previous alarm): SELL placement is rejected until `penaltyUntil`; emit `PolicyFlag`.
- **Decay:** the level falls by one after W_esc with no alarm.
- **Owner path:** `resetPenalty(account, id)`.

**Missing readings (D16):** if any slot older than `settlementLag + grace` has cleared sales and no meter reading, new SELL legs are rejected until the reading arrives. This fails closed.

**D10:** BUY legs and cancellations are never rejected by S9.

**Persistence.**
- `check` computes the processing in memory; `commit` persists it. A rejected submission persists nothing, and the next call recomputes the same result (deterministic).
- Add a permissionless `PolicyGate.poke(account, instance)` that processes and persists without a market call, so alarms and pointer advances do not depend on the agent submitting.

**Calibration (D19).**
- k comes from the honest shortfall distribution per account. Default: the p95 of s(t) under the HEMS B2 arm with realized PV and load. Extend `calibrate_policy.py`.
- h comes from a target ARL₀ (honest false-alarm interval, default ≥ 30 days); report ARL₁ under the oversell attack.
- This is the inverter-C lesson from the GFM work: a global slack penalizes volatile households.

**Config:**
- k, h, T_pen (default 24 h), W_esc (default 7 days), H_pen, settlementLag (default one slot), grace (default 4 slots), maxProcess.
- Lower k or h, longer T_pen, lower H_pen, smaller grace are tighter.

### S10. Operating-envelope compliance: `OperatingEnvelopePolicy`

**Closes:**
- Joint feasibility needs the network model, and DSOs share envelopes instead of the model (theme A).
- EqGrid's violations and silent projection.
- TRANSAX enforces per market, not per owner across markets.

**Check, per affected slot t:** ne(t) = committedSell(t) − committedBuy(t) across all markets.
- Require ne(t) ≤ E_exp(t) and −ne(t) ≤ E_imp(t).
- If no fresh `Envelope` covers t, use the owner-set static connection limits (P_conn · slot length). This falls back to static rather than rejecting, because the connection rating is always known.

**Verdicts:**
- FLAG above a soft fraction σ of the limit (default 90%).
- REJECT when a limit is exceeded and the submission makes the excess larger (D10).
- If an envelope update tightens limits below existing commitments, new worsening orders are rejected and cancellations pass.

**Stated limitation:** the envelope applies to physical flow at the connection, which includes uncontracted PV and load. Committed net position is a proxy. State this; do not claim physical compliance.

**Config:** P_conn and σ (lower is tighter).

### G1. Session circuit breaker (PolicyGate feature, not an IPolicy)

**Closes:**
- Cheap probing of bounds, since rejections return normally.
- Sleeper and on-off agents.
- Bursts triggered by prompt injection.

It lives in the gate, because only the gate sees REJECT outcomes and can persist state on the non-reverting reject path.

**State:** two SLIDING counters per account, rejected submissions and flagged submissions. Defaults: rejects W = 1 h, b = 5 min; flags W = 24 h, b = 1 h.

**Rule:**
- If rejects > R_max or flags > F_max, set the agent's status to SUSPENDED and emit `AgentSuspended(account, agent, reason)`.
- Defaults: R_max = 10 per hour, F_max = 30 per 24 h.

**While suspended (D17):** cancel-only. Only legs that every installed policy classifies as exposure-reducing pass, and S12's direction rule still applies.

**Reinstatement:** owner path only by default. An optional auto-reinstate after cooldown T_c is configured by the owner.

**Config direction:** lower thresholds and longer windows are tighter.

### S12. Grid-state authority narrowing (tier 2; build after tier 1 is evaluated): `GridStatePolicy`

**Closes:** the blackout analysis. Precursor conditions are visible minutes ahead, and household agents contribute through correlated behaviour. A signed operator state narrows every agent's authority automatically.

**Input:**
- the latest fresh `GridState`; or
- an adapter reading the HRIA `Coordinator` frequency on the same chain: DEFICIT if f_PCC < f_nom − δ for m consecutive epochs (D20).

**Rules while level ≥ ALERT,** for slots within `horizonSlots`:
- **DEFICIT:** reject legs that raise net import or lower net export. That means BUY placements, and SELL cancellations or reductions.
- **SURPLUS:** reject legs that raise net export or lower net import.
- **EMERGENCY with direction NONE:** reject all new placements; cancellations pass.

**Declared exception to D10:** in DEFICIT a SELL cancellation reduces the owner's exposure but harms the grid, so S12 rejects it. Test this explicitly.

**Stale or missing state (D18):** NORMAL, i.e. fail open. The policy restricts the owner beyond the owner's own interest, so an oracle outage must not freeze trading.

## 6. Deferred or out of scope

| Item | Reason |
|---|---|
| S14 counterparty concentration | Only meaningful if the market exposes the counterparty per fill. Check the mock market; if fills are bilateral, propose a design before building |
| COSIGN flag mode | Owner is offline; 30-min slots. Keep EMIT |
| Carry-over on structural changes | Accepted limitation (decision 4.4) |
| Carbon cross-market consistency | No carbon market in the setting |
| Market-level fairness, energy-poverty transfers | Market design, not owner-side; later paper with the game-theoretic layer |
| Private window sums (homomorphic commitments) | Later paper |
| NL policy compiler | Later; policies first |

## 7. Evaluation additions

**New attacks.** Each must be shown blocked by the named policy, and shown to pass with that policy removed.

| Attack | Blocked by |
|---|---|
| Price walk: 12 bids, each a few percent above the previous | A3T |
| Collusive transfer: many SELLs each just inside A3T but below feed-in | S7 |
| Round-trip churn on one slot, split across two markets | S8 (with C4) |
| Chronic oversell: agent sells against an inflated BMS SoC from a compromised BMS signer; S3 passes | S9 alarm within a bounded number of slots, then H_pen |
| Meter withholding: keeper stops posting readings | S9 fails closed on SELL |
| Envelope breach, split across orders and two markets | S10 |
| Probing campaign: binary search for the S1 cap | G1 |
| On-off agent: 2-slot burst, 10-slot rest (the GFM adaptive pattern) | G1 within the 24 h flag window, S9 if the bursts oversell |
| Counter-grid trading under ALERT, including cancelling sells in DEFICIT | S12 (tier 2) |
| Signer collusion: owner config registers the agent address as meter signer | Registration rejected (Section 4) |

**Honest runs.**
- False-positive rate per policy for HEMS arms B0 and B2 (A0 and A1 once run), over every available data day, not only 2022-06-13.
- Score against B2.
- S9 needs realized flows. Check whether the HEMS simulation outputs realized PV, load and battery dispatch given cleared positions. If not, add a delivery simulator: cleared positions plus realized PV and load → battery dispatch → meter import and export per slot. Report what was built.

**Synthetic feeds, documented in the repo:**
- Tariff from the HEMS tariff series.
- Envelope: static connection limit, with a midday export cut on some days.
- GridState: scripted ALERT episodes; optionally replay HRIA f_PCC.

**Metrics:**
- false positives per policy per arm;
- S9 ARL₀ and ARL₁;
- regret vs B2 with each policy enabled;
- gas per policy and combined at k = 8, 48, 96.

## 8. Build order and acceptance

Each step passes before the next. Mutation suite and verifier are extended at every step: every new comparison gets `<=`/`<` and off-by-one mutants, and the verifier recomputes every new quantity by brute force.

1. **C1–C5 and oracle infrastructure** (the four kinds, per-slot meter storage, signer distinctness).
   - Accept: the two-market aggregation test, and the distinctness rejections.
2. **G1.**
   - Accept: probing campaign suspended; zero suspensions on honest arms; cancel-only while suspended.
3. **Tariff oracle, A3T, S7.**
   - Accept: price walk and collusive transfer blocked; honest false positives reported.
4. **S8.**
   - Accept: churn blocked across two markets; a single correction passes.
5. **Meter oracle, S9, `poke`, calibration.**
   - Accept: chronic oversell alarm and penalty levels; fail-closed on missing readings; honest ARL₀ ≥ target; `poke` persists alarms without a market call.
6. **Envelope oracle, S10.**
   - Accept: envelope breach blocked across markets; tightening update behaviour; static fallback.
7. **Tier-1 evaluation** (Section 7, all but S12). Report before step 8.
8. **S12 and GridState**, only after Dan confirms. Accept the S12 rows of Section 7.

## 9. Decisions (defaults to build with)

| ID | Decision | Default |
|---|---|---|
| D15 | Markets with different slot lengths on one account | Reject registration |
| D16 | S9 when meter readings are missing beyond grace | Fail closed on new SELLs |
| D17 | Agent state while suspended by G1 | Cancel-only |
| D18 | S12 when grid state is stale or missing | Fail open (NORMAL) |
| D19 | S9 slack k | Per account, p95 of honest shortfall under B2 |
| D20 | S12 source | Signed GridState first; HRIA Coordinator adapter optional |
| D21 | S7 and S8 budgets | S7: L $1.00, S $0.50 per 7 days. S8: H 1 kWh, S 0.5 kWh per 24 h |

## 10. Invariants added to v0.1

- METER and ENVELOPE signers are distinct from the BMS and PV signers and from every agent address, checked at registration.
- Penalty and suspension state changes only through deterministic processing of signed data or owner actions, never through agent-supplied values.
- A policy that overrides D10 (S6, S12) declares the exception in its NatSpec and has a test for it.
- Fail-closed by default. Fail-open only where declared (S12, and S10's static fallback), with the reason in the code.
- Every new quantity is recomputable by the independent verifier from events alone. Alarm, penalty and suspension events carry the inputs that triggered them.

## 11. Decisions of 21 October 2026: what is implemented

This section is binding for implementation. Sections 1–10 remain as the analysis behind it.

### 11.1 Implementation set

**Updates to implemented policies: all of Section 3.**
- C1: A1 rated-power term.
- C2: A1 minimum order size.
- C3: S3 socMin hour-of-day profile.
- C4: ledger aggregation across all registered markets. **Highest priority:** every sequence policy depends on it.
- C5: fees counted in S1, if the market charges any.

**New sequence policies (5):**

| ID | Policy | Spec |
|---|---|---|
| S9 | Delivery reconciliation: CUSUM on sold vs meter-delivered energy, escalating sell limits | §5 S9, unchanged |
| S7 | Dominated-trade budget, sliding window | §5 S7 |
| G1 | Session circuit breaker in the gate | §5 G1 |
| S10 | Operating envelope, across orders and markets | §5 S10 |
| S8 | Same-slot round-trip quota | §5 S8 |

**New per-transaction policies (3):**

| ID | Policy | Spec |
|---|---|---|
| A3T | Tariff-relative price band | §5 A3T |
| A9 | Recipient lock | §11.2 |
| A10 | Grid-state direction gate | §5 S12 rules, built as a per-transaction policy (§11.3) |

**Oracles needed:** `TariffSchedule`, `MeterReading`, `Envelope`, `GridState` (Section 4), with signer distinctness.

**Not implemented in this round:**
- S14 counterparty concentration;
- COSIGN;
- carry-over on structural changes;
- carbon, fairness and privacy items;
- the market layer (§11.5).

### 11.2 A9. Recipient lock (new spec)

**Closes:** payee swap and fund drain (Compositional Security). Any registered market function that moves funds out of the market or the account is a drain path once the agent can call it.

**Rules:**
- Every registered (target, selector) is classified by its decoder as ORDER, CANCEL or FUNDS_MOVE.
- A FUNDS_MOVE selector (withdraw, claim, transfer, or similar) must decode its recipient and amount.
  - The gate rejects the call unless recipient == account.
  - A selector that can move funds but whose decoder cannot expose the recipient cannot be registered.
- An `approve(spender, amount)` call on the settlement token is accepted only if the spender is a registered market contract.
- Implement in the gate, next to the A7 allowlist, not as an IPolicy: the rule binds every call, whatever policies are installed.

**Acceptance:**
- withdraw to the agent's address rejected;
- withdraw to the account passes;
- approve to an unregistered spender rejected;
- registration of a funds-moving selector without a recipient decoder refused;
- mutants on the recipient comparison caught.

### 11.3 A10. Grid-state direction gate

- Same rules, oracle and fail-open default as §5 S12 (D18, D20). Built now, not after the tier-1 evaluation.
- Built as a stateless `GridStatePolicy`: each submission is judged only against the current signed grid state and the ledger.
- Keeps the declared exception to D10: in DEFICIT, cancelling or reducing a SELL is rejected.

### 11.4 Framing: every policy is owner-side (option 1)

All policies are installed and configured by the owner at the owner's account. They protect different parties:

| Protects | Policies |
|---|---|
| Owner | A1, A2, A3, A3T, A4, A6, A7, A8, A9, S1, S4, S7, G1, S2 (mostly) |
| Owner and counterparties | S3, S9 |
| Market or grid | S5, S6, S8, S10, A10 |

For the market-or-grid group, the owner's incentive is **liability**:
- spoofing and wash trades by the agent are the owner's offence under REMIT;
- envelope breaches and counter-grid trading bring DSO penalties and curtailment to the owner.

Stated limitation, for the paper: the owner can widen these after the timelock or uninstall the gate, so they bind the agent, not the owner.

### 11.5 Next paper, not implemented: market layer (option 2)

A second configuration authority in the gate:
- The market operator or DSO sets a baseline for the market-or-grid policies (S5, S6, S8, S10, A10). The owner can only tighten it.
- The market contract accepts orders only from accounts whose gate has that baseline installed, checked at order time.

This removes the owner's ability to switch off policies that protect others. Do not build it now. Keep interfaces open for it: config records should carry their author, and policies should not assume the owner is the only configurer.

### 11.6 Build order (replaces Section 8)

Each step passes before the next. The mutation suite and the independent verifier are extended at every step.

1. **C1–C5, the four oracle kinds, signer distinctness.**
   - Accept: the two-market aggregation test; the distinctness rejections.
2. **G1 and A9** (both in the gate).
   - Accept: G1 rows of Section 7; the A9 acceptance in §11.2.
3. **Tariff oracle, A3T, S7.**
   - Accept: price walk and collusive transfer blocked; honest false positives reported.
4. **S8.**
   - Accept: churn blocked across two markets; a single correction passes.
5. **Meter oracle, S9, `poke`, calibration** (D19).
   - Accept: chronic oversell alarm and penalty levels; fail-closed on missing readings (D16); honest ARL₀ ≥ target; `poke` persists alarms without a market call.
6. **Envelope oracle, S10.**
   - Accept: breach blocked across markets; tightening update; static fallback.
7. **GridState oracle, A10.**
   - Accept: DEFICIT blocks BUY placement and SELL cancellation; SURPLUS mirrored; stale state is NORMAL.
8. **Evaluation:** Section 7 in full, including A9, plus the honest false-positive and gas reports.

## 12. Build status

Kept current at the end of each step of 11.6. Detail in `docs/decisions/design-decisions.md`, section "v0.2 Step 1" onwards.

| Step | Branch | Status |
|---|---|---|
| 1. C1–C5, four oracle kinds, signer distinctness | `v0.2/1-oracles-aggregation` | Committed `7b4c8d7`, 21 October |
| 2. G1 session circuit breaker, A9 recipient lock | `v0.2/2-breaker-recipient` | Committed `9bc3c52`, 22 October |
| 3. A3T tariff band, S7 dominated-trade budget | `v0.2/3-tariff-band` | Committed `2afdd4e`, 24 October |
| 4. S8 same-slot round-trip quota | `v0.2/4-round-trip` | Committed `ad2d0f4`, 24 October |
| 5. S9 delivery reconciliation, `poke`, delivery simulator, calibration | `v0.2/5-delivery` | Committed `aec1ef7`, 25 October |
| 6. S10 operating envelope | `v0.2/6-envelope` | Committed `17a092a`, 25 October |
| 7. A10 grid-state gate | `v0.2/7-grid-state` | Committed `858eb84`, 25 October |
| 8. Evaluation | `v0.2/8-evaluation` | Committed, 25 October; report `docs/reports/evaluation-v0.2-2026-10-25.md` |

**Decisions of 21 October 2026, before step 1** (log v0.2-1.1):
- Agent keys for signer distinctness are declared by the owner in the OracleVerifier (at most 8): the gate has no agent registry since D1.
- D15 extended: a market whose slot grid differs from the account's in length **or origin** is refused.
- Meter readings follow per-slot rules (any order once the slot has ended; ring of 128 slots), not the "reordered" rule of Section 4.

**Findings of step 1:**
- C4: the ledger already summed across markets (no market key per slot); the gap was the slot grid. One grid per account now lives in the ledger.
- C5: the ported market charges no fee. The settlement deviation penalty is not order-time spend.
- The independent verifier is JavaScript (v0.1 log 3.7), not Python.

**Decisions of 21 and 22 October 2026, step 2** (log v0.2-2.1):
- D17 cancel-only is pure cancellations, still judged by every policy; G1 is opt-in; A9 refuses without reverting and G1 counts the refusal; `setPaymentAllowance` and `setApprovalForAll` are A9 approvals.
- An honest arm becomes day-ahead batches of net per-slot orders. G1's honest run leaves out S3 and S4 and merges flows below A1's minimum.

**Findings of step 2:**
- G1 suspends the account's `submit` path, the owner's own `submit` included: the gate sees no agent (D1).
- S3 rejects honest household days: its constant reserve load (D4) reads grid imports for the house as battery charge. A1's 50 Wh demo minimum catches 13 % of honest slots. Both are for step 8.

**Decisions of 22 October 2026, step 3** (log v0.2-3.1):
- The honest agent prices at the tariff (BUY at retail, SELL at feed-in; 1 unit where it is zero). The demo's absolute A3 bounds widen to 0.001–2.50. The demo runs with A3T and S7, on a synthetic flat tariff (retail 0.28, feed-in 0.16); the HEMS tariff is for the honest replay and step 8.

**Findings of step 3:**
- The HEMS tariff of 2022 is real-time: retail median 0.067 USD/kWh, from 0 to 2.00, and 0 in 467 of 17,520 slots. A3T refuses every BUY where retail is 0, since the band above 0 is 0. A3's absolute sell floor (0.001) refuses every SELL where feed-in is below it: 0 in the same 467 slots, above 0 but under 0.001 in 153 more. Over the year, the honest arms had 95 (B0) and 116 (B2) A3 or A3T refusals. Open for Dan (log v0.2-3.8).
- S7 counted nothing for either honest arm over the year: priced at the tariff, nothing is given away.
- S7 keeps the excess it charged per placement, so a credit never depends on a later tariff.

**Findings of step 4** (log v0.2 Step 4):
- S8 reads the ledger's committed positions, already summed across markets (C4), so churn split between two venues is one round trip. A modification is a cancellation and a placement, so S8 counts only what it adds.
- S8 counted nothing for either honest arm over the year: a day-ahead agent nets each slot.
- The step 3 gas figure for A3T and S7 was not the worst case it claimed (S7 counted nothing in that test). Corrected: 12,001,954 gas for the 24-offer batch, +11.2 %.

**Decisions of 25 October 2026, steps 5 to 8** (log v0.2-5.1):
- Dan asked for steps 5 to 8 in one go: each step on its own branch, committed under his name, with its hand-over in the log.
- S9's honest data come from a delivery simulator (§7); the calibration is in JavaScript in this repo; A3T at zero tariff stays as specified; regret vs B2 settles refused volume at the real-time price.
- **D19 refined:** k is the p95 of honest shortfall over the slots where the agent sold. Over all slots it is 0 (only 3.8 % of B2's half-hours fall short).

**Findings of step 5:**
- k = 436 Wh, h = 2,100 Wh (home_01, B2). On chain, honest B2 alarms 36.3 days apart (target ≥ 30); B0 22.7 days apart with B2's calibration: per account means per controller too.
- ARL₁ under oversell: +10 % 14.0 days between alarms, +20 % 9.9, +50 % 3.1; winter delays the first alarm to February.
- S9 reads a slot only once reconciled, and only when processing reaches it: a keeper's `poke` keeps alarms and D16 current. A reading older than the meter's 128-slot ring can no longer be posted; the owner's reset moves past it.

**Findings of step 6:**
- S10 judges a modification's two legs as one change to the slot, so reducing a sale after a tightening passes.
- On the synthetic envelope (9 kW, a midday export cut to 40 % every fifth day), S10 refused 3 honest B2 submissions in the year and none of B0's; the rating itself never binds for home_01.

**Findings of step 7:**
- A10 judges the change per slot, not per leg: a modification that raises or only reprices a sale passes in DEFICIT; withdrawing or reducing one is refused (the declared exception to D10).
- Every v0.2 policy at its worst in one 24-offer batch costs about 12.93 M gas, 3.8 M under EIP-7825's cap.

**Findings of step 8** (evaluation report §7):
- Every §7 attack is shown blocked by its policy and passing without it (13 of 13, A9 included).
- Honest arms, a year each, every policy but S3/S4: B0 21.6 %, B2 25.0 % of submissions refused; no suspension. Every A1–A6 refusal is A3 or A3T at the bottom of the tariff; A10 costs an agent that ignores the grid nearly every alert day; S7, S8 and S10 cost almost nothing.
- With S3 kept, about 70 % refused: S3 needs a load forecast before it can run against a real household.
- S9 meets ARL₀ ≥ 30 days for B2 (40.3) and not for B0 (24.2) with B2's calibration: calibrate per controller.
- Replays now reproduce exactly (fixed block times).
