"""Run both implementations on the same real days and report where they disagree.

Chain side: test/Differential.t.sol replays each scenario through the real
contracts -- oracle publication, meter signature, on-chain settlement -- and
writes its verdict to differential/data/chain/.

Verifier side: verifier/verify.py, written from docs/spec/enforcement-rule.md
by an author who never saw the Solidity, is given the same readings, prices
and captured policy events.

Compared, per settled day: spend, window sum, cap and window length in force,
the policy version the chain bound against the version the verifier finds in
force, compliance, and authorisation on the next day. Per policy write: whether
the chain's effective day matches the day the rule derives.

Disagreements are the output. A clean run is a weaker result than it looks: it
is at least as likely to mean the two sides share an assumption as that both
are right. Read docs/verifier/implementation-notes.md alongside it.

usage:
    python differential/run_diff.py                # build inputs if missing, run chain, compare
    python differential/run_diff.py --skip-chain   # reuse differential/data/chain/
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
INPUTS = DATA / "inputs"
CHAIN = DATA / "chain"
VERIFY = DATA / "verify"
VERIFIER = ROOT / "verifier" / "verify.py"
BUILDER = ROOT / "differential" / "build_settlement_inputs.py"

DAY_FIELDS = [
    # (chain column, verifier column)
    ("spendMilliUsd", "spendMilliUsd"),
    ("windowSum", "windowSum"),
    ("capInForce", "capInForce"),
    ("windowDaysInForce", "windowDaysInForce"),
    ("policyVersion", "policyVersionInForce"),
    ("compliant", "compliant"),
    ("authorisedNextDay", "authorisedNextDay"),
]


def read_csv(path: Path) -> list[dict]:
    with io.open(path, encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def write_csv(path: Path, header: list[str], rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with io.open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)


def norm(value: str) -> str:
    v = str(value).strip()
    return v.lower() if v.lower() in ("true", "false", "na") else v


# ----------------------------------------------------------------------------
# Stages
# ----------------------------------------------------------------------------

def ensure_inputs() -> None:
    if (INPUTS / "prices.csv").exists():
        return
    print("building settlement inputs from the HEMS step logs ...")
    proc = subprocess.run([sys.executable, str(BUILDER)], cwd=ROOT)
    if proc.returncode != 0:
        raise SystemExit("input build failed")


def run_chain() -> None:
    CHAIN.mkdir(parents=True, exist_ok=True)
    for stale in CHAIN.glob("*"):
        stale.unlink()
    print("running the Solidity suite to capture the chain's verdict ...")
    proc = subprocess.run(
        ["npx", "hardhat", "test", "solidity"],
        cwd=ROOT, capture_output=True, text=True, shell=(os.name == "nt"),
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout[-4000:] + "\n" + proc.stderr[-4000:] + "\n")
        raise SystemExit("Solidity suite failed; the chain verdict is not trustworthy")


def run_verifier(scenario: str, arm: str, first: int, last: int) -> tuple[dict, list[dict], str]:
    """Slice this scenario's inputs, run the verifier, return (days, policy report, stderr)."""
    out_dir = VERIFY / scenario
    out_dir.mkdir(parents=True, exist_ok=True)

    readings = [r for r in read_csv(INPUTS / f"{arm}.readings.csv") if first <= int(r["dayIndex"]) <= last]
    prices = [r for r in read_csv(INPUTS / "prices.csv") if first <= int(r["dayIndex"]) <= last]
    write_csv(out_dir / "readings.csv", ["dayIndex", "slot", "importMWh", "exportMWh"],
              ([r["dayIndex"], r["slot"], r["importMWh"], r["exportMWh"]] for r in readings))
    write_csv(out_dir / "prices.csv", ["dayIndex", "slot", "importPrice", "exportPrice"],
              ([r["dayIndex"], r["slot"], r["importPrice"], r["exportPrice"]] for r in prices))

    policy_in = CHAIN / f"{scenario}.policy.csv"
    days_out = out_dir / "days.csv"
    policy_out = out_dir / "policy_report.csv"
    summary_out = out_dir / "summary.json"
    # Delete previous output first. A verifier that fails must never leave the
    # last good run in place to be compared as though it were this one (D5.4).
    for stale in (days_out, policy_out, summary_out):
        if stale.exists():
            stale.unlink()

    proc = subprocess.run(
        [sys.executable, str(VERIFIER),
         "--readings", str(out_dir / "readings.csv"),
         "--prices", str(out_dir / "prices.csv"),
         "--policy", str(policy_in),
         "--out", str(days_out),
         "--policy-report", str(policy_out),
         "--summary-json", str(summary_out)],
        cwd=ROOT, capture_output=True, text=True,
    )
    # Non-zero is expected when the verifier reports anomalies. No output file
    # means it did not run to completion, which is a failure of the harness.
    if not days_out.exists() or not policy_out.exists():
        sys.stderr.write(proc.stdout + "\n" + proc.stderr + "\n")
        raise SystemExit(f"verifier produced no output for {scenario} (exit {proc.returncode})")

    days = {int(r["dayIndex"]): r for r in read_csv(days_out)}
    return days, read_csv(policy_out), proc.stderr


# ----------------------------------------------------------------------------
# Comparison
# ----------------------------------------------------------------------------

def compare_days(chain_rows: list[dict], verifier_days: dict) -> list[tuple]:
    diffs = []
    seen = set()
    for row in chain_rows:
        day = int(row["dayIndex"])
        seen.add(day)
        v = verifier_days.get(day)
        if v is None:
            diffs.append((day, "row", "present", "missing"))
            continue
        for chain_col, verifier_col in DAY_FIELDS:
            a, b = norm(row[chain_col]), norm(v.get(verifier_col, "<absent>"))
            if a != b:
                diffs.append((day, chain_col, a, b))
    for day in sorted(set(verifier_days) - seen):
        diffs.append((day, "row", "missing", "present"))
    return diffs


def deferral_findings(chain_policy: list[dict], report: list[dict]) -> list[tuple]:
    findings = []
    by_seq = {int(r["seq"]): r for r in report}
    for event in chain_policy:
        seq = int(event["seq"])
        r = by_seq.get(seq)
        if r is None:
            findings.append((seq, "missing from verifier report", "", ""))
            continue
        if norm(r["deferralOk"]) != "true":
            findings.append((seq, "deferral mismatch", r["emittedEffectiveFromDay"], r["derivedEffectiveFromDay"]))
    return findings


def quantisation(scenario_arm: str, chain_rows: list[dict]) -> float | None:
    path = INPUTS / f"{scenario_arm}.simulator.csv"
    if not path.exists():
        return None
    sim = {int(r["dayIndex"]): float(r["simulatorEnergyCostMilliUsd"]) for r in read_csv(path)}
    worst = 0.0
    for row in chain_rows:
        day = int(row["dayIndex"])
        if day in sim:
            worst = max(worst, abs(int(row["spendMilliUsd"]) - sim[day]))
    return worst


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-chain", action="store_true", help="reuse differential/data/chain/")
    args = ap.parse_args()

    ensure_inputs()
    if not args.skip_chain:
        run_chain()

    metas = sorted(CHAIN.glob("*.meta.csv"))
    if not metas:
        raise SystemExit("no chain scenarios found in differential/data/chain/")

    header = (f"{'scenario':<10} {'days':>5} {'writes':>6} {'breaches':>8} {'unauth':>6} "
              f"{'disagree':>8} {'deferral':>8} {'max |chain-sim| mUSD':>21}")
    print("\n" + header)
    print("-" * len(header))

    total = 0
    details = []
    for meta_path in metas:
        meta = read_csv(meta_path)[0]
        scenario, arm = meta["scenario"], meta["arm"]
        first, last = int(meta["firstDay"]), int(meta["lastDay"])

        chain_rows = read_csv(CHAIN / f"{scenario}.days.csv")
        chain_policy = read_csv(CHAIN / f"{scenario}.policy.csv")
        verifier_days, report, stderr = run_verifier(scenario, arm, first, last)

        diffs = compare_days(chain_rows, verifier_days)
        deferrals = deferral_findings(chain_policy, report)
        breaches = sum(1 for r in chain_rows if norm(r["compliant"]) == "false")
        unauth = sum(1 for r in chain_rows if norm(r["authorisedNextDay"]) == "false")
        quant = quantisation(arm, chain_rows)

        print(f"{scenario:<10} {len(chain_rows):>5} {len(chain_policy):>6} {breaches:>8} {unauth:>6} "
              f"{len(diffs):>8} {len(deferrals):>8} {quant if quant is not None else float('nan'):>21.6f}")

        total += len(diffs) + len(deferrals)
        if diffs or deferrals or stderr.strip():
            details.append((scenario, diffs, deferrals, stderr))

    print("-" * len(header))
    print(f"total disagreements and deferral findings: {total}\n")

    for scenario, diffs, deferrals, stderr in details:
        print(f"=== {scenario} ===")
        if stderr.strip():
            lines = stderr.strip().splitlines()
            print(f"verifier stderr ({len(lines)} lines):")
            for line in lines[:15]:
                print(f"  {line}")
        if diffs:
            print(f"{'day':>8} {'field':<20} {'chain':>14} {'verifier':>14}")
            for day, field, a, b in diffs[:40]:
                print(f"{day:>8} {field:<20} {a:>14} {b:>14}")
            if len(diffs) > 40:
                print(f"  ... and {len(diffs) - 40} more")
        for seq, kind, emitted, derived in deferrals:
            print(f"  policy seq {seq}: {kind} (chain {emitted}, rule {derived})")
        print()

    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
