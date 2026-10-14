#!/usr/bin/env python3
"""
Independent verifier for the rolling-window energy spending cap -- version 2.

Implemented solely from ``docs/earlier-design/enforcement-rule.md`` (version 2).  No
Solidity, no on-chain source, and nothing describing the on-chain side was
consulted.  Every judgment call not settled by the spec is listed in
``docs/earlier-design/verifier-implementation-notes.md`` under "Ambiguities".

Structure, and why it looks the way it does
-------------------------------------------

The pipeline is four pure stages, each a function of complete inputs:

1.  :func:`settle` -- readings + prices -> ``{dayIndex: spendMilliUsd}`` for
    settled days only, plus anomalies (spec sections 4, 5).
2.  :func:`replay_policy` -- policy events -> every write with its *derived*
    effective day and whether it survived (spec 7.1, 7.2, 7.4).
3.  :func:`regime_on` -- surviving writes + a day -> the regime in force
    (spec 7.3).  Called afresh for every day asked about.
4.  :func:`window_sum` -- the *complete* spend mapping + a day + a window
    length -> the sum (spec 6).  It scans every settled day on every call and
    keeps nothing between calls: no running total, no add-new/subtract-expiring
    step, no cursor, no cache.  Evaluating days in any order, or one day in
    isolation, gives identical answers.

All arithmetic is on Python ``int``.  There is no ``float``, no ``Decimal`` and
no built-in ``round`` anywhere in this module; section 5's half-away-from-zero
rounding is :func:`round_exact_to_milli_usd`, done with ``divmod`` on
magnitudes.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import dataclass
from typing import Iterable, Mapping, Optional, Sequence

__all__ = [
    "SLOTS_PER_DAY", "EXACT_UNITS_PER_MILLI_USD",
    "Reading", "Price", "PolicyEvent", "ReplayedWrite", "Anomaly",
    "DayResult", "PolicyRow", "Report",
    "day_index_from_unix_seconds", "round_exact_to_milli_usd",
    "exact_day_total", "settle", "next_window_boundary", "replay_policy",
    "regime_on", "window_sum", "verify",
    "read_readings_csv", "read_prices_csv", "read_policy_csv",
    "write_days_csv", "write_policy_csv", "summary_dict", "main",
]

SLOTS_PER_DAY = 48
SECONDS_PER_DAY = 86400
# exact is in 1e-14 USD (1 mWh = 1e-6 kWh, one price unit = 1e-8 USD/kWh).
# One milli-USD = 1e-3 USD = 1e11 exact units.
EXACT_UNITS_PER_MILLI_USD = 100_000_000_000

# Anomaly categories.  The first five are the ones spec section 10.1 names;
# the rest are places the input is malformed in a way the spec does not name
# (see the ambiguity list).
INCOMPLETE_DAY = "incomplete_day"
INVALID_HALF_HOUR = "invalid_half_hour"
GAP = "gap"
NO_REGIME = "no_regime"
DEFERRAL_MISMATCH = "deferral_mismatch"
DUPLICATE_SLOT = "duplicate_slot"
POLICY_OUT_OF_ORDER = "policy_out_of_order"
NO_INCUMBENT_REGIME = "no_incumbent_regime"


# ---------------------------------------------------------------------------
# Integer primitives
# ---------------------------------------------------------------------------

_INT_RE = re.compile(r"[+-]?[0-9]+", re.ASCII)


def parse_int(text, what: str) -> int:
    """Parse a strictly integral field.  ``"1.0"``, ``"1e3"``, ``""`` and
    non-ASCII digits are rejected rather than coerced."""
    if isinstance(text, bool):
        raise ValueError(f"{what} must be an integer, got a bool")
    if isinstance(text, int):
        return text
    s = str(text).strip()
    if not _INT_RE.fullmatch(s):
        raise ValueError(f"{what} is not an integer: {text!r}")
    return int(s)


def day_index_from_unix_seconds(unix_seconds: int) -> int:
    """Spec section 3: ``floor(unix_seconds / 86400)``.  ``//`` floors."""
    return parse_int(unix_seconds, "unix_seconds") // SECONDS_PER_DAY


def round_exact_to_milli_usd(exact: int) -> int:
    """Spec section 5: ``exact / 1e11`` rounded half away from zero.

    Works on the magnitude so that the sign cannot interact with floor
    division, then restores the sign.  A remainder of at least one half
    (``2 * r >= divisor``) rounds the magnitude up.
    """
    if isinstance(exact, bool) or not isinstance(exact, int):
        raise TypeError("exact must be an int")
    magnitude = -exact if exact < 0 else exact
    quotient, remainder = divmod(magnitude, EXACT_UNITS_PER_MILLI_USD)
    if 2 * remainder >= EXACT_UNITS_PER_MILLI_USD:
        quotient += 1
    return -quotient if exact < 0 else quotient


def next_window_boundary(day: int, window_days: int) -> int:
    """Spec 7.2: the smallest multiple of ``window_days`` strictly greater
    than ``day``.  If ``day`` is a multiple, the answer is ``day + w``."""
    if window_days < 1:
        raise ValueError("windowDays must be >= 1")
    return (day // window_days + 1) * window_days


# ---------------------------------------------------------------------------
# Input and output types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Reading:
    dayIndex: int
    slot: int
    importMWh: int
    exportMWh: int


@dataclass(frozen=True)
class Price:
    dayIndex: int
    slot: int
    importPrice: int
    exportPrice: int


@dataclass(frozen=True)
class PolicyEvent:
    seq: int
    policyVersion: int
    cap: int
    windowDays: int
    submittedOnDay: int
    effectiveFromDay: int
    setBy: str = ""


@dataclass(frozen=True)
class ReplayedWrite:
    """A policy event after replay.

    ``classification`` is one of ``genesis``, ``raise``, ``not_raise`` or
    ``no_incumbent``.  ``cancelledBySeq`` is the seq of the lowering/unchanged
    write that cancelled it, or ``None`` if it survived.
    """
    event: PolicyEvent
    derivedEffectiveFromDay: int
    classification: str
    incumbentSeq: Optional[int]
    cancelledBySeq: Optional[int] = None

    @property
    def seq(self) -> int:
        return self.event.seq

    @property
    def cap(self) -> int:
        return self.event.cap

    @property
    def windowDays(self) -> int:
        return self.event.windowDays

    @property
    def policyVersion(self) -> int:
        return self.event.policyVersion

    @property
    def survives(self) -> bool:
        return self.cancelledBySeq is None

    @property
    def deferralOk(self) -> bool:
        if self.classification == "genesis":
            return True
        return self.derivedEffectiveFromDay == self.event.effectiveFromDay


@dataclass(frozen=True)
class Anomaly:
    category: str
    dayIndex: Optional[int]
    detail: str
    seq: Optional[int] = None


@dataclass(frozen=True)
class DayResult:
    dayIndex: int
    spendMilliUsd: int
    windowSum: Optional[int]
    capInForce: Optional[int]
    windowDaysInForce: Optional[int]
    policyVersionInForce: Optional[int]
    compliant: Optional[bool]
    authorisedNextDay: Optional[bool]


@dataclass(frozen=True)
class PolicyRow:
    seq: int
    policyVersion: int
    submittedOnDay: int
    derivedEffectiveFromDay: int
    emittedEffectiveFromDay: int
    deferralOk: bool


@dataclass
class Report:
    days: list          # list[DayResult], ascending dayIndex, settled days only
    policy: list        # list[PolicyRow], ascending seq
    replay: list        # list[ReplayedWrite], ascending seq
    spends: dict        # {dayIndex: spendMilliUsd}, settled days only
    anomalies: list     # list[Anomaly]

    @property
    def ok(self) -> bool:
        return not self.anomalies


# ---------------------------------------------------------------------------
# Sections 4 and 5 -- settlement and daily spend
# ---------------------------------------------------------------------------


def exact_day_total(pairs: Iterable[tuple]) -> int:
    """Spec 5: sum(import * importPrice) - sum(export * exportPrice), exact,
    over (Reading, Price) pairs.  Not rounded."""
    imported = 0
    exported = 0
    for reading, price in pairs:
        imported += reading.importMWh * price.importPrice
        exported += reading.exportMWh * price.exportPrice
    return imported - exported


def settle(readings: Iterable[Reading], prices: Iterable[Price]):
    """Decide which days are settled and compute each settled day's spend.

    Returns ``(spends, anomalies)`` where ``spends`` maps dayIndex to signed
    milli-USD for settled days only.

    A day is considered if it appears in *either* input.  It is settled only
    if both inputs have exactly one row for each of slots 0..47 and no
    half-hour both imports and exports.
    """
    readings_by_day: dict = {}
    for r in readings:
        readings_by_day.setdefault(r.dayIndex, []).append(r)
    prices_by_day: dict = {}
    for p in prices:
        prices_by_day.setdefault(p.dayIndex, []).append(p)

    anomalies: list = []
    spends: dict = {}
    all_slots = set(range(SLOTS_PER_DAY))

    for day in sorted(set(readings_by_day) | set(prices_by_day)):
        settled = True
        per_input = (("readings", readings_by_day.get(day, [])),
                     ("prices", prices_by_day.get(day, [])))
        for label, rows in per_input:
            counts: dict = {}
            for row in rows:
                counts[row.slot] = counts.get(row.slot, 0) + 1
            duplicated = sorted(s for s, c in counts.items() if c > 1)
            missing = sorted(all_slots - set(counts))
            if duplicated:
                settled = False
                anomalies.append(Anomaly(
                    DUPLICATE_SLOT, day,
                    f"{label} has more than one row for slot(s) "
                    f"{_fmt_slots(duplicated)}; day not settled"))
            if missing:
                settled = False
                anomalies.append(Anomaly(
                    INCOMPLETE_DAY, day,
                    f"{label} missing {len(missing)} of {SLOTS_PER_DAY} "
                    f"slot(s): {_fmt_slots(missing)}; day not settled"))

        for r in sorted(readings_by_day.get(day, []), key=lambda x: x.slot):
            if r.importMWh > 0 and r.exportMWh > 0:
                settled = False
                anomalies.append(Anomaly(
                    INVALID_HALF_HOUR, day,
                    f"slot {r.slot} imports {r.importMWh} mWh and exports "
                    f"{r.exportMWh} mWh; day not settled"))

        if not settled:
            continue

        price_at = {p.slot: p for p in prices_by_day[day]}
        pairs = [(r, price_at[r.slot]) for r in readings_by_day[day]]
        spends[day] = round_exact_to_milli_usd(exact_day_total(pairs))

    settled_days = sorted(spends)
    for earlier, later in zip(settled_days, settled_days[1:]):
        if later - earlier > 1:
            first, last = earlier + 1, later - 1
            span = str(first) if first == last else f"{first}..{last}"
            anomalies.append(Anomaly(
                GAP, first,
                f"no settled day in {span} ({last - first + 1} day(s)) between "
                f"settled days {earlier} and {later}; contributes 0"))

    return spends, anomalies


def _fmt_slots(slots: Sequence[int]) -> str:
    if len(slots) > 12:
        return ",".join(map(str, slots[:12])) + f",... ({len(slots)} total)"
    return ",".join(map(str, slots))


# ---------------------------------------------------------------------------
# Section 7 -- policy replay and regime selection
# ---------------------------------------------------------------------------


def regime_on(writes: Iterable[ReplayedWrite], day: int) -> Optional[ReplayedWrite]:
    """Spec 7.3: among *surviving* writes whose derived effective day is
    ``<= day``, the greatest effective day; on a tie, the higher seq.
    Stateless: scans every write on every call."""
    best = None
    for w in writes:
        if not w.survives or w.derivedEffectiveFromDay > day:
            continue
        key = (w.derivedEffectiveFromDay, w.seq)
        if best is None or key > (best.derivedEffectiveFromDay, best.seq):
            best = w
    return best


def replay_policy(events: Iterable[PolicyEvent]):
    """Replay policy writes from genesis in seq order (spec 7.1, 7.2).

    Returns ``(replayed, anomalies)``; ``replayed`` is in ascending seq and
    includes cancelled writes (marked via ``cancelledBySeq``) so that the
    deferral check (7.4) still covers them.
    """
    ordered = sorted(events, key=lambda e: e.seq)
    seen = set()
    for e in ordered:
        if e.seq in seen:
            raise ValueError(f"duplicate policy seq {e.seq}")
        seen.add(e.seq)
        if e.windowDays < 1:
            raise ValueError(f"policy seq {e.seq}: windowDays {e.windowDays} < 1")

    anomalies: list = []
    replayed: list = []
    latest_submitted: Optional[int] = None

    for index, event in enumerate(ordered):
        s = event.submittedOnDay
        if latest_submitted is not None and s < latest_submitted:
            anomalies.append(Anomaly(
                POLICY_OUT_OF_ORDER, s,
                f"seq {event.seq} submittedOnDay {s} is earlier than an "
                f"earlier-seq write's submittedOnDay {latest_submitted}; "
                "replayed in seq order regardless", seq=event.seq))
        latest_submitted = s if latest_submitted is None else max(latest_submitted, s)

        if index == 0:
            replayed.append(ReplayedWrite(event, event.effectiveFromDay,
                                          "genesis", None))
            continue

        current = regime_on(replayed, s)
        if current is None:
            # 7.2 is undefined without an incumbent.  Treated as not-a-raise:
            # effective on s, cancelling later-effective writes.
            anomalies.append(Anomaly(
                NO_INCUMBENT_REGIME, s,
                f"seq {event.seq}: no regime in force on submittedOnDay {s}, "
                "so raise/not-raise is undefined; treated as not a raise "
                "(effective on submittedOnDay)", seq=event.seq))
            classification, derived, incumbent_seq = "no_incumbent", s, None
        elif event.cap > current.cap:
            classification = "raise"
            derived = next_window_boundary(s, current.windowDays)
            incumbent_seq = current.seq
        else:
            classification, derived, incumbent_seq = "not_raise", s, current.seq

        if classification != "raise":
            replayed = [
                ReplayedWrite(w.event, w.derivedEffectiveFromDay,
                              w.classification, w.incumbentSeq, event.seq)
                if (w.survives and w.derivedEffectiveFromDay > s) else w
                for w in replayed
            ]

        replayed.append(ReplayedWrite(event, derived, classification,
                                      incumbent_seq))

    for w in replayed:
        if not w.deferralOk:
            anomalies.append(Anomaly(
                DEFERRAL_MISMATCH, w.event.submittedOnDay,
                f"seq {w.seq} ({w.classification}, cap {w.cap}): chain recorded "
                f"effectiveFromDay {w.event.effectiveFromDay}, rule derives "
                f"{w.derivedEffectiveFromDay}; derived day used. Finding about "
                "the chain, not a breach by the agent", seq=w.seq))

    return replayed, anomalies


# ---------------------------------------------------------------------------
# Section 6 -- the window sum
# ---------------------------------------------------------------------------


def window_sum(spends: Mapping[int, int], day: int, window_days: int) -> int:
    """Spec 6: sum of spend over the inclusive range ``[day - w + 1, day]``.

    Scans the complete mapping of settled-day spends and keeps nothing
    between calls.  Days absent from ``spends`` (not settled, gaps, before the
    data) contribute 0 by not being present.  Negative spends are summed as
    they are.
    """
    if window_days < 1:
        raise ValueError("windowDays must be >= 1")
    oldest = day - window_days + 1
    total = 0
    for d, spend in spends.items():
        if oldest <= d <= day:
            total += spend
    return total


# ---------------------------------------------------------------------------
# Sections 8, 9 -- per-day verdicts
# ---------------------------------------------------------------------------


def verify(readings: Iterable[Reading], prices: Iterable[Price],
           events: Iterable[PolicyEvent]) -> Report:
    spends, anomalies = settle(readings, prices)
    replayed, policy_anomalies = replay_policy(events)
    anomalies.extend(policy_anomalies)

    days: list = []
    for d in sorted(spends):
        regime = regime_on(replayed, d)
        if regime is None:
            anomalies.append(Anomaly(
                NO_REGIME, d,
                "settled day earlier than every effective policy write; "
                "compliance and authorisation undetermined"))
            days.append(DayResult(d, spends[d], None, None, None, None,
                                  None, None))
            continue

        total = window_sum(spends, d, regime.windowDays)
        next_regime = regime_on(replayed, d + 1)
        authorised = None if next_regime is None else total <= next_regime.cap
        days.append(DayResult(
            dayIndex=d,
            spendMilliUsd=spends[d],
            windowSum=total,
            capInForce=regime.cap,
            windowDaysInForce=regime.windowDays,
            policyVersionInForce=regime.policyVersion,
            compliant=total <= regime.cap,
            authorisedNextDay=authorised,
        ))

    policy = [PolicyRow(w.seq, w.policyVersion, w.event.submittedOnDay,
                        w.derivedEffectiveFromDay, w.event.effectiveFromDay,
                        w.deferralOk)
              for w in replayed]
    return Report(days=days, policy=policy, replay=replayed, spends=spends,
                  anomalies=anomalies)


# ---------------------------------------------------------------------------
# CSV I/O
# ---------------------------------------------------------------------------


def _read_rows(path: str, required: Sequence[str]):
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"{path}: empty file")
        names = [n.strip() for n in reader.fieldnames]
        missing = [c for c in required if c not in names]
        if missing:
            raise ValueError(f"{path}: missing column(s) {', '.join(missing)}")
        reader.fieldnames = names
        return [(line_no, row) for line_no, row in enumerate(reader, start=2)]


def _slot(value, what):
    slot = parse_int(value, what)
    if not 0 <= slot < SLOTS_PER_DAY:
        raise ValueError(f"{what} {slot} outside 0..{SLOTS_PER_DAY - 1}")
    return slot


def _non_negative(value, what):
    n = parse_int(value, what)
    if n < 0:
        raise ValueError(f"{what} must be >= 0, got {n}")
    return n


def read_readings_csv(path: str) -> list:
    out = []
    for line_no, row in _read_rows(path, ["dayIndex", "slot", "importMWh", "exportMWh"]):
        try:
            out.append(Reading(parse_int(row["dayIndex"], "dayIndex"),
                               _slot(row["slot"], "slot"),
                               _non_negative(row["importMWh"], "importMWh"),
                               _non_negative(row["exportMWh"], "exportMWh")))
        except ValueError as exc:
            raise ValueError(f"{path}:{line_no}: {exc}") from exc
    return out


def read_prices_csv(path: str) -> list:
    out = []
    for line_no, row in _read_rows(path, ["dayIndex", "slot", "importPrice", "exportPrice"]):
        try:
            out.append(Price(parse_int(row["dayIndex"], "dayIndex"),
                             _slot(row["slot"], "slot"),
                             parse_int(row["importPrice"], "importPrice"),
                             parse_int(row["exportPrice"], "exportPrice")))
        except ValueError as exc:
            raise ValueError(f"{path}:{line_no}: {exc}") from exc
    return out


def read_policy_csv(path: str) -> list:
    required = ["seq", "policyVersion", "cap", "windowDays",
                "submittedOnDay", "effectiveFromDay"]
    out = []
    for line_no, row in _read_rows(path, required):
        try:
            window = parse_int(row["windowDays"], "windowDays")
            if window < 1:
                raise ValueError(f"windowDays must be >= 1, got {window}")
            out.append(PolicyEvent(
                seq=parse_int(row["seq"], "seq"),
                policyVersion=parse_int(row["policyVersion"], "policyVersion"),
                cap=parse_int(row["cap"], "cap"),
                windowDays=window,
                submittedOnDay=parse_int(row["submittedOnDay"], "submittedOnDay"),
                effectiveFromDay=parse_int(row["effectiveFromDay"], "effectiveFromDay"),
                setBy=(row.get("setBy") or "").strip(),
            ))
        except ValueError as exc:
            raise ValueError(f"{path}:{line_no}: {exc}") from exc
    return out


DAY_COLUMNS = ["dayIndex", "spendMilliUsd", "windowSum", "capInForce",
               "windowDaysInForce", "policyVersionInForce", "compliant",
               "authorisedNextDay"]
POLICY_COLUMNS = ["seq", "policyVersion", "submittedOnDay",
                  "derivedEffectiveFromDay", "emittedEffectiveFromDay",
                  "deferralOk"]


def _cell(value) -> str:
    if value is None:
        return "NA"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def write_days_csv(report: Report, handle) -> None:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(DAY_COLUMNS)
    for r in report.days:
        writer.writerow([_cell(getattr(r, c)) for c in DAY_COLUMNS])


def write_policy_csv(report: Report, handle) -> None:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(POLICY_COLUMNS)
    for p in report.policy:
        writer.writerow([_cell(getattr(p, c)) for c in POLICY_COLUMNS])


def summary_dict(report: Report) -> dict:
    by_category: dict = {}
    for a in report.anomalies:
        by_category[a.category] = by_category.get(a.category, 0) + 1
    days = report.days
    settled = sorted(report.spends)
    return {
        "settledDays": len(settled),
        "firstSettledDay": settled[0] if settled else None,
        "lastSettledDay": settled[-1] if settled else None,
        "totalSpendMilliUsd": sum(report.spends.values()),
        "compliantDays": sum(1 for r in days if r.compliant is True),
        "breachDays": sum(1 for r in days if r.compliant is False),
        "undeterminedDays": sum(1 for r in days if r.compliant is None),
        "authorisedNextDayTrue": sum(1 for r in days if r.authorisedNextDay is True),
        "authorisedNextDayFalse": sum(1 for r in days if r.authorisedNextDay is False),
        "breaches": [r.dayIndex for r in days if r.compliant is False],
        "notAuthorisedNextDay": [r.dayIndex for r in days
                                 if r.authorisedNextDay is False],
        "anomalyCount": len(report.anomalies),
        "anomaliesByCategory": by_category,
        "anomalies": [{"category": a.category, "dayIndex": a.dayIndex,
                       "seq": a.seq, "detail": a.detail}
                      for a in report.anomalies],
        "policyReplay": [{
            "seq": w.seq, "policyVersion": w.policyVersion, "cap": w.cap,
            "windowDays": w.windowDays,
            "submittedOnDay": w.event.submittedOnDay,
            "emittedEffectiveFromDay": w.event.effectiveFromDay,
            "derivedEffectiveFromDay": w.derivedEffectiveFromDay,
            "classification": w.classification,
            "incumbentSeq": w.incumbentSeq,
            "cancelledBySeq": w.cancelledBySeq,
            "deferralOk": w.deferralOk,
        } for w in report.replay],
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _open_out(path: str):
    if path == "-":
        return None
    return open(path, "w", newline="", encoding="utf-8")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="verify.py",
        description="Independent verifier for the rolling-window energy "
                    "spending cap (docs/earlier-design/enforcement-rule.md, version 2).")
    parser.add_argument("--readings", required=True,
                        help="CSV: dayIndex,slot,importMWh,exportMWh")
    parser.add_argument("--prices", required=True,
                        help="CSV: dayIndex,slot,importPrice,exportPrice")
    parser.add_argument("--policy", required=True,
                        help="CSV: seq,policyVersion,cap,windowDays,"
                             "submittedOnDay,effectiveFromDay[,setBy]")
    parser.add_argument("--out", required=True,
                        help="per-settled-day CSV ('-' for stdout)")
    parser.add_argument("--policy-report", default=None,
                        help="per-policy-write CSV")
    parser.add_argument("--summary-json", default=None,
                        help="JSON summary including every anomaly")
    args = parser.parse_args(argv)

    try:
        report = verify(read_readings_csv(args.readings),
                        read_prices_csv(args.prices),
                        read_policy_csv(args.policy))
    except (OSError, ValueError) as exc:
        print(f"verify.py: input error: {exc}", file=sys.stderr)
        return 2

    handle = _open_out(args.out)
    if handle is None:
        write_days_csv(report, sys.stdout)
    else:
        with handle:
            write_days_csv(report, handle)
    if args.policy_report:
        with open(args.policy_report, "w", newline="", encoding="utf-8") as h:
            write_policy_csv(report, h)
    summary = summary_dict(report)
    if args.summary_json:
        with open(args.summary_json, "w", encoding="utf-8") as h:
            json.dump(summary, h, indent=2)
            h.write("\n")

    for a in report.anomalies:
        where = "" if a.dayIndex is None else f" day={a.dayIndex}"
        print(f"ANOMALY [{a.category}]{where} {a.detail}", file=sys.stderr)
    print("settledDays={settledDays} totalSpendMilliUsd={totalSpendMilliUsd} "
          "compliant={compliantDays} breaches={breachDays} "
          "undetermined={undeterminedDays} "
          "authorisedNextDayFalse={authorisedNextDayFalse} "
          "anomalies={anomalyCount}".format(**summary), file=sys.stderr)

    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
