# Independent verifier: rolling-window energy spending cap (version 2)

> **Earlier design.** This document describes the daily spend rule that came before
> Policy Spec v0.1 (`PolicyConfig`, `SpendLedger`, `SpendValidator`). It is kept for
> reference and is no longer maintained. The current project is described in
> `docs/guide/project-guide.md`.

This verifier is a separate implementation of the rule in
[`docs/earlier-design/enforcement-rule.md`](../spec/enforcement-rule.md), **version 2**.
It replaces the version 1 verifier, which checked daily spend reported by the
agent. Version 2 works out daily spend itself from meter readings and prices.

**Provenance.** Written from `enforcement-rule.md` v2 alone. The only other
files read were the version 1 verifier (`verifier/verify.py`,
`verifier/test_verify.py`, `verifier/fixtures/`), the version 1 copy of this
notes file, and the data files `differential/data/inputs/prices.csv` and
`differential/data/inputs/B{0,1,2}.readings.csv`. Those data files were used
only to check column names and value ranges and for smoke runs. No `.sol` file
and nothing under `contracts/`, `test/`, `docs/decisions/`, `docs/plan/`,
`scripts/`, `artifacts/` or `cache/` was opened, searched or listed. The same
goes for anything else in `differential/`, the root `README.md` and
`docs/guide/`.

---

## Running it

Python 3 standard library only (developed on 3.14.6). No third-party packages
and no chain access.

```bash
python verifier/verify.py --readings R.csv --prices P.csv --policy E.csv \
    --out days.csv [--policy-report policy.csv] [--summary-json summary.json]
```

| Flag | Meaning |
|---|---|
| `--readings` | meter readings CSV (required) |
| `--prices` | prices CSV (required) |
| `--policy` | policy events CSV (required) |
| `--out` | per-settled-day CSV (required; `-` writes to stdout) |
| `--policy-report` | per-policy-write CSV |
| `--summary-json` | JSON with counts, total spend, breach days, every anomaly, and the full policy replay (classification, incumbent, cancellation) |

Exit codes:

- `0`: no anomalies. Breach days can still be present (see A20).
- `1`: at least one anomaly.
- `2`: input the verifier cannot read, such as a non-integer field, a slot
  outside 0–47, a negative energy value, `windowDays < 1`, a duplicate `seq`,
  or a missing column.

Every anomaly goes to stderr as `ANOMALY [category] day=N detail`. A one-line
summary follows.

### Tests

`pytest` is **not** installed here, so the suite uses `unittest`:

```bash
python -m unittest discover -s verifier -p "test_*.py" -v
python verifier/test_verify.py
```

There are 53 tests and all pass. They cover every case in spec §10.2, plus
settlement edge cases, window independence, the CLI (column order, `NA`, exit
codes) and a scan of `verify.py`'s syntax tree. The scan confirms there are no
float literals, no `float`, no `round`, no `/`, and no `decimal`/`Decimal`/
`quantize`.

A mutation check was run on a scratch copy. The suite catches each of these
single-change mutants:

- half-cases rounding down
- truncation toward zero for negative values
- `<` in place of `<=`
- authorisation using the cap on day `d`
- dropping the oldest day of the window
- measuring the deferral boundary with the new write's window length
- a non-strict boundary
- no cancellation
- an unchanged cap treated as a raise
- the lower `seq` winning a tie
- trusting the chain's `effectiveFromDay`

### Library API

```python
import verify as v
report = v.verify(readings, prices, events)   # lists of Reading / Price / PolicyEvent
report.days       # list[DayResult]    settled days only, ascending
report.policy     # list[PolicyRow]    one per write, ascending seq
report.replay     # list[ReplayedWrite] incl. classification, incumbentSeq, cancelledBySeq
report.spends     # {dayIndex: spendMilliUsd} for settled days
report.anomalies  # list[Anomaly(category, dayIndex, detail, seq)]
report.ok         # no anomalies
```

---

## Input formats

All inputs are CSV files with a header row. Columns are matched by name and
extra columns are ignored. Every numeric field must match `[+-]?[0-9]+`: ASCII
digits only, so `1.0`, `1e3`, blanks and non-ASCII digits are rejected. No
value is rounded while parsing.

| File | Required columns | Checked on parse (else exit 2) |
|---|---|---|
| readings | `dayIndex, slot, importMWh, exportMWh` | slot in 0–47; energies ≥ 0 |
| prices | `dayIndex, slot, importPrice, exportPrice` | slot in 0–47; prices may be negative |
| policy | `seq, policyVersion, cap, windowDays, submittedOnDay, effectiveFromDay` (+ optional `setBy`) | `windowDays` ≥ 1; `seq` unique |

## Output formats

`--out`:
`dayIndex,spendMilliUsd,windowSum,capInForce,windowDaysInForce,policyVersionInForce,compliant,authorisedNextDay`

`--policy-report`:
`seq,policyVersion,submittedOnDay,derivedEffectiveFromDay,emittedEffectiveFromDay,deferralOk`

Booleans are written as `true`/`false`. A value that cannot be determined is
written as `NA`.

### Anomaly categories

| Category | Source | Spec |
|---|---|---|
| `incomplete_day` | readings or prices missing slots for a day found in either input | §4 |
| `invalid_half_hour` | a half-hour with import > 0 and export > 0 | §4 |
| `gap` | one maximal run of unsettled days between two settled days | §4 |
| `no_regime` | a settled day earlier than every surviving effective day | §7.3 |
| `deferral_mismatch` | derived effective day ≠ emitted, for a write after genesis | §7.4 |
| `duplicate_slot` | more than one row for a (day, slot) in one input | not named; see A2 |
| `policy_out_of_order` | `submittedOnDay` decreases as `seq` increases | not named; see A15 |
| `no_incumbent_regime` | a later write with no regime in force on its `submittedOnDay` | not named; see A14 |

---

## How it is computed

The verifier runs four pure stages, and each takes complete inputs:

1. **`settle(readings, prices)`** returns `{day: spendMilliUsd}` for settled
   days only, plus settlement anomalies. For each day it sums
   `Σ import×importPrice − Σ export×exportPrice` exactly over 48 slot pairs,
   then calls `round_exact_to_milli_usd` once on that total. Rounding uses
   `divmod` on the magnitude: if `2·remainder ≥ 10¹¹` the result moves one
   further from zero, then the sign is restored. There is no float, no
   `Decimal` and no `round()`.
2. **`replay_policy(events)`** processes writes in `seq` order. For each write
   it records the derived effective day, a classification (`genesis`, `raise`,
   `not_raise`, `no_incumbent`), the incumbent it was compared against, and
   `cancelledBySeq` if a later write cancelled it. The incumbent is found by
   calling `regime_on` over the writes replayed so far.
3. **`regime_on(writes, day)`** scans every surviving write, keeps those with
   derived effective day `≤ day`, and returns the one with the largest
   `(effectiveDay, seq)`.
4. **`window_sum(spends, day, w)`** scans the **entire** spend mapping and adds
   every entry with `day − w + 1 ≤ dayIndex ≤ day`.

### The independence requirement (spec §6)

`window_sum` is a pure function of the complete set of settled-day spends, a
day and a window length:

- It keeps nothing between calls: no accumulator, no subtraction of an
  expiring day, no cursor or deque, and no prefix sums or memoisation.
- It does not iterate over the day range and look days up. It filters the
  whole mapping, so it makes no assumption that the data is ordered or
  contiguous.
- Days that are not settled contribute 0 simply because they are not in the
  mapping.
- The main loop in `verify` calls `window_sum` and `regime_on` separately for
  each day, and nothing from one day's result reaches the next day's
  computation.
- Tests confirm that forward, backward, shuffled and isolated evaluations agree
  with a brute-force sum. They also confirm that a change in window length
  mid-series gives a fresh answer without adjusting anything.

---

## Smoke runs (real data, 364 UTC days 18994–19357)

All three buildings have 17 472 readings rows and share a 17 472-row price
file. The data has no missing or duplicate slots, no half-hour that both
imports and exports, and no negative prices.

| Run | Settled | Total spend (milli-USD) | Breach days | `authorisedNextDay=false` | Anomalies | Exit |
|---|---|---|---|---|---|---|
| B2 + `policy_genesis_w7.csv` (cap 50 000, w 7, from day 0) | 364 | 728 421 | 26 | 26 | 0 | 0 |
| B2 + `policy_multi_event.csv` | 364 | 728 421 | 27 | 27 | 0 | 0 |
| B2 + `policy_deferral_mismatch.csv` | 364 | 728 421 | 27 | 27 | 1 (`deferral_mismatch`, seq 7) | 1 |
| B0 + `policy_genesis_w7.csv` | 364 | 754 526 | 26 | 26 | 0 | 0 |
| B1 + `policy_genesis_w7.csv` | 364 | 680 618 | 26 | 26 | 0 | 0 |

B2 details:

- 20 days have negative spend. The smallest daily spend is −1 237 and the
  largest is 40 905.
- The 7-day window sum ranges from 8 to 107 036.
- With the genesis-only policy, the breach runs are 19242–19248 and
  19337–19355.

What `policy_multi_event.csv` exercises (§7.2), as the replay reports it:

| seq | Write | Result |
|---|---|---|
| 1 | genesis, cap 50 000, w 7 | effective 18990 |
| 2 | raise to 80 000, submitted 19100 | defers to boundary **19103** |
| 3 | raise to 90 000, submitted 19150 | would land on 19152; **cancelled by seq 4** |
| 4 | lowering to 60 000, submitted 19151 | effective **19151** immediately |
| 5 | raise to 70 000 with w 14, submitted **19194** (a multiple of 7) | defers a full window to **19201** |
| 6 | unchanged cap 70 000, w 10, submitted 19210 | effective **19210** immediately |
| 7 | raise to 100 000, submitted 19250 | boundary measured with incumbent w 10: **19260** |
| 8 | lowering to 40 000, submitted 19300 | effective 19300 |
| 9 | unchanged cap 40 000, w 5, submitted 19300 | same day as seq 8; **higher seq wins** |

`policy_deferral_mismatch.csv` is the same history, except the chain records
seq 7 as effective on 19250 (applied immediately). The verifier reports one
`deferral_mismatch` and exits 1. Its per-day output is **byte-identical** to
the clean run, because the derived day is used in both.

---

## Ambiguities and assumptions

These are the places where spec v2 does not fully determine the answer, with
the reading taken here. **⚠** marks the entries I would check first if this
verifier and the chain disagree.

### Settlement and spend

**A1. Which days are considered at all.** ⚠
§4 defines settlement per day but does not say where the list of days comes
from.
*Assumed:* every day that appears in **either** input is checked. A day with
48 readings and no prices, or prices and no readings, is `incomplete_day`.
*Consequence:* if the price feed covers a longer range than the meter data,
each extra day is reported as incomplete and the exit code is 1. An
implementation driven only by readings would stay silent. The data here covers
the same days in both files, so this does not arise.

**A2. Duplicate (day, slot) rows.**
§4 requires "exactly 48 … one per slot" but does not name the case where a
slot appears twice.
*Assumed:* the day is not settled and a separate `duplicate_slot` anomaly is
reported. It is not treated as a hard input error, and the rows are not summed,
deduplicated or resolved as first-wins or last-wins.

**A3. Out-of-range or wrongly typed fields are input errors, not anomalies.**
A slot outside 0–47, a negative `importMWh`/`exportMWh`, a fractional value or
`windowDays < 1` stops the run with exit 2. §2 declares these as types, and §4's
anomaly list does not include them.
*Alternative:* report them as anomalies and leave the day unsettled.

**A4. Invalid half-hours are checked on readings only.**
§4 defines "invalid" as import and export both greater than zero. A day that is
incomplete **and** has an invalid half-hour gets both anomalies, and every
invalid half-hour gets its own anomaly row.

**A5. What counts as a gap.** ⚠
§4 says "a gap between settled days" but not whether an unsettled day
(incomplete or invalid) inside the run is also a gap.
*Assumed:* any run of **unsettled** days between two settled days is one `gap`
anomaly, whatever the cause. So an incomplete day between settled days
produces both `incomplete_day` and `gap`.
*Consequence:* anomaly **counts** can differ from an implementation that only
treats days absent from both inputs as gaps. Days before the first settled day
and after the last are never gaps.

**A6. Windows that reach back before the first settled day.** ⚠
On the first data day (18994) the 7-day window covers 18988–18993, where no
data exists. §6's rule that "a day that is not settled contributes 0" is
applied, and no anomaly is raised. B2's first row therefore has
`windowSum = spendMilliUsd = 3301`.
*Consequence:* if the chain started with carried-over state, or with a policy
made before the data begins, the first `w − 1` days' sums will differ, and
neither side will call it an anomaly.

**A7. Settled days with no regime still count in later windows.**
§6 sums spend over the window whether or not a regime was in force on each
day. A pre-policy settled day gets `NA` verdicts in its own row but its spend
still counts toward later days' windows (tested).
*Alternative:* treat pre-policy days as not counting.

**A8. Sign convention for export.**
§2.2 calls `exportPrice` the "price paid for exporting", and §5 subtracts
`export × exportPrice`. A negative export price therefore makes exporting cost
money. That follows from the text; it is listed because the natural-language
reading and the formula could be implemented separately.

**A9. Integer width.**
Python integers are unbounded, so the verifier cannot overflow and does not
check for it. On this data each slot is at most about 9×10¹⁴ exact units and a
day is at most about 4.3×10¹⁶, which fits in int64. An on-chain implementation
using narrower types could fail where this one cannot. The spec sets no bounds.

### Policy replay

**A10. Genesis is taken on trust.** ⚠
§7.1 and §10.1 make genesis's derived day equal its recorded day, with
`deferralOk = true`. A genesis whose `effectiveFromDay` is earlier than its
`submittedOnDay` (a cap applied retroactively) is **not** flagged. That is the
literal reading, and it is a blind spot.

**A11. Cancellation uses derived effective days, is strict, and covers genesis.**
§7.2 says "earlier write whose effective day is later than `s`". It is read as:

- the **derived** effective day, consistent with §7.3;
- **strictly** later than `s`, so a write effective exactly on `s` survives
  and loses to `W` on `seq`;
- every surviving earlier-`seq` write, **including genesis** if its effective
  day is later than `s`.

A write that has already been cancelled keeps its first canceller. Cancelled
writes still go through the §7.4 deferral check (tested).

**A12. Which writes the incumbent can come from.**
"`current` … using the writes replayed so far" is read as **surviving**
lower-`seq` writes whose derived effective day is `≤ s`, with ties broken by
§7.3. Two things follow:

- A raise that is pending and not yet effective on `s` is not the incumbent.
  So a write between the in-force cap and the pending cap counts as a
  **raise**, cancels nothing, and wins the boundary day by `seq` (tested).
- A lowering on day `s` followed by another write on the same day: the second
  is classified against the lowering (tested).

**A13. The boundary uses floor division.**
"Smallest multiple of `w` greater than `s`" is `(s // w + 1) · w` with
floor division, which is also correct for negative `s`
(`next_window_boundary(-1, 7) = 0`). An implementation that truncates toward
zero would give 7.

**A14. A later write with no regime in force on its `submittedOnDay`.** ⚠
This happens if genesis's effective day is later than a later write's `s`, or
if a lowering cancelled genesis. §7.2 then compares against a `current` that
does not exist.
*Assumed:* the write is **not a raise**. It takes effect on `s`, cancels
surviving writes effective after `s` (possibly genesis itself), and a
`no_incumbent_regime` anomaly is reported.
*Alternatives:*

- use the recorded `effectiveFromDay`, as for genesis;
- treat the write as a raise from nothing (but there is no window length to
  measure a boundary with);
- compare against the next write that will take effect.

Each alternative gives a different schedule.

**A15. `submittedOnDay` that is not non-decreasing in `seq`.** ⚠
§2.3 gives emission order but does not require submission days to be
monotonic. If they are not, a write with a higher `seq` but an earlier `s` can
cancel or pre-empt writes that were already effective in real time, and so
rewrite history.
*Assumed:* replay strictly in `seq` order, as §7 says, and report a
`policy_out_of_order` anomaly.

**A16. Events file order versus `seq`.**
The file is sorted by `seq` before replay, and a duplicate `seq` is a hard
error. File order is otherwise ignored.

**A17. `policyVersion` is informational.**
It is copied to `policyVersionInForce` and the policy report. Duplicate or
non-increasing versions are not checked, because the spec gives no rule for
them.

**A18. An empty policy file.**
This is accepted. Every settled day then gets `no_regime` and exit is 1.

### Verdicts

**A19. Authorisation is judged with full hindsight of the policy log.** ⚠
§9 uses the cap in force on `d + 1`, taken from the whole replayed history. A
lowering submitted **during** day `d + 1` therefore withdraws authority for all
of `d + 1`, including the part of the day before the write was made. A chain
that checks authorisation at a particular moment on `d + 1` only knows the
writes made up to that moment, so it will disagree on every day with a
lowering on `d + 1`. The spec's "withdraws authority immediately" suggests the
hindsight reading, but the spec has no notion of time within a day.

**A20. Breaches do not make the exit code non-zero.** ⚠
§10.1 says "exits non-zero if there is any anomaly" and lists the anomaly
kinds. Breaches and `authorisedNextDay = false` are not on that list.
*Assumed:* both are verdicts in the output, and on their own they give exit 0.
They are counted in the summary and listed in `summary.json`.
*Consequence:* a pipeline that checks only the exit code will not notice
breaches. The version 1 verifier did exit non-zero on breaches.

**A21. Authorisation when there is no regime on day `d`.**
If `d` has no regime, `windowSum(d)` has no window length, so
`authorisedNextDay` is `NA` even if `d + 1` has a regime. If `d` has a regime,
`d + 1` always does too (§7.3 is monotonic), so `NA` cannot happen in that
direction.

**A22. Authorisation on the last settled day.**
It is computed from the policy log even though `d + 1` has no data.

**A23. Rows exist only for settled days.**
§10.1 asks for output "per settled day". A day the chain may have settled with
partial data has no row here, so a row-by-row comparison has to treat a
missing row as a finding, not as a match.

**A24. A regime change inside the window.**
The window length in force on `d` is applied to every day in the window,
whatever regime was in force on those earlier days. After a raise that also
lengthens the window, older spend immediately counts again. In the smoke run,
the B2 window sum goes from 4 868 on 19200 to 11 125 on 19201, when w changes
from 7 to 14.

---

## Things I believe are wrong, missing or contradictory in the spec

1. **Epoch-aligned boundaries do not fit a rolling window.** The deferral
   defers a raise to the next multiple of `w`. A rolling window never resets
   at a multiple of `w`: the window on a boundary day still holds the
   previous `w − 1` days of spend. So deferring to a boundary does not stop
   the agent getting new capacity in a window it has already partly spent,
   which is the evident purpose. The only effect is an arbitrary delay of
   between 1 and `w` days, depending on `s mod w`. The "strictly after" rule
   (a raise submitted on a boundary waits a full `w`) is unambiguous in v2,
   but it makes this worse rather than better. If the intent is "no new
   capacity until every day spent under the old cap has left the window",
   the rule should be `s + w` (or `s + current.w`), not a multiple of `w`.

2. **Classifying by cap alone lets a shortened window skip deferral.** §7.2
   classifies on caps only. A write that keeps the cap (or even lowers it
   slightly) and **shortens** `windowDays` takes effect at once. It drops
   already-spent days from the window, which is new capacity with no
   deferral. For example: cap 70 000 with w 14, then cap 70 000 with w 1, on
   the same day. It is not ambiguous, since the spec says "compares caps
   only", but it is a loophole in a rule meant to hold back new capacity. A
   write that lengthens the window with a higher cap, on the other hand, is
   deferred even though it may tighten the limit.

3. **§9 uses `windowSum(d)`, not the window that will contain `d + 1`.**
   Authorisation for `d + 1` compares the cap on `d + 1` with a sum that still
   includes day `d − w + 1`, which will have left the window by `d + 1`, and
   uses the window length on `d`, not on `d + 1`. If that expiring day had
   positive spend, authority is withheld that the next window would allow. If
   it had negative spend (a credit), authority is granted that the next window
   would not support. I have implemented §9 as written. Whether this
   off-by-one is intended should be confirmed, because an on-chain
   implementation checking "can the agent act today" would naturally use
   today's window.

4. **The deferral check trusts `submittedOnDay`.** §7.4 says `submittedOnDay`
   exists so the chain's effective day can be checked. But `submittedOnDay`
   is itself recorded by the chain. A chain that records the wrong submission
   day (for example, backdating a raise so its boundary has already passed)
   passes §7.4. The check detects a chain that stops deferring, not one that
   misstates when writes were made. Genesis is not checked at all (A10).

5. **§10.1's anomaly list is incomplete.** It names five categories. Malformed
   input with nowhere to go also exists: duplicate slots, out-of-order
   submission days, a later write with no incumbent. I added three categories
   (A2, A14, A15), and each one also makes the exit non-zero. Another
   implementation might silently accept, crash on, or ignore these, and would
   exit differently.

6. **§7.2 has no answer when there is no incumbent** (A14), even though
   §7.1/§7.3 clearly allow a genesis that becomes effective later than a
   subsequent write's submission day.

7. **§4 does not say where the list of days comes from** (A1), or whether an
   unsettled day between settled days is a "gap" (A5). Both affect anomaly
   counts and exit codes, but not verdicts.

8. **§10's scope is slightly inconsistent.** §10 opens with "Everything under
   `verifier/`", but §10.3 puts a deliverable in `docs/verifier/`. This is
   trivial but it is a contradiction.

9. **§10.1 does not say whether breaches affect the exit code** (A20). An
   independent verifier whose exit code ignores breaches is easy to misuse in
   CI.

---

## Fixtures

| File | Contents |
|---|---|
| `verifier/fixtures/policy_genesis_w7.csv` | single genesis write: cap 50 000 milli-USD, w 7, submitted and effective day 0 |
| `verifier/fixtures/policy_multi_event.csv` | nine writes on real days 18990–19300 exercising §7.2 (see smoke runs); all recorded effective days agree with the rule |
| `verifier/fixtures/policy_deferral_mismatch.csv` | the same history, except seq 7's recorded effective day is 19250 (raise applied immediately); should produce exactly one `deferral_mismatch` |

The version 1 fixtures `records_example.csv` and `policy_example.csv` were
removed. They use the v1 input model (reported `netSpend`, no
`submittedOnDay`), which v2 does not accept. The unit tests build readings and
prices in code, so they do not need them.
