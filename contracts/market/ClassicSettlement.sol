// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MarketTypes} from "./MarketTypes.sol";

/// @title ISettlementRule
/// @notice How a measured deviation from a commitment is priced. After the
///         `SettlementInterface` of BRIGHT and DEDALUS.
interface ISettlementRule {
    /// @param pricePerKWh The market's real-time price.
    /// @param deviationWh |measured net export − committed net export|.
    /// @param committedWh |committed net export|.
    /// @return The penalty, in payment-token units.
    function penalty(uint256 pricePerKWh, uint256 deviationWh, uint256 committedWh) external pure returns (uint256);
}

/// @title ClassicSettlement
/// @notice The settlement rule of both source projects: a deviation within 10%
///         of the commitment costs nothing; beyond it, the whole deviation is
///         paid at the real-time price.
///
/// The source computed |100 − measured × 100 / committed| > 10 in int32, which
/// divides by zero on a zero commitment and wraps on large values. The same
/// rule is written here without division: deviation × 100 > 10 × committed. A
/// commitment that nets to zero therefore tolerates no deviation.
contract ClassicSettlement is ISettlementRule {
    uint256 public constant DEVIATION_THRESHOLD_PERCENT = 10;

    function penalty(uint256 pricePerKWh, uint256 deviationWh, uint256 committedWh)
        external
        pure
        override
        returns (uint256)
    {
        if (deviationWh * 100 <= DEVIATION_THRESHOLD_PERCENT * committedWh) return 0;
        return MarketTypes.value(deviationWh, pricePerKWh);
    }
}
