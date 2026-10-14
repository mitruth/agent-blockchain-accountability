#!/usr/bin/env python3
"""Tests for verify.py (version 2), written against docs/earlier-design/enforcement-rule.md.

pytest is not installed here; the suite is plain unittest and runs under either::

    python -m unittest discover -s verifier -p "test_*.py" -v
    python verifier/test_verify.py

Each test names the spec section it exercises.
"""

from __future__ import annotations

import ast
import csv
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verify as v  # noqa: E402
from verify import (  # noqa: E402
    EXACT_UNITS_PER_MILLI_USD as UNIT,
    PolicyEvent, Price, Reading,
    day_index_from_unix_seconds, exact_day_total, next_window_boundary,
    regime_on, replay_policy, round_exact_to_milli_usd, settle, verify,
    window_sum,
)

# One price unit is 1e-8 USD/kWh, so 1e8 is 1 USD/kWh; 1000 mWh at 1 USD/kWh
# is exactly 1e11 exact units = 1 milli-USD.
ONE_USD_PER_KWH = 100_000_000


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def day_rows(day, spend_milli=0, *, skip_slot=None, both_slot=None):
    """48 readings + 48 prices whose exact total is spend_milli * 1e11."""
    readings, prices = [], []
    for slot in range(48):
        prices.append(Price(day, slot, ONE_USD_PER_KWH, ONE_USD_PER_KWH))
        if slot == skip_slot:       # drop the reading only; prices stay complete
            continue
        imp = exp = 0
        if slot == 0 and spend_milli > 0:
            imp = spend_milli * 1000
        if slot == 0 and spend_milli < 0:
            exp = -spend_milli * 1000
        if slot == both_slot:
            imp, exp = imp or 1, exp or 1
        readings.append(Reading(day, slot, imp, exp))
    return readings, prices


def ledger(spends):
    """{day: spend_milli} -> (readings, prices), every day settled."""
    readings, prices = [], []
    for day, spend in spends.items():
        r, p = day_rows(day, spend)
        readings += r
        prices += p
    return readings, prices


def ev(seq, cap, window=7, submitted=0, effective=None, version=None):
    return PolicyEvent(seq=seq, policyVersion=seq if version is None else version,
                       cap=cap, windowDays=window, submittedOnDay=submitted,
                       effectiveFromDay=submitted if effective is None else effective,
                       setBy="0xowner")


def run(spends, events):
    readings, prices = ledger(spends)
    return verify(readings, prices, events)


def day_of(report, d):
    for r in report.days:
        if r.dayIndex == d:
            return r
    raise AssertionError(f"no result row for day {d}")


def derived(replayed, seq):
    for w in replayed:
        if w.seq == seq:
            return w
    raise AssertionError(f"no write seq {seq}")


def categories(report):
    return [a.category for a in report.anomalies]


# ---------------------------------------------------------------------------
# Section 5 -- rounding and daily spend
# ---------------------------------------------------------------------------


class TestRounding(unittest.TestCase):

    def test_spec_table_both_signs(self):
        table = [
            (250_000_000_000, 3), (-250_000_000_000, -3),
            (150_000_000_000, 2), (-150_000_000_000, -2),
            (249_999_999_999, 2), (-249_999_999_999, -2),
            (50_000_000_000, 1), (-50_000_000_000, -1),
            (49_999_999_999, 0), (-49_999_999_999, 0),
        ]
        for exact, expected in table:
            with self.subTest(exact=exact):
                self.assertEqual(round_exact_to_milli_usd(exact), expected)

    def test_half_cases_are_not_bankers_or_truncation(self):
        # 2.5 -> 3 (banker's gives 2, truncation gives 2);
        # -2.5 -> -3 (truncation toward zero gives -2); 3.5 -> 4 both ways.
        self.assertEqual(round_exact_to_milli_usd(25 * UNIT // 10), 3)
        self.assertEqual(round_exact_to_milli_usd(-25 * UNIT // 10), -3)
        self.assertEqual(round_exact_to_milli_usd(45 * UNIT // 10), 5)
        self.assertEqual(round_exact_to_milli_usd(-45 * UNIT // 10), -5)
        self.assertEqual(round_exact_to_milli_usd(0), 0)
        self.assertEqual(round_exact_to_milli_usd(7 * UNIT), 7)
        self.assertEqual(round_exact_to_milli_usd(-7 * UNIT), -7)

    def test_rejects_non_int(self):
        with self.assertRaises(TypeError):
            round_exact_to_milli_usd(2.5)
        with self.assertRaises(TypeError):
            round_exact_to_milli_usd(True)

    def test_exact_half_reached_through_a_real_day_both_signs(self):
        # 250_000 mWh at 1 USD/kWh = 250 milli... use price 1e6 to get 2.5
        r = [Reading(0, s, 250_000 if s == 0 else 0, 0) for s in range(48)]
        p = [Price(0, s, 1_000_000, 0) for s in range(48)]
        spends, _ = settle(r, p)
        self.assertEqual(spends, {0: 3})
        r = [Reading(0, s, 0, 250_000 if s == 0 else 0) for s in range(48)]
        p = [Price(0, s, 0, 1_000_000) for s in range(48)]
        spends, _ = settle(r, p)
        self.assertEqual(spends, {0: -3})

    def test_round_once_per_day_not_per_half_hour(self):
        # Each half-hour is exactly 0.4 milli-USD: per-half-hour rounding gives
        # 48 * 0 = 0; rounding the day's exact total gives round(19.2) = 19.
        r = [Reading(0, s, 40_000, 0) for s in range(48)]
        p = [Price(0, s, 1_000_000, 0) for s in range(48)]
        per_half_hour = sum(round_exact_to_milli_usd(x.importMWh * y.importPrice)
                            for x, y in zip(r, p))
        self.assertEqual(per_half_hour, 0)
        spends, _ = settle(r, p)
        self.assertEqual(spends, {0: 19})

    def test_round_once_per_day_half_case(self):
        # Each half-hour exactly 0.5 -> per-half-hour gives 48, daily gives 24.
        r = [Reading(0, s, 50_000, 0) for s in range(48)]
        p = [Price(0, s, 1_000_000, 0) for s in range(48)]
        spends, _ = settle(r, p)
        self.assertEqual(spends, {0: 24})

    def test_negative_price(self):
        # Importing at a negative price earns money; exporting at a negative
        # price costs money.
        r = [Reading(0, s, 3000 if s == 0 else 0, 2000 if s == 1 else 0)
             for s in range(48)]
        p = [Price(0, s, -ONE_USD_PER_KWH, -ONE_USD_PER_KWH) for s in range(48)]
        self.assertEqual(exact_day_total(zip(r, p)), (-3 + 2) * UNIT)
        spends, anomalies = settle(r, p)
        self.assertEqual(spends, {0: -1})
        self.assertEqual(anomalies, [])

    def test_negative_day_contributes_negatively(self):
        report = run({0: 500, 1: -800, 2: 100}, [ev(1, 10_000)])
        self.assertEqual(report.spends[1], -800)
        self.assertEqual(day_of(report, 1).spendMilliUsd, -800)
        self.assertEqual(day_of(report, 1).windowSum, -300)
        self.assertEqual(day_of(report, 2).windowSum, -200)

    def test_sum_can_be_negative_and_negative_cap_compared_with_le(self):
        report = run({0: -100}, [ev(1, -100)])
        self.assertTrue(day_of(report, 0).compliant)
        report = run({0: -99}, [ev(1, -100)])
        self.assertFalse(day_of(report, 0).compliant)


# ---------------------------------------------------------------------------
# Section 4 -- settlement
# ---------------------------------------------------------------------------


class TestSettlement(unittest.TestCase):

    def test_missing_slot_not_settled(self):
        r, p = day_rows(5, 100, skip_slot=17)
        spends, anomalies = settle(r, p)
        self.assertNotIn(5, spends)
        self.assertEqual([a.category for a in anomalies], ["incomplete_day"])

    def test_missing_price_slot_not_settled(self):
        r, p = day_rows(5, 100)
        p = [x for x in p if x.slot != 47]
        spends, anomalies = settle(r, p)
        self.assertNotIn(5, spends)
        self.assertEqual([a.category for a in anomalies], ["incomplete_day"])

    def test_readings_without_any_prices_is_incomplete(self):
        r, _ = day_rows(5, 100)
        spends, anomalies = settle(r, [])
        self.assertEqual(spends, {})
        self.assertEqual([a.category for a in anomalies], ["incomplete_day"])

    def test_import_and_export_in_same_half_hour_not_settled(self):
        r, p = day_rows(5, 100, both_slot=0)
        spends, anomalies = settle(r, p)
        self.assertNotIn(5, spends)
        self.assertEqual([a.category for a in anomalies], ["invalid_half_hour"])

    def test_duplicate_slot_not_settled(self):
        r, p = day_rows(5, 100)
        r.append(Reading(5, 3, 0, 0))
        spends, anomalies = settle(r, p)
        self.assertNotIn(5, spends)
        self.assertEqual([a.category for a in anomalies], ["duplicate_slot"])

    def test_gap_reported(self):
        r1, p1 = day_rows(1, 10)
        r4, p4 = day_rows(4, 10)
        spends, anomalies = settle(r1 + r4, p1 + p4)
        self.assertEqual(sorted(spends), [1, 4])
        self.assertEqual([(a.category, a.dayIndex) for a in anomalies], [("gap", 2)])

    def test_unsettled_day_between_settled_days_is_also_a_gap(self):
        r1, p1 = day_rows(1, 10)
        r2, p2 = day_rows(2, 10, skip_slot=0)
        r3, p3 = day_rows(3, 10)
        _, anomalies = settle(r1 + r2 + r3, p1 + p2 + p3)
        self.assertEqual(sorted(a.category for a in anomalies), ["gap", "incomplete_day"])

    def test_zero_import_and_zero_export_is_valid(self):
        spends, anomalies = settle(*day_rows(0, 0))
        self.assertEqual((spends, anomalies), ({0: 0}, []))

    def test_day_index(self):
        self.assertEqual(day_index_from_unix_seconds(0), 0)
        self.assertEqual(day_index_from_unix_seconds(86399), 0)
        self.assertEqual(day_index_from_unix_seconds(86400), 1)
        self.assertEqual(day_index_from_unix_seconds(-1), -1)


# ---------------------------------------------------------------------------
# Sections 6, 8 -- window sum and compliance
# ---------------------------------------------------------------------------


class TestWindowAndCompliance(unittest.TestCase):

    def test_equality_at_cap_passes_one_over_fails(self):
        self.assertTrue(day_of(run({0: 600, 1: 400}, [ev(1, 1000)]), 1).compliant)
        self.assertFalse(day_of(run({0: 600, 1: 401}, [ev(1, 1000)]), 1).compliant)

    def test_oldest_day_included_and_leaves_one_day_later(self):
        spends = {d: 0 for d in range(0, 10)}
        spends[0] = 1000
        report = run(spends, [ev(1, 5000, window=7)])
        self.assertEqual(day_of(report, 6).windowSum, 1000)   # [0, 6]
        self.assertEqual(day_of(report, 7).windowSum, 0)      # [1, 7]

    def test_gap_day_contributes_zero(self):
        report = run({0: 100, 1: 200, 3: 300}, [ev(1, 5000)])
        self.assertEqual(day_of(report, 3).windowSum, 600)
        self.assertNotIn(2, [r.dayIndex for r in report.days])
        self.assertIn("gap", categories(report))

    def test_unsettled_day_contributes_zero_even_with_readings(self):
        r0, p0 = day_rows(0, 100)
        r1, p1 = day_rows(1, 5000, both_slot=5)
        r2, p2 = day_rows(2, 100)
        report = verify(r0 + r1 + r2, p0 + p1 + p2, [ev(1, 1000)])
        self.assertEqual(day_of(report, 2).windowSum, 200)

    def test_window_sum_is_order_independent_and_isolated(self):
        spends = {d: (d * 37) % 101 - 50 for d in range(0, 40)}
        forward = [window_sum(spends, d, 7) for d in range(0, 40)]
        backward = [window_sum(spends, d, 7) for d in reversed(range(0, 40))]
        self.assertEqual(forward, list(reversed(backward)))
        shuffled = dict(sorted(spends.items(), key=lambda kv: -kv[0]))
        self.assertEqual(window_sum(shuffled, 25, 7), forward[25])
        brute = sum(spends[d] for d in range(19, 26))
        self.assertEqual(window_sum(spends, 25, 7), brute)

    def test_window_length_change_recomputes_from_scratch(self):
        # Window 7 until day 14, then a window-only write to 3 (unchanged cap).
        spends = {d: 10 for d in range(0, 20)}
        report = run(spends, [ev(1, 1000, window=7, submitted=0),
                              ev(2, 1000, window=3, submitted=14)])
        self.assertEqual(day_of(report, 13).windowSum, 70)
        self.assertEqual(day_of(report, 14).windowSum, 30)
        self.assertEqual(day_of(report, 14).windowDaysInForce, 3)

    def test_lowering_is_not_retroactive(self):
        spends = {d: 100 for d in range(0, 6)}
        report = run(spends, [ev(1, 1000), ev(2, 250, submitted=4)])
        self.assertTrue(day_of(report, 3).compliant)       # 400 <= 1000
        self.assertEqual(day_of(report, 3).capInForce, 1000)
        self.assertFalse(day_of(report, 4).compliant)      # 500 > 250

    def test_settled_day_before_any_regime_is_undetermined(self):
        report = run({0: 5, 1: 5, 2: 5}, [ev(1, 1000, submitted=2, effective=2)])
        r0 = day_of(report, 0)
        self.assertEqual((r0.spendMilliUsd, r0.windowSum, r0.capInForce,
                          r0.compliant, r0.authorisedNextDay), (5, None, None, None, None))
        self.assertEqual(categories(report).count("no_regime"), 2)
        # The pre-regime days still count in later windows.
        self.assertEqual(day_of(report, 2).windowSum, 15)
        # Day 1 has no regime; day 2 does. windowSum(1) has no window length,
        # so authorisation on day 2 is undetermined as well.
        self.assertIsNone(day_of(report, 1).authorisedNextDay)

    def test_no_float_decimal_or_round_in_verifier_source(self):
        with open(os.path.join(HERE, "verify.py"), encoding="utf-8") as h:
            tree = ast.parse(h.read())
        names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
        attrs = {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
        imports = {a.name for n in ast.walk(tree)
                   if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names}
        modules = {n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
        floats = [n for n in ast.walk(tree)
                  if isinstance(n, ast.Constant) and isinstance(n.value, float)]
        self.assertNotIn("float", names)
        self.assertNotIn("round", names)
        self.assertNotIn("Decimal", names | imports)
        self.assertNotIn("decimal", modules | imports)
        self.assertNotIn("quantize", attrs)
        self.assertEqual(floats, [])
        divisions = [n for n in ast.walk(tree)
                     if isinstance(n, (ast.BinOp, ast.AugAssign)) and isinstance(n.op, ast.Div)]
        self.assertEqual(divisions, [])


# ---------------------------------------------------------------------------
# Section 7 -- policy replay
# ---------------------------------------------------------------------------


class TestPolicyReplay(unittest.TestCase):

    def test_boundary_arithmetic(self):
        self.assertEqual(next_window_boundary(4, 7), 7)
        self.assertEqual(next_window_boundary(7, 7), 14)
        self.assertEqual(next_window_boundary(0, 7), 7)
        self.assertEqual(next_window_boundary(-1, 7), 0)
        self.assertEqual(next_window_boundary(-7, 7), 0)
        self.assertEqual(next_window_boundary(5, 1), 6)

    def test_genesis_uses_recorded_effective_day(self):
        replayed, anomalies = replay_policy([ev(1, 1000, submitted=10, effective=3)])
        self.assertEqual(replayed[0].derivedEffectiveFromDay, 3)
        self.assertTrue(replayed[0].deferralOk)
        self.assertEqual(anomalies, [])

    def test_raise_takes_effect_at_next_boundary_of_incumbent_window(self):
        # Incumbent window 10; the raise introduces window 3. Submitted day 4:
        # boundary under 10 is day 10 (under 3 it would be day 6).
        events = [ev(1, 1000, window=10, submitted=0),
                  ev(2, 2000, window=3, submitted=4, effective=10)]
        replayed, anomalies = replay_policy(events)
        self.assertEqual(derived(replayed, 2).derivedEffectiveFromDay, 10)
        self.assertEqual(derived(replayed, 2).classification, "raise")
        self.assertEqual(anomalies, [])
        self.assertEqual(regime_on(replayed, 9).seq, 1)
        self.assertEqual(regime_on(replayed, 10).seq, 2)
        spends = {d: 0 for d in range(0, 12)}
        report = run(spends, events)
        self.assertEqual(day_of(report, 9).capInForce, 1000)
        self.assertEqual(day_of(report, 10).capInForce, 2000)
        self.assertEqual(day_of(report, 10).windowDaysInForce, 3)

    def test_raise_submitted_on_boundary_defers_a_full_window(self):
        replayed, _ = replay_policy([ev(1, 1000, window=7, submitted=0),
                                     ev(2, 2000, window=7, submitted=14, effective=21)])
        self.assertEqual(derived(replayed, 2).derivedEffectiveFromDay, 21)
        self.assertEqual(regime_on(replayed, 20).seq, 1)

    def test_lowering_immediate_and_cancels_pending_raise(self):
        events = [ev(1, 1000, window=7, submitted=0),
                  ev(2, 5000, window=7, submitted=2, effective=7),   # pending raise
                  ev(3, 800, window=7, submitted=4, effective=4)]    # lowering
        replayed, anomalies = replay_policy(events)
        self.assertEqual(anomalies, [])
        self.assertEqual(derived(replayed, 3).derivedEffectiveFromDay, 4)
        self.assertEqual(derived(replayed, 2).cancelledBySeq, 3)
        self.assertEqual(regime_on(replayed, 3).seq, 1)
        for d in (4, 7, 30):
            self.assertEqual(regime_on(replayed, d).cap, 800)

    def test_lowering_does_not_cancel_write_effective_on_its_own_day(self):
        events = [ev(1, 1000, window=7, submitted=0),
                  ev(2, 5000, window=7, submitted=3, effective=7),
                  ev(3, 900, window=7, submitted=7, effective=7)]
        replayed, _ = replay_policy(events)
        self.assertIsNone(derived(replayed, 2).cancelledBySeq)
        self.assertEqual(derived(replayed, 3).classification, "not_raise")  # vs 5000
        self.assertEqual(regime_on(replayed, 7).seq, 3)

    def test_unchanged_cap_takes_effect_immediately(self):
        events = [ev(1, 1000, window=7, submitted=0),
                  ev(2, 1000, window=14, submitted=3, effective=3)]
        replayed, anomalies = replay_policy(events)
        self.assertEqual(anomalies, [])
        self.assertEqual(derived(replayed, 2).derivedEffectiveFromDay, 3)
        self.assertEqual(derived(replayed, 2).classification, "not_raise")
        self.assertEqual(regime_on(replayed, 3).windowDays, 14)

    def test_unchanged_cap_also_cancels_pending_raise(self):
        events = [ev(1, 1000, submitted=0),
                  ev(2, 5000, submitted=1, effective=7),
                  ev(3, 1000, window=5, submitted=2)]
        replayed, _ = replay_policy(events)
        self.assertEqual(derived(replayed, 2).cancelledBySeq, 3)
        self.assertEqual(regime_on(replayed, 7).seq, 3)

    def test_same_effective_day_higher_seq_wins(self):
        events = [ev(1, 1000, submitted=0),
                  ev(2, 3000, submitted=1, effective=7),
                  ev(3, 2000, submitted=2, effective=7)]    # also a raise vs 1000
        replayed, anomalies = replay_policy(events)
        self.assertEqual(anomalies, [])
        self.assertEqual(derived(replayed, 2).derivedEffectiveFromDay, 7)
        self.assertEqual(derived(replayed, 3).derivedEffectiveFromDay, 7)
        self.assertEqual(regime_on(replayed, 7).seq, 3)
        report = run({7: 0}, events)
        self.assertEqual(day_of(report, 7).capInForce, 2000)
        self.assertEqual(day_of(report, 7).policyVersionInForce, 3)

    def test_same_day_lowering_then_raise_classified_against_the_lowering(self):
        events = [ev(1, 1000, submitted=0),
                  ev(2, 600, submitted=3),
                  ev(3, 900, submitted=3, effective=7)]
        replayed, anomalies = replay_policy(events)
        self.assertEqual(anomalies, [])
        self.assertEqual(derived(replayed, 3).classification, "raise")
        self.assertEqual(regime_on(replayed, 3).cap, 600)
        self.assertEqual(regime_on(replayed, 7).cap, 900)

    def test_raise_compared_to_regime_in_force_not_to_pending(self):
        # 1000 in force; 2000 pending at 7; on day 4 write 1500. 1500 > 1000,
        # so it is a raise: deferred to 7, cancels nothing, and wins day 7 on seq.
        events = [ev(1, 1000), ev(2, 2000, submitted=2, effective=7),
                  ev(3, 1500, submitted=4, effective=7)]
        replayed, _ = replay_policy(events)
        self.assertIsNone(derived(replayed, 2).cancelledBySeq)
        self.assertEqual(regime_on(replayed, 4).cap, 1000)
        self.assertEqual(regime_on(replayed, 7).cap, 1500)

    def test_deferral_mismatch_reported_not_a_breach_and_derived_day_used(self):
        # The chain applied a raise immediately on day 3; the rule defers to 7.
        events = [ev(1, 100, submitted=0), ev(2, 10_000, submitted=3, effective=3)]
        spends = {d: 60 for d in range(0, 8)}
        report = run(spends, events)
        self.assertEqual(categories(report), ["deferral_mismatch"])
        row = [p for p in report.policy if p.seq == 2][0]
        self.assertEqual((row.derivedEffectiveFromDay, row.emittedEffectiveFromDay,
                          row.deferralOk), (7, 3, False))
        # Derived day used: days 3..6 are judged against 100 and breach.
        self.assertEqual(day_of(report, 3).capInForce, 100)
        self.assertFalse(day_of(report, 3).compliant)
        self.assertEqual(day_of(report, 7).capInForce, 10_000)
        # Breaches are verdicts in the day rows, never deferral anomalies, and
        # the mismatch never appears as a day verdict.
        self.assertNotIn("breach", " ".join(categories(report)))
        genesis_row = [p for p in report.policy if p.seq == 1][0]
        self.assertTrue(genesis_row.deferralOk)

    def test_lowering_recorded_late_is_a_mismatch(self):
        events = [ev(1, 1000), ev(2, 500, submitted=3, effective=7)]
        replayed, anomalies = replay_policy(events)
        self.assertEqual(derived(replayed, 2).derivedEffectiveFromDay, 3)
        self.assertEqual([a.category for a in anomalies], ["deferral_mismatch"])

    def test_cancelled_write_still_deferral_checked(self):
        events = [ev(1, 1000), ev(2, 5000, submitted=1, effective=1),
                  ev(3, 500, submitted=2)]
        replayed, anomalies = replay_policy(events)
        self.assertEqual(derived(replayed, 2).cancelledBySeq, 3)
        self.assertEqual([(a.category, a.seq) for a in anomalies],
                         [("deferral_mismatch", 2)])

    def test_later_write_with_no_incumbent_is_flagged(self):
        events = [ev(1, 1000, submitted=0, effective=100),
                  ev(2, 2000, submitted=50, effective=50)]
        replayed, anomalies = replay_policy(events)
        self.assertEqual([a.category for a in anomalies], ["no_incumbent_regime"])
        self.assertEqual(derived(replayed, 2).derivedEffectiveFromDay, 50)
        self.assertEqual(derived(replayed, 1).cancelledBySeq, 2)

    def test_out_of_order_submission_flagged(self):
        events = [ev(1, 1000, submitted=0), ev(2, 900, submitted=10),
                  ev(3, 800, submitted=5)]
        _, anomalies = replay_policy(events)
        self.assertEqual([a.category for a in anomalies], ["policy_out_of_order"])

    def test_events_sorted_by_seq_and_duplicate_seq_rejected(self):
        replayed, _ = replay_policy([ev(2, 500, submitted=3), ev(1, 1000)])
        self.assertEqual(replayed[0].classification, "genesis")
        self.assertEqual(replayed[0].seq, 1)
        with self.assertRaises(ValueError):
            replay_policy([ev(1, 1000), ev(1, 500)])


# ---------------------------------------------------------------------------
# Section 9 -- authorisation on the next day
# ---------------------------------------------------------------------------


class TestAuthorisation(unittest.TestCase):

    def test_uses_cap_in_force_on_next_day(self):
        spends = {d: 100 for d in range(0, 6)}
        events = [ev(1, 1000), ev(2, 300, submitted=4)]  # lowering effective day 4
        report = run(spends, events)
        r3 = day_of(report, 3)                           # windowSum 400
        self.assertEqual(r3.windowSum, 400)
        self.assertTrue(r3.compliant)                    # 400 <= 1000 on day 3
        self.assertFalse(r3.authorisedNextDay)           # 400 > 300 on day 4
        self.assertTrue(day_of(report, 2).authorisedNextDay)

    def test_raise_on_next_day_grants_authority(self):
        spends = {d: 100 for d in range(0, 8)}
        events = [ev(1, 600), ev(2, 5000, submitted=3, effective=7)]
        report = run(spends, events)
        r6 = day_of(report, 6)                           # windowSum 700
        self.assertFalse(r6.compliant)
        self.assertTrue(r6.authorisedNextDay)

    def test_next_day_equality_passes(self):
        report = run({0: 300}, [ev(1, 1000), ev(2, 300, submitted=1)])
        self.assertTrue(day_of(report, 0).authorisedNextDay)
        report = run({0: 301}, [ev(1, 1000), ev(2, 300, submitted=1)])
        self.assertFalse(day_of(report, 0).authorisedNextDay)

    def test_window_for_authorisation_is_day_d_window(self):
        # Window 7 on day d, window 1 from d+1 (unchanged cap). windowSum(d)
        # must still use 7.
        spends = {d: 100 for d in range(0, 7)}
        report = run(spends, [ev(1, 650, window=7), ev(2, 650, window=1, submitted=7)])
        self.assertEqual(day_of(report, 6).windowSum, 700)
        self.assertFalse(day_of(report, 6).authorisedNextDay)


# ---------------------------------------------------------------------------
# Section 10.1 -- CLI and file formats
# ---------------------------------------------------------------------------


def _write_csv(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as h:
        w = csv.writer(h)
        w.writerow(header)
        w.writerows(rows)


class TestCli(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        readings, prices = ledger({0: 400, 1: 700, 2: -150})
        self.readings = os.path.join(self.dir, "r.csv")
        self.prices = os.path.join(self.dir, "p.csv")
        _write_csv(self.readings, ["dayIndex", "slot", "importMWh", "exportMWh"],
                   [(x.dayIndex, x.slot, x.importMWh, x.exportMWh) for x in readings])
        _write_csv(self.prices, ["dayIndex", "slot", "importPrice", "exportPrice"],
                   [(x.dayIndex, x.slot, x.importPrice, x.exportPrice) for x in prices])

    def tearDown(self):
        self.tmp.cleanup()

    def _policy(self, rows):
        path = os.path.join(self.dir, "e.csv")
        _write_csv(path, ["seq", "policyVersion", "cap", "windowDays",
                          "submittedOnDay", "effectiveFromDay", "setBy"], rows)
        return path

    def _run(self, policy_rows):
        out = os.path.join(self.dir, "days.csv")
        pol = os.path.join(self.dir, "policy.csv")
        summ = os.path.join(self.dir, "summary.json")
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            code = v.main(["--readings", self.readings, "--prices", self.prices,
                           "--policy", self._policy(policy_rows), "--out", out,
                           "--policy-report", pol, "--summary-json", summ])
        finally:
            sys.stderr = old
        with open(out, encoding="utf-8") as h:
            days = h.read().splitlines()
        with open(pol, encoding="utf-8") as h:
            policy = h.read().splitlines()
        with open(summ, encoding="utf-8") as h:
            summary = json.load(h)
        return code, days, policy, summary, err.getvalue()

    def test_clean_run_columns_and_exit_zero(self):
        code, days, policy, summary, err = self._run([(1, 1, 1000, 7, 0, 0, "0xa")])
        self.assertEqual(code, 0)
        self.assertEqual(days[0], "dayIndex,spendMilliUsd,windowSum,capInForce,"
                                  "windowDaysInForce,policyVersionInForce,compliant,"
                                  "authorisedNextDay")
        self.assertEqual(days[1:], ["0,400,400,1000,7,1,true,true",
                                    "1,700,1100,1000,7,1,false,false",
                                    "2,-150,950,1000,7,1,true,true"])
        self.assertEqual(policy, ["seq,policyVersion,submittedOnDay,"
                                  "derivedEffectiveFromDay,emittedEffectiveFromDay,"
                                  "deferralOk", "1,1,0,0,0,true"])
        self.assertEqual(summary["settledDays"], 3)
        self.assertEqual(summary["totalSpendMilliUsd"], 950)
        self.assertEqual(summary["breaches"], [1])
        self.assertEqual(summary["anomalyCount"], 0)

    def test_anomalies_exit_nonzero_and_go_to_stderr(self):
        code, days, policy, summary, err = self._run(
            [(1, 1, 1000, 7, 1, 1, "0xa"), (2, 2, 5000, 7, 2, 2, "0xa")])
        self.assertEqual(code, 1)
        self.assertIn("0,400,NA,NA,NA,NA,NA,NA", days)
        self.assertIn("[no_regime]", err)
        self.assertIn("[deferral_mismatch]", err)
        self.assertEqual(policy[2], "2,2,2,7,2,false")
        self.assertEqual(summary["anomaliesByCategory"],
                         {"deferral_mismatch": 1, "no_regime": 1})

    def test_bad_input_exit_two(self):
        code = v.main(["--readings", self.readings, "--prices", self.prices,
                       "--policy", self._policy([(1, 1, "1000.5", 7, 0, 0, "")]),
                       "--out", os.path.join(self.dir, "x.csv")])
        self.assertEqual(code, 2)

    def test_parse_int_is_strict(self):
        for bad in ["1.0", "1e3", "", " ", "٣", "0x10"]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                v.parse_int(bad, "x")
        self.assertEqual(v.parse_int(" -42 ", "x"), -42)
        self.assertEqual(v.parse_int("+7", "x"), 7)

    def test_fixture_policies_parse(self):
        fixtures = os.path.join(HERE, "fixtures")
        for name in sorted(os.listdir(fixtures)):
            if name.startswith("policy_") and name.endswith(".csv"):
                with self.subTest(name=name):
                    self.assertTrue(v.read_policy_csv(os.path.join(fixtures, name)))


if __name__ == "__main__":
    unittest.main()
