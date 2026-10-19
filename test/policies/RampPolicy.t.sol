// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyFixture} from "./PolicyFixture.sol";
import {RampPolicy} from "../../contracts/policies/RampPolicy.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {Side, ConfigChange, CheckResult, Verdict} from "../../contracts/gate/GateTypes.sol";

/// @notice S5, the ramp between consecutive slots (spec 6.6), through the gate
///         on the mock market: the net position may step by at most 1,500 Wh
///         from one slot to the next, flagged above 1,000.
contract RampPolicyTest is PolicyFixture {
    bytes32 internal constant S5 = keccak256("S5");
    uint64 internal constant SOFT = 1_000;
    uint64 internal constant MAX = 1_500;

    RampPolicy internal s5;

    function setUp() public override {
        super.setUp();
        s5 = new RampPolicy(address(gate));
        _addPolicy(s5, S5, abi.encode(RampPolicy.Config({softStepWh: SOFT, maxStepWh: MAX})));
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(s5));
        return all[all.length - 1];
    }

    /// @dev Positions placed before S5 is installed, so a test can start from
    ///      a profile already too steep.
    function _withoutS5(function() internal setup) internal {
        vm.prank(owner);
        account.execute(address(gate), 0, abi.encodeCall(gate.proposeRemovePolicy, (s5, S5)));
        vm.warp(block.timestamp + 24 hours);
        vm.prank(owner);
        account.execute(address(gate), 0, abi.encodeCall(gate.applyRemovePolicy, (s5, S5)));
        setup();
        _addPolicy(s5, S5, abi.encode(RampPolicy.Config({softStepWh: SOFT, maxStepWh: MAX})));
    }

    // ------------------------------------------------------------------

    function test_aStepWithinTheSoftBoundPasses() public {
        vm.recordLogs();
        _place(Side.SELL, 5, SOFT, PRICE);
        CheckResult memory r = _lastResult();
        assertEq(r.valueBefore, 0);
        assertEq(r.valueAfter, SOFT);
        assertEq(uint8(r.verdict), uint8(Verdict.EXECUTE));
    }

    function test_aStepAboveTheSoftBoundIsFlagged() public {
        vm.recordLogs();
        _place(Side.SELL, 5, 1_200, PRICE);
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.FLAG));
        assertEq(market.orderCount(), 1);
    }

    /// @dev Spec step 5: a position spike is blocked, built in two orders that
    ///      would each pass on their own.
    function test_aPositionSpikeIsBlocked() public {
        _place(Side.SELL, 5, 1_000, PRICE);
        vm.recordLogs();
        assertEq(_place(Side.SELL, 5, 600, PRICE), bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(r.valueBefore, 1_000);
        assertEq(r.valueAfter, 1_600);
        assertEq(market.orderCount(), 1);
    }

    function test_aBuySpikeIsBlockedToo() public {
        assertEq(_place(Side.BUY, 5, MAX + 1, PRICE), bytes32(0));
        assertTrue(_place(Side.BUY, 5, MAX, PRICE) != bytes32(0));
    }

    function test_aRampBuiltSlotBySlotPasses() public {
        _place(Side.SELL, 4, 1_000, PRICE);
        _place(Side.SELL, 5, 1_000, PRICE);
        _place(Side.SELL, 6, 1_000, PRICE);
        _place(Side.SELL, 5, 1_000, PRICE); // 1,000 / 2,000 / 1,000: steps of 1,000
        assertEq(market.orderCount(), 4);
    }

    function test_theStepToTheRightCountsToo() public {
        _place(Side.BUY, 6, 800, PRICE);
        assertEq(_place(Side.SELL, 5, 800, PRICE), bytes32(0));
    }

    function test_aSaleNextToABidCountsTheWholeSwing() public {
        _place(Side.BUY, 5, 800, PRICE);
        // From +800 to -800 is a step of 1,600.
        assertEq(_place(Side.SELL, 6, 800, PRICE), bytes32(0));
    }

    // ------------------------------------------------------------------
    // What smooths the profile passes (D10)
    // ------------------------------------------------------------------

    /// @dev Removing S5 waits a day, so these slots count from the current one.
    function _spike() internal {
        _place(Side.SELL, market.currentSlot() + 5, 3_000, PRICE);
    }

    function test_aSmoothingOrderPassesWhileTheProfileIsTooSteep() public {
        _withoutS5(_spike);
        uint32 b = market.currentSlot();
        assertTrue(_place(Side.BUY, b + 5, 500, PRICE) != bytes32(0)); // -3,000 to -2,500
        assertTrue(_place(Side.SELL, b + 4, 1_000, PRICE) != bytes32(0)); // steps of 1,000 and 1,500
        assertEq(_place(Side.SELL, b + 5, 100, PRICE), bytes32(0)); // steeper again
    }

    function test_cancellingTheSpikePasses() public {
        _withoutS5(_spike);
        bytes32 spike = bytes32(market.orderCount());
        _cancel(spike);
        assertFalse(market.isOpen(spike));
    }

    function test_aModificationThatSpreadsTheSpikePasses() public {
        _withoutS5(_spike);
        bytes32 spike = bytes32(market.orderCount());
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (spike, market.currentSlot() + 6, 1_000, PRICE)));
        assertFalse(market.isOpen(spike));
        assertEq(market.orderCount(), 2);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_configurations() public view {
        assertEq(
            uint8(s5.classifyConfig(address(account), S5, abi.encode(RampPolicy.Config(0, 0)))),
            uint8(ConfigChange.INVALID)
        );
        assertEq(
            uint8(s5.classifyConfig(address(account), S5, abi.encode(RampPolicy.Config(MAX + 1, MAX)))),
            uint8(ConfigChange.INVALID)
        );
        assertEq(
            uint8(s5.classifyConfig(address(account), S5, abi.encode(RampPolicy.Config(SOFT, MAX + 1)))),
            uint8(ConfigChange.WIDEN)
        );
        assertEq(
            uint8(s5.classifyConfig(address(account), S5, abi.encode(RampPolicy.Config(SOFT + 1, MAX)))),
            uint8(ConfigChange.WIDEN)
        );
        assertEq(
            uint8(s5.classifyConfig(address(account), S5, abi.encode(RampPolicy.Config(SOFT, MAX - 1)))),
            uint8(ConfigChange.TIGHTEN)
        );
    }

    function test_onlyTheGateConfigures() public {
        vm.expectRevert();
        s5.configure(address(account), S5, abi.encode(RampPolicy.Config(SOFT, MAX)));
    }
}
