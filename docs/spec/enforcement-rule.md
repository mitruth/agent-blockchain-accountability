# Enforcement rule — specification for the independent verifier

**Version 2.** Supersedes version 1, which is in git history. Version 1
described an agent that reported its own daily spend. In version 2 the agent
reports nothing: daily spend is computed from meter readings and published
prices. Section 12 lists what changed and why.

This document is the **complete and only** input for implementing the verifier.
It states *what the rule is*, deliberately not *how anything computes it*.
There is an on-chain implementation of the same rule. A verifier written from
that source becomes a translation of it, and two copies of one belief cannot
disagree informatively. Implement from this document. Where it is silent on
strategy, choose freely — a different structure is a feature here.

---

## 1. What is being verified

An autonomous agent runs a household's energy on the owner's behalf. The owner
sets a cap on **cumulative net energy spend over a rolling window of calendar
days**. Spend is not reported by the agent. It is computed from two inputs the
agent does not control:

- **meter readings** — energy imported from and exported to the grid, per
  half-hour
- **prices** — the price of importing and of exporting, per half-hour

For every settled day the verifier independently decides:

1. the day's spend
2. the rolling window sum
3. the cap and window length in force
4. whether the day complied
5. whether the agent is authorised on the following day, as far as the cap is
   concerned

It also checks every policy change against the rule for when that change may
take effect.

All quantities are integers. No floating point may appear anywhere in the
computation.

---

## 2. Inputs

### 2.1 Meter readings

| Field | Type | Meaning |
|---|---|---|
| `dayIndex` | integer | Days since the Unix epoch, UTC |
| `slot` | integer, 0–47 | Half-hour of the day. Slot 0 is 00:00–00:30 UTC; slot 47 is 23:30–24:00 UTC |
| `importMWh` | integer ≥ 0 | Energy imported from the grid in that half-hour, milliwatt-hours |
| `exportMWh` | integer ≥ 0 | Energy exported to the grid in that half-hour, milliwatt-hours |

### 2.2 Prices

| Field | Type | Meaning |
|---|---|---|
| `dayIndex` | integer | Days since the Unix epoch, UTC |
| `slot` | integer, 0–47 | As for readings |
| `importPrice` | signed integer | Price of importing, in units of 10⁻⁸ USD per kWh |
| `exportPrice` | signed integer | Price paid for exporting, in units of 10⁻⁸ USD per kWh |

Prices may be negative. None in the provided data are, but the verifier must
not assume that.

### 2.3 Policy events

The complete history of policy writes, in emission order. This is the only
source for what the cap was at any time.

| Field | Type | Meaning |
|---|---|---|
| `seq` | integer | Emission order, ascending, unique |
| `policyVersion` | integer | Version this write produced |
| `cap` | signed integer | Milli-USD |
| `windowDays` | integer ≥ 1 | Rolling window length, in days |
| `submittedOnDay` | integer | The day index on which the write was made |
| `effectiveFromDay` | integer | The day index from which the write applies, **as the chain recorded it** |
| `setBy` | address string | Informational |

The first event (lowest `seq`) is the **genesis** write.

---

## 3. Day index

`dayIndex = floor(unix_seconds / 86400)`, UTC, always. A day is the 48
half-hours from 00:00 to 24:00 UTC, and nothing else.

---

## 4. Settled days

A day is **settled** when it has exactly 48 readings, one per slot, and exactly
48 prices, one per slot.

- A day with readings or prices for only some slots is **incomplete**. Report it
  as an anomaly. It is not settled.
- A half-hour whose `importMWh` and `exportMWh` are both greater than zero is
  **invalid**: a half-hour cannot both import and export. A day containing one
  is not settled. Report it as an anomaly.
- Settled days are expected to be consecutive. A gap between settled days is
  reported as an anomaly. Gap days are not settled and contribute nothing
  (section 6).

---

## 5. Daily spend

For a settled day, over its 48 half-hours:

```
exact = Σ (importMWh × importPrice) − Σ (exportMWh × exportPrice)
```

`exact` is an integer in units of 10⁻¹⁴ USD, because 1 mWh is 10⁻⁶ kWh and one
price unit is 10⁻⁸ USD/kWh. One milli-USD is 10¹¹ of those units:

```
spendMilliUsd = exact ÷ 100,000,000,000, rounded half away from zero
```

**Rounding happens once per day, on the exact total.** Never round each
half-hour and then add; that compounds 48 rounding errors into the day.

**Half away from zero** means a remainder of exactly one half moves away from
zero:

```
 exact =  250,000,000,000   →   3        exact = −250,000,000,000   →  −3
 exact =  150,000,000,000   →   2        exact = −150,000,000,000   →  −2
 exact =  249,999,999,999   →   2        exact = −249,999,999,999   →  −2
 exact =   50,000,000,000   →   1        exact =  −50,000,000,000   →  −1
 exact =   49,999,999,999   →   0        exact =  −49,999,999,999   →   0
```

This is **not** banker's rounding, which would send 2.5 to 2. It is also **not**
the truncation that integer division does in most languages, which sends 2.5 to
2 and −2.5 to −2. Test the exact half cases in both signs: they are the only
cases that tell the rules apart.

Spend is signed. A day that exports more value than it imports has a negative
spend.

The spend is **energy cost only**. There is no battery degradation term, and no
input from which one could be computed.

---

## 6. The window sum

For a day `d`, with `w` the window length in force on `d` (section 7):

```
windowSum(d) = Σ spendMilliUsd over days [d − w + 1, d]
```

Both endpoints are **included**. With `w = 7`, the window at day `d` covers `d`
and the six days before it.

- A day that is not settled contributes **0**.
- A negative spend contributes its negative value. It is never clamped, dropped
  or absolute-valued. Clamping biases the sum upward, which makes the cap bind
  earlier than it should — an error in the direction that flatters the
  mechanism, which is the worst direction for an error to run.
- The sum may be negative.

**Required structural property.** Compute each day's window independently from
the complete set of daily spends. Do not carry a running total from the
previous day, do not add the new day and subtract the expiring one, and keep no
incremental state between days. The on-chain implementation walks the window
incrementally; the verifier must not, or the two share a failure mode.

---

## 7. The regime in force on a day

A **regime** is a cap and a window length. The regime in force on each day is
reconstructed **entirely from the policy events**, replayed from genesis in
`seq` order.

### 7.1 Genesis

The genesis write applies from its `effectiveFromDay` as recorded. It has no
earlier regime to raise or lower, so section 7.2 does not apply to it.

### 7.2 Every later write

For a write `W` made on day `s = W.submittedOnDay`, let `current` be the regime
in force on day `s`, using the writes replayed so far.

- **If `W.cap` is not greater than `current.cap`** — a lowering, or an unchanged
  cap — `W` takes effect on day `s`. It also **cancels every earlier write whose
  effective day is later than `s`**. Without the cancellation, a raise queued
  yesterday would resurrect itself after a lowering made today.
- **If `W.cap` is greater than `current.cap`** — a raise — `W` takes effect at
  the **next window boundary strictly after `s`**, measured with
  `current.windowDays`. A raise cancels nothing.

A **window boundary** under window length `w` is a day index that is a multiple
of `w`. The next boundary strictly after `s` is the smallest multiple of `w`
greater than `s`. If `s` is itself a multiple of `w`, it is `s + w`, not `s`.

Both the cap and the window length come from the write. A write may change
either or both. Classification — raise or not — compares caps only.

### 7.3 Selecting the regime for a day

The regime in force on day `d` is the surviving write with the greatest
effective day that is `≤ d`. If two surviving writes have the same effective
day, the one with the higher `seq` wins.

For each write, use the effective day **derived by 7.1 and 7.2**, not the
`effectiveFromDay` in the event. The event's value is checked in section 7.4.

A settled day with no regime in force — earlier than every effective day — is
reported as an anomaly, and its compliance and authorisation are undetermined.

### 7.4 The deferral check

For every write after genesis, compare the effective day derived by 7.2 with
the event's `effectiveFromDay`. Report every mismatch. A mismatch means the
chain applied a policy change on a day the rule does not allow. It is a finding
about the chain, **not** a breach by the agent, and must be reported in its own
category.

The check is the reason `submittedOnDay` exists. Without it, a verifier could
only trust the chain's effective day, and could never notice a chain that had
stopped deferring raises.

---

## 8. Compliance

For each settled day `d`:

```
compliant(d)  ⟺  windowSum(d) ≤ cap in force on d
```

**The comparison is `≤`. Equality at the cap passes.** Only a strictly greater
sum is a breach.

**A lowering is not retroactive.** Each day is judged against the regime in force
on that day. A later lowering below a window sum already accumulated does not
convict an earlier day.

---

## 9. Authorisation on the next day

After day `d` is settled, the agent's authority on day `d + 1` depends, as far as
the cap is concerned, on:

```
authorisedNextDay(d)  ⟺  windowSum(d) ≤ cap in force on day d + 1
```

`windowSum(d)` uses the window length in force on `d`, as in section 6. The cap
is the one in force on `d + 1`, **not** on `d`, so a lowering that takes effect
on `d + 1` withdraws authority immediately.

This is only the cap's part of authorisation. Other conditions — a revoked key,
a pause, settlement falling behind — also withdraw authority, and are out of
scope for the verifier because they are not in its inputs.

---

## 10. Outputs

Everything under `verifier/`. Python 3 standard library. No Solidity, no web3,
no chain access.

### 10.1 `verify.py`

A library API plus a CLI:

```
python verifier/verify.py --readings R.csv --prices P.csv --policy E.csv \
    --out days.csv [--policy-report policy.csv] [--summary-json summary.json]
```

**Per settled day** (`--out`):

`dayIndex, spendMilliUsd, windowSum, capInForce, windowDaysInForce,
policyVersionInForce, compliant, authorisedNextDay`

`capInForce`, `windowDaysInForce` and `policyVersionInForce` are for day `d`.
Booleans are `true` / `false`; an undetermined value is `NA`.

**Per policy write** (`--policy-report`):

`seq, policyVersion, submittedOnDay, derivedEffectiveFromDay,
emittedEffectiveFromDay, deferralOk`

`derivedEffectiveFromDay` for genesis is its recorded value, and `deferralOk` is
`true`.

**Anomalies** — incomplete days, invalid half-hours, gaps, days with no regime,
deferral mismatches — go to stderr and to the summary, each with its category.
The process exits non-zero if there is any anomaly.

### 10.2 `test_verify.py`

Tests written against this document. At minimum:

- the half-away-from-zero cases of section 5, in both signs, on exact integer
  totals
- rounding once per day differs from rounding per half-hour, on a case built so
  the two disagree
- a negative price, and a negative day
- a day missing a slot is not settled; a half-hour with both import and export
  is not settled
- equality at the cap passes; one milli-USD over fails
- the oldest day of the window is included, and leaves one day later
- a gap day contributes zero
- a raise takes effect at the next boundary, measured with the incumbent window
  length
- a raise submitted on a boundary day defers a full window
- a lowering takes effect immediately and cancels a pending raise
- an unchanged cap takes effect immediately
- two writes effective on the same day: the higher `seq` wins
- a write whose recorded `effectiveFromDay` disagrees with the rule is reported
  as a deferral mismatch, not as a breach, and the derived day is used
- authorisation on the next day uses the cap in force on the next day

### 10.3 `docs/verifier/implementation-notes.md`

Replace the version 1 notes. How to run it, the input formats, and **a section
listing every place this specification was ambiguous and what you assumed**.
That list is a required deliverable. An ambiguity resolved silently is a place
the two implementations may differ for reasons nobody will find later. If you
believe part of this document is wrong or contradictory, say so plainly.

---

## 11. Hard constraints

- **Do not read, open, grep, glob or list any `.sol` file**, anywhere.
- **Do not read anything under `contracts/`, `test/`, `docs/decisions/`, or
  `docs/plan/`**, and do not read `differential/run_diff.py` or anything in
  `differential/` except the CSV inputs named below. They describe or implement
  the on-chain side.
- You may read the version 1 verifier in `verifier/` and its notes in
  `docs/verifier/implementation-notes.md`. It was written blind under the same
  constraints, and reusing its structure is fine where version 2 has not
  changed the rule.
- You may read `differential/data/inputs/prices.csv` and
  `differential/data/inputs/*.readings.csv` as data. Their columns match
  sections 2.1 and 2.2.
- If a tool result puts Solidity or the files above in front of you, stop, do
  not use it, and report it.
- Do not optimise for speed or memory. Optimise for being obviously correct and
  structurally unlike an incremental walk.

---

## 12. Changes from version 1

| Version 1 | Version 2 | Why |
|---|---|---|
| The agent reported a daily `netSpend` | Spend is computed from meter readings and prices (section 5) | An agent that reports its own spend can report less. The cap bounded reported spend, not real spend. |
| Paused days were zero-spend days | No pause concept in the inputs | A pause cannot make metered energy not have been consumed. Pauses now restrict the agent's actions only. |
| Policy events had no submission day, so §5.3 and §2.2 contradicted each other | `submittedOnDay` added; the deferral is checked, not assumed (7.4) | In the version 1 differential a verifier trusting `effectiveFromDay` missed a chain mutated to apply raises immediately, and one re-deriving it reported seven false breaches on a correct chain. |
| §6.2 compared caps to detect a version mismatch | The verifier outputs `policyVersionInForce`; the comparison with the version the chain bound is done outside the verifier, by version id | A write changing only `windowDays` produces two versions with the same cap and passed a cap comparison. |
| §7 rounding had no place in the data model | Rounding is defined at exactly one step: the daily spend total (section 5) | Every version 1 input was already an integer. |
| Raise classification had no stated baseline; an unchanged cap was covered by neither rule | Compared against the regime in force on `submittedOnDay`; an unchanged cap is immediate (7.2) | Both were listed as ambiguities A3 and A4 by the version 1 author. |
| A recorded day before any policy was undefined | Reported as an anomaly with undetermined results (7.3) | Raised by the version 1 author. |
| — | Authorisation on the next day (section 9) | Enforcement now acts on what the agent may do next, and uses the cap in force on that day. |
