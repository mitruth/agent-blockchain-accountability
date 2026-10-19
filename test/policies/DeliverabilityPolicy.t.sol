// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyFixture} from "./PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {DeliverabilityPolicy} from "../../contracts/policies/DeliverabilityPolicy.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {console} from "forge-std/console.sol";
import {Side, Order, OrderKind, ConfigChange, CheckResult, CheckContext} from "../../contracts/gate/GateTypes.sol";

/// @notice S3, deliverability (spec 6.4), through the gate on the mock market.
///
/// The battery is home_01's as the honest arms ran it: 5 kWh, 3 kW both ways,
/// 95 % each way, 10 % to 100 %. Slots are 30 minutes, so 1.5 kWh a slot at
/// most. The horizon is 16 slots from the battery reading, slots 0 to 15; it
/// is 09:00, slot 0, and trading in a slot closes an hour before it starts.
contract DeliverabilityPolicyTest is PolicyFixture, OracleFixture {
    bytes32 internal constant S3 = keccak256("S3");
    uint16 internal constant K = 16;

    DeliverabilityPolicy internal s3;
    OracleVerifier internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = gate.oracle();
        s3 = new DeliverabilityPolicy(address(gate));
        vm.startPrank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.BMS, bmsSigner, SLOT_SECONDS)));
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.PV_FORECAST, pvSigner, 3600)));
        vm.stopPrank();
        _addPolicy(s3, S3, abi.encode(_config()));
    }

    function _config() internal pure returns (DeliverabilityPolicy.Config memory) {
        return DeliverabilityPolicy.Config({
            horizonSlots: K,
            capacityWh: 5_000,
            socMinBps: 1_000,
            socMaxBps: 10_000,
            chargePowerW: 3_000,
            dischargePowerW: 3_000,
            etaChargeBps: 9_500,
            etaDischargeBps: 9_500,
            pvCreditBps: 10_000,
            reserveLoadWh: 0
        });
    }

    // --- readings -----------------------------------------------------------

    function _slotStartNow() internal view returns (uint64) {
        return market.slotStart(market.currentSlot());
    }

    /// @dev The battery at the start of the current slot, signed by its BMS.
    function _battery(uint64 socWh) internal view returns (SignedReading[] memory one) {
        one = new SignedReading[](1);
        one[0] = _signBms(oracle, BMS_KEY, _bms(address(account), _slotStartNow(), socWh, 0));
    }

    /// @dev Post a forecast from the current slot on: `pvWh` per slot.
    function _forecastNow(uint64[] memory pvWh) internal {
        oracle.accept(_signPv(oracle, PV_KEY, _forecast(address(account), uint64(block.timestamp), _slotStartNow(), pvWh)));
    }

    function _pvAt(uint256 index, uint64 wh) internal pure returns (uint64[] memory pvWh) {
        pvWh = new uint64[](K);
        pvWh[index] = wh;
    }

    // --- orders -------------------------------------------------------------

    function _submitWith(bytes memory marketCall, SignedReading[] memory readings) internal returns (bytes32) {
        vm.prank(agent);
        bytes memory result =
            account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (address(market), marketCall, readings)));
        return result.length == 32 ? abi.decode(result, (bytes32)) : bytes32(0);
    }

    function _sell(uint32 slot, uint64 qtyWh) internal returns (bytes32) {
        return _place(Side.SELL, slot, qtyWh, PRICE);
    }

    function _bid(uint32 slot, uint64 qtyWh) internal returns (bytes32) {
        return _place(Side.BUY, slot, qtyWh, PRICE);
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(s3));
        return all[all.length - 1];
    }

    // ------------------------------------------------------------------
    // The floor: what was sold must be deliverable
    // ------------------------------------------------------------------

    function test_aSaleTheBatteryCanDeliverPasses() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        assertEq(market.orderCount(), 1);
    }

    /// @dev Spec step 5: cross-slot over-commitment is blocked. Each sale fits
    ///      the battery and its power on its own; the second sells energy the
    ///      first already took. 3,000 Wh stored, 500 the floor: 1,400 Wh to the
    ///      house draws 1,474 from the cells, twice is 2,948.
    function test_crossSlotOverCommitmentIsBlocked() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        vm.recordLogs();
        assertEq(_sell(5, 1_400), bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(r.valueBefore, 0);
        assertEq(r.valueAfter, 448); // 3,000 - 1,474 - 1,474 = 52, 448 short of 500
        assertEq(market.orderCount(), 1);
    }

    /// @dev Where the second sale falls in the horizon does not matter: the
    ///      first took the energy. 1,526 Wh are left after slot 4; 975 Wh to
    ///      the house draws 1,027, 970 draws 1,022.
    function test_theSameSaleInALaterSlotIsBlockedToo() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        assertEq(_sell(15, 1_400), bytes32(0));
        assertEq(_sell(15, 975), bytes32(0));
        assertTrue(_sell(15, 970) != bytes32(0));
    }

    function test_theForecastPVMakesRoom() public {
        _forecastNow(_pvAt(5, 1_000));
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        // Slot 5: 1,000 Wh of PV against 1,400 sold draws 422 from the cells.
        assertTrue(_sell(5, 1_400) != bytes32(0));
    }

    function test_onlyTheCreditedShareOfThePVCounts() public {
        DeliverabilityPolicy.Config memory c = _config();
        c.pvCreditBps = 0;
        _asAccount(abi.encodeCall(gate.setConfig, (s3, S3, abi.encode(c))));
        _forecastNow(_pvAt(5, 1_000));
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        assertEq(_sell(5, 1_400), bytes32(0));
    }

    /// @dev Spec 9.1, phantom-buy justification (D3): an unfilled bid does not
    ///      count, so it cannot justify a sale. Once filled, it does.
    function test_anUnfilledBidCannotJustifyASale() public {
        _submitWith(_placeCall(Side.BUY, 4, 1_500, PRICE), _battery(3_000));
        bytes32 bid = bytes32(market.orderCount());
        _sell(4, 1_400);
        assertEq(_sell(5, 1_400), bytes32(0));

        vm.prank(operator);
        market.fill(bid, 1_000, PRICE);
        _reconcile(bid);
        // Slot 4 now nets -400 to the house: 422 from the cells.
        assertTrue(_sell(5, 1_400) != bytes32(0));
    }

    // ------------------------------------------------------------------
    // The power limits and the ceiling
    // ------------------------------------------------------------------

    function test_aSaleBeyondTheDischargePowerIsBlocked() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_501, PRICE), _battery(5_000));
        assertEq(market.orderCount(), 0);
        _sell(4, 1_500);
        assertEq(market.orderCount(), 1);
    }

    /// @dev The ledger's sale in slot 4 and the new one there share the
    ///      slot's 1,500 Wh of discharge power.
    function test_aSecondSaleInTheSameSlotCountsTheFirst() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_500, PRICE), _battery(5_000));
        assertEq(_sell(4, 100), bytes32(0));
        assertTrue(_sell(5, 100) != bytes32(0));
    }

    function test_PVRaisesTheDischargeLimitOfItsSlot() public {
        _forecastNow(_pvAt(4, 200));
        _submitWith(_placeCall(Side.SELL, 4, 1_700, PRICE), _battery(5_000));
        assertEq(market.orderCount(), 1);
    }

    function test_aBidBeyondTheChargePowerIsBlocked() public {
        _submitWith(_placeCall(Side.BUY, 4, 1_501, PRICE), _battery(1_000));
        assertEq(market.orderCount(), 0);
        _bid(4, 1_500);
        assertEq(market.orderCount(), 1);
    }

    function test_bidsThatWouldOverfillTheBatteryAreBlocked() public {
        // 4,500 stored: 500 Wh bought stores 475, 1,000 would store 950.
        _submitWith(_placeCall(Side.BUY, 4, 500, PRICE), _battery(4_500));
        assertEq(market.orderCount(), 1);
        vm.recordLogs();
        _bid(6, 100);
        assertEq(market.orderCount(), 1);
        assertEq(_lastResult().valueAfter, 70); // 4,975 + 95 = 5,070
    }

    function test_PVAloneNeverCausesARejection() public {
        _forecastNow(_pvAt(4, 1_000));
        _submitWith(_placeCall(Side.SELL, 8, 100, PRICE), _battery(5_000));
        assertEq(market.orderCount(), 1);
    }

    /// @dev A forecast past its maximum age gives no credit: issued at slot 0,
    ///      it is stale by slot 3, and the second sale needs its PV.
    function test_aStaleForecastGivesNoCredit() public {
        _forecastNow(_pvAt(7, 1_000));
        vm.warp(block.timestamp + 3 * SLOT_SECONDS);
        _submitWith(_placeCall(Side.SELL, 6, 1_400, PRICE), _battery(3_000));
        assertEq(market.orderCount(), 1);
        assertEq(_sell(7, 1_400), bytes32(0));
    }

    /// @dev A full battery cannot store the PV of slot 4: it is spilled, and
    ///      gives no room for later sales. Three sales of 1,500 draw 4,737,
    ///      more than the 4,500 above the floor.
    function test_PVBeyondAFullBatteryIsSpilled() public {
        _forecastNow(_pvAt(4, 2_000));
        _submitWith(_placeCall(Side.SELL, 6, 1_500, PRICE), _battery(5_000));
        _sell(7, 1_500);
        assertEq(_sell(8, 1_500), bytes32(0));
        assertEq(market.orderCount(), 2);
    }

    // ------------------------------------------------------------------
    // The reserve load
    // ------------------------------------------------------------------

    /// @dev 100 Wh a slot kept for the house draws 106 from the cells, 1,696
    ///      over the horizon: 3,000 stored leaves 804 above the floor. Selling
    ///      764 more in slot 4 makes that slot draw 910 instead of 106, which
    ///      uses the 804 exactly.
    function test_theReserveLoadStaysCovered() public {
        DeliverabilityPolicy.Config memory c = _config();
        c.reserveLoadWh = 100;
        _asAccount(abi.encodeCall(gate.setConfig, (s3, S3, abi.encode(c))));
        _submitWith(_placeCall(Side.SELL, 4, 765, PRICE), _battery(3_000));
        assertEq(market.orderCount(), 0);
        _sell(4, 764);
        assertEq(market.orderCount(), 1);
        assertEq(_sell(5, 1), bytes32(0));
    }

    // ------------------------------------------------------------------
    // What only reduces exposure always passes (D10)
    // ------------------------------------------------------------------

    function test_aCancellationAlwaysPasses() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        bytes32 sale = bytes32(market.orderCount());
        // The battery is found nearly empty, and no reading is fresh any more.
        vm.warp(block.timestamp + SLOT_SECONDS);
        _submitWith(abi.encodeCall(MockEnergyMarket.cancelOrder, (sale)), _battery(600));
        assertFalse(market.isOpen(sale));
    }

    function test_aCancellationPassesWithNoReadingAtAll() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        bytes32 sale = bytes32(market.orderCount());
        vm.warp(block.timestamp + SLOT_SECONDS + 1);
        _cancel(sale);
        assertFalse(market.isOpen(sale));
    }

    function test_aSmallerModificationPassesEvenShort() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        bytes32 sale = bytes32(market.orderCount());
        _sell(5, 900);
        // Next slot: the battery has less than expected, so the plan is short.
        vm.warp(block.timestamp + SLOT_SECONDS);
        SignedReading[] memory low = _battery(2_000);
        vm.recordLogs();
        _submitWith(abi.encodeCall(MockEnergyMarket.modifyOrder, (sale, 4, 1_200, PRICE)), low);
        CheckResult memory r = _lastResult();
        assertGt(r.valueAfter, 0);
        assertLt(r.valueAfter, r.valueBefore);
        assertFalse(market.isOpen(sale));
    }

    function test_aBidPassesWhileTheFloorIsShort() public {
        _submitWith(_placeCall(Side.SELL, 4, 1_400, PRICE), _battery(3_000));
        _sell(5, 900);
        vm.warp(block.timestamp + SLOT_SECONDS);
        _submitWith(_placeCall(Side.BUY, 8, 500, PRICE), _battery(2_000));
        assertEq(market.orderCount(), 3); // a bid does not deepen the shortfall
        assertEq(_sell(9, 1), bytes32(0)); // a sale does
    }

    // ------------------------------------------------------------------
    // What cannot be judged is refused
    // ------------------------------------------------------------------

    function test_withoutAFreshReadingAPlacementIsRefused() public {
        vm.recordLogs();
        _sell(4, 100);
        assertEq(market.orderCount(), 0);
        assertEq(_lastResult().valueAfter, type(uint256).max);
    }

    function test_aReadingGoneStaleNoLongerServes() public {
        _submitWith(_placeCall(Side.SELL, 4, 100, PRICE), _battery(3_000));
        vm.warp(block.timestamp + SLOT_SECONDS + 1);
        _sell(6, 100);
        assertEq(market.orderCount(), 1);
    }

    function test_aSlotBeyondTheHorizonIsRefused() public {
        _submitWith(_placeCall(Side.SELL, K, 100, PRICE), _battery(3_000));
        assertEq(market.orderCount(), 0);
        _sell(K - 1, 100);
        assertEq(market.orderCount(), 1);
    }

    function test_theHorizonMovesWithTheReading() public {
        _submitWith(_placeCall(Side.SELL, K - 1, 100, PRICE), _battery(3_000));
        vm.warp(block.timestamp + SLOT_SECONDS);
        _submitWith(_placeCall(Side.SELL, K, 100, PRICE), _battery(3_000));
        assertEq(market.orderCount(), 2);
    }

    // ------------------------------------------------------------------
    // An independent bound, fuzzed
    // ------------------------------------------------------------------

    /// @dev With no PV, no reserve and no bids, whatever sequence of sales the
    ///      agent tries, what the executed ones draw from the cells never
    ///      exceeds the energy above the floor.
    function testFuzz_executedSalesNeverOverdrawTheBattery(uint64 socWh, uint256 seed) public {
        socWh = uint64(bound(socWh, 500, 5_000));
        _submitWith(_placeCall(Side.SELL, 3, 1, PRICE), _battery(socWh));
        // A lower bound on what the executed sales draw: each rounded down,
        // where the policy rounds each slot's total up.
        uint256 drawn = market.orderCount() == 1 ? 1 : 0;
        for (uint256 i = 0; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint32 slot = uint32(3 + (seed % (K - 3)));
            uint64 qty = uint64(1 + ((seed >> 64) % 1_500));
            uint256 before = market.orderCount();
            _sell(slot, qty);
            if (market.orderCount() > before) drawn += (uint256(qty) * 10_000) / 9_500;
            assertLe(drawn, uint256(socWh) - 500);
        }
    }

    // ------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------

    /// @dev The check alone, for one sale, at four horizons: O(k). The step
    ///      5.6 report measures whole submissions.
    function test_gasOfTheCheckGrowsWithTheHorizon() public {
        oracle.accept(_battery(3_000)[0]);
        _forecastNow(new uint64[](96));
        Order[] memory legs = new Order[](1);
        legs[0] = Order({
            kind: OrderKind.PLACE, side: Side.SELL, slot: 4, qtyWh: 100, price: PRICE, value: 25, orderId: bytes32(0)
        });
        CheckContext memory ctx = CheckContext({
            market: address(market), decoder: address(decoder), time: uint64(block.timestamp), oracle: address(oracle)
        });
        uint16[4] memory horizons = [uint16(8), 16, 48, 96];
        for (uint256 i = 0; i < horizons.length; ++i) {
            bytes32 id = keccak256(abi.encode("k", horizons[i]));
            DeliverabilityPolicy.Config memory c = _config();
            c.horizonSlots = horizons[i];
            _addPolicy(s3, id, abi.encode(c));
            uint256 used = gasleft();
            s3.check(address(account), id, legs, ctx);
            used -= gasleft();
            console.log("S3 check, k =", horizons[i], "gas:", used);
        }
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_malformedConfigurationsAreInvalid() public view {
        DeliverabilityPolicy.Config[6] memory bad;
        for (uint256 i = 0; i < bad.length; ++i) {
            bad[i] = _config();
        }
        bad[0].horizonSlots = 0;
        bad[1].horizonSlots = 97;
        bad[2].capacityWh = 0;
        bad[3].socMinBps = 6_000;
        bad[3].socMaxBps = 5_000;
        bad[4].etaDischargeBps = 0;
        bad[5].pvCreditBps = 10_001;
        for (uint256 i = 0; i < bad.length; ++i) {
            assertEq(
                uint8(s3.classifyConfig(address(account), S3, abi.encode(bad[i]))), uint8(ConfigChange.INVALID)
            );
        }
        assertEq(uint8(s3.classifyConfig(address(account), S3, hex"00")), uint8(ConfigChange.INVALID));
    }

    /// @dev From a configuration with room on every side, each parameter made
    ///      looser on its own is a widening, and so is another horizon.
    function test_whatLoosensWidensAndWhatTightensTightens() public {
        DeliverabilityPolicy.Config memory base = _config();
        base.capacityWh = 4_000;
        base.socMinBps = 2_000;
        base.socMaxBps = 9_000;
        base.chargePowerW = 2_000;
        base.dischargePowerW = 2_000;
        base.etaChargeBps = 9_000;
        base.etaDischargeBps = 9_000;
        base.pvCreditBps = 5_000;
        base.reserveLoadWh = 50;
        _asAccount(abi.encodeCall(gate.setConfig, (s3, S3, abi.encode(base))));

        DeliverabilityPolicy.Config[11] memory looser;
        for (uint256 i = 0; i < looser.length; ++i) {
            looser[i] = _copy(base);
        }
        looser[0].horizonSlots = K - 1;
        looser[1].horizonSlots = K + 1;
        looser[2].capacityWh = 4_001;
        looser[3].socMinBps = 1_999;
        looser[4].socMaxBps = 9_001;
        looser[5].chargePowerW = 2_001;
        looser[6].dischargePowerW = 2_001;
        looser[7].etaChargeBps = 9_001;
        looser[8].etaDischargeBps = 9_001;
        looser[9].pvCreditBps = 5_001;
        looser[10].reserveLoadWh = 49;
        for (uint256 i = 0; i < looser.length; ++i) {
            assertEq(
                uint8(s3.classifyConfig(address(account), S3, abi.encode(looser[i]))), uint8(ConfigChange.WIDEN)
            );
        }

        DeliverabilityPolicy.Config memory tighter = _copy(base);
        tighter.capacityWh = 3_999;
        tighter.socMinBps = 2_001;
        tighter.socMaxBps = 8_999;
        tighter.chargePowerW = 1_999;
        tighter.dischargePowerW = 1_999;
        tighter.etaChargeBps = 8_999;
        tighter.etaDischargeBps = 8_999;
        tighter.pvCreditBps = 4_999;
        tighter.reserveLoadWh = 51;
        assertEq(uint8(s3.classifyConfig(address(account), S3, abi.encode(tighter))), uint8(ConfigChange.TIGHTEN));
        assertEq(uint8(s3.classifyConfig(address(account), S3, abi.encode(base))), uint8(ConfigChange.TIGHTEN));
    }

    /// @dev A struct assigned in memory is the same struct: copy it.
    function _copy(DeliverabilityPolicy.Config memory c) internal pure returns (DeliverabilityPolicy.Config memory) {
        return abi.decode(abi.encode(c), (DeliverabilityPolicy.Config));
    }

    function test_lessPVCreditOrMoreReserveTightens() public view {
        DeliverabilityPolicy.Config memory c = _config();
        c.pvCreditBps = 9_000;
        assertEq(uint8(s3.classifyConfig(address(account), S3, abi.encode(c))), uint8(ConfigChange.TIGHTEN));
        c = _config();
        c.reserveLoadWh = 1;
        assertEq(uint8(s3.classifyConfig(address(account), S3, abi.encode(c))), uint8(ConfigChange.TIGHTEN));
    }

    function test_onlyTheGateChangesTheConfiguration() public {
        vm.expectRevert();
        s3.configure(address(account), S3, abi.encode(_config()));
    }
}
