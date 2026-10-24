// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console} from "forge-std/console.sol";
import {PolicyFixture} from "./PolicyFixture.sol";
import {RoundTripPolicy} from "../../contracts/policies/RoundTripPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {Side, ConfigChange, Verdict, CheckResult} from "../../contracts/gate/GateTypes.sol";

/// @notice S8, the same-slot round-trip quota (spec v0.2 section 5), through
///         the gate on the mock market. The quota: 1,000 Wh over a sliding day
///         of half-hour buckets, flagged above 500 Wh.
contract RoundTripPolicyTest is PolicyFixture {
    bytes32 internal constant S8 = keccak256("S8");
    uint64 internal constant CAP = 1_000;
    uint64 internal constant SOFT = 500;

    RoundTripPolicy internal s8;
    MockEnergyMarket internal marketB;

    function setUp() public override {
        super.setUp();
        s8 = new RoundTripPolicy(address(gate));
        _addPolicy(s8, S8, abi.encode(_config(SOFT, CAP)));

        marketB = new MockEnergyMarket(GENESIS, SLOT_SECONDS, GATE_LEAD, operator);
        bytes4[3] memory selectors = [
            MockEnergyMarket.placeOrder.selector,
            MockEnergyMarket.cancelOrder.selector,
            MockEnergyMarket.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            _asAccount(abi.encodeCall(gate.setDecoder, (address(marketB), selectors[i], decoder)));
        }
    }

    function _config(uint64 soft, uint64 cap) internal pure returns (RoundTripPolicy.Config memory c) {
        c.soft = soft;
        c.window = WindowLib.Config({kind: WindowLib.Kind.SLIDING, step: 1800, buckets: 48, anchor: 0, cap: cap, rate: 0, initial: 0});
    }

    function _used() internal view returns (uint64 used) {
        (used,) = s8.usedOf(address(account), S8);
    }

    function _slot() internal view returns (uint32) {
        return market.currentSlot() + 10;
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(s8));
        return all[all.length - 1];
    }

    function _modify(bytes32 id, uint32 slot, uint64 qtyWh) internal returns (bytes32) {
        uint256 before = market.orderCount();
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (id, slot, qtyWh, PRICE)));
        return market.orderCount() > before ? bytes32(market.orderCount()) : bytes32(0);
    }

    function _onB(Side side, uint32 slot, uint64 qtyWh) internal returns (bytes32) {
        uint256 before = marketB.orderCount();
        vm.prank(agent);
        account.executeAsSession(
            address(gate),
            abi.encodeCall(gate.submit, (address(marketB), _placeCall(side, slot, qtyWh, PRICE), new SignedReading[](0)))
        );
        return marketB.orderCount() > before ? bytes32(marketB.orderCount()) : bytes32(0);
    }

    function _cancelOnB(bytes32 id) internal {
        vm.prank(agent);
        account.executeAsSession(
            address(gate),
            abi.encodeCall(gate.submit, (address(marketB), abi.encodeCall(MockEnergyMarket.cancelOrder, (id)), new SignedReading[](0)))
        );
    }

    // ------------------------------------------------------------------
    // What a submission adds
    // ------------------------------------------------------------------

    /// @dev 1,000 Wh bought, then 300 sold in the same slot: 300 Wh round trip.
    function test_aSellAgainstABuyCountsTheOverlap() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 1_000, PRICE);
        assertEq(_used(), 0, "one side alone is no round trip");
        _place(Side.SELL, slot, 300, PRICE);
        assertEq(_used(), 300);
    }

    function test_differentSlotsCountNothing() public {
        _place(Side.BUY, _slot(), 1_000, PRICE);
        _place(Side.SELL, _slot() + 1, 1_000, PRICE);
        assertEq(_used(), 0);
    }

    /// @dev Only the overlap counts: 200 bought, 700 sold, 200 round trip; a
    ///      further 100 sold adds nothing, the buy side binds.
    function test_onlyTheSmallerSideCounts() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 200, PRICE);
        _place(Side.SELL, slot, 700, PRICE);
        assertEq(_used(), 200);
        _place(Side.SELL, slot, 100, PRICE);
        assertEq(_used(), 200);
    }

    /// @dev A modification is a cancellation and a placement. Moving the sell
    ///      out of the slot adds nothing; growing the binding buy from 300 to
    ///      400 adds 100, not 400.
    function test_aModificationCountsOnlyWhatItAdds() public {
        uint32 slot = _slot();
        bytes32 buy = _place(Side.BUY, slot, 300, PRICE);
        bytes32 sell = _place(Side.SELL, slot, 500, PRICE);
        assertEq(_used(), 300);
        buy = _modify(buy, slot, 400);
        assertTrue(buy != bytes32(0));
        assertEq(_used(), 400, "100 more on the binding side");
        assertTrue(_modify(sell, slot + 1, 500) != bytes32(0), "moved out of the slot");
        assertEq(_used(), 400);
    }

    // ------------------------------------------------------------------
    // Soft and hard bounds
    // ------------------------------------------------------------------

    function test_aboveTheSoftBoundIsFlagged() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 1_000, PRICE);
        vm.recordLogs();
        assertTrue(_place(Side.SELL, slot, 501, PRICE) != bytes32(0));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.FLAG));
    }

    function test_atTheSoftBoundIsNotFlagged() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 1_000, PRICE);
        vm.recordLogs();
        _place(Side.SELL, slot, 500, PRICE);
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.EXECUTE));
    }

    /// @dev 1,000 Wh round trip is the cap exactly; 1 Wh more is refused.
    function test_theCapIsInclusive() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 2_000, PRICE);
        assertTrue(_place(Side.SELL, slot, 1_000, PRICE) != bytes32(0));
        assertEq(_used(), CAP);
        vm.recordLogs();
        assertEq(_place(Side.SELL, slot, 1, PRICE), bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(uint8(r.verdict), uint8(Verdict.REJECT));
        assertEq(r.valueBefore, CAP);
        assertEq(r.valueAfter, CAP + 1);
        assertEq(r.hard, CAP);
        assertEq(r.soft, SOFT);
    }

    /// @dev D10: with the quota spent, a cancellation and an order on one side
    ///      of another slot still pass.
    function test_whatAddsNothingAlwaysPasses() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 1_000, PRICE);
        bytes32 sell = _place(Side.SELL, slot, 1_000, PRICE);
        assertTrue(_place(Side.BUY, slot + 2, 5_000, PRICE) != bytes32(0), "one side of another slot");
        assertTrue(_place(Side.SELL, slot, 500, PRICE) != bytes32(0), "the buy side binds: adds nothing");
        vm.recordLogs();
        _cancel(sell);
        assertFalse(market.isOpen(sell));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.EXECUTE), "not even flagged");
    }

    // ------------------------------------------------------------------
    // No credits
    // ------------------------------------------------------------------

    /// @dev A round trip counts when created. Cancelling the sell gives
    ///      nothing back, and selling the same volume again counts again.
    function test_aReleasedRoundTripStillCounts() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 1_000, PRICE);
        bytes32 sell = _place(Side.SELL, slot, 400, PRICE);
        _cancel(sell);
        assertEq(_used(), 400, "no credit");
        _place(Side.SELL, slot, 400, PRICE);
        assertEq(_used(), 800, "counted again");
    }

    /// @dev The window is a day: a day and a slot later the count is gone.
    function test_theWindowSlidesAfterADay() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 1_000, PRICE);
        _place(Side.SELL, slot, 1_000, PRICE);
        assertEq(_used(), CAP);
        vm.warp(block.timestamp + 24 hours + 30 minutes);
        assertEq(_used(), 0);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_configurationDirections() public view {
        assertEq(uint8(_classify(_config(SOFT, CAP - 1))), uint8(ConfigChange.TIGHTEN), "a lower cap");
        assertEq(uint8(_classify(_config(SOFT - 1, CAP))), uint8(ConfigChange.TIGHTEN), "a lower soft bound");
        assertEq(uint8(_classify(_config(SOFT, CAP))), uint8(ConfigChange.TIGHTEN), "the same");
        assertEq(uint8(_classify(_config(SOFT, CAP + 1))), uint8(ConfigChange.WIDEN), "a higher cap");
        assertEq(uint8(_classify(_config(SOFT + 1, CAP))), uint8(ConfigChange.WIDEN), "a higher soft bound");
        RoundTripPolicy.Config memory reshaped = _config(SOFT, CAP);
        reshaped.window.buckets = 24;
        assertEq(uint8(_classify(reshaped)), uint8(ConfigChange.WIDEN), "another shape");
        assertEq(uint8(_classify(_config(CAP + 1, CAP))), uint8(ConfigChange.INVALID), "soft above the cap");
        assertEq(uint8(s8.classifyConfig(address(account), S8, hex"00")), uint8(ConfigChange.INVALID));
    }

    function _classify(RoundTripPolicy.Config memory c) internal view returns (ConfigChange) {
        return s8.classifyConfig(address(account), S8, abi.encode(c));
    }

    function test_onlyTheGateWritesThePolicy() public {
        vm.expectRevert();
        s8.configure(address(account), S8, abi.encode(_config(SOFT, CAP)));
    }

    // ------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------

    /// @dev One bid, the second of two (the first writes storage for the
    ///      first time): into a slot with no sell, and into one with a sell.
    function test_gas_oneBid() public {
        uint32 slot = _slot();
        _place(Side.SELL, slot + 1, 5_000, PRICE);
        _place(Side.BUY, slot, 100, PRICE);
        console.log("S8, a bid with no round trip:", _gasOfBid(slot, 100));
        _place(Side.BUY, slot + 1, 100, PRICE);
        console.log("S8, a bid that adds a round trip:", _gasOfBid(slot + 1, 100));
    }

    function _gasOfBid(uint32 slot, uint64 qtyWh) internal returns (uint256 used) {
        bytes memory sub =
            abi.encodeCall(gate.submit, (address(market), _placeCall(Side.BUY, slot, qtyWh, PRICE), new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        account.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }

    // ------------------------------------------------------------------
    // Spec section 7: churn split across two markets
    // ------------------------------------------------------------------

    /// @dev Buy 200 Wh on market A, sell 200 Wh of the same slot on market B,
    ///      cancel both, again and again. Each venue alone holds one side
    ///      only. Returns how many of 10 rounds had their sell placed.
    function _churn() internal returns (uint256 placed) {
        uint32 slot = _slot();
        for (uint256 i = 0; i < 10; ++i) {
            bytes32 buy = _place(Side.BUY, slot, 200, PRICE);
            bytes32 sell = _onB(Side.SELL, slot, 200);
            if (sell != bytes32(0)) ++placed;
            PositionLedger.Position memory p = ledger.positionOf(address(account), slot);
            if (sell != bytes32(0)) assertEq(p.committedSellWh, 200, "the sell is on B, summed on one grid");
            _cancel(buy);
            if (sell != bytes32(0)) _cancelOnB(sell);
        }
    }

    /// @dev Five rounds make 1,000 Wh of round trips; the sixth sell would
    ///      pass the cap.
    function test_churnAcrossTwoMarkets_isStoppedByS8() public {
        assertEq(_churn(), 5);
        assertEq(_used(), CAP);
    }

    function test_churnAcrossTwoMarkets_passesWithoutS8() public {
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (s8, S8)));
        vm.warp(block.timestamp + 24 hours);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (s8, S8)));
        assertEq(_churn(), 10);
    }

    // ------------------------------------------------------------------
    // Spec section 11.6: a single correction passes
    // ------------------------------------------------------------------

    /// @dev 3 kWh bought for a slot; the forecast then rises, and 400 Wh is
    ///      sold back into it. It is placed, under the soft bound, unflagged.
    function test_aSingleCorrectionPasses() public {
        uint32 slot = _slot();
        _place(Side.BUY, slot, 3_000, PRICE);
        vm.warp(block.timestamp + 30 minutes);
        vm.recordLogs();
        assertTrue(_place(Side.SELL, slot, 400, PRICE) != bytes32(0));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.EXECUTE));
        assertEq(_used(), 400);
    }
}
