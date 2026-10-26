# Evaluation of policy spec v0.2, 25 October 2026

Spec `docs/spec/policy-spec-v0.2-gap-policies.md`, §7 in full (build order
11.6 step 8). How each figure was made is in the decision log, "v0.2 Step 8";
every run below can be repeated with the command next to it.

## 1. What was evaluated

- **The system:** the v0.1 gate and policies (A1–A8, S1–S6) and every v0.2
  addition: C1–C5, the four oracle kinds with signer distinctness, G1, A9,
  A3T, S7, S8, S9 with `poke`, S10, A10.
- **The house:** `home_01`, every data day of 2022 (363 market days), on an
  in-process chain whose blocks no longer follow the wall clock, so each run
  reproduces exactly.
- **The honest agents:** the HEMS arms B0 (rules) and B2 (forecast plan; the
  reference). The A arms are left out: their current logs are mock echoes of
  B0 and B2 (`data/arms/README.md`).
- **The agent's behaviour:** each morning it trades the next day as net
  per-slot orders in day-ahead batches of 24, priced at the tariff, from the
  delivery simulator's forecast plan (`offchain/eval/delivery.js`); the
  meter then reports what the real sun and load, and the re-dispatched
  battery, delivered. It does not read the envelope or the grid state, and
  it does not retry a refused batch.
- **Synthetic feeds** (§7): the HEMS tariff; the DSO's envelope, the 9 kW
  connection with a midday export cut to 40 % every fifth day
  (`envelope-feed.js`); grid alerts on fixed days, every 7th DEFICIT, every
  11th SURPLUS, every 61st EMERGENCY (`grid-feed.js`).

## 2. The attacks of §7

`node offchain/eval/section7.js` (report: `section7-2026-10-25.md`). Each
attack is shown blocked by its policy and shown passing without it.

| Attack | Blocked by | Blocked | Counterpart |
|---|---|---|---|
| Price walk: 12 bids, each 3 % above the last | A3T | `test_priceWalk_isBlockedByA3T` passes | `test_priceWalk_passesUnderA3Alone` passes: passes with A3T removed |
| Collusive transfer: sales inside A3T's band but under feed-in | S7 | `test_collusiveTransfer_isBlockedByS7` passes | `test_collusiveTransfer_passesUnderA3TAlone` passes: passes with S7 removed |
| Round-trip churn on one slot, split across two markets | S8 | `test_churnAcrossTwoMarkets_isStoppedByS8` passes | `test_churnAcrossTwoMarkets_passesWithoutS8` passes: passes with S8 removed |
| Chronic oversell against an inflated BMS state of charge; S3 passes | S9 | `test_chronicOversell_isStoppedByS9` passes | `test_chronicOversell_passesWithoutS9` passes: passes with S9 removed |
| Meter withholding: the keeper stops posting readings | S9 | `test_meterWithholding_failsClosed` passes | `test_meterWithholding_passesWithoutS9` passes: passes with S9 removed |
| Envelope breach, split across orders and two markets | S10 | `test_breachAcrossMarkets_isBlockedByS10` passes | `test_breachAcrossMarkets_passesWithoutS10` passes: passes with S10 removed |
| Probing campaign: binary search for the S1 cap | G1 | `test_probingCampaign_isSuspendedByG1` passes | `test_probingCampaign_findsTheCapWithoutG1` passes: finds the cap with G1 removed |
| On-off agent: 2-slot bursts, 10-slot rests | G1 | `test_onOffAgent_isSuspendedWithinTheFlagWindow` passes | `test_onOffAgent_spacedBeyondTheWindowIsNeverSuspended` passes: the same bursts spaced beyond the 24 h window are never suspended |
| Counter-grid trading under ALERT, cancelling sales in DEFICIT | A10 | `test_counterGrid_isBlockedByA10` passes | `test_counterGrid_passesWithoutA10` passes: passes with A10 removed |
| Signer collusion: the agent's address registered as a signer | registration | `test_noAgentKeyMayBeARegisteredSigner` passes | `test_noSignerOfAnyKindMayBeADeclaredAgentKey` passes: the converse: a signer cannot be declared an agent |
| A9: a withdrawal to the agent | A9 | `test_aWithdrawalToTheAgentIsRefused` passes | `test_aWithdrawalToTheAccountPasses` passes: a withdrawal to the account passes |
| A9: an approval for an unregistered spender | A9 | `test_anAllowanceForAnyoneElseIsRefused` passes | `test_anAllowanceForARegisteredMarketPasses` passes: an allowance for a registered market passes |
| A9: a funds-moving selector without a recipient decoder | A9 | `test_aFundsMoveWithoutADecodableRecipientCannotBeRegistered` passes | `test_theTokenDecoderExposesEveryRecipient` passes: the token decoder exposes every recipient |

**13 of 13 attacks shown both ways.** Two counterparts are not "the policy removed": G1's on-off agent passes when its bursts are spaced beyond the 24 h window, and signer collusion is refused at registration (the converse is shown). The chronic oversell is blocked within two slots (§4).

## 3. Honest false positives, per policy and arm

`node offchain/eval/honest-day-ahead.js --arm <B0|B2> --delivery`, every
policy but S3 and S4; reports `honest-eval-<arm>-2026-10-25.json`; tables by
`node offchain/eval/summarize.js`. "Refused" and "flagged" count
submissions; a submission is a batch of up to 24 orders. Regret: the refused
energy settled at the real-time price (0.30 USD/kWh) instead of the tariff;
a refused buy costs q (0.30 − p), a refused sale earns q (p − 0.30), negative
while feed-in is below 0.30.

### B0

363 days; 989 submissions, 214 refused (21.6 %), 142 flagged; **0
suspensions**; 84 grid alerts; S9 15 alarms, ARL₀ 24.2 days.

| Policy | Refused | Flagged | Refused buy kWh | Refused sell kWh | Buy regret USD | Sell regret USD |
|---|---:|---:|---:|---:|---:|---:|
| A1–A6 per action (A3 85, A3T 22) | 107 | 0 | 274.5 | 1,202.8 | 67.75 | −354.20 |
| S7 dominated trades | 0 | 0 | 0 | 0 | 0 | 0 |
| S8 round trip | 0 | 0 | 0 | 0 | 0 | 0 |
| S9 delivery | 7 | 0 | 0 | 121.2 | 0 | −30.38 |
| S10 envelope | 0 | 16 | 0 | 0 | 0 | 0 |
| A10 grid state | 77 | 0 | 927.2 | 342.8 | 160.52 | −97.17 |
| S1 budget | 28 | 15 | 567.2 | 0 | −50.21 | 0 |
| S2 export / import | 0 / 13 | 0 / 0 | 244.5 | 0 | 32.48 | 0 |
| S6 cancel quota | 0 | 0 | 0 | 0 | 0 | 0 |
| S5 ramp | 7 | 120 | 108.7 | 24.7 | 23.46 | −7.16 |
| **Any policy** | **214** | **142** | **1,805.8** | **1,568.1** | **220.52** | **−452.64** |

### B2

363 days; 831 submissions, 208 refused (25.0 %), 163 flagged; **0
suspensions**; 84 grid alerts; S9 9 alarms, ARL₀ 40.3 days.

| Policy | Refused | Flagged | Refused buy kWh | Refused sell kWh | Buy regret USD | Sell regret USD |
|---|---:|---:|---:|---:|---:|---:|
| A1–A6 per action (A3 49, A3T 61) | 110 | 0 | 1,006.6 | 700.5 | 257.51 | −205.64 |
| S7 dominated trades | 0 | 0 | 0 | 0 | 0 | 0 |
| S8 round trip | 0 | 0 | 0 | 0 | 0 | 0 |
| S9 delivery | 4 | 0 | 0 | 56.4 | 0 | −15.68 |
| S10 envelope | 3 | 16 | 0 | 59.0 | 0 | −16.25 |
| A10 grid state | 82 | 0 | 886.0 | 336.6 | 164.60 | −95.51 |
| S1 budget | 21 | 10 | 506.6 | 0 | −29.19 | 0 |
| S2 export / import | 0 / 0 | 0 / 0 | 0 | 0 | 0 | 0 |
| S6 cancel quota | 0 | 0 | 0 | 0 | 0 | 0 |
| S5 ramp | 9 | 145 | 162.3 | 40.3 | 35.63 | −11.46 |
| **Any policy** | **208** | **163** | **2,322.1** | **1,049.8** | **396.79** | **−303.67** |

### With S3 and S4 (`--full`)

The same runs with S3 and S4 kept (`--full`; reports
`honest-eval-<arm>-full-2026-10-25.json`). Only the rows that differ:

| | B0 | B2 |
|---|---:|---:|
| Submissions refused | **704 of 989 (71.2 %)** | **637 of 831 (76.7 %)** |
| Refused by S3 deliverability | 668 | 591 |
| Refused / flagged by S4 cycles | 84 / 35 | 71 / 16 |
| Refused buy / sell kWh, any policy | 5,867.9 / 5,021.2 | 5,341.4 / 4,012.1 |
| Buy / sell regret USD, any policy | 1,080.04 / −1,412.43 | 1,020.86 / −1,126.44 |
| S9 alarms | 0 | 0 |
| Suspensions (G1) | 0 | 0 |

S3 refuses two submissions in three of an honest house: its constant reserve
load (D4) reads the house's own imports as battery charge (since step 2).
With most sales refused there is nothing left for S9 to find short. S3 needs
a load forecast before it can run against a real household.

## 4. S9: false alarms and detection

- **Calibration** (`node offchain/eval/calibrate-s9.js`;
  `calibration-s9-2026-10-25.json`): k = 436 Wh, the p95 of B2's shortfall
  over the slots where it sold (decision of 25 October: over all slots it is
  0, as only 3.8 % of half-hours fall short); h = 2,100 Wh, the smallest with
  ARL₀ ≥ 30 days under B2.
- **ARL₀, honest, on chain:** B2 9 alarms, **40.3 days** apart (target met);
  B0 15 alarms, 24.2 days apart (not met: S9 is calibrated on B2, and B0 is
  another controller on the same house, selling more and missing more).
- **ARL₁, chronic oversell** (every sale made larger, the battery trying to
  deliver it; off-chain, through the simulator): +10 % 26 alarms a year (14.0
  days apart), +20 % 37 (9.9), +50 % 119 (3.1). The first alarm comes in
  early February in every case: winter has few sales to oversell.
- **The chronic-oversell test** (§2): with the BMS lying that the battery is
  full, the alarm comes on the second slot, and level 1 refuses the next
  sale.

## 5. Gas

Reports `gas-v0.2-step3` to `step7`; per policy at k = 8, 16, 24, 48, 96
from `Step5Acceptance.t.sol` (`test_gas_k*`). Warm storage, one transaction.

**One offer, every policy added one at a time:**

| Added | k = 8 | k = 48 | k = 96 |
|---|---:|---:|---:|
| none | 382,733 | 382,733 | 382,733 |
| + S3 | 469,107 | 653,133 | 876,787 |
| + S4 | 527,784 | 810,912 | 1,156,107 |
| + S5 | 552,065 | 835,193 | 1,180,388 |
| + S1, S2 ×2 | 602,663 | 885,791 | 1,230,986 |
| + A1–A6 with A3T | 627,747 | 910,875 | 1,256,070 |
| + S7 | 669,307 | 952,435 | 1,297,630 |
| + S8 | 691,146 | 974,274 | 1,319,469 |
| + S9 | 726,257 | 1,009,385 | 1,354,580 |
| + S10 | 748,727 | 1,031,855 | 1,377,050 |
| + A10 (an ALERT in force) | 767,087 | 1,050,215 | 1,395,410 |

S3 and S4 grow with the horizon; every v0.2 policy costs the same at every k.

**The day-ahead batch** (24 offers, k = 48, every policy, each at its worst:
every offer dominated, every slot a round trip, the envelope and an alert
over every slot): 12,694,138 gas, and about 12.93 M with S9 taking in 8
settled slots. The per-transaction cap (EIP-7825) is 16,777,216: about
3.8 M of headroom.

## 6. Mutation

Every catalogue, in Foundry's Docker image (`npm run mutate`): 14
catalogues, 492 mutants. **489 caught, 3 accepted, none missed, none failed
to build.** Per mutant: `mutation-v0.2-2026-10-25.md`.

- **The 3 accepted** are `ledger`'s faults in the mock market, a test double
  of `test/gate/`, accepted since v0.1. The real market's catalogue,
  `market`, catches all 55 of its own.
- **Every catalogue in full:** `gate` 43, `ledger` 51 (48 + 3 accepted),
  `market` 55, `window` 35, `policies` 53, `physical` 47, `oracle2` 34,
  `breaker` 45, `price` 30, `roundtrip` 20, `delivery` 37, `envelope` 18,
  `gridstate` 15, `accounts` 9.
- **The v0.1 catalogues** (`gate`, `ledger`, `market`, `window`, `policies`,
  `physical`, `accounts`) were re-run on the v0.2 code, which changed the
  gate, the ledger and the market beneath them; each v0.2 catalogue also
  ran in full at its own step, with the same result.
- **The run went in three parts** (25–26 October): one stopped to commit
  this step, one that died overnight with the session, and one of 343
  mutants in 186 minutes that re-ran `window` in full and finished the
  rest. The report merges the three logs.

## 7. Findings for calibration

1. **A3T and A3 at the bottom of the tariff** (log v0.2-3.8, left as
   specified by Dan's decision). The 2022 tariff is 0 in 467 half-hours, and
   feed-in is under 0.001 in 153 more: A3T refuses every buy where retail is
   0, A3's 0.001 sell floor every sale under it. Every one of A1–A6's
   refusals is A3's or A3T's (B0 85 + 22 = 107, B2 49 + 61 = 110).
2. **A10 against an agent that ignores the grid:** 77 (B0) and 82 (B2) of 84
   alert days cost a submission. An agent that reads the state and trades
   with the grid's need would lose little; the cost here is of not reading
   it.
3. **S5's ramp and S1's budget** (since step 2) still refuse honest days and
   flag many (S5 120 and 145 flags). S1's buy regret is negative: it refuses
   when retail is above the real-time price.
4. **S9 is calibrated per controller, not per house:** B0 misses the ARL₀
   target with B2's k and h. Level 2 is common (B0 6 of 15 alarms, B2 3 of
   9): honest alarms are a month apart on average but cluster in the season,
   within the 7-day escalation window.
5. **S3's load model** (since step 2): see the `--full` runs above.
6. **G1** never suspended an honest arm, but a day-ahead agent submits at
   most a few times a day: an intraday agent would test it hard.
7. **S7, S8 and S10 cost an honest day-ahead agent almost nothing** (S10 3
   refusals in B2's year, on cut days).

## 8. Limits of this evaluation

- One house, one year, two honest arms; the A arms were not run.
- The delivery simulator is a model: the plan is B2's forecasts with the
  arm's own battery schedule, re-dispatched to honour the contracts; an order
  the policies refuse is still delivered as planned.
- The envelope and grid feeds are synthetic, on fixed days.
- Regret settles refused energy at the market's deviation penalty price: a
  bound of the stakes, not a bill.
- Gas is measured with warm storage in one transaction; cold reads cost more
  (the step 3 report quantifies the tariff's).
