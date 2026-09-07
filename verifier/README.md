# Independent verifier — rolling-window spending cap

An independent reimplementation of the enforcement rule described in
[`SPEC.md`](SPEC.md).

**Provenance.** This was written from `SPEC.md` alone. No `.sol` file was read,
opened, grepped, globbed or listed; `DECISIONS.md`, the repository `README.md`,
`scripts/`, `artifacts/` and `cache/` were not consulted. The only other files
read were the daily-record CSVs at the repository root, and only as *data*
(column names and value ranges), never as a source for the rule.

The point of the exercise is that this implementation must be *capable of
disagreeing* with the on-chain one. Where `SPEC.md` under-determines an answer,
the reading taken here is recorded in [Ambiguities](#ambiguities-and-assumptions)
below rather than smoothed over. Those entries are the map of where the two
implementations can legitimately diverge.

---

## Running it

Python 3 (developed against 3.14). Standard library only — no third-party
dependency, no `pandas`, no `web3`, no chain access.

```bash
python verifier/verify.py --records <records.csv> --policy <policy_events.csv> [options]
```

Options:

| Flag | Meaning |
|---|---|
| `--records PATH` | day-record CSV (required) |
| `--policy PATH` | policy-event CSV (required) |
| `--out PATH` | results CSV; `-` (default) writes to stdout |
| `--agent ID` | select one `agentId` when the records file holds several |
| `--summary-json PATH` | write a JSON summary, including the replayed policy schedule |
| `--quiet` | suppress the human-readable summary on stderr |

Exit codes: `0` clean, `1` at least one breach / version mismatch / anomaly /
undetermined day, `2` bad input.

### Tests

`pytest` is **not** installed in this environment, so the suite is written for
`unittest` and runs under either runner:

```bash
python -m unittest discover -s verifier -p "test_*.py" -v   # what was actually run
python -m pytest verifier/test_verify.py                    # also works, if pytest is present
python verifier/test_verify.py
```

58 tests, all passing.

### Library API

```python
from verify import DayRecord, PolicyEvent, verify, window_sum, build_policy_schedule

report = verify(records, events)
report.results              # list[DayResult]
report.breaches             # compliant is False
report.version_mismatches   # SPEC.md 6.2 divergences
report.undetermined         # recorded days with no policy in force
report.anomalies            # list[Anomaly]
report.schedule             # the replayed list[Regime]
report.ok                   # bool
```

---

## Input formats

### Day records (`--records`)

CSV. Required: `dayIndex`, plus one of `netSpend` / `spendMilliUsd` /
`netSpendMilliUsd`. Optional: `policyVersion`, `paused`, `agentId`.

| Column | Type | Notes |
|---|---|---|
| `dayIndex` | integer | days since the Unix epoch, UTC (`floor(unix_seconds / 86400)`) |
| `netSpend` | signed integer | milli-USD; `spendMilliUsd` is accepted as an alias |
| `policyVersion` | integer, optional | omitted ⇒ the §6.2 cross-check reports `NA` rather than guessing |
| `paused` | boolean, optional | `true/false/1/0/yes/no`; default `false` |
| `agentId` | string, optional | more than one distinct value requires `--agent` |

The generated `records_B0.csv` / `records_B1.csv` / `records_B2.csv` at the
repository root are readable as-is: they use `spendMilliUsd` and carry no
`policyVersion` or `paused` column, so the version cross-check reports `NA` for
every day and no day is treated as paused.

### Policy events (`--policy`)

CSV. Required: `seq`, `policyVersion`, `cap`, `windowDays`, `effectiveFromDay`.
Optional: `setBy` (informational).

Rows may be in any order; `seq` is authoritative. A duplicate `seq` is a hard
error (`SPEC.md` §2.2: "Ties are impossible"). `windowDays` must be ≥ 1.

Fixtures under `verifier/fixtures/`:

| File | What it is |
|---|---|
| `policy_genesis_w7.csv` | a single genesis write, cap 100 000 milli-USD, `windowDays = 7`, from day 0 |
| `policy_multi_event.csv` | genesis plus two raises and two lowerings, to exercise the §5 replay |
| `records_example.csv`, `policy_example.csv` | the worked example below |

## Output format

CSV with exactly the columns `SPEC.md` §8.1 asks for:

```
dayIndex, netSpend, windowSum, capInForce, windowDaysInForce, compliant, policyVersionMismatch
```

`netSpend` echoes the value **as recorded**. `compliant` and
`policyVersionMismatch` are `true` / `false` / `NA`. `NA` appears when no policy
regime is in force on that day (all computed columns), or when the record
carries no `policyVersion` (that column only).

### Worked example

```bash
python verifier/verify.py --records verifier/fixtures/records_example.csv \
                         --policy  verifier/fixtures/policy_example.csv
```

```
dayIndex,netSpend,windowSum,capInForce,windowDaysInForce,compliant,policyVersionMismatch
0,400,400,1000,7,true,false
1,400,800,1000,7,true,false
2,-300,500,1000,7,true,false      <- export credit reduces the sum
3,0,500,1000,7,true,false         <- paused day: contributes 0, window advances
5,900,1400,1000,7,false,false     <- breach; day 4 is missing and contributes 0
7,50,1050,5000,7,true,false       <- the raise requested on day 4 lands at day 7
```

### Smoke run against a real 365-day ledger

```bash
python verifier/verify.py --records records_B0.csv \
                         --policy verifier/fixtures/policy_genesis_w7.csv \
                         --out /tmp/out_b0.csv
# days=365 compliant=360 breaches=5 versionMismatches=0 undetermined=0 anomalies=0
```

With `policy_multi_event.csv` against `records_B1.csv` the replayed schedule
shows the §5 rules firing: the raise requested on day 100 lands on day 105, the
lowering requested on day 200 lands on day 200, the raise requested on day 300
lands on day 301, and the lowering requested on day 303 lands on day 303.

---

## How the window sum is computed (the structural requirement)

`SPEC.md` §4 requires each day's window to be computed **independently from the
complete record set**, because the on-chain implementation walks the window
incrementally and two implementations sharing that structure share its failure
modes.

`window_sum(records, day, window_days)` is a pure function that takes the whole
record set and one day, performs a **full linear scan** of every record, and
sums those whose `dayIndex` falls inside the inclusive range
`[day - w + 1, day]`. It is O(days × records) and that is deliberate — §4 says
cost is irrelevant.

Concretely, it holds **no** state of any kind:

- no running total carried forward from the previous day;
- no add-the-new-day / subtract-the-expiring-day step;
- no cursor, head index, ring buffer or deque;
- no memoisation, no cached prefix sums;
- no assumption that `records` is sorted, contiguous, or gap-free;
- no knowledge that any other day was ever evaluated.

Four tests pin this down (`TestWindowSumIndependence`): evaluating days forward
and backward gives the same answers; evaluating a single day in isolation
matches the full pass; reversing the record list changes nothing; and changing
`windowDays` mid-ledger simply produces a different answer rather than needing
the accumulator to be told.

The paused/missing distinction falls out of this structure for free. A missing
day never matches the range test, so it contributes 0. A paused day *does* match
the range test but contributes 0 through `DayRecord.contribution`, so the window
still advances across it — it is a zero-spend day, not a hole.

---

## Ambiguities and assumptions

This section is a required deliverable (`SPEC.md` §8.3). Each entry is a place
where `SPEC.md` did not determine an answer, the reading taken here, and — where
it matters — the alternative reading that the on-chain implementation might
plausibly have taken instead. Entries marked **⚠ divergence candidate** are the
ones I would check first if the two implementations disagree.

### A1 — "the day it is made" for a lowering ⚠ divergence candidate

§5.3 says a lowering "takes effect the day it is made". §2.2 says
`effectiveFromDay` is always explicit and must **never** be inferred from a
timestamp, a block number, or log position. The inputs therefore carry no
"day it was made" distinct from `effectiveFromDay`.

**Assumed:** the day a write is made *is* its `effectiveFromDay`. A lowering
takes effect on its stated `effectiveFromDay`, full stop.

**Consequences:** a lowering with a *future* `effectiveFromDay` takes effect on
that future day, not immediately on submission; a lowering with a *past*
`effectiveFromDay` is retroactive in the schedule (it governs from that past day
forward, subject to §5.2's greatest-effective-day rule). If the on-chain version
has access to `block.timestamp` and uses it as "the day it is made", the two
will differ on every write whose `effectiveFromDay` is not the submission day.

### A2 — genesis, and writes with no incumbent regime

§5.3 and §5.4 classify a write relative to an existing cap. The first event has
none; nor does any write whose `effectiveFromDay` precedes every regime resolved
so far.

**Assumed:** such a write is neither a raise nor a lowering. It takes effect at
its stated `effectiveFromDay`, is never deferred, and cancels nothing.

### A3 — what "raises" and "lowers" are measured against ⚠ divergence candidate

§5 never says which cap the new cap is compared to. Three defensible baselines:

- **(a)** the cap **in force** on the write's `effectiveFromDay` (§5.2's regime);
- **(b)** the cap of the most recently emitted write, *including* one still
  pending at a future boundary;
- **(c)** the cap in force at some notion of "now".

**Assumed: (a).** It is the only one of the three that §5.2 actually defines,
and it is the cap the agent is genuinely constrained by at that moment.

**Consequence, and it is a large one.** Suppose cap 1000 is in force, a raise to
2000 is pending at day 14, and on day 10 the owner writes cap 1500. Under (a)
that is a *raise* (1500 > 1000): it defers to day 14 and does **not** cancel the
pending 2000; both then land on day 14 and §5.6 gives it to the later `seq`, so
1500 wins. Under (b) it is a *lowering* (1500 < 2000): it takes effect
immediately on day 10 and cancels the 2000 outright. Days 10–13 differ.

A second consequence is tested directly
(`test_raise_classification_sees_an_earlier_same_day_lowering`): two writes with
the same `effectiveFromDay`, the first lowering 1000 → 600 and the second
setting 900, do **not** both land on that day. The first applies immediately, so
the second is classified against 600, is a raise, and defers. §5.6 therefore
never fires for that pair. If the on-chain version classifies both against the
pre-existing 1000, both land on the same day and §5.6 hands the day to 900.

### A4 — a write that leaves the cap unchanged ⚠ divergence candidate

§5.3 covers "lowers", §5.4 covers "raises". Equality is covered by neither.
This is not hypothetical: a write that changes only `windowDays` keeps the cap.

**Assumed:** anything that is not a *strict* raise is handled like a lowering —
it takes effect at its `effectiveFromDay` and it cancels strictly-later
scheduled changes. Rationale: §5.4's deferral exists solely to withhold *fresh
capacity*, and an unchanged cap grants none, so there is nothing to withhold;
§5.3's "the owner's most recent instruction wins" still applies.

**Alternative:** treat equality as "neither" — immediate but *not* cancelling.
That differs whenever a cap-neutral write is issued while a raise is pending.

### A5 — which `windowDays` measures the boundary for a deferred raise ⚠ divergence candidate

§5.5 puts boundaries at multiples of `windowDays` from the epoch, but a raising
write may itself change `windowDays`, so there are two candidate lengths.

**Assumed:** the length **in force at the write's `effectiveFromDay`** (the
incumbent's). §5.4's stated rationale is about not handing fresh capacity
"part-way through a window it has already partly spent" — the window being
protected is the incumbent one, so its length is what defines its boundary.

**Alternative:** the new write's own `windowDays`. With incumbent `w = 10` and a
raise on day 4 introducing `w = 3`, this reading gives day 6 rather than day 10.
Tested explicitly as `test_deferred_raise_uses_the_window_length_currently_in_force`.

### A6 — a raise made on a day that is already a boundary ⚠ divergence candidate, and possibly a spec defect

§5.5 defines the boundary as the next multiple of `w` **strictly** above `d`. So
a raise with `effectiveFromDay = 14` under `w = 7` defers to day **21** — even
though day 14 is itself the start of a fresh, entirely unspent window, which
§5.4's own rationale would seem to permit immediately.

**Assumed:** the literal text. Strictly above, so day 21.

I consider this the single most likely source of legitimate disagreement,
because the spec's letter and the spec's stated reason point different ways. See
[Spec issues](#things-i-believe-are-wrong-missing-or-contradictory-in-specmd) §2.

### A7 — scope of "cancels any policy change scheduled to take effect on a later day"

§5.3 does not say *strictly* later, does not say whether the cancellation is
limited to changes with a higher `seq`, and does not say what happens when there
is no clock to distinguish "already in effect" from "scheduled".

**Assumed:** a non-raise write removes every already-resolved regime whose
effective day is **strictly greater** than its own effective day, regardless of
`seq`. Same-day collisions are *not* cancelled; they are left to §5.6. And
because the inputs carry no clock (see A1), the cancellation is unconditional —
even a retroactive lowering wipes later-scheduled changes.

### A8 — recorded days before any policy is effective

§5 gives no cap before the first effective write, and §6 defines compliance only
against a cap. `SPEC.md` never says what to do with a record on such a day.

**Assumed:** report `windowSum`, `capInForce`, `windowDaysInForce`, `compliant`
and `policyVersionMismatch` all as `NA`, raise a `no_policy_in_force` anomaly,
and exit non-zero. Calling those days *breaches* would fabricate convictions the
spec does not authorise; calling them *compliant* would launder them.

### A9 — §6.2 compares caps, not version identifiers ⚠ divergence candidate

§6.2 says to compare "the cap from the regime in force" against "the cap from
the policy event whose `policyVersion` matches the record's".

**Assumed:** exactly that, literally. Two *different* versions that happen to
carry the *same* cap therefore do **not** raise a mismatch — including the case
where they differ in `windowDays`, which is materially a different policy and
which this check will not catch. A stricter implementation comparing
`policyVersion` identifiers directly would flag both cases.

### A10 — a record bound to an unknown `policyVersion`

§6.2 assumes the version resolves to an event. **Assumed:** if it resolves to
nothing, that is a mismatch (`true`) plus an `unknown_policy_version` anomaly.

### A11 — the same `policyVersion` appearing on more than one event

§2.2 implies one version per write but does not forbid repeats. **Assumed:** the
event with the highest `seq` bearing that version defines its cap.

### A12 — a `paused` record carrying non-zero `netSpend`

§2.1 defines `paused` as "True when a pause forced this day to zero", so the two
fields should agree.

**Assumed:** §4 governs — the day contributes **0** to every window regardless
of what `netSpend` says — and the disagreement is reported as a
`paused_day_nonzero_netspend` anomaly rather than silently accepted. Note the
visible consequence: the output's `netSpend` column echoes the recorded value,
so a paused day can show a non-zero `netSpend` beside a `windowSum` that
excludes it. Emitting `0` there instead would have been equally defensible.

### A13 — duplicate `dayIndex` in the records

§2.1 says "one row per calendar day". **Assumed:** a duplicate is a hard error.
Not summed, not last-wins, not first-wins — silently choosing any of those would
change window sums in a way nobody would notice.

### A14 — where §7's rounding actually applies

§7 mandates half-away-from-zero "where a real-valued quantity must become an
integer", but every field in §2 is already declared an integer, so within the
specified data model there is no such quantity.

**Assumed:** the boundary is *parsing*. If a records or policy file supplies a
fractional `netSpend` or `cap`, it is converted once, at read time, with
`round_half_away_from_zero`, and nothing downstream is ever non-integer.
`dayIndex`, `policyVersion`, `windowDays` and `seq` are required to be exact
whole numbers and are **not** rounded — rounding an index would be silent data
corruption, not a rounding decision.

Implementation note: the conversion runs through `decimal.Decimal` on the input
*text* with `ROUND_HALF_UP` (which in `decimal` is sign-aware, i.e. away from
zero). No binary float is ever constructed, so no float can reach a comparison.
Python's built-in `round()` is not used anywhere.

### A15 — `float` inputs to the rounding helper

A `float` cannot represent most decimal fractions exactly (`2.675` is really
`2.67499…`), so "round this float half away from zero" is ambiguous about
*which* value is being rounded.

**Assumed:** a `float` is converted via `Decimal(repr(x))`, i.e. the shortest
decimal that round-trips — so `round_half_away_from_zero(2.5) == 3` and
`(-2.5) == -3` as §7 requires. Strings and `Decimal` are exact and are the
preferred input at the boundary.

### A16 — file format and column names

`SPEC.md` names fields but never specifies a file format. **Assumed:** CSV with
those field names as headers.

Because the repository's generated daily-record files call the spend column
`spendMilliUsd` and carry no `policyVersion` or `paused` column, the reader
accepts `spendMilliUsd` (and `netSpendMilliUsd`) as aliases for `netSpend`,
defaults `paused` to `false`, and treats an absent `policyVersion` as "no
verdict available" (`NA`) rather than inventing one.

### A17 — one agent per run

`SPEC.md` describes a single agent's ledger and never mentions `agentId`; the
record CSVs have such a column. **Assumed:** a verification run covers exactly
one agent. If the file holds more than one distinct `agentId`, `--agent` is
required. Records for different agents are never summed into one window.

### A18 — negative day indices

§3's floor is well-defined for pre-epoch seconds. **Assumed:** nothing special
is needed, but it is worth naming because the arithmetic depends on flooring
division: `day_index_from_unix_seconds(-1) == -1` and
`next_window_boundary(-1, 7) == 0`. An implementation using C-style truncating
division would get `0` and `7` respectively.

### A19 — negative caps

§2.2 declares `cap` signed. **Assumed:** a negative cap is legal and means the
window must show a net credit of at least `|cap|`. §6's `<=` handles it with no
special case (`-100 <= -100` passes, `-99 > -100` fails). Tested.

### A20 — windows reaching back before the first record, or before the epoch

No lower bound is given on `dayIndex` or upper bound on `windowDays`.
**Assumed:** the range `[d - w + 1, d]` is used as-is; days with no record
contribute 0 by §4 whether they are merely absent, before the ledger started, or
before the epoch.

### A21 — event ordering in the file

§2.2 says the log is "in emission order" with ascending `seq`. **Assumed:**
`seq` is authoritative and the file may be in any physical order; the replay
sorts by `seq` first. Duplicate `seq` is a hard error rather than a tie-break,
because §2.2 states ties are impossible.

### A22 — which days appear in the output

§6 says "for each day `d` that has a record". **Assumed:** result rows exist
only for recorded days. Unrecorded days still contribute 0 to other days'
windows but produce no row of their own.

---

## Things I believe are wrong, missing, or contradictory in `SPEC.md`

Stated plainly rather than quietly resolved, as §9 asks.

1. **§5.3 contradicts §2.2.** §2.2 forbids inferring an effective day from
   anything other than `effectiveFromDay`; §5.3 then invokes "the day it is
   made", which is a submission time the data model does not carry. Either
   §5.3's phrase is just a loose way of saying "its `effectiveFromDay`" — the
   reading taken here — or §5.3 requires exactly the timestamp inference §2.2
   forbids. The spec should say which. See A1.

2. **§5.4's rule and §5.4's rationale disagree at boundary days.** The rule plus
   §5.5's "strictly after" defers a raise made *on* a boundary to the *following*
   boundary. The rationale — do not hand fresh capacity part-way through a
   partly-spent window — does not apply on a boundary day, because the window
   starting there is unspent. One of the two needs amending. See A6.

3. **§5 does not define what a raise is measured against, what happens when the
   cap is unchanged, or which `windowDays` measures a deferred raise's
   boundary.** Taken together these three gaps are the largest
   under-determination in the document, and they compound: the raise/lower
   classification (A3) feeds the deferral decision (A4), which feeds the boundary
   calculation (A5). §5's own closing paragraph correctly predicts that rules 3–5
   are where the implementations will disagree, but it does not close the gaps
   that make disagreement likely.

4. **§7 has no application inside the data model §2 defines.** Every field in §2
   is already an integer, so no real-valued quantity ever needs to become one.
   The rounding rule is therefore only reachable at the parsing boundary (A14).
   That is not a defect in the rule, but it means the mandated `.5` tests
   exercise a helper rather than the enforcement path, and a reader should not
   take the presence of rounding tests as evidence that rounding affects any
   verdict here. If rounding *is* meant to apply somewhere specific — converting
   energy at a tariff into milli-USD, say — §7 should name that step.

5. **§6.2 under-detects the failure it describes.** It describes the failure as
   "the record was checked against a policy that was not the one in force", which
   is a *version identity* failure, but then instructs a comparison of *caps*.
   Two distinct versions sharing a cap — very likely when a write changes only
   `windowDays` — pass the check while exhibiting exactly the failure §6.2 is
   worried about. See A9.

6. **§5 does not say what governs a recorded day before the first effective
   write.** §6 requires a cap to render a verdict and §5 provides none for such
   days. See A8.

7. **§2.1 does not say whether `paused` and `netSpend` may disagree**, i.e.
   whether `paused = true, netSpend = 500` is malformed input or a meaningful
   record. See A12.

None of these prevented implementation; each was resolved as recorded above.
