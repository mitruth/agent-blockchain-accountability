#!/usr/bin/env python3
"""Tests for verify.py, written against verifier/SPEC.md only.

Run with either::

    python -m pytest verifier/test_verify.py
    python -m unittest discover -s verifier -p "test_*.py"
    python verifier/test_verify.py

Every test names the SPEC.md clause it is exercising.
"""

from __future__ import annotations

import io
import os
import sys
import unittest
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from verify import (  # noqa: E402
    Anomaly,
    DayRecord,
    PolicyEvent,
    build_policy_schedule,
    day_index_from_unix_seconds,
    next_window_boundary,
    regime_in_force,
    round_half_away_from_zero,
    verify,
    window_sum,
    write_results_csv,
)


def genesis(cap=1000, window_days=7, day=0, seq=1, version=1):
    return PolicyEvent(seq=seq, policyVersion=version, cap=cap,
                       windowDays=window_days, effectiveFromDay=day,
                       setBy="0xowner")


def rec(day, spend, version=None, paused=False):
    return DayRecord(dayIndex=day, netSpend=spend, policyVersion=version,
                     paused=paused)


def result_for(report, day):
    for r in report.results:
        if r.dayIndex == day:
            return r
    raise AssertionError(f"no result for day {day}")


# ---------------------------------------------------------------------------
# Section 7 -- rounding
# ---------------------------------------------------------------------------


class TestRoundingHalfAwayFromZero(unittest.TestCase):
    """SPEC.md section 7. The .5 cases in BOTH signs are the only cases that
    distinguish half-away-from-zero from banker's rounding."""

    def test_positive_half_cases(self):
        self.assertEqual(round_half_away_from_zero("2.5"), 3)
        self.assertEqual(round_half_away_from_zero("3.5"), 4)
        self.assertEqual(round_half_away_from_zero("0.5"), 1)
        self.assertEqual(round_half_away_from_zero("1.5"), 2)

    def test_negative_half_cases(self):
        self.assertEqual(round_half_away_from_zero("-2.5"), -3)
        self.assertEqual(round_half_away_from_zero("-3.5"), -4)
        self.assertEqual(round_half_away_from_zero("-0.5"), -1)
        self.assertEqual(round_half_away_from_zero("-1.5"), -2)

    def test_differs_from_builtin_round_on_every_half_case(self):
        # If this ever passes trivially the rounding rule has been broken.
        for text, expected in [("2.5", 3), ("-2.5", -3), ("0.5", 1),
                               ("-0.5", -1), ("4.5", 5), ("-4.5", -5)]:
            with self.subTest(text=text):
                self.assertEqual(round_half_away_from_zero(text), expected)
                self.assertNotEqual(round(float(text)), expected,
                                    "builtin round() should disagree here; "
                                    "if it agrees the test is not testing "
                                    "the distinguishing case")

    def test_non_half_cases_are_ordinary_nearest(self):
        self.assertEqual(round_half_away_from_zero("2.4"), 2)
        self.assertEqual(round_half_away_from_zero("2.6"), 3)
        self.assertEqual(round_half_away_from_zero("-2.4"), -2)
        self.assertEqual(round_half_away_from_zero("-2.6"), -3)

    def test_accepts_int_decimal_and_float(self):
        self.assertEqual(round_half_away_from_zero(7), 7)
        self.assertEqual(round_half_away_from_zero(-7), -7)
        self.assertEqual(round_half_away_from_zero(Decimal("-2.5")), -3)
        self.assertEqual(round_half_away_from_zero(2.5), 3)
        self.assertEqual(round_half_away_from_zero(-2.5), -3)

    def test_rejects_garbage(self):
        with self.assertRaises(ValueError):
            round_half_away_from_zero("not a number")
        with self.assertRaises(TypeError):
            round_half_away_from_zero(True)


# ---------------------------------------------------------------------------
# Section 3 -- day index
# ---------------------------------------------------------------------------


class TestDayIndex(unittest.TestCase):
    """SPEC.md section 3: floor(unix_seconds / 86400), UTC, always."""

    def test_epoch_and_first_boundary(self):
        self.assertEqual(day_index_from_unix_seconds(0), 0)
        self.assertEqual(day_index_from_unix_seconds(86399), 0)
        self.assertEqual(day_index_from_unix_seconds(86400), 1)
        self.assertEqual(day_index_from_unix_seconds(86401), 1)

    def test_floors_towards_negative_infinity_before_epoch(self):
        self.assertEqual(day_index_from_unix_seconds(-1), -1)
        self.assertEqual(day_index_from_unix_seconds(-86400), -1)
        self.assertEqual(day_index_from_unix_seconds(-86401), -2)


# ---------------------------------------------------------------------------
# Section 4 -- the window sum
# ---------------------------------------------------------------------------


class TestWindowSum(unittest.TestCase):

    def test_both_endpoints_included(self):
        """SPEC.md section 4: with w=7 the window covers d and the six days
        before it -- seven days total."""
        records = [rec(d, 1) for d in range(0, 20)]
        self.assertEqual(window_sum(records, 10, 7), 7)
        self.assertEqual(window_sum(records, 10, 1), 1)

    def test_oldest_day_is_included_then_leaves_one_day_later(self):
        """SPEC.md section 8.2 bullet 3."""
        records = [rec(0, 500)] + [rec(d, 0) for d in range(1, 10)]
        self.assertEqual(window_sum(records, 6, 7), 500)   # [0..6] includes 0
        self.assertEqual(window_sum(records, 7, 7), 0)     # [1..7] excludes 0

    def test_missing_day_contributes_zero(self):
        """SPEC.md section 4: a day with no record contributes 0."""
        records = [rec(0, 100), rec(5, 100)]   # days 1-4 absent entirely
        self.assertEqual(window_sum(records, 5, 7), 200)
        self.assertEqual(window_sum(records, 4, 3), 0)     # [2..4]: nothing

    def test_negative_day_reduces_the_sum(self):
        """SPEC.md section 4: never clamped, never dropped, never abs()."""
        records = [rec(0, 1000), rec(1, -400)]
        self.assertEqual(window_sum(records, 1, 7), 600)

    def test_window_sum_may_be_negative(self):
        """SPEC.md section 4: the sum may legitimately be negative."""
        records = [rec(0, 100), rec(1, -900)]
        self.assertEqual(window_sum(records, 1, 7), -800)

    def test_paused_day_is_zero_and_the_window_still_advances(self):
        """SPEC.md section 4: a paused day is a zero-spend day, not a missing
        day. It contributes 0 and the window advances across it."""
        records = [rec(0, 700), rec(1, 999, paused=True), rec(2, 100)]
        self.assertEqual(window_sum(records, 2, 7), 800)
        # The window is not frozen while paused: day 0 still ages out on
        # schedule even though day 1 was paused.
        self.assertEqual(window_sum(records, 7, 7), 100)   # [1..7]
        self.assertEqual(window_sum(records, 9, 7), 0)     # [3..9]

    def test_window_of_one_day(self):
        records = [rec(0, 100), rec(1, 200)]
        self.assertEqual(window_sum(records, 1, 1), 200)

    def test_rejects_zero_window(self):
        with self.assertRaises(ValueError):
            window_sum([rec(0, 1)], 0, 0)


class TestWindowSumIndependence(unittest.TestCase):
    """SPEC.md section 4, required structural property: every day's window is
    computed independently from the complete record set."""

    def setUp(self):
        self.records = [rec(d, (d * 37) % 101 - 50) for d in range(0, 40)]

    def test_order_of_evaluation_does_not_matter(self):
        forward = [window_sum(self.records, d, 7) for d in range(0, 40)]
        backward = [window_sum(self.records, d, 7) for d in range(39, -1, -1)]
        self.assertEqual(forward, list(reversed(backward)))

    def test_a_single_day_in_isolation_matches_the_full_pass(self):
        full = {d: window_sum(self.records, d, 7) for d in range(0, 40)}
        for d in (0, 1, 6, 7, 23, 39):
            with self.subTest(day=d):
                self.assertEqual(window_sum(self.records, d, 7), full[d])

    def test_record_ordering_does_not_matter(self):
        shuffled = list(reversed(self.records))
        for d in range(0, 40):
            with self.subTest(day=d):
                self.assertEqual(window_sum(self.records, d, 7),
                                 window_sum(shuffled, d, 7))

    def test_changing_window_length_recomputes_from_scratch(self):
        # An incremental walk would have to be told the length changed; a
        # from-scratch recomputation simply gets a different answer.
        self.assertNotEqual(window_sum(self.records, 20, 7),
                            window_sum(self.records, 20, 3))


# ---------------------------------------------------------------------------
# Section 5 -- the cap in force
# ---------------------------------------------------------------------------


class TestWindowBoundaries(unittest.TestCase):
    """SPEC.md section 5.5: boundaries are multiples of windowDays measured
    from the Unix epoch; the boundary is the next multiple STRICTLY above d."""

    def test_next_multiple_above(self):
        self.assertEqual(next_window_boundary(0, 7), 7)
        self.assertEqual(next_window_boundary(1, 7), 7)
        self.assertEqual(next_window_boundary(6, 7), 7)
        self.assertEqual(next_window_boundary(7, 7), 14)   # strictly after
        self.assertEqual(next_window_boundary(13, 7), 14)

    def test_boundaries_are_anchored_to_the_epoch_not_to_the_ledger(self):
        # Nothing about these answers depends on when records started.
        self.assertEqual(next_window_boundary(100, 30), 120)
        self.assertEqual(next_window_boundary(-1, 7), 0)

    def test_window_of_one_day_boundaries_every_day(self):
        self.assertEqual(next_window_boundary(5, 1), 6)


class TestPolicyReplay(unittest.TestCase):

    def test_genesis_applies_from_its_effective_day(self):
        schedule = build_policy_schedule([genesis(cap=1000, day=3)])
        self.assertIsNone(regime_in_force(schedule, 2))
        self.assertEqual(regime_in_force(schedule, 3).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 99).cap, 1000)

    def test_a_lowering_applies_immediately(self):
        """SPEC.md section 5 rule 3."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=400, windowDays=7,
                        effectiveFromDay=3),
        ])
        self.assertEqual(regime_in_force(schedule, 2).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 3).cap, 400)
        self.assertEqual(regime_in_force(schedule, 4).cap, 400)

    def test_a_raise_applies_at_the_boundary_not_immediately(self):
        """SPEC.md section 5 rules 4 and 5. Genesis day 0, w=7. A raise made
        on day 3 waits for day 7."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=5000, windowDays=7,
                        effectiveFromDay=3),
        ])
        for day in (3, 4, 5, 6):
            with self.subTest(day=day):
                self.assertEqual(regime_in_force(schedule, day).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 7).cap, 5000)

    def test_a_raise_made_on_a_boundary_day_still_waits(self):
        """The literal reading of section 5.5 ('strictly after day d'). This is
        called out in README.md's ambiguity list as a likely divergence."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=5000, windowDays=7,
                        effectiveFromDay=14),
        ])
        self.assertEqual(regime_in_force(schedule, 14).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 20).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 21).cap, 5000)

    def test_a_lowering_cancels_a_pending_raise(self):
        """SPEC.md section 5 rule 3: a raise queued yesterday must not
        resurrect itself after a lowering made today."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=5000, windowDays=7,
                        effectiveFromDay=3),      # would become effective day 7
            PolicyEvent(seq=3, policyVersion=3, cap=500, windowDays=7,
                        effectiveFromDay=4),      # lowering, immediate
        ])
        self.assertEqual(regime_in_force(schedule, 3).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 4).cap, 500)
        self.assertEqual(regime_in_force(schedule, 7).cap, 500)
        self.assertEqual(regime_in_force(schedule, 100).cap, 500)
        self.assertNotIn(5000, [r.cap for r in schedule])

    def test_a_raise_does_not_cancel_anything(self):
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=5000, windowDays=7,
                        effectiveFromDay=3),      # effective day 7
            PolicyEvent(seq=3, policyVersion=3, cap=3000, windowDays=7,
                        effectiveFromDay=4),      # raise vs in-force 1000
        ])
        # Both land on day 7; rule 6 gives it to the later seq.
        self.assertEqual(regime_in_force(schedule, 6).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 7).cap, 3000)

    def test_two_writes_effective_on_the_same_day_later_seq_wins(self):
        """SPEC.md section 5 rule 6."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=800, windowDays=7,
                        effectiveFromDay=5),
            PolicyEvent(seq=3, policyVersion=3, cap=600, windowDays=7,
                        effectiveFromDay=5),
        ])
        self.assertEqual(regime_in_force(schedule, 5).cap, 600)
        self.assertEqual(regime_in_force(schedule, 5).policyVersion, 3)

    def test_raise_classification_sees_an_earlier_same_day_lowering(self):
        """Consequence of classifying against the cap in force at the write's
        effectiveFromDay (README ambiguity A3). seq 2 lowers 1000 -> 600 on
        day 5 immediately; seq 3's 900 is then a RAISE relative to 600, so it
        defers to the boundary instead of winning day 5 under rule 6."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=600, windowDays=7,
                        effectiveFromDay=5),
            PolicyEvent(seq=3, policyVersion=3, cap=900, windowDays=7,
                        effectiveFromDay=5),
        ])
        self.assertEqual(regime_in_force(schedule, 5).cap, 600)
        self.assertEqual(regime_in_force(schedule, 6).cap, 600)
        self.assertEqual(regime_in_force(schedule, 7).cap, 900)

    def test_a_write_may_change_the_window_length_too(self):
        """SPEC.md section 5: both the cap and the window length come from the
        regime in force."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=1000, windowDays=3,
                        effectiveFromDay=5),
        ])
        self.assertEqual(regime_in_force(schedule, 4).windowDays, 7)
        # Cap unchanged -> not a raise -> immediate (see README ambiguity A4).
        self.assertEqual(regime_in_force(schedule, 5).windowDays, 3)

    def test_deferred_raise_uses_the_window_length_currently_in_force(self):
        """The boundary belongs to the window already partly spent, so it is
        measured with the incumbent w=10, not the new w=3 (README A5)."""
        schedule = build_policy_schedule([
            genesis(cap=1000, window_days=10, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=5000, windowDays=3,
                        effectiveFromDay=4),
        ])
        self.assertEqual(regime_in_force(schedule, 9).cap, 1000)
        self.assertEqual(regime_in_force(schedule, 10).cap, 5000)
        self.assertEqual(regime_in_force(schedule, 10).windowDays, 3)

    def test_events_are_replayed_in_seq_order_not_file_order(self):
        events = [
            PolicyEvent(seq=3, policyVersion=3, cap=500, windowDays=7,
                        effectiveFromDay=4),
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=5000, windowDays=7,
                        effectiveFromDay=3),
        ]
        schedule = build_policy_schedule(events)
        self.assertEqual(regime_in_force(schedule, 7).cap, 500)

    def test_duplicate_seq_is_rejected(self):
        with self.assertRaises(ValueError):
            build_policy_schedule([genesis(seq=1), genesis(seq=1, cap=2)])

    def test_zero_window_days_is_rejected(self):
        with self.assertRaises(ValueError):
            build_policy_schedule([genesis(window_days=0)])


# ---------------------------------------------------------------------------
# Section 6 -- the compliance test
# ---------------------------------------------------------------------------


class TestCompliance(unittest.TestCase):

    def test_equality_exactly_at_the_cap_passes(self):
        """SPEC.md section 6: the comparison is <=; equality passes."""
        report = verify([rec(0, 1000)], [genesis(cap=1000)])
        day = result_for(report, 0)
        self.assertEqual(day.windowSum, 1000)
        self.assertEqual(day.capInForce, 1000)
        self.assertTrue(day.compliant)

    def test_one_milli_usd_over_the_cap_fails(self):
        """SPEC.md section 6: only a strictly greater sum is a breach."""
        report = verify([rec(0, 1001)], [genesis(cap=1000)])
        self.assertFalse(result_for(report, 0).compliant)
        self.assertEqual(len(report.breaches), 1)

    def test_one_milli_usd_under_the_cap_passes(self):
        report = verify([rec(0, 999)], [genesis(cap=1000)])
        self.assertTrue(result_for(report, 0).compliant)

    def test_export_credit_restores_headroom_that_would_otherwise_breach(self):
        """SPEC.md section 4/8.2: a negative day is real headroom."""
        spends = [rec(0, 400), rec(1, 400), rec(2, 400)]
        breaching = verify(spends, [genesis(cap=1000)])
        self.assertFalse(result_for(breaching, 2).compliant)   # 1200 > 1000

        with_credit = spends + [rec(3, -300)]
        # Day 3's window [0..3] is 900, back under the cap.
        report = verify(with_credit, [genesis(cap=1000)])
        self.assertEqual(result_for(report, 3).windowSum, 900)
        self.assertTrue(result_for(report, 3).compliant)

    def test_a_negative_window_sum_is_compliant_against_a_positive_cap(self):
        report = verify([rec(0, 100), rec(1, -900)], [genesis(cap=1000)])
        self.assertEqual(result_for(report, 1).windowSum, -800)
        self.assertTrue(result_for(report, 1).compliant)

    def test_a_negative_cap_can_be_breached_by_a_less_negative_sum(self):
        # Caps are signed (section 2.2). -100 <= -100 passes, -99 > -100 fails.
        report = verify([rec(0, -100)], [genesis(cap=-100)])
        self.assertTrue(result_for(report, 0).compliant)
        report = verify([rec(0, -99)], [genesis(cap=-100)])
        self.assertFalse(result_for(report, 0).compliant)

    def test_paused_day_counts_as_zero_and_the_window_advances(self):
        records = [rec(0, 900), rec(1, 900, paused=True), rec(2, 50)]
        report = verify(records, [genesis(cap=1000)])
        self.assertEqual(result_for(report, 1).windowSum, 900)
        self.assertTrue(result_for(report, 1).compliant)
        self.assertEqual(result_for(report, 2).windowSum, 950)
        # The inconsistent record (paused but non-zero netSpend) is reported.
        self.assertIn("paused_day_nonzero_netspend",
                      {a.kind for a in report.anomalies})

    def test_missing_day_counts_as_zero(self):
        report = verify([rec(0, 600), rec(4, 300)], [genesis(cap=1000)])
        self.assertEqual(result_for(report, 4).windowSum, 900)
        self.assertTrue(result_for(report, 4).compliant)

    def test_a_raise_applies_at_the_boundary_in_the_compliance_result(self):
        records = [rec(d, 300) for d in range(0, 9)]
        events = [
            genesis(cap=1000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=100000, windowDays=7,
                        effectiveFromDay=3),
        ]
        report = verify(records, events)
        # Day 3: sum 1200 > cap 1000, and the raise is not yet effective.
        self.assertEqual(result_for(report, 3).capInForce, 1000)
        self.assertFalse(result_for(report, 3).compliant)
        # Day 7: the raise has landed.
        self.assertEqual(result_for(report, 7).capInForce, 100000)
        self.assertTrue(result_for(report, 7).compliant)

    def test_lowering_below_the_accumulated_sum_is_not_retroactive(self):
        """SPEC.md section 6.1."""
        records = [rec(d, 300) for d in range(0, 5)]   # 1500 by day 4
        events = [
            genesis(cap=2000, window_days=7, day=0),
            PolicyEvent(seq=2, policyVersion=2, cap=100, windowDays=7,
                        effectiveFromDay=4),
        ]
        report = verify(records, events)
        for day in (0, 1, 2, 3):
            with self.subTest(day=day):
                self.assertTrue(result_for(report, day).compliant,
                                "earlier days must not be convicted "
                                "retroactively")
                self.assertEqual(result_for(report, day).capInForce, 2000)
        self.assertFalse(result_for(report, 4).compliant)
        self.assertEqual(result_for(report, 4).capInForce, 100)

    def test_days_before_any_policy_are_undetermined_not_breaches(self):
        report = verify([rec(0, 99999)], [genesis(cap=1000, day=5)])
        day = result_for(report, 0)
        self.assertIsNone(day.compliant)
        self.assertIsNone(day.capInForce)
        self.assertEqual(report.breaches, [])
        self.assertIn("no_policy_in_force", {a.kind for a in report.anomalies})

    def test_duplicate_day_records_are_rejected(self):
        with self.assertRaises(ValueError):
            verify([rec(0, 1), rec(0, 2)], [genesis()])


# ---------------------------------------------------------------------------
# Section 6.2 -- the bound policy-version cross-check
# ---------------------------------------------------------------------------


class TestPolicyVersionCrossCheck(unittest.TestCase):

    def test_mismatch_is_reported_and_is_not_a_breach(self):
        """SPEC.md section 6.2: a divergence here is a separate, more serious
        category than overspending."""
        events = [
            genesis(cap=1000, window_days=7, day=0, seq=1, version=1),
            PolicyEvent(seq=2, policyVersion=2, cap=50, windowDays=7,
                        effectiveFromDay=2),          # lowering, immediate
        ]
        # Day 2 is governed by version 2 (cap 50) but the record claims it was
        # checked against version 1 (cap 1000).
        report = verify([rec(2, 10, version=1)], events)
        day = result_for(report, 2)
        self.assertTrue(day.policyVersionMismatch)
        self.assertTrue(day.compliant, "10 <= 50 is compliant; the mismatch "
                                       "must not be reported as a breach")
        self.assertEqual(report.breaches, [])
        self.assertEqual(len(report.version_mismatches), 1)

    def test_matching_version_is_not_a_mismatch(self):
        events = [genesis(cap=1000, day=0, seq=1, version=1)]
        report = verify([rec(0, 10, version=1)], events)
        self.assertFalse(result_for(report, 0).policyVersionMismatch)

    def test_check_is_on_the_cap_not_the_version_number(self):
        """Section 6.2 says to compare the two CAPS. Two versions carrying the
        same cap therefore agree (README ambiguity A9)."""
        events = [
            genesis(cap=1000, window_days=7, day=0, seq=1, version=1),
            PolicyEvent(seq=2, policyVersion=2, cap=1000, windowDays=3,
                        effectiveFromDay=2),
        ]
        report = verify([rec(2, 10, version=1)], events)
        self.assertFalse(result_for(report, 2).policyVersionMismatch)

    def test_unknown_policy_version_is_a_mismatch(self):
        report = verify([rec(0, 10, version=99)], [genesis(cap=1000)])
        self.assertTrue(result_for(report, 0).policyVersionMismatch)
        self.assertIn("unknown_policy_version",
                      {a.kind for a in report.anomalies})

    def test_absent_policy_version_column_yields_no_verdict(self):
        report = verify([rec(0, 10)], [genesis(cap=1000)])
        self.assertIsNone(result_for(report, 0).policyVersionMismatch)
        self.assertEqual(report.version_mismatches, [])

    def test_a_breach_and_a_mismatch_are_counted_separately(self):
        events = [
            genesis(cap=1000, window_days=7, day=0, seq=1, version=1),
            PolicyEvent(seq=2, policyVersion=2, cap=50, windowDays=7,
                        effectiveFromDay=2),
        ]
        report = verify([rec(2, 500, version=1)], events)
        self.assertFalse(result_for(report, 2).compliant)      # 500 > 50
        self.assertTrue(result_for(report, 2).policyVersionMismatch)
        self.assertEqual(len(report.breaches), 1)
        self.assertEqual(len(report.version_mismatches), 1)


# ---------------------------------------------------------------------------
# Output shape (section 8.1)
# ---------------------------------------------------------------------------


class TestOutput(unittest.TestCase):

    def test_csv_header_and_row_shape(self):
        report = verify([rec(0, 10, version=1)], [genesis(cap=1000)])
        buf = io.StringIO()
        write_results_csv(report, buf)
        lines = buf.getvalue().strip().split("\n")
        self.assertEqual(
            lines[0],
            "dayIndex,netSpend,windowSum,capInForce,windowDaysInForce,"
            "compliant,policyVersionMismatch",
        )
        self.assertEqual(lines[1], "0,10,10,1000,7,true,false")

    def test_undetermined_days_render_as_NA(self):
        report = verify([rec(0, 10)], [genesis(cap=1000, day=5)])
        buf = io.StringIO()
        write_results_csv(report, buf)
        self.assertEqual(buf.getvalue().strip().split("\n")[1],
                         "0,10,NA,NA,NA,NA,NA")

    def test_results_are_ordered_by_day(self):
        report = verify([rec(3, 1), rec(1, 1), rec(2, 1)], [genesis()])
        self.assertEqual([r.dayIndex for r in report.results], [1, 2, 3])

    def test_report_ok_flag(self):
        self.assertTrue(verify([rec(0, 10, version=1)],
                               [genesis(cap=1000)]).ok)
        self.assertFalse(verify([rec(0, 10000, version=1)],
                                [genesis(cap=1000)]).ok)


if __name__ == "__main__":
    unittest.main(verbosity=2)
