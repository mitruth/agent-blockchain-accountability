// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClassicSettlement} from "../../contracts/market/ClassicSettlement.sol";

/// The settlement rule of both source projects, at its edges: exactly 10% is
/// tolerated, a hair more is not, and a penalty rounds up.
contract ClassicSettlementTest is Test {
    ClassicSettlement internal rule;

    function setUp() public {
        rule = new ClassicSettlement();
    }

    function test_theThresholdIsTenPercent() public view {
        assertEq(rule.DEVIATION_THRESHOLD_PERCENT(), 10);
    }

    function test_exactlyTenPercentCostsNothing() public view {
        assertEq(rule.penalty(300_000, 150, 1500), 0);
    }

    /// One Wh beyond 10% and the whole deviation is paid, not just the excess.
    function test_justBeyondTenPercentCostsTheWholeDeviation() public view {
        assertEq(rule.penalty(300_000, 151, 1500), 45_300);
    }

    /// A 16% deviation is penalised; a 20% threshold would have let it pass.
    function test_sixteenPercentIsPenalised() public view {
        assertEq(rule.penalty(300_000, 240, 1500), 72_000);
    }

    /// 151 Wh at 0.333333 per kWh is 50,333.283 units: the penalty rounds up.
    function test_aPenaltyRoundsUp() public view {
        assertEq(rule.penalty(333_333, 151, 1000), 50_334);
    }

    /// A commitment that nets to zero tolerates no deviation.
    function test_aZeroCommitmentToleratesNoDeviation() public view {
        assertEq(rule.penalty(300_000, 0, 0), 0);
        assertEq(rule.penalty(300_000, 1, 0), 300);
    }
}
