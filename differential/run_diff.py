"""Step 3: run both implementations against the same records, report the
disagreement set.

The on-chain side is test/Differential.t.sol, which replays scenarios into the
real contracts and prints its verdict as CSV. The off-chain side is
verifier/verify.py, written from docs/spec/enforcement-rule.md by an author who never saw
the Solidity.

Disagreements are the output of this script. A clean run is a weaker result
than it looks: it is at least as likely to mean the two sides share an
assumption as that both are right. Read the ambiguity list in
docs/verifier/implementation-notes.md alongside whatever this prints.

Usage:
    python differential/run_diff.py            # runs hardhat, then compares
    python differential/run_diff.py --from-file out.txt
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "differential" / "data"
VERIFIER = ROOT / "verifier" / "verify.py"

DAY_COLS = [
    "scenario", "dayIndex", "netSpend", "windowSum",
    "capInForce", "windowDaysInForce", "compliant", "policyVersion", "paused",
]
POLICY_COLS = [
    "scenario", "seq", "policyVersion", "cap",
    "windowDays", "effectiveFromDay", "setBy",
]


def run_hardhat() -> str:
    print("running hardhat solidity tests to capture the on-chain verdict ...")
    proc = subprocess.run(
        ["npx", "hardhat", "test", "solidity"],
        cwd=ROOT, capture_output=True, text=True, shell=(os.name == "nt"),
    )
    if "DAY," not in proc.stdout:
        sys.stderr.write(proc.stdout[-4000:] + "\n" + proc.stderr[-4000:] + "\n")
        raise SystemExit("hardhat produced no DAY rows; see output above")
    return proc.stdout


def parse(text: str):
    days, policies = [], []
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("DAY,"):
            days.append(dict(zip(DAY_COLS, line[4:].split(","))))
        elif line.startswith("POLICY,"):
            policies.append(dict(zip(POLICY_COLS, line[7:].split(","))))
    return days, policies


def write_scenario_inputs(scenario: str, days, policies) -> tuple[Path, Path]:
    d = DATA / scenario
    d.mkdir(parents=True, exist_ok=True)

    rec_path = d / "records.csv"
    with io.open(rec_path, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["dayIndex", "netSpend", "policyVersion", "paused"])
        for row in days:
            w.writerow([
                row["dayIndex"], row["netSpend"], row["policyVersion"],
                "true" if row["paused"] == "1" else "false",
            ])

    pol_path = d / "policy.csv"
    with io.open(pol_path, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["seq", "policyVersion", "cap", "windowDays", "effectiveFromDay", "setBy"])
        for row in policies:
            w.writerow([
                row["seq"], row["policyVersion"], row["cap"],
                row["windowDays"], row["effectiveFromDay"], row["setBy"],
            ])
    return rec_path, pol_path


def run_verifier(scenario: str, rec_path: Path, pol_path: Path):
    out_path = DATA / scenario / "verifier_results.csv"
    proc = subprocess.run(
        [sys.executable, str(VERIFIER),
         "--records", str(rec_path), "--policy", str(pol_path),
         "--out", str(out_path), "--quiet"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if not out_path.exists():
        sys.stderr.write(proc.stdout + "\n" + proc.stderr + "\n")
        raise SystemExit(f"verifier produced no output for scenario {scenario}")
    with io.open(out_path, encoding="utf-8") as fh:
        return {int(r["dayIndex"]): r for r in csv.DictReader(fh)}, proc.stderr


def norm_bool(v: str) -> str:
    return str(v).strip().lower() in ("1", "true", "yes")


def compare(scenario: str, chain_days, verifier_rows):
    """Compare the two verdicts day by day. Returns a list of disagreements."""
    out = []
    for row in chain_days:
        day = int(row["dayIndex"])
        v = verifier_rows.get(day)
        if v is None:
            out.append((day, "missing", "row present", "no row from verifier"))
            continue

        checks = [
            ("windowSum", row["windowSum"], v.get("windowSum")),
            ("capInForce", row["capInForce"], v.get("capInForce")),
            ("windowDaysInForce", row["windowDaysInForce"], v.get("windowDaysInForce")),
        ]
        for name, a, b in checks:
            if b in (None, "", "NA"):
                out.append((day, name, a, f"verifier: {b!r}"))
                continue
            if int(a) != int(b):
                out.append((day, name, a, b))

        a_ok = norm_bool(row["compliant"])
        b_raw = v.get("compliant")
        if b_raw in (None, "", "NA"):
            out.append((day, "compliant", a_ok, f"verifier: {b_raw!r}"))
        elif a_ok != norm_bool(b_raw):
            out.append((day, "compliant", a_ok, norm_bool(b_raw)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-file", help="parse a saved hardhat output file instead of re-running")
    args = ap.parse_args()

    text = io.open(args.from_file, encoding="utf-8", errors="replace").read() \
        if args.from_file else run_hardhat()

    days, policies = parse(text)
    scenarios = sorted({r["scenario"] for r in days})
    if not scenarios:
        raise SystemExit("no scenarios found in the on-chain output")

    print(f"\nscenarios: {', '.join(scenarios)}\n")
    print(f"{'scenario':<12} {'days':>6} {'policy':>7} {'breaches(chain)':>16} "
          f"{'disagreements':>14}")
    print("-" * 62)

    total_disagreements = 0
    details = []

    for scenario in scenarios:
        s_days = [r for r in days if r["scenario"] == scenario]
        s_pol = [r for r in policies if r["scenario"] == scenario]
        s_days.sort(key=lambda r: int(r["dayIndex"]))
        s_pol.sort(key=lambda r: int(r["seq"]))

        rec_path, pol_path = write_scenario_inputs(scenario, s_days, s_pol)
        v_rows, _ = run_verifier(scenario, rec_path, pol_path)
        diffs = compare(scenario, s_days, v_rows)

        breaches = sum(1 for r in s_days if not norm_bool(r["compliant"]))
        print(f"{scenario:<12} {len(s_days):>6} {len(s_pol):>7} {breaches:>16} {len(diffs):>14}")

        total_disagreements += len(diffs)
        if diffs:
            details.append((scenario, diffs))

    print("-" * 62)
    print(f"total disagreements: {total_disagreements}\n")

    for scenario, diffs in details:
        print(f"=== {scenario}: {len(diffs)} disagreements ===")
        print(f"{'day':>8} {'field':<20} {'chain':>14} {'verifier':>14}")
        for day, field, a, b in diffs[:40]:
            print(f"{day:>8} {field:<20} {str(a):>14} {str(b):>14}")
        if len(diffs) > 40:
            print(f"  ... and {len(diffs) - 40} more")
        print()

    return 1 if total_disagreements else 0


if __name__ == "__main__":
    raise SystemExit(main())
