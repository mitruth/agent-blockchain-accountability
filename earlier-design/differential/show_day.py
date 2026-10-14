"""Show one real day end to end: its 48 half-hours, the spend worked out step by
step, and what the chain, the verifier and the simulator each concluded.

Meant for learning the system and for checking a single day by eye. It is a
third, deliberately plain computation of the same arithmetic -- not part of
either implementation.

usage:
    python earlier-design/differential/show_day.py B2 19158
    python earlier-design/differential/show_day.py B0 19200 --all     # print every half-hour, not only active ones
    python earlier-design/differential/show_day.py B2 19349 --scenario B2atCap   # a scenario other than the default cap

Needs earlier-design/differential/data/, which `python earlier-design/differential/run_diff.py` builds.
"""

from __future__ import annotations

import argparse
import csv
import io
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "earlier-design" / "differential" / "data"

UNITS_PER_MILLI_USD = 10**11  # mWh x (1e-8 USD/kWh) = 1e-14 USD; 1 milli-USD = 1e11 of those


def rows(path: Path, day: int) -> list[dict]:
    if not path.exists():
        return []
    with io.open(path, encoding="utf-8", newline="") as fh:
        return [r for r in csv.DictReader(fh) if int(r["dayIndex"]) == day]


def round_half_away(n: int, d: int) -> int:
    q, r = divmod(abs(n), d)
    if 2 * r >= d:
        q += 1
    return q if n >= 0 else -q


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("arm", help="B0, B1 or B2")
    ap.add_argument("day", type=int, help="UTC day index, 18994..19357")
    ap.add_argument("--all", action="store_true", help="show all 48 half-hours")
    ap.add_argument("--scenario", help="differential scenario whose verdicts to show "
                    "(default: the arm itself, capped at 100,000); e.g. B2strict, B2atCap, churn")
    args = ap.parse_args()

    readings = {int(r["slot"]): r for r in rows(DATA / "inputs" / f"{args.arm}.readings.csv", args.day)}
    prices = {int(r["slot"]): r for r in rows(DATA / "inputs" / "prices.csv", args.day)}
    if len(readings) != 48 or len(prices) != 48:
        raise SystemExit(
            f"day {args.day} not found for {args.arm} in earlier-design/differential/data/inputs/ "
            "(valid days are 18994..19357; run `python earlier-design/differential/run_diff.py` first)"
        )

    date = datetime.fromtimestamp(args.day * 86400, tz=timezone.utc).strftime("%Y-%m-%d")
    print(f"\n{args.arm}, day {args.day} = {date} (UTC)\n")
    print(f"{'slot':>4} {'time UTC':>11} {'import Wh':>10} {'export Wh':>10} "
          f"{'buy $/kWh':>10} {'sell $/kWh':>10} {'this half-hour, mUSD':>21}")

    exact = 0
    shown = 0
    for slot in range(48):
        imp = int(readings[slot]["importMWh"])
        exp = int(readings[slot]["exportMWh"])
        pi = int(prices[slot]["importPrice"])
        pe = int(prices[slot]["exportPrice"])
        term = imp * pi - exp * pe
        exact += term
        if args.all or imp or exp:
            start, end = slot * 30, slot * 30 + 30
            window = f"{start // 60:02d}:{start % 60:02d}-{end // 60 % 24:02d}:{end % 60:02d}"
            print(f"{slot:>4} {window:>11} {imp / 1000:>10.3f} {exp / 1000:>10.3f} {pi / 1e8:>10.5f} {pe / 1e8:>10.5f}"
                  f" {term / UNITS_PER_MILLI_USD:>+21.5f}")
            shown += 1
    if not args.all:
        print(f"     ({48 - shown} half-hours with no grid flow hidden; --all shows them)")

    spend = round_half_away(exact, UNITS_PER_MILLI_USD)
    print(f"\nexact total      {exact:,} x 1e-14 USD  =  {exact / UNITS_PER_MILLI_USD:.5f} milli-USD")
    print(f"rounded once     {spend} milli-USD   (half away from zero, on the day total)\n")

    def first(path: Path) -> dict | None:
        found = rows(path, args.day)
        return found[0] if found else None

    sim = first(DATA / "inputs" / f"{args.arm}.simulator.csv")
    scenario = args.scenario or args.arm
    chain = first(DATA / "chain" / f"{scenario}.days.csv")
    verifier = first(DATA / "verify" / scenario / "days.csv")
    print(f"verdicts from scenario: {scenario}")

    print(f"{'':<26} {'spend':>8} {'7-day window':>13} {'cap':>8} {'compliant':>10} {'agent ok next day':>18}")
    print(f"{'this script':<26} {spend:>8}")
    if sim:
        print(f"{'simulator (float)':<26} {float(sim['simulatorEnergyCostMilliUsd']):>8.3f}")
    for label, r in (("chain (Solidity)", chain), ("verifier (Python, blind)", verifier)):
        if r:
            print(f"{label:<26} {r['spendMilliUsd']:>8} {r['windowSum']:>13} {r['capInForce']:>8} "
                  f"{r['compliant']:>10} {r['authorisedNextDay']:>18}")
        else:
            print(f"{label:<26} {'(not found -- run python earlier-design/differential/run_diff.py)':>8}")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
