// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Test.sol";
import {PolicyFixture} from "./PolicyFixture.sol";
import {StaticOrderPolicy} from "../../contracts/policies/StaticOrderPolicy.sol";
import {PolicyBase} from "../../contracts/policies/PolicyBase.sol";
import {
    Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release
} from "../../contracts/gate/GateTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";

/// Step 4.3: the per-action bounds A1 to A4 and A6 (spec 6.1), each at its
/// edge, then through the gate.
///
/// The default configuration: at most 2000 Wh and 600,000 units per order;
/// SELL at no less than 0.10, BUY at no more than 0.30 per kWh; BUY blocked
/// for slots starting at 14:00 UTC; slots up to 24 hours ahead.
contract StaticOrderPolicyTest is PolicyFixture {
    bytes32 internal constant ID = keccak256("static");
    uint64 internal constant FLOOR = 100_000;
    uint64 internal constant CEILING = 300_000;

    StaticOrderPolicy internal policy;

    function setUp() public override {
        super.setUp();
        policy = new StaticOrderPolicy(address(gate));
        _addPolicy(policy, ID, abi.encode(_config()));
    }

    function _config() internal pure returns (StaticOrderPolicy.Config memory c) {
        c.maxQtyWh = 2000;
        c.maxValue = 600_000;
        c.sellFloor = FLOOR;
        c.buyCeiling = CEILING;
        c.buyBlockedHours = uint24(1) << 14;
        c.sellBlockedHours = 0;
        c.horizonSeconds = 24 hours;
    }

    /// Slot 12 starts at 15:00 UTC: not blocked for either side.
    uint32 internal constant OPEN_SLOT = 12;

    // ------------------------------------------------------------------
    // Each bound at its edge, through check
    // ------------------------------------------------------------------

    function test_anOrderWithinEveryBoundPasses() public view {
        CheckResult memory r = _check(_buy(OPEN_SLOT, 2000, CEILING));
        assertEq(uint8(r.verdict), uint8(Verdict.EXECUTE));
        assertEq(r.valueAfter, 0);
    }

    function test_A1_quantityIsBoundedInclusively() public view {
        assertEq(_broken(_buy(OPEN_SLOT, 2000, 200_000)), 0);
        assertEq(_broken(_buy(OPEN_SLOT, 2001, 200_000)), policy.A1_QUANTITY());
    }

    /// 2000 Wh at 0.30 per kWh is 600,000 units, the bound; one unit of price
    /// more puts the value over it.
    function test_A2_valueIsBoundedInclusively() public {
        _tighten(2000, 500_000);
        assertEq(_broken(_buy(OPEN_SLOT, 2000, 250_000)), 0);
        assertEq(_broken(_buy(OPEN_SLOT, 2000, 250_001)), policy.A2_VALUE());
    }

    function test_A3_buyAtTheCeilingPassesAndAboveItDoesNot() public view {
        assertEq(_broken(_buy(OPEN_SLOT, 100, CEILING)), 0);
        assertEq(_broken(_buy(OPEN_SLOT, 100, CEILING + 1)), policy.A3_PRICE());
    }

    function test_A3_sellAtTheFloorPassesAndBelowItDoesNot() public view {
        assertEq(_broken(_sell(OPEN_SLOT, 100, FLOOR)), 0);
        assertEq(_broken(_sell(OPEN_SLOT, 100, FLOOR - 1)), policy.A3_PRICE());
        // The floor is a SELL bound only; a cheap BUY is fine.
        assertEq(_broken(_buy(OPEN_SLOT, 100, 1)), 0);
    }

    /// BUY is blocked at 14:00 UTC; SELL is not; 14:30 is still hour 14.
    function test_A4_aBlockedHourIsBlockedForItsSideOnly() public view {
        assertEq(_broken(_buy(SLOT, 100, 200_000)), policy.A4_TIME_OF_DAY(), "14:00");
        assertEq(_broken(_buy(SLOT + 1, 100, 200_000)), policy.A4_TIME_OF_DAY(), "14:30");
        assertEq(_broken(_buy(SLOT + 2, 100, 200_000)), 0, "15:00");
        assertEq(_broken(_sell(SLOT, 100, 200_000)), 0, "SELL at 14:00");
    }

    /// The slot must start after now and no later than 24 hours from now.
    function test_A6_theHorizonIsBoundedOnBothSides() public view {
        uint32 last = uint32((24 hours) / SLOT_SECONDS); // starts exactly 24 h after genesis
        assertEq(_broken(_sell(last, 100, 200_000)), 0, "exactly at the horizon");
        assertEq(_broken(_sell(last + 1, 100, 200_000)), policy.A6_HORIZON(), "beyond it");
        assertEq(_broken(_sell(0, 100, 200_000)), policy.A6_HORIZON(), "a slot starting now");
    }

    function test_severalBrokenBoundsAreAllReported() public view {
        uint256 broken = _broken(_buy(SLOT, 5000, CEILING + 1));
        assertEq(broken, policy.A1_QUANTITY() | policy.A2_VALUE() | policy.A3_PRICE() | policy.A4_TIME_OF_DAY());
    }

    /// One bad leg rejects the whole submission; a cancellation is never
    /// checked, so it passes even if every placement would be refused (D10).
    function test_oneBadLegRejectsTheSubmissionAndACancelIsNeverChecked() public view {
        Order[] memory legs = new Order[](2);
        legs[0] = _buy(OPEN_SLOT, 100, 200_000);
        legs[1] = _buy(OPEN_SLOT, 5000, 200_000);
        assertEq(uint8(_checkLegs(legs).verdict), uint8(Verdict.REJECT));

        Order[] memory cancel = new Order[](1);
        cancel[0] = _buy(SLOT, 5000, CEILING + 1);
        cancel[0].kind = OrderKind.CANCEL;
        CheckResult memory r = _checkLegs(cancel);
        assertEq(uint8(r.verdict), uint8(Verdict.EXECUTE));
        assertEq(r.valueAfter, 0);
    }

    // ------------------------------------------------------------------
    // Through the gate
    // ------------------------------------------------------------------

    function test_aBrokenBoundStopsTheOrderAtTheGate() public {
        vm.recordLogs();
        bytes32 refused = _place(Side.BUY, SLOT, 100, 200_000); // 14:00, blocked
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(refused, bytes32(0), "the market never saw it");
        CheckResult[] memory results = _resultsFor(logs, address(policy));
        assertEq(results.length, 1);
        assertEq(results[0].valueAfter, policy.A4_TIME_OF_DAY(), "the log says which bound");

        assertTrue(_place(Side.BUY, OPEN_SLOT, 100, 200_000) != bytes32(0), "a good order goes through");
    }

    /// A modification is checked as its new order; cancelling the same order
    /// is always possible.
    function test_aModificationIsCheckedAsItsNewOrder() public {
        bytes32 orderId = _place(Side.BUY, OPEN_SLOT, 1000, 200_000);

        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (orderId, OPEN_SLOT, 3000, 200_000)));
        assertTrue(market.isOpen(orderId), "a modification beyond A1 is refused");

        _tighten(0, 0); // nothing may be placed any more
        _cancel(orderId);
        assertFalse(market.isOpen(orderId), "the cancellation still passes");
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_everyLooserParameterIsAWidening() public view {
        StaticOrderPolicy.Config[7] memory looser;
        for (uint256 i = 0; i < 7; ++i) looser[i] = _config();
        looser[0].maxQtyWh += 1;
        looser[1].maxValue += 1;
        looser[2].sellFloor -= 1;
        looser[3].buyCeiling += 1;
        looser[4].buyBlockedHours = 0;
        looser[5].horizonSeconds += 1;
        looser[6].maxQtyWh -= 1; // tighter here...
        looser[6].horizonSeconds += 1; // ...but looser there: mixed is a widening
        for (uint256 i = 0; i < 7; ++i) {
            assertEq(uint8(_classify(looser[i])), uint8(ConfigChange.WIDEN));
        }
    }

    function test_everyTighterParameterIsATightening() public view {
        StaticOrderPolicy.Config[7] memory tighter;
        for (uint256 i = 0; i < 7; ++i) tighter[i] = _config();
        tighter[0].maxQtyWh -= 1;
        tighter[1].maxValue -= 1;
        tighter[2].sellFloor += 1;
        tighter[3].buyCeiling -= 1;
        tighter[4].buyBlockedHours |= 1;
        tighter[5].sellBlockedHours |= 1;
        tighter[6].horizonSeconds -= 1;
        for (uint256 i = 0; i < 7; ++i) {
            assertEq(uint8(_classify(tighter[i])), uint8(ConfigChange.TIGHTEN));
        }
        assertEq(uint8(_classify(_config())), uint8(ConfigChange.TIGHTEN), "unchanged");
    }

    function test_aMalformedConfigurationIsInvalid() public view {
        assertEq(uint8(policy.classifyConfig(address(account), ID, hex"1234")), uint8(ConfigChange.INVALID));
    }

    function test_onlyTheGateWritesThePolicy() public {
        Order[] memory none = new Order[](0);
        Release memory release;
        vm.expectRevert(abi.encodeWithSelector(PolicyBase.Policy_OnlyGate.selector, address(this)));
        policy.configure(address(account), ID, abi.encode(_config()));
        vm.expectRevert(abi.encodeWithSelector(PolicyBase.Policy_OnlyGate.selector, address(this)));
        policy.deconfigure(address(account), ID);
        vm.expectRevert(abi.encodeWithSelector(PolicyBase.Policy_OnlyGate.selector, address(this)));
        policy.commit(address(account), ID, none, _ctx());
        vm.expectRevert(abi.encodeWithSelector(PolicyBase.Policy_OnlyGate.selector, address(this)));
        policy.credit(address(account), ID, release);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _tighten(uint64 maxQtyWh, uint64 maxValue) internal {
        StaticOrderPolicy.Config memory c = _config();
        c.maxQtyWh = maxQtyWh;
        c.maxValue = maxValue;
        _asAccount(abi.encodeCall(gate.setConfig, (policy, ID, abi.encode(c))));
    }

    function _classify(StaticOrderPolicy.Config memory c) internal view returns (ConfigChange) {
        return policy.classifyConfig(address(account), ID, abi.encode(c));
    }

    function _leg(Side side, uint32 slot, uint64 qtyWh, uint64 price) internal pure returns (Order memory leg) {
        leg.kind = OrderKind.PLACE;
        leg.side = side;
        leg.slot = slot;
        leg.qtyWh = qtyWh;
        leg.price = price;
        leg.value = uint64((uint256(qtyWh) * price + 999) / 1000);
    }

    function _buy(uint32 slot, uint64 qtyWh, uint64 price) internal pure returns (Order memory) {
        return _leg(Side.BUY, slot, qtyWh, price);
    }

    function _sell(uint32 slot, uint64 qtyWh, uint64 price) internal pure returns (Order memory) {
        return _leg(Side.SELL, slot, qtyWh, price);
    }

    function _ctx() internal view returns (CheckContext memory) {
        return CheckContext({market: address(market), decoder: address(decoder), time: uint64(block.timestamp), oracle: address(0)});
    }

    function _checkLegs(Order[] memory legs) internal view returns (CheckResult memory) {
        return policy.check(address(account), ID, legs, _ctx());
    }

    function _check(Order memory leg) internal view returns (CheckResult memory) {
        Order[] memory legs = new Order[](1);
        legs[0] = leg;
        return _checkLegs(legs);
    }

    function _broken(Order memory leg) internal view returns (uint256) {
        return _check(leg).valueAfter;
    }
}
