// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PolicyFixture} from "./PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {DominatedTradePolicy} from "../../contracts/policies/DominatedTradePolicy.sol";
import {StaticOrderPolicy} from "../../contracts/policies/StaticOrderPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, TariffSchedule, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {Side, ConfigChange, Verdict, CheckResult} from "../../contracts/gate/GateTypes.sol";

/// @notice S7, the dominated-trade budget (spec v0.2 section 5), through the
///         gate on the mock market. The tariff: retail 0.20, feed-in 0.08 per
///         kWh in every slot. The budget: 1 USD (1,000,000 units) over a
///         sliding week of hourly buckets, flagged above 0.50.
contract DominatedTradePolicyTest is PolicyFixture, OracleFixture {
    bytes32 internal constant S7 = keccak256("S7");
    uint64 internal constant RETAIL = 200_000;
    uint64 internal constant FEED_IN = 80_000;
    uint64 internal constant CAP = 1_000_000;
    uint64 internal constant SOFT = 500_000;

    DominatedTradePolicy internal s7;
    OracleVerifier internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = gate.oracle();
        s7 = new DominatedTradePolicy(address(gate));
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.TARIFF, tariffSigner, 24 hours)));
        _postTariff(RETAIL, FEED_IN);
        _addPolicy(s7, S7, abi.encode(_config(SOFT, CAP)));
    }

    function _config(uint64 soft, uint64 cap) internal pure returns (DominatedTradePolicy.Config memory c) {
        c.soft = soft;
        c.window = WindowLib.Config({kind: WindowLib.Kind.SLIDING, step: 3600, buckets: 168, anchor: 0, cap: cap, rate: 0, initial: 0});
    }

    function _postTariff(uint64 retail, uint64 feedIn) internal {
        uint64[] memory r = new uint64[](96);
        uint64[] memory f = new uint64[](96);
        for (uint256 i = 0; i < 96; ++i) {
            r[i] = retail;
            f[i] = feedIn;
        }
        oracle.accept(
            _signTariff(
                oracle,
                TARIFF_KEY,
                TariffSchedule({
                    account: address(account),
                    issuedAt: uint64(block.timestamp),
                    firstSlotStart: market.slotStart(market.currentSlot()),
                    slotSeconds: SLOT_SECONDS,
                    retail: r,
                    feedIn: f
                })
            )
        );
    }

    function _used() internal view returns (uint64 used) {
        (used,) = s7.usedOf(address(account), S7);
    }

    function _slot() internal view returns (uint32) {
        return market.currentSlot() + 10;
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(s7));
        return all[all.length - 1];
    }

    // ------------------------------------------------------------------
    // What a placement gives away
    // ------------------------------------------------------------------

    /// @dev 1 kWh bought at 0.25 against retail 0.20: 0.05 given away.
    function test_aBuyAboveRetailCountsTheExcess() public {
        _place(Side.BUY, _slot(), 1_000, 250_000);
        assertEq(_used(), 50_000);
    }

    /// @dev 2 kWh sold at 0.07 against feed-in 0.08: 0.02 given away.
    function test_aSellBelowFeedInCountsTheShortfall() public {
        _place(Side.SELL, _slot(), 2_000, 70_000);
        assertEq(_used(), 20_000);
    }

    /// @dev 1 Wh one unit above retail: 0.001 units, rounded up to 1 (D12).
    function test_theAmountRoundsUp() public {
        _place(Side.BUY, _slot(), 1, RETAIL + 1);
        assertEq(_used(), 1);
    }

    /// @dev Inside the corridor [feed-in, retail] nothing is dominated.
    function test_insideTheCorridorNothingCounts() public {
        _place(Side.BUY, _slot(), 5_000, RETAIL);
        _place(Side.SELL, _slot(), 5_000, FEED_IN);
        _place(Side.BUY, _slot(), 5_000, 150_000);
        _place(Side.SELL, _slot(), 5_000, 150_000);
        assertEq(_used(), 0);
        assertEq(market.orderCount(), 4);
    }

    // ------------------------------------------------------------------
    // Soft and hard bounds
    // ------------------------------------------------------------------

    /// @dev 12 kWh at 0.05 over retail: 600,000, above the soft 500,000.
    function test_aboveTheSoftBoundIsFlagged() public {
        vm.recordLogs();
        assertTrue(_place(Side.BUY, _slot(), 12_000, 250_000) != bytes32(0));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.FLAG));
    }

    /// @dev 10 kWh at 0.05 over retail: 500,000, the soft bound exactly, is
    ///      not flagged.
    function test_atTheSoftBoundIsNotFlagged() public {
        vm.recordLogs();
        assertTrue(_place(Side.BUY, _slot(), 10_000, 250_000) != bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(r.valueAfter, SOFT);
        assertEq(uint8(r.verdict), uint8(Verdict.EXECUTE));
    }

    /// @dev 20 kWh at 0.05 over is 1,000,000, the cap exactly; 1 Wh more is
    ///      refused.
    function test_theCapIsInclusive() public {
        assertTrue(_place(Side.BUY, _slot(), 20_000, 250_000) != bytes32(0));
        assertEq(_used(), CAP);
        vm.recordLogs();
        assertEq(_place(Side.BUY, _slot(), 1, 250_000), bytes32(0));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.REJECT));
    }

    /// @dev D10: with the budget spent, an order inside the corridor and a
    ///      cancellation still pass.
    function test_whatAddsNothingAlwaysPasses() public {
        bytes32 id = _place(Side.BUY, _slot(), 20_000, 250_000);
        assertTrue(_place(Side.BUY, _slot(), 1_000, RETAIL) != bytes32(0), "inside the corridor");
        _cancel(id);
        assertFalse(market.isOpen(id));
    }

    // ------------------------------------------------------------------
    // Credits (D2)
    // ------------------------------------------------------------------

    function test_aCancellationGivesItBack() public {
        bytes32 id = _place(Side.BUY, _slot(), 1_000, 250_000);
        _cancel(id);
        assertEq(_used(), 0);
    }

    /// @dev 1 kWh at 0.05 over: 50,000. 400 Wh fill; the rest is cancelled:
    ///      50,000 - 20,000 = 30,000 back.
    function test_onlyTheUnfilledPartIsGivenBack() public {
        bytes32 id = _place(Side.BUY, _slot(), 1_000, 250_000);
        vm.prank(operator);
        market.fill(id, 400, 250_000);
        _cancel(id);
        assertEq(_used(), 20_000);
    }

    /// @dev An order that expires at its gate is released by reconcile, and
    ///      credited the same way.
    function test_anExpiryGivesItBack() public {
        uint32 slot = _slot();
        bytes32 id = _place(Side.SELL, slot, 1_000, 70_000);
        assertEq(_used(), 10_000);
        vm.warp(market.gateTime(slot));
        _reconcile(id);
        assertEq(_used(), 0);
    }

    /// @dev The tariff falls to 0.10 after the placement. The credit is what
    ///      was charged against 0.20, not a recomputation against 0.10.
    function test_aNewTariffDoesNotChangeTheCredit() public {
        bytes32 id = _place(Side.BUY, _slot(), 1_000, 250_000);
        vm.warp(block.timestamp + 60);
        _postTariff(100_000, FEED_IN);
        _cancel(id);
        assertEq(_used(), 0, "50,000 charged, 50,000 back");
    }

    /// @dev Two hours on, the credit still goes to the placement's bucket,
    ///      which the week still counts, not to the current, empty one.
    function test_theCreditGoesToThePlacementsBucket() public {
        bytes32 id = _place(Side.BUY, _slot(), 1_000, 250_000);
        vm.warp(block.timestamp + 2 hours);
        _postTariff(RETAIL, FEED_IN);
        _cancel(id);
        assertEq(_used(), 0);
    }

    /// @dev Two orders in one block, same slot and side, different prices:
    ///      each keeps its own excess, 50,000 and 10,000 for 1 kWh. Cancelling
    ///      the first gives back its 50,000, not the second's 10,000.
    function test_ordersInOneBlockKeepTheirOwnExcess() public {
        uint32 slot = _slot();
        bytes32 first = _place(Side.BUY, slot, 1_000, 250_000);
        _place(Side.BUY, slot, 1_000, 210_000);
        assertEq(_used(), 60_000);
        _cancel(first);
        assertEq(_used(), 10_000);
    }

    /// @dev The window is a week: a week and an hour later the charge is gone.
    function test_theWindowSlidesAfterAWeek() public {
        _place(Side.BUY, _slot(), 20_000, 250_000);
        vm.warp(block.timestamp + 7 days + 1 hours);
        assertEq(_used(), 0);
    }

    // ------------------------------------------------------------------
    // What cannot be judged
    // ------------------------------------------------------------------

    function test_withoutAUsableTariffAPlacementIsRefused() public {
        vm.warp(block.timestamp + 24 hours + 1);
        vm.recordLogs();
        assertEq(_place(Side.BUY, _slot(), 1_000, RETAIL), bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(uint8(r.verdict), uint8(Verdict.REJECT));
        assertEq(r.valueAfter, type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_configurationDirections() public view {
        assertEq(uint8(_classify(_config(SOFT, CAP - 1))), uint8(ConfigChange.TIGHTEN), "a lower cap");
        assertEq(uint8(_classify(_config(SOFT - 1, CAP))), uint8(ConfigChange.TIGHTEN), "a lower soft bound");
        assertEq(uint8(_classify(_config(SOFT, CAP + 1))), uint8(ConfigChange.WIDEN), "a higher cap");
        assertEq(uint8(_classify(_config(SOFT + 1, CAP))), uint8(ConfigChange.WIDEN), "a higher soft bound");
        DominatedTradePolicy.Config memory reshaped = _config(SOFT, CAP);
        reshaped.window.buckets = 84;
        assertEq(uint8(_classify(reshaped)), uint8(ConfigChange.WIDEN), "another shape");
        assertEq(uint8(_classify(_config(CAP + 1, CAP))), uint8(ConfigChange.INVALID), "soft above the cap");
        assertEq(uint8(s7.classifyConfig(address(account), S7, hex"00")), uint8(ConfigChange.INVALID));
    }

    function _classify(DominatedTradePolicy.Config memory c) internal view returns (ConfigChange) {
        return s7.classifyConfig(address(account), S7, abi.encode(c));
    }

    function test_onlyTheGateWritesThePolicy() public {
        vm.expectRevert();
        s7.configure(address(account), S7, abi.encode(_config(SOFT, CAP)));
    }

    // ------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------

    function _gasOfBid(uint64 price) internal returns (uint256 used) {
        bytes memory sub = abi.encodeCall(
            gate.submit, (address(market), _placeCall(Side.BUY, _slot(), 1_000, price), new SignedReading[](0))
        );
        vm.prank(agent);
        uint256 before = gasleft();
        account.executeAsSession(address(gate), sub);
        used = before - gasleft();
        _cancel(bytes32(market.orderCount()));
    }

    /// @dev One bid, the second of two (the first writes storage for the
    ///      first time), under: S7 alone; then A1-A6 with the band off; then
    ///      with the band on; then A1-A6 with the band and S7.
    function test_gas_priceBids() public {
        _gasOfBid(250_000);
        console.log("S7 alone, a dominated bid:", _gasOfBid(250_000));
        _gasOfBid(RETAIL);
        console.log("S7 alone, a bid at retail:", _gasOfBid(RETAIL));

        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (s7, S7)));
        vm.warp(block.timestamp + 24 hours);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (s7, S7)));
        _postTariff(RETAIL, FEED_IN);
        StaticOrderPolicy statics = new StaticOrderPolicy(address(gate));
        StaticOrderPolicy.Config memory c;
        c.maxQtyWh = 50_000;
        c.maxValue = type(uint64).max;
        c.sellFloor = 1_000;
        c.buyCeiling = 2_500_000;
        c.horizonSeconds = 3 days;
        c.ratedPowerW = 200_000;
        _addPolicy(statics, keccak256("A"), abi.encode(c));
        _gasOfBid(RETAIL);
        console.log("A1-A6, band off:", _gasOfBid(RETAIL));
        c.tariffBand = true;
        c.buyMarkupBps = 1_000;
        c.sellDiscountBps = 1_000;
        _asAccount(abi.encodeCall(gate.setConfig, (statics, keccak256("A"), abi.encode(c))));
        _gasOfBid(RETAIL);
        console.log("A1-A6, band on:", _gasOfBid(RETAIL));
        _addPolicy(s7, S7, abi.encode(_config(SOFT, CAP)));
        _gasOfBid(250_000);
        console.log("A1-A6 with the band, and S7, a dominated bid:", _gasOfBid(250_000));
    }

    // ------------------------------------------------------------------
    // Spec section 7: the collusive transfer
    // ------------------------------------------------------------------

    /// @dev A3T allows a SELL down to 0.072 (feed-in less 10 %). The agent
    ///      sells 5 kWh at 0.0721 again and again, to a colluder: each sale
    ///      inside the band, each 0.0079 per kWh below feed-in, 39,500 given
    ///      away. Returns how many of 30 sales were placed.
    function _transfer() internal returns (uint256 placed) {
        StaticOrderPolicy a3t = new StaticOrderPolicy(address(gate));
        StaticOrderPolicy.Config memory c;
        c.maxQtyWh = 50_000;
        c.maxValue = type(uint64).max;
        c.sellFloor = 1_000;
        c.buyCeiling = 2_500_000;
        c.horizonSeconds = 3 days;
        c.ratedPowerW = 200_000;
        c.tariffBand = true;
        c.buyMarkupBps = 1_000;
        c.sellDiscountBps = 1_000;
        _addPolicy(a3t, keccak256("A3T"), abi.encode(c));
        for (uint256 i = 0; i < 30; ++i) {
            if (_place(Side.SELL, _slot(), 5_000, 72_100) != bytes32(0)) ++placed;
        }
    }

    /// @dev 25 sales give away 987,500; the 26th would pass the 1 USD cap.
    function test_collusiveTransfer_isBlockedByS7() public {
        assertEq(_transfer(), 25);
        assertEq(_used(), 987_500);
    }

    function test_collusiveTransfer_passesUnderA3TAlone() public {
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (s7, S7)));
        vm.warp(block.timestamp + 24 hours);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (s7, S7)));
        _postTariff(RETAIL, FEED_IN);
        assertEq(_transfer(), 30, "every sale inside A3T's band");
    }
}
