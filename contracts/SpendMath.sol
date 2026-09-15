// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title SpendMath
/// @notice Daily energy spend from meter readings and published prices.
///
///     spend = Σ over 48 half-hours of (import × import_price − export × export_price)
///
/// Energy cost only. Battery degradation is excluded: it is modelled wear
/// rather than money paid, and computing it would need battery discharge, which
/// sits behind the meter and would have to come from the agent (D7.4).
///
/// Units (D7.10):
///     readings  milliwatt-hours          = 1e-6 kWh
///     prices    1e-8 USD per kWh
///     product   1e-6 kWh × 1e-8 USD/kWh  = 1e-14 USD
///     spend     milli-USD                = 1e-3 USD  =  product / 1e11
///
/// The 48 products are summed exactly as an integer and the total is rounded
/// once, half away from zero. Rounding each half-hour instead would compound 48
/// rounding errors into the day.
library SpendMath {
    /// @notice Divisor from (mWh × 1e-8 USD/kWh) to milli-USD.
    int256 internal constant PRODUCT_PER_MILLI_USD = 1e11;

    uint256 internal constant INTERVALS_PER_DAY = 48;

    /// @notice The exact day total in 1e-14 USD, before rounding.
    function dailyNumerator(
        uint64[48] memory importMWh,
        uint64[48] memory exportMWh,
        int64[48] memory importPrices,
        int64[48] memory exportPrices
    ) internal pure returns (int256 total) {
        for (uint256 i = 0; i < INTERVALS_PER_DAY; i++) {
            total += int256(uint256(importMWh[i])) * int256(importPrices[i]);
            total -= int256(uint256(exportMWh[i])) * int256(exportPrices[i]);
        }
    }

    /// @notice Daily spend in milli-USD, rounded once, half away from zero.
    function dailySpendMilliUsd(
        uint64[48] memory importMWh,
        uint64[48] memory exportMWh,
        int64[48] memory importPrices,
        int64[48] memory exportPrices
    ) internal pure returns (int256) {
        return divRoundHalfAwayFromZero(
            dailyNumerator(importMWh, exportMWh, importPrices, exportPrices),
            PRODUCT_PER_MILLI_USD
        );
    }

    /// @notice n / d rounded half away from zero, for d > 0.
    ///
    /// Solidity's signed division truncates toward zero, so 2.5 → 2 and
    /// −2.5 → −2. Half away from zero sends them to 3 and −3. Banker's rounding
    /// would send 2.5 → 2 and 3.5 → 4, and in this ledger its errors are
    /// signed, so they would not cancel out over a window (F4).
    function divRoundHalfAwayFromZero(int256 n, int256 d) internal pure returns (int256 q) {
        require(d > 0, "SpendMath: divisor must be positive");
        q = n / d;
        int256 r = n % d; // same sign as n
        int256 absR = r < 0 ? -r : r;
        if (2 * absR >= d) {
            q += n < 0 ? int256(-1) : int256(1);
        }
    }
}
