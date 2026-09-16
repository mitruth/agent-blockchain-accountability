"""Build what the simulated meter and price publisher would publish.

Reads each arm's HEMS step log from the Demo_PlanApplyEvaluate repository and
produces, per UTC day of 48 half-hours:

  - meter readings: grid import and export, milliwatt-hours
  - prices: import and export, 1e-8 USD per kWh

The dataset's clock is mapped to UTC as a fixed UTC-8 offset, and only complete
UTC days are kept -- 364 of them for the 2022 evaluation year (D7.7). Values are
rounded half away from zero, once, the way a meter rounds to its resolution
(D7.10). Prices are the same for every arm; the script checks that rather than
assuming it.

Outputs, under differential/data/inputs/ (regenerated, not committed):

  <arm>.days.hex        packed for the Solidity differential: per day,
                        uint64 dayIndex, then 48 x uint32 import, 48 x uint32
                        export, 48 x int32 import price, 48 x int32 export
                        price, all big-endian
  <arm>.readings.csv    dayIndex, slot, importMWh, exportMWh
  prices.csv            dayIndex, slot, importPrice, exportPrice
  <arm>.simulator.csv   dayIndex, simulatorEnergyCostMilliUsd -- the
                        simulator's own float energy cost, for measuring
                        quantisation; neither implementation reads it

usage:
    python differential/build_settlement_inputs.py [--hems-repo PATH] [--home home_01]
"""

from __future__ import annotations

import argparse
import io
import struct
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "differential" / "data" / "inputs"
ARMS = ("B0", "B1", "B2")
SLOTS = 48
UTC_OFFSET_HOURS = 8  # dataset clock treated as fixed UTC-8 (D7.7)

UINT32_MAX = 2**32 - 1
INT32_MIN, INT32_MAX = -(2**31), 2**31 - 1


def round_half_away(x: float) -> int:
    # repr gives the shortest decimal that round-trips the float, so the tie
    # test sees what the simulator wrote rather than binary noise.
    return int(Decimal(repr(float(x))).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def load_arm(hems: Path, home: str, arm: str) -> pd.DataFrame:
    path = hems / "data" / "outputs" / home / arm / "step_log.csv"
    frame = pd.read_csv(path)
    local = pd.to_datetime(frame["day"]) + pd.to_timedelta((frame["day_step"] - 1) * 30, unit="min")
    utc_seconds = ((local + pd.Timedelta(hours=UTC_OFFSET_HOURS)) - pd.Timestamp("1970-01-01")).dt.total_seconds()
    utc_seconds = utc_seconds.astype("int64")
    frame["dayIndex"] = utc_seconds // 86400
    frame["slot"] = (utc_seconds % 86400) // 1800

    counts = frame.groupby("dayIndex")["slot"].count()
    complete = counts[counts == SLOTS].index
    dropped = sorted(set(counts.index) - set(complete))
    frame = frame[frame["dayIndex"].isin(complete)].sort_values(["dayIndex", "slot"]).reset_index(drop=True)

    frame["importMWh"] = [round_half_away(v * 1e6) for v in frame["imp"]]
    frame["exportMWh"] = [round_half_away(v * 1e6) for v in frame["exp"]]
    frame["importPrice"] = [round_half_away(v * 1e8) for v in frame["price_imp"]]
    frame["exportPrice"] = [round_half_away(v * 1e8) for v in frame["price_exp"]]

    assert frame["importMWh"].between(0, UINT32_MAX).all(), f"{arm}: import out of uint32"
    assert frame["exportMWh"].between(0, UINT32_MAX).all(), f"{arm}: export out of uint32"
    assert frame["importPrice"].between(INT32_MIN, INT32_MAX).all(), f"{arm}: import price out of int32"
    assert frame["exportPrice"].between(INT32_MIN, INT32_MAX).all(), f"{arm}: export price out of int32"
    overlap = ((frame["importMWh"] > 0) & (frame["exportMWh"] > 0)).sum()
    assert overlap == 0, f"{arm}: {overlap} half-hours both import and export"

    print(f"[{arm}] {len(complete)} complete UTC days "
          f"({int(complete.min())}..{int(complete.max())}); dropped partial days {dropped}")
    return frame


def pack(frame: pd.DataFrame) -> bytes:
    out = bytearray()
    for day, group in frame.groupby("dayIndex", sort=True):
        out += struct.pack(">Q", int(day))
        out += struct.pack(">48I", *group["importMWh"].astype(int))
        out += struct.pack(">48I", *group["exportMWh"].astype(int))
        out += struct.pack(">48i", *group["importPrice"].astype(int))
        out += struct.pack(">48i", *group["exportPrice"].astype(int))
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hems-repo", default=str(ROOT.parent / "Demo_PlanApplyEvaluate"))
    ap.add_argument("--home", default="home_01")
    args = ap.parse_args()

    hems = Path(args.hems_repo)
    OUT.mkdir(parents=True, exist_ok=True)

    prices_reference = None
    for arm in ARMS:
        frame = load_arm(hems, args.home, arm)

        prices = frame[["dayIndex", "slot", "importPrice", "exportPrice"]].reset_index(drop=True)
        if prices_reference is None:
            prices_reference = prices
            prices.to_csv(OUT / "prices.csv", index=False, lineterminator="\n")
        else:
            assert prices.equals(prices_reference), f"{arm}: prices differ from {ARMS[0]}"

        frame[["dayIndex", "slot", "importMWh", "exportMWh"]].to_csv(
            OUT / f"{arm}.readings.csv", index=False, lineterminator="\n")

        blob = pack(frame)
        io.open(OUT / f"{arm}.days.hex", "w", encoding="ascii", newline="").write("0x" + blob.hex())

        frame["energyCost"] = frame["imp"] * frame["price_imp"] - frame["exp"] * frame["price_exp"]
        sim = frame.groupby("dayIndex")["energyCost"].sum() * 1000
        sim.rename("simulatorEnergyCostMilliUsd").to_csv(OUT / f"{arm}.simulator.csv", lineterminator="\n")

        print(f"[{arm}] wrote {len(blob):,} bytes packed; "
              f"energy cost {sim.sum() / 1000:.3f} USD over the complete days")

    print(f"inputs in {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
