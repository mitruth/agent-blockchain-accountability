// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyFixture} from "./PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {StaticOrderPolicy} from "../../contracts/policies/StaticOrderPolicy.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, TariffSchedule} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult} from "../../contracts/gate/GateTypes.sol";

/// @notice A3T, the tariff-relative price band (spec v0.2 section 5), in
///         StaticOrderPolicy, on the mock market. The tariff: retail 0.20 and
///         feed-in 0.08 per kWh in every slot, signed by the retailer. The
///         band: 10 % above retail for a BUY, 10 % below feed-in for a SELL.
///         A3's absolute bounds are wide (0.001 to 2.50), a backstop.
contract TariffBandTest is PolicyFixture, OracleFixture {
    bytes32 internal constant ID = keccak256("A1-A6");
    uint64 internal constant RETAIL = 200_000;
    uint64 internal constant FEED_IN = 80_000;
    uint32 internal constant TARIFF_MAX_AGE = 24 hours;

    StaticOrderPolicy internal policy;
    OracleVerifier internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = gate.oracle();
        policy = new StaticOrderPolicy(address(gate));
        vm.prank(owner);
        account.execute(
            address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.TARIFF, tariffSigner, TARIFF_MAX_AGE))
        );
        _postTariff(RETAIL, FEED_IN);
        _addPolicy(policy, ID, abi.encode(_config(true, 1_000, 1_000)));
    }

    function _config(bool band, uint16 markup, uint16 discount) internal pure returns (StaticOrderPolicy.Config memory c) {
        c.maxQtyWh = 50_000;
        c.maxValue = type(uint64).max;
        c.sellFloor = 1_000;
        c.buyCeiling = 2_500_000;
        c.horizonSeconds = 3 days;
        c.ratedPowerW = 200_000;
        c.tariffBand = band;
        c.buyMarkupBps = markup;
        c.sellDiscountBps = discount;
    }

    function _setConfig(StaticOrderPolicy.Config memory c) internal {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, ID, abi.encode(c))));
    }

    /// @dev The same retail and feed-in for 96 slots from the current slot.
    function _postTariff(uint64 retail, uint64 feedIn) internal {
        uint64[] memory r = new uint64[](96);
        uint64[] memory f = new uint64[](96);
        for (uint256 i = 0; i < 96; ++i) {
            r[i] = retail;
            f[i] = feedIn;
        }
        TariffSchedule memory t = TariffSchedule({
            account: address(account),
            issuedAt: uint64(block.timestamp),
            firstSlotStart: market.slotStart(market.currentSlot()),
            slotSeconds: SLOT_SECONDS,
            retail: r,
            feedIn: f
        });
        oracle.accept(_signTariff(oracle, TARIFF_KEY, t));
    }

    function _leg(Side side, uint64 price) internal pure returns (Order memory leg) {
        leg.kind = OrderKind.PLACE;
        leg.side = side;
        leg.slot = SLOT;
        leg.qtyWh = 1_000;
        leg.price = price;
        leg.value = uint64((uint256(leg.qtyWh) * price + 999) / 1000);
    }

    function _broken(Order memory leg) internal view returns (uint256) {
        Order[] memory legs = new Order[](1);
        legs[0] = leg;
        CheckContext memory ctx = CheckContext({
            market: address(market), decoder: address(decoder), time: uint64(block.timestamp), oracle: address(oracle)
        });
        return policy.check(address(account), ID, legs, ctx).valueAfter;
    }

    function _buy(uint64 price) internal view returns (uint256) {
        return _broken(_leg(Side.BUY, price));
    }

    function _sell(uint64 price) internal view returns (uint256) {
        return _broken(_leg(Side.SELL, price));
    }

    // ------------------------------------------------------------------
    // The band at its edges
    // ------------------------------------------------------------------

    /// @dev 0.20 + 10 % = 0.22: inclusive.
    function test_aBuyMayGoUpToTheBandAboveRetail() public view {
        assertEq(_buy(220_000), 0);
        assertEq(_buy(220_001), policy.A3T_TARIFF_BAND());
        assertEq(_buy(1_000), 0, "far below retail is fine");
    }

    /// @dev 0.08 - 10 % = 0.072: inclusive.
    function test_aSellMayGoDownToTheBandBelowFeedIn() public view {
        assertEq(_sell(72_000), 0);
        assertEq(_sell(71_999), policy.A3T_TARIFF_BAND());
        assertEq(_sell(2_000_000), 0, "far above feed-in is fine");
    }

    /// @dev beta 3.33 % on a retail of 100,001: 103,331.03 exactly, so the BUY
    ///      bound is 103,331 (down). On a feed-in of 100,001: 96,670.97, so the
    ///      SELL bound is 96,671 (up). Both toward the stricter side.
    function test_eachBoundRoundsTowardTheStricterSide() public {
        _postTariffAfter(100_001, 100_001);
        _setConfig(_config(true, 333, 333));
        assertEq(_buy(103_331), 0);
        assertEq(_buy(103_332), policy.A3T_TARIFF_BAND());
        assertEq(_sell(96_671), 0);
        assertEq(_sell(96_670), policy.A3T_TARIFF_BAND());
    }

    /// @dev Each side has its own beta: 5 % above retail for a BUY (0.21),
    ///      20 % below feed-in for a SELL (0.064).
    function test_eachSideHasItsOwnBeta() public {
        _setConfig(_config(true, 500, 1_000));
        _asAccount(abi.encodeCall(gate.addPolicy, (new StaticOrderPolicy(address(gate)), keccak256("asym"), abi.encode(_config(true, 500, 2_000)))));
        StaticOrderPolicy asym = StaticOrderPolicy(address(gate.policiesOf(address(account))[1].policy));
        Order[] memory legs = new Order[](1);
        CheckContext memory ctx = CheckContext({
            market: address(market), decoder: address(decoder), time: uint64(block.timestamp), oracle: address(oracle)
        });
        legs[0] = _leg(Side.BUY, 210_000);
        assertEq(asym.check(address(account), keccak256("asym"), legs, ctx).valueAfter, 0);
        legs[0] = _leg(Side.BUY, 210_001);
        assertEq(asym.check(address(account), keccak256("asym"), legs, ctx).valueAfter, policy.A3T_TARIFF_BAND());
        legs[0] = _leg(Side.SELL, 64_000);
        assertEq(asym.check(address(account), keccak256("asym"), legs, ctx).valueAfter, 0);
        legs[0] = _leg(Side.SELL, 63_999);
        assertEq(asym.check(address(account), keccak256("asym"), legs, ctx).valueAfter, policy.A3T_TARIFF_BAND());
    }

    /// @dev A3's absolute bounds still apply inside the band.
    function test_A3StillAppliesAlongside() public {
        StaticOrderPolicy.Config memory c = _config(true, 1_000, 1_000);
        c.buyCeiling = 210_000;
        _setConfig(c);
        assertEq(_buy(215_000), policy.A3_PRICE(), "inside the band, above A3's ceiling");
    }

    // ------------------------------------------------------------------
    // What cannot be judged is refused
    // ------------------------------------------------------------------

    function test_withoutATariffAPlacementIsRefused() public {
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.TARIFF, address(0), 0)));
        assertEq(_buy(100_000), policy.A3T_TARIFF_BAND());
        assertEq(_sell(100_000), policy.A3T_TARIFF_BAND());
    }

    /// @dev Only A3T's bit is read: a day later the slot is also past A6.
    function test_aStaleTariffJudgesNothing() public {
        uint256 band = policy.A3T_TARIFF_BAND();
        vm.warp(block.timestamp + TARIFF_MAX_AGE);
        assertEq(_buy(100_000) & band, 0, "at the maximum age");
        vm.warp(block.timestamp + 1);
        assertEq(_buy(100_000) & band, band, "one second past it");
    }

    function test_aSlotBeyondTheScheduleIsRefused() public view {
        Order memory leg = _leg(Side.BUY, 100_000);
        leg.slot = 96; // the schedule covers slots 0 to 95
        assertEq(_broken(leg), policy.A3T_TARIFF_BAND());
    }

    /// @dev D10: a cancellation is never checked, tariff or not.
    function test_aCancellationIsNeverChecked() public {
        bytes32 id = _place(Side.BUY, SLOT, 1_000, 210_000);
        assertTrue(id != bytes32(0));
        vm.prank(owner); // no tariff any more
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.TARIFF, address(0), 0)));
        _cancel(id);
        assertFalse(market.isOpen(id), "cancelled");
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_configurationDirections() public view {
        assertEq(uint8(_classify(_config(true, 999, 1_000))), uint8(ConfigChange.TIGHTEN), "a lower markup");
        assertEq(uint8(_classify(_config(true, 1_000, 999))), uint8(ConfigChange.TIGHTEN), "a lower discount");
        assertEq(uint8(_classify(_config(true, 1_001, 1_000))), uint8(ConfigChange.WIDEN), "a higher markup");
        assertEq(uint8(_classify(_config(true, 1_000, 1_001))), uint8(ConfigChange.WIDEN), "a higher discount");
        assertEq(uint8(_classify(_config(false, 1_000, 1_000))), uint8(ConfigChange.WIDEN), "the band off");
        assertEq(uint8(_classify(_config(true, 1_000, 10_001))), uint8(ConfigChange.INVALID), "a discount above 100 %");
        assertEq(uint8(_classify(_config(true, 1_000, 10_000))), uint8(ConfigChange.WIDEN), "100 %: valid, and wider");
    }

    function test_turningTheBandOnIsATightening() public {
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, ID)));
        vm.warp(block.timestamp + 24 hours);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, ID)));
        _addPolicy(policy, ID, abi.encode(_config(false, 1_000, 1_000)));
        assertEq(uint8(_classify(_config(true, 1_000, 1_000))), uint8(ConfigChange.TIGHTEN));
    }

    function _classify(StaticOrderPolicy.Config memory c) internal view returns (ConfigChange) {
        return policy.classifyConfig(address(account), ID, abi.encode(c));
    }

    // ------------------------------------------------------------------
    // Spec section 7: the price walk
    // ------------------------------------------------------------------

    /// @dev Twelve bids, each 3 % above the last, from retail. A per-step
    ///      guard against the agent's own last price would pass every one;
    ///      the band, anchored on the signed tariff, stops the walk at the
    ///      fifth (1.03^4 = 1.126 > 1.10). Returns how many were placed.
    function _walk() internal returns (uint256 placed) {
        uint256 price = RETAIL;
        uint32 slot = market.currentSlot() + 10;
        for (uint256 i = 0; i < 12; ++i) {
            if (_place(Side.BUY, slot, 1_000, uint64(price)) != bytes32(0)) ++placed;
            price = price * 103 / 100;
        }
    }

    function test_priceWalk_isBlockedByA3T() public {
        assertEq(_walk(), 4, "four bids inside the band, then none");
    }

    function test_priceWalk_passesUnderA3Alone() public {
        _setConfig(_config(false, 1_000, 1_000));
        vm.warp(block.timestamp + 24 hours);
        _postTariffAfter(RETAIL, FEED_IN);
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, ID, abi.encode(_config(false, 1_000, 1_000)))));
        assertEq(_walk(), 12, "every bid placed: 0.20 to 0.28, under A3's 2.50");
    }

    /// @dev A new schedule, issued later than the one held.
    function _postTariffAfter(uint64 retail, uint64 feedIn) internal {
        vm.warp(block.timestamp + 1);
        _postTariff(retail, feedIn);
    }
}
