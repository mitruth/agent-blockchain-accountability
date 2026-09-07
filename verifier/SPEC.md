# Enforcement rule — specification for the independent verifier

This document is the **complete and only** input for implementing the verifier.

It states *what the rule is*, deliberately not *how anything computes it*. That
omission is the point. There is an on-chain implementation of this same rule;
if the verifier is written from that source it becomes a translation of it, and
two copies of one belief cannot disagree informatively. A verifier that cannot
disagree measures nothing.

So: implement from this document. Do not read the Solidity. Where this document
is silent on strategy, choose freely — a different structure is a feature here,
not a risk.

---

## 1. What is being verified

An autonomous agent spends money on a household's behalf. The owner has set a
cap on **cumulative net spending over a rolling window of calendar days**. The
verifier decides, independently, whether each day's record complied.

The unit throughout is **milli-USD, as an integer**. No floating point may reach
any comparison. Values are signed.

---

## 2. Inputs

### 2.1 Day records

One row per calendar day the agent reported.

| Field | Type | Meaning |
|---|---|---|
| `dayIndex` | integer | Days since the Unix epoch, UTC |
| `netSpend` | signed integer | Milli-USD. Positive = net import cost. Negative = net export credit. |
| `policyVersion` | integer | The policy version this record was checked against |
| `paused` | boolean | True when a pause forced this day to zero |

### 2.2 Policy events

The complete history of owner policy writes, in emission order. This is the only
source for what the cap was at any time.

| Field | Type | Meaning |
|---|---|---|
| `seq` | integer | Emission order, ascending. Ties are impossible. |
| `policyVersion` | integer | Version this write produced |
| `cap` | signed integer | Milli-USD |
| `windowDays` | integer | Rolling window length, in days. Always ≥ 1. |
| `effectiveFromDay` | integer | The day index this write applies from |
| `setBy` | address string | Informational |

**`effectiveFromDay` is always explicit.** Never infer it from a timestamp, a
block number, or the position of the event in the log. If you find yourself
deriving it, something is wrong.

---

## 3. Day index

`dayIndex = floor(unix_seconds / 86400)`, UTC, always.

Not the host timezone. Not a local calendar date. A day boundary is a multiple
of 86400 seconds since the epoch, and nothing else.

---

## 4. The window sum

For a day `d`, with `w` = the window length in force on `d` (see §5):

```
windowSum(d) = sum of netSpend over days [d - w + 1, d]
```

Both endpoints are **included**. With `w = 7`, the window at day `d` covers `d`
and the six days before it — seven days total.

- A day with no record contributes **0**.
- A day with a negative record contributes its **negative** value. Export credit
  reduces the sum. It is never clamped, never dropped, never absolute-valued.
  Clamping biases the sum upward, which makes the cap bind earlier than it
  should — an error in the direction that flatters the mechanism, which is the
  worst direction for an error to run.
- A paused day is a **zero-spend day, not a missing day**. It contributes 0 and
  the window still advances across it. Do not skip it, and do not treat the
  window as frozen while paused.
- The sum may legitimately be negative.

**Required structural property.** Compute the window for every day
**independently, from the complete record set**. Do not carry a running total
forward from the previous day, do not add the new day and subtract the expiring
one, and do not maintain any incremental state between days. The on-chain
implementation walks the window incrementally; the verifier must not, or the two
share a failure mode and the comparison is worthless.

Cost is irrelevant here. Correctness and independence are the whole deliverable.

---

## 5. The cap in force on a day

Reconstructed **entirely from the policy events**, replayed from genesis.

The rules:

1. A policy write applies from its `effectiveFromDay` onward, until a later
   write supersedes it.
2. The regime in force on day `d` is the applicable write with the **greatest
   `effectiveFromDay` that is ≤ `d`**.
3. **A write that lowers the cap takes effect the day it is made, and cancels
   any policy change scheduled to take effect on a later day.** Without this, a
   raise queued yesterday resurrects itself after a lowering made today. The
   owner's most recent instruction wins.
4. **A write that raises the cap takes effect at the next window boundary**, not
   immediately. It must not hand the agent fresh capacity part-way through a
   window it has already partly spent.
5. **Window boundaries sit at multiples of `windowDays`, measured from the Unix
   epoch.** The boundary strictly after day `d` under window length `w` is the
   next multiple of `w` above `d`. The schedule is fixed to the epoch, so it
   never depends on when a transaction was mined or on when the ledger started.
6. If two writes end up effective on the **same** day, the one emitted later
   wins.

Both the **cap** and the **window length** come from the regime in force. A
write may change either or both.

Rules 3, 4 and 5 are not derivable from the window arithmetic. They must be
implemented from this section, and they are the likeliest place for the two
implementations to legitimately disagree — which is exactly what this exercise
is meant to surface.

---

## 6. The compliance test

For each day `d` that has a record:

```
compliant(d)  ⟺  windowSum(d) <= capAt(d)
```

**The comparison is `<=`. Equality at the cap passes.** A window sum exactly
equal to the cap is compliant. Only a strictly greater sum is a breach.

### 6.1 Lowering below the current window sum is not a retroactive breach

If the owner lowers the cap to a value below the window sum already accumulated,
that blocks further spending. It does **not** retroactively convict days already
recorded. Each day is judged against the cap in force **on that day**, which is
what §5 already gives you — but state it explicitly in the code rather than
letting it be an accident of the ordering.

### 6.2 Cross-check the bound policy version

Each record carries the `policyVersion` it claims to have been checked against.
Independently of the compliance test, compare:

- the cap from the regime in force on that day, per §5, and
- the cap from the policy event whose `policyVersion` matches the record's.

These should agree. **Report every case where they do not, as a separate
category from a compliance breach.** A divergence here means the record was
checked against a policy that was not the one in force — which is a different
and more serious failure than overspending, and neither implementation should be
trusted to notice it about itself.

---

## 7. Rounding

Where a real-valued quantity must become an integer, rounding is
**half away from zero**:

```
 2.5 →  3        -2.5 → -3
 3.5 →  4        -3.5 → -4
 2.4 →  2        -2.4 → -2
 2.6 →  3        -2.6 → -3
```

This is **not** banker's rounding (round-half-to-even), which would send
`2.5 → 2` and `-2.5 → -2`. Banker's rounding produces signed off-by-one errors
at the boundary and compounds the export-credit problem in §4.

Note that Python's built-in `round()` is banker's rounding and must not be used
for this. Test the exact `.5` cases in both signs explicitly — they are the only
cases that distinguish the two rules, so a test suite without them is not
testing rounding at all.

No float may cross into a comparison. Convert once, at the boundary, then work
in integers.

---

## 8. Deliverables

Everything under `verifier/`. Python 3, standard library plus `pandas` if
useful. No Solidity, no web3, no chain access.

1. **`verify.py`** — the implementation. A library API plus a CLI that takes a
   records file and a policy-events file and writes per-day results:
   `dayIndex, netSpend, windowSum, capInForce, windowDaysInForce, compliant,
   policyVersionMismatch`.

2. **`test_verify.py`** — its own tests, written against this document. At
   minimum:
   - equality exactly at the cap passes
   - one milli-USD over the cap fails
   - the oldest day of the window is included, and leaves the window one day later
   - a negative day reduces the window sum
   - export credit restores headroom that would otherwise breach
   - a window sum may be negative
   - a paused day counts as zero and the window advances across it
   - a missing day counts as zero
   - a raise applies at the boundary, not immediately
   - a lowering applies immediately
   - a lowering cancels a pending raise
   - two writes effective on the same day: the later one wins
   - the `.5` rounding cases in both signs
   - a record whose bound `policyVersion` disagrees with the regime in force is
     reported as a mismatch, not as a breach

3. **`README.md`** — how to run it, the input formats, and **a short section
   listing every place this specification was ambiguous and what you assumed.**
   That list is a required deliverable, not a courtesy. An ambiguity you
   silently resolved is a place the two implementations may differ for reasons
   nobody will find later.

---

## 9. Hard constraints

- **Do not read, open, grep, or list any `.sol` file.** Not the contracts, not
  the tests. If a tool result puts Solidity in front of you, stop and report it
  rather than using it.
- **Do not read `DECISIONS.md`.** It records implementation strategy and would
  leak the on-chain approach.
- Do not consult any other file in this repository for the rule. This document
  is complete; if you believe it is not, say so explicitly and state what is
  missing rather than filling the gap from something you found.
- Do not optimise for gas, speed, or memory. Optimise for being obviously
  correct and structurally unlike an incremental walk.
- Where this document genuinely does not determine an answer, pick the reading
  you can defend, implement it, and record it in the README's ambiguity list.
