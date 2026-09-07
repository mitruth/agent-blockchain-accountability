#!/usr/bin/env python3
"""
Independent verifier for the rolling-window spending-cap enforcement rule.

Implemented solely from ``verifier/SPEC.md``.  No on-chain source, no
``DECISIONS.md``, no Solidity of any kind was consulted.

Design notes that matter for the audit
--------------------------------------

*   **The window sum is recomputed from scratch for every day.**  See
    :func:`window_sum`.  It performs a full linear scan of the *complete*
    record set and selects the days inside ``[d - w + 1, d]``.  There is no
    running total, no add-new/subtract-expiring step, no cursor, no
    incremental state of any kind carried between days.  Deleting the result
    for day ``d`` would not change the result for day ``d + 1``.  This is
    required by SPEC.md section 4 and is deliberately the opposite structure
    to an incremental walk.

*   **All money is integer milli-USD.**  Floats never reach a comparison.
    The only place a real-valued quantity becomes an integer is
    :func:`round_half_away_from_zero`, applied once at the parsing boundary,
    and it is implemented with :mod:`decimal` rather than the built-in
    ``round`` (which is banker's rounding and would be wrong -- SPEC.md
    section 7).

*   **The policy schedule is reconstructed by replaying the event log.**
    See :func:`build_policy_schedule`.  Every judgment call taken there is
    recorded in ``README.md`` under "Ambiguities".
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Iterable, Optional, Sequence

__all__ = [
    "DayRecord",
    "PolicyEvent",
    "Regime",
    "DayResult",
    "Anomaly",
    "VerificationReport",
    "round_half_away_from_zero",
    "to_int_milli_usd",
    "day_index_from_unix_seconds",
    "next_window_boundary",
    "build_policy_schedule",
    "regime_in_force",
    "window_sum",
    "verify",
    "read_records_csv",
    "read_policy_events_csv",
    "write_results_csv",
]


# ---------------------------------------------------------------------------
# Section 7 -- rounding, and the integer boundary
# ---------------------------------------------------------------------------

_ONE = Decimal(1)


def round_half_away_from_zero(value) -> int:
    """Round *value* to the nearest integer, ties going away from zero.

    ``2.5 -> 3``, ``-2.5 -> -3``, ``3.5 -> 4``, ``-3.5 -> -4``.

    This is *not* Python's built-in :func:`round`, which is round-half-to-even
    and would give ``2.5 -> 2`` and ``-2.5 -> -2``.  SPEC.md section 7 forbids
    that rule here.

    Accepts ``int``, ``str``, :class:`decimal.Decimal` and ``float``.  Strings
    and ``Decimal`` are exact.  A ``float`` is converted through ``repr`` so
    that the value the *caller wrote* is what gets rounded, rather than the
    binary artefact underneath it (``2.675`` is really ``2.67499...`` in
    binary; ``Decimal(repr(2.675))`` is ``2.675``).
    """
    if isinstance(value, bool):  # bool is an int subclass; refuse it explicitly
        raise TypeError("bool is not a numeric value here")
    if isinstance(value, int):
        return value
    if isinstance(value, Decimal):
        dec = value
    elif isinstance(value, float):
        dec = Decimal(repr(value))
    elif isinstance(value, str):
        try:
            dec = Decimal(value.strip())
        except InvalidOperation as exc:
            raise ValueError(f"not a number: {value!r}") from exc
    else:
        raise TypeError(f"cannot round value of type {type(value).__name__}")
    if not dec.is_finite():
        raise ValueError(f"not a finite number: {value!r}")
    # Decimal's ROUND_HALF_UP means "half away from zero" (it is sign-aware),
    # which is exactly the rule SPEC.md section 7 asks for.
    return int(dec.quantize(_ONE, rounding=ROUND_HALF_UP))


def to_int_milli_usd(value) -> int:
    """Convert a parsed field to integer milli-USD, once, at the boundary.

    After this call nothing downstream is anything other than ``int``.
    """
    return round_half_away_from_zero(value)


def _to_int_exact(value, what: str) -> int:
    """Parse a field that must already be a whole number (indices, versions)."""
    if isinstance(value, bool):
        raise TypeError(f"{what} must not be a bool")
    if isinstance(value, int):
        return value
    text = str(value).strip()
    try:
        dec = Decimal(text)
    except InvalidOperation as exc:
        raise ValueError(f"{what} is not an integer: {value!r}") from exc
    if dec != dec.to_integral_value():
        raise ValueError(f"{what} must be a whole number, got {value!r}")
    return int(dec)


# ---------------------------------------------------------------------------
# Section 3 -- day index
# ---------------------------------------------------------------------------

SECONDS_PER_DAY = 86400


def day_index_from_unix_seconds(unix_seconds: int) -> int:
    """``floor(unix_seconds / 86400)``, UTC, always.

    Python's ``//`` floors towards negative infinity, which is what "floor"
    means here, including for pre-epoch instants.  No timezone, no calendar
    library, no host clock is involved.
    """
    return _to_int_exact(unix_seconds, "unix_seconds") // SECONDS_PER_DAY


# ---------------------------------------------------------------------------
# Input types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DayRecord:
    """One reported calendar day (SPEC.md section 2.1)."""

    dayIndex: int
    netSpend: int                      # signed milli-USD, as recorded
    policyVersion: Optional[int] = None
    paused: bool = False

    @property
    def contribution(self) -> int:
        """What this day contributes to a window sum.

        A paused day is a *zero-spend day, not a missing day* (section 4): it
        contributes 0, and the window still advances across it.  The recorded
        ``netSpend`` is kept verbatim on the record so the discrepancy stays
        visible; it is reported as an anomaly rather than silently trusted.
        """
        return 0 if self.paused else self.netSpend


@dataclass(frozen=True)
class PolicyEvent:
    """One owner policy write (SPEC.md section 2.2)."""

    seq: int
    policyVersion: int
    cap: int                           # signed milli-USD
    windowDays: int                    # >= 1
    effectiveFromDay: int
    setBy: str = ""


@dataclass(frozen=True)
class Regime:
    """A policy write resolved onto the day it actually starts governing."""

    effectiveDay: int                  # resolved: may be deferred past effectiveFromDay
    seq: int
    policyVersion: int
    cap: int
    windowDays: int
    requestedFromDay: int              # the event's raw effectiveFromDay
    deferred: bool = False             # True if a raise was pushed to a boundary

    @property
    def sort_key(self) -> tuple:
        # Section 5.2 orders by effective day; section 5.6 breaks ties on the
        # same day in favour of the later-emitted write.
        return (self.effectiveDay, self.seq)


# ---------------------------------------------------------------------------
# Output types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DayResult:
    dayIndex: int
    netSpend: int
    windowSum: Optional[int]
    capInForce: Optional[int]
    windowDaysInForce: Optional[int]
    compliant: Optional[bool]
    policyVersionMismatch: Optional[bool]
    policyVersionInForce: Optional[int] = None
    paused: bool = False


@dataclass(frozen=True)
class Anomaly:
    kind: str
    dayIndex: Optional[int]
    detail: str


@dataclass
class VerificationReport:
    results: list = field(default_factory=list)      # list[DayResult]
    schedule: list = field(default_factory=list)     # list[Regime]
    anomalies: list = field(default_factory=list)    # list[Anomaly]

    @property
    def breaches(self) -> list:
        return [r for r in self.results if r.compliant is False]

    @property
    def version_mismatches(self) -> list:
        return [r for r in self.results if r.policyVersionMismatch]

    @property
    def undetermined(self) -> list:
        """Days with a record but no policy regime in force."""
        return [r for r in self.results if r.compliant is None]

    @property
    def ok(self) -> bool:
        return not (self.breaches or self.version_mismatches
                    or self.undetermined or self.anomalies)


# ---------------------------------------------------------------------------
# Section 5 -- the cap in force on a day
# ---------------------------------------------------------------------------


def next_window_boundary(day: int, window_days: int) -> int:
    """The window boundary *strictly after* ``day`` (SPEC.md section 5.5).

    Boundaries sit at multiples of ``window_days`` counted from the Unix
    epoch, so the answer is the next multiple of ``window_days`` strictly
    above ``day``.  If ``day`` is itself a multiple, the answer is
    ``day + window_days``, not ``day`` -- see the ambiguity list in README.md,
    this is the literal reading of "strictly after".
    """
    if window_days < 1:
        raise ValueError("windowDays must be >= 1")
    return (day // window_days + 1) * window_days


def _resolve_at(schedule: Sequence[Regime], day: int) -> Optional[Regime]:
    """Greatest effective day <= ``day``; later ``seq`` wins a tie."""
    best = None
    for regime in schedule:
        if regime.effectiveDay <= day:
            if best is None or regime.sort_key > best.sort_key:
                best = regime
    return best


def build_policy_schedule(events: Iterable[PolicyEvent]) -> list:
    """Replay the policy event log from genesis into a list of `Regime`.

    Implements SPEC.md section 5 rules 1-6:

    1/2. A write governs from its effective day until superseded; the regime on
         day ``d`` is the applicable write with the greatest effective day
         ``<= d``.
    3.   A write that *lowers* the cap takes effect on the day it is made (its
         ``effectiveFromDay``) and cancels every change already scheduled for a
         strictly later day.
    4.   A write that *raises* the cap takes effect at the next window boundary.
    5.   Boundaries are multiples of ``windowDays`` from the epoch.
    6.   Same effective day -> the later-emitted write wins.

    The returned list is sorted by ``(effectiveDay, seq)``.
    """
    ordered = sorted(events, key=lambda e: e.seq)
    seen_seq = set()
    for event in ordered:
        if event.seq in seen_seq:
            raise ValueError(f"duplicate policy event seq {event.seq}; "
                             "SPEC.md section 2.2 says ties are impossible")
        seen_seq.add(event.seq)
        if event.windowDays < 1:
            raise ValueError(f"policy event seq {event.seq} has windowDays "
                             f"{event.windowDays}; SPEC.md section 2.2 "
                             "requires >= 1")

    schedule: list = []
    for event in ordered:
        current = _resolve_at(schedule, event.effectiveFromDay)

        if current is None:
            # Genesis (or a write effective before anything else governs).
            # "Raise" is undefined with no incumbent cap to raise above, so
            # rule 4 cannot bite; the write takes effect as written.
            effective_day = event.effectiveFromDay
            deferred = False
            is_raise = False
        else:
            is_raise = event.cap > current.cap
            if is_raise:
                # Rule 4 + rule 5.  The boundary that matters is a boundary of
                # the window the agent has *already partly spent*, so it is
                # measured with the window length currently in force, not the
                # (possibly different) length this write is introducing.
                effective_day = next_window_boundary(
                    event.effectiveFromDay, current.windowDays
                )
                deferred = effective_day != event.effectiveFromDay
            else:
                # A lowering (or a cap-neutral write) applies at once.
                effective_day = event.effectiveFromDay
                deferred = False

        if not is_raise and current is not None:
            # Rule 3: the owner's most recent instruction wins -- drop anything
            # queued for a strictly later day so a stale raise cannot
            # resurrect itself.  Same-day collisions are left to rule 6.
            schedule = [r for r in schedule if r.effectiveDay <= effective_day]

        schedule.append(
            Regime(
                effectiveDay=effective_day,
                seq=event.seq,
                policyVersion=event.policyVersion,
                cap=event.cap,
                windowDays=event.windowDays,
                requestedFromDay=event.effectiveFromDay,
                deferred=deferred,
            )
        )

    schedule.sort(key=lambda r: r.sort_key)
    return schedule


def regime_in_force(schedule: Sequence[Regime], day: int) -> Optional[Regime]:
    """The regime governing ``day``, or ``None`` if no policy governs it yet."""
    return _resolve_at(schedule, day)


# ---------------------------------------------------------------------------
# Section 4 -- the window sum
# ---------------------------------------------------------------------------


def window_sum(records: Sequence[DayRecord], day: int, window_days: int) -> int:
    """Sum of ``netSpend`` over the inclusive day range ``[day - w + 1, day]``.

    **Structural note (SPEC.md section 4).**  This function is deliberately
    stateless and self-contained.  It re-scans the *entire* record set on every
    call and keeps nothing between calls.  It does not know, and cannot know,
    what the previous day's answer was.  There is no accumulator to drift, no
    expiry pointer to fall out of step, and no ordering assumption about
    ``records``.  Calling it for the days of a ledger in reverse order, or for
    one day in isolation, gives identical answers.

    Days with no record contribute 0 simply by not matching the range test.
    Paused days contribute 0 via :attr:`DayRecord.contribution` but *are* in
    the range, so the window still advances across them.  Negative records
    contribute their negative value: never clamped, never dropped, never
    absolute-valued.
    """
    if window_days < 1:
        raise ValueError("windowDays must be >= 1")
    first_day = day - window_days + 1
    total = 0
    for record in records:
        if first_day <= record.dayIndex <= day:
            total += record.contribution
    return total


# ---------------------------------------------------------------------------
# Sections 6 / 6.1 / 6.2 -- the compliance test and the cross-check
# ---------------------------------------------------------------------------


def _cap_by_policy_version(events: Sequence[PolicyEvent]) -> dict:
    """Map policyVersion -> cap, taking the latest ``seq`` if it repeats."""
    latest: dict = {}
    for event in sorted(events, key=lambda e: e.seq):
        latest[event.policyVersion] = event
    return {version: ev.cap for version, ev in latest.items()}


def verify(records: Iterable[DayRecord],
           events: Iterable[PolicyEvent]) -> VerificationReport:
    """Verify every recorded day against the replayed policy history."""
    records = list(records)
    events = list(events)

    anomalies: list = []

    seen_days: dict = {}
    for record in records:
        if record.dayIndex in seen_days:
            raise ValueError(
                f"duplicate record for dayIndex {record.dayIndex}; SPEC.md "
                "section 2.1 specifies one row per calendar day"
            )
        seen_days[record.dayIndex] = record
        if record.paused and record.netSpend != 0:
            anomalies.append(Anomaly(
                "paused_day_nonzero_netspend", record.dayIndex,
                f"paused day carries netSpend {record.netSpend}; treated as 0 "
                "for the window sum per SPEC.md section 4",
            ))

    schedule = build_policy_schedule(events)
    caps_by_version = _cap_by_policy_version(events)

    results: list = []
    for record in sorted(records, key=lambda r: r.dayIndex):
        day = record.dayIndex

        # Section 6.1, stated explicitly rather than left to fall out of the
        # ordering: the day is judged against the regime in force ON THAT DAY.
        # A later lowering never reaches back and convicts it.
        regime = regime_in_force(schedule, day)

        if regime is None:
            anomalies.append(Anomaly(
                "no_policy_in_force", day,
                "no policy write is effective on or before this day; "
                "compliance is undetermined",
            ))
            results.append(DayResult(
                dayIndex=day,
                netSpend=record.netSpend,
                windowSum=None,
                capInForce=None,
                windowDaysInForce=None,
                compliant=None,
                policyVersionMismatch=None,
                policyVersionInForce=None,
                paused=record.paused,
            ))
            continue

        total = window_sum(records, day, regime.windowDays)
        compliant = total <= regime.cap        # section 6: <= , equality passes

        # Section 6.2 -- an entirely separate question from compliance.
        mismatch: Optional[bool]
        if record.policyVersion is None:
            mismatch = None
        elif record.policyVersion not in caps_by_version:
            mismatch = True
            anomalies.append(Anomaly(
                "unknown_policy_version", day,
                f"record is bound to policyVersion {record.policyVersion}, "
                "which appears in no policy event",
            ))
        else:
            bound_cap = caps_by_version[record.policyVersion]
            mismatch = bound_cap != regime.cap
            if mismatch:
                anomalies.append(Anomaly(
                    "policy_version_cap_mismatch", day,
                    f"record bound to policyVersion {record.policyVersion} "
                    f"(cap {bound_cap}) but the regime in force is version "
                    f"{regime.policyVersion} (cap {regime.cap})",
                ))

        results.append(DayResult(
            dayIndex=day,
            netSpend=record.netSpend,
            windowSum=total,
            capInForce=regime.cap,
            windowDaysInForce=regime.windowDays,
            compliant=compliant,
            policyVersionMismatch=mismatch,
            policyVersionInForce=regime.policyVersion,
            paused=record.paused,
        ))

    return VerificationReport(results=results, schedule=schedule,
                              anomalies=anomalies)


# ---------------------------------------------------------------------------
# CSV I/O
# ---------------------------------------------------------------------------

_TRUE = {"1", "true", "t", "yes", "y"}
_FALSE = {"", "0", "false", "f", "no", "n"}

# Accepted spellings for the net-spend column.  The generated daily-record
# files in this repository call it ``spendMilliUsd``; SPEC.md calls it
# ``netSpend``.  Both are accepted, ``netSpend`` wins if both are present.
_NET_SPEND_ALIASES = ("netSpend", "spendMilliUsd", "netSpendMilliUsd")


def _parse_bool(value, what: str) -> bool:
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in _TRUE:
        return True
    if text in _FALSE:
        return False
    raise ValueError(f"{what} is not a boolean: {value!r}")


def _optional(row: dict, key: str):
    value = row.get(key)
    if value is None:
        return None
    value = value.strip() if isinstance(value, str) else value
    return None if value == "" else value


def read_records_csv(path: str, agent_id: Optional[str] = None) -> list:
    """Read a day-record CSV.

    Required column: ``dayIndex`` plus one of ``netSpend`` / ``spendMilliUsd``.
    Optional columns: ``policyVersion``, ``paused``, ``agentId``.
    """
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"{path}: empty file")
        fields = set(reader.fieldnames)
        if "dayIndex" not in fields:
            raise ValueError(f"{path}: missing required column 'dayIndex'")
        spend_col = next((c for c in _NET_SPEND_ALIASES if c in fields), None)
        if spend_col is None:
            raise ValueError(
                f"{path}: missing a net-spend column (one of "
                f"{', '.join(_NET_SPEND_ALIASES)})"
            )

        records = []
        agents = set()
        for line_no, row in enumerate(reader, start=2):
            row_agent = _optional(row, "agentId")
            if row_agent is not None:
                agents.add(row_agent)
                if agent_id is not None and row_agent != agent_id:
                    continue
            try:
                version = _optional(row, "policyVersion")
                paused_raw = _optional(row, "paused")
                records.append(DayRecord(
                    dayIndex=_to_int_exact(row["dayIndex"], "dayIndex"),
                    netSpend=to_int_milli_usd(row[spend_col]),
                    policyVersion=(None if version is None
                                   else _to_int_exact(version, "policyVersion")),
                    paused=(False if paused_raw is None
                            else _parse_bool(paused_raw, "paused")),
                ))
            except (ValueError, TypeError) as exc:
                raise ValueError(f"{path}:{line_no}: {exc}") from exc

    if agent_id is None and len(agents) > 1:
        raise ValueError(
            f"{path}: contains {len(agents)} distinct agentId values; pass "
            "--agent to select one (the rule is per-agent)"
        )
    return records


def read_policy_events_csv(path: str) -> list:
    """Read a policy-event CSV.

    Required columns: ``seq``, ``policyVersion``, ``cap``, ``windowDays``,
    ``effectiveFromDay``.  Optional: ``setBy``.
    """
    required = ["seq", "policyVersion", "cap", "windowDays", "effectiveFromDay"]
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"{path}: empty file")
        missing = [c for c in required if c not in set(reader.fieldnames)]
        if missing:
            raise ValueError(f"{path}: missing column(s) {', '.join(missing)}")

        events = []
        for line_no, row in enumerate(reader, start=2):
            try:
                events.append(PolicyEvent(
                    seq=_to_int_exact(row["seq"], "seq"),
                    policyVersion=_to_int_exact(row["policyVersion"],
                                                "policyVersion"),
                    cap=to_int_milli_usd(row["cap"]),
                    windowDays=_to_int_exact(row["windowDays"], "windowDays"),
                    effectiveFromDay=_to_int_exact(row["effectiveFromDay"],
                                                   "effectiveFromDay"),
                    setBy=(_optional(row, "setBy") or ""),
                ))
            except (ValueError, TypeError) as exc:
                raise ValueError(f"{path}:{line_no}: {exc}") from exc
    if not events:
        raise ValueError(f"{path}: no policy events; SPEC.md section 5 needs "
                         "at least a genesis write")
    return events


RESULT_COLUMNS = [
    "dayIndex", "netSpend", "windowSum", "capInForce", "windowDaysInForce",
    "compliant", "policyVersionMismatch",
]


def _cell(value):
    if value is None:
        return "NA"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def write_results_csv(report: VerificationReport, handle) -> None:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(RESULT_COLUMNS)
    for r in report.results:
        writer.writerow([
            _cell(r.dayIndex), _cell(r.netSpend), _cell(r.windowSum),
            _cell(r.capInForce), _cell(r.windowDaysInForce),
            _cell(r.compliant), _cell(r.policyVersionMismatch),
        ])


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _summary(report: VerificationReport) -> dict:
    return {
        "days": len(report.results),
        "compliant": sum(1 for r in report.results if r.compliant is True),
        "breaches": len(report.breaches),
        "policyVersionMismatches": len(report.version_mismatches),
        "undetermined": len(report.undetermined),
        "anomalies": len(report.anomalies),
        "regimes": [
            {
                "effectiveDay": g.effectiveDay,
                "requestedFromDay": g.requestedFromDay,
                "deferredToBoundary": g.deferred,
                "seq": g.seq,
                "policyVersion": g.policyVersion,
                "cap": g.cap,
                "windowDays": g.windowDays,
            }
            for g in report.schedule
        ],
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="verify.py",
        description="Independent verifier for the rolling-window spending cap "
                    "(implemented from verifier/SPEC.md).",
    )
    parser.add_argument("--records", required=True,
                        help="day-record CSV (dayIndex, netSpend/spendMilliUsd"
                             "[, policyVersion, paused, agentId])")
    parser.add_argument("--policy", required=True,
                        help="policy-event CSV (seq, policyVersion, cap, "
                             "windowDays, effectiveFromDay[, setBy])")
    parser.add_argument("--out", default="-",
                        help="per-day results CSV; '-' for stdout (default)")
    parser.add_argument("--agent", default=None,
                        help="agentId to select when the records file holds "
                             "more than one agent")
    parser.add_argument("--summary-json", default=None,
                        help="write a JSON summary (incl. the replayed policy "
                             "schedule) to this path")
    parser.add_argument("--quiet", action="store_true",
                        help="suppress the human-readable summary on stderr")
    args = parser.parse_args(argv)

    try:
        records = read_records_csv(args.records, agent_id=args.agent)
        events = read_policy_events_csv(args.policy)
        report = verify(records, events)
    except (OSError, ValueError) as exc:
        print(f"verify.py: error: {exc}", file=sys.stderr)
        return 2

    if args.out == "-":
        write_results_csv(report, sys.stdout)
    else:
        with open(args.out, "w", newline="", encoding="utf-8") as handle:
            write_results_csv(report, handle)

    summary = _summary(report)
    if args.summary_json:
        with open(args.summary_json, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2)
            handle.write("\n")

    if not args.quiet:
        print(
            "days={days} compliant={compliant} breaches={breaches} "
            "versionMismatches={policyVersionMismatches} "
            "undetermined={undetermined} anomalies={anomalies}".format(**summary),
            file=sys.stderr,
        )
        for anomaly in report.anomalies[:20]:
            print(f"  [{anomaly.kind}] day={anomaly.dayIndex} "
                  f"{anomaly.detail}", file=sys.stderr)
        if len(report.anomalies) > 20:
            print(f"  ... {len(report.anomalies) - 20} further anomalies",
                  file=sys.stderr)

    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
