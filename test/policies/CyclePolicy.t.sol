// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyFixture} from "./PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {CyclePolicy} from "../../contracts/policies/CyclePolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {Side, ConfigChange, CheckResult, Verdict} from "../../contracts/gate/GateTypes.sol";

/// @notice S4, battery cycles per window (spec 6.5), through the gate on the
///         mock market. A 5 kWh battery allowed one full cycle a day: 5,000 Wh
///         drawn from the cells over a sliding 24 hours, flagged above 4,000.
///         Sales count over a horizon of 16 half-hour slots; 95 % discharge
///         efficiency, so 1,400 Wh sold draws 1,474.
contract CyclePolicyTest is PolicyFixture, OracleFixture {
    bytes32 internal constant S4 = keccak256("S4");
    uint64 internal constant CAP_WH = 5_000;
    uint64 internal constant SOFT_WH = 4_000;

    CyclePolicy internal s4;
    OracleVerifier internal oracle;

    event Discharged(address indexed account, bytes32 indexed policyId, uint64 fromWh, uint64 toWh);

    function setUp() public override {
        super.setUp();
        oracle = gate.oracle();
        s4 = new CyclePolicy(address(gate));
        vm.startPrank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.BMS, bmsSigner, SLOT_SECONDS)));
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.PV_FORECAST, pvSigner, 3600)));
        vm.stopPrank();
        _addPolicy(s4, S4, abi.encode(_config()));
    }

    function _config() internal pure returns (CyclePolicy.Config memory) {
        return CyclePolicy.Config({
            softWh: SOFT_WH,
            window: WindowLib.Config({
                kind: WindowLib.Kind.SLIDING, step: SLOT_SECONDS, buckets: 48, anchor: 0, cap: CAP_WH, rate: 0, initial: 0
            }),
            horizonSlots: 16,
            pvCreditBps: 10_000,
            etaDischargeBps: 9_500
        });
    }

    function _battery(uint64 odometerWh) internal view returns (SignedReading[] memory one) {
        one = new SignedReading[](1);
        uint64 start = market.slotStart(market.currentSlot());
        one[0] = _signBms(oracle, BMS_KEY, _bms(address(account), start, 3_000, odometerWh));
    }

    function _submitWith(bytes memory marketCall, SignedReading[] memory readings) internal {
        vm.prank(agent);
        account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (address(market), marketCall, readings)));
    }

    function _sellWith(uint32 slot, uint64 qtyWh, SignedReading[] memory readings) internal {
        _submitWith(_placeCall(Side.SELL, slot, qtyWh, PRICE), readings);
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(s4));
        return all[all.length - 1];
    }

    function _nextSlot() internal {
        vm.warp(block.timestamp + SLOT_SECONDS);
    }

    // ------------------------------------------------------------------
    // The budget of cycles
    // ------------------------------------------------------------------

    function test_aSaleWithinTheBudgetPasses() public {
        vm.recordLogs();
        _sellWith(4, 1_400, _battery(10_000));
        CheckResult memory r = _lastResult();
        assertEq(r.valueBefore, 0);
        assertEq(r.valueAfter, 1_474);
        assertEq(r.hard, CAP_WH);
        assertEq(market.orderCount(), 1);
    }

    /// @dev Spec step 5: excess cycling is blocked. The battery has already
    ///      discharged 2,000 Wh today; the sales placed would draw 2,948 more,
    ///      so 4,948 of the 5,000: flagged. One more sale, of 100 Wh, would
    ///      take it to 5,054.
    function test_excessCyclingIsBlocked() public {
        _sellWith(4, 1_400, _battery(10_000)); // the policy's odometer starts at 10,000
        _nextSlot();
        vm.recordLogs();
        _sellWith(5, 1_400, _battery(12_000));
        CheckResult memory r = _lastResult();
        assertEq(r.valueBefore, 2_000 + 1_474);
        assertEq(r.valueAfter, 2_000 + 1_474 + 1_474);
        assertEq(uint8(r.verdict), uint8(Verdict.FLAG));
        assertEq(market.orderCount(), 2);

        _sellWith(6, 100, new SignedReading[](0));
        assertEq(market.orderCount(), 2);
        assertEq(_lastResult().valueAfter, 5_054);
    }

    function test_theDischargeIsCountedAtTheNextAcceptedSubmission() public {
        _sellWith(4, 100, _battery(10_000));
        _nextSlot();
        vm.expectEmit(address(s4));
        emit Discharged(address(account), S4, 10_000, 10_700);
        _submitWith(_placeCall(Side.BUY, 6, 100, PRICE), _battery(10_700));
        (uint64 used,) = s4.usedOf(address(account), S4);
        assertEq(used, 700);
    }

    function test_whatWasDischargedLeavesTheWindowAfterADay() public {
        _sellWith(4, 100, _battery(10_000));
        _nextSlot();
        _submitWith(_placeCall(Side.BUY, 6, 100, PRICE), _battery(14_500)); // 4,500 discharged, counted now
        assertEq(market.orderCount(), 2);
        _sellWith(8, 1_000, new SignedReading[](0)); // 4,500 + 106 + 1,053 > 5,000
        assertEq(market.orderCount(), 2);

        vm.warp(block.timestamp + 24 hours);
        _sellWith(market.currentSlot() + 4, 1_000, _battery(14_500));
        assertEq(market.orderCount(), 3);
    }

    function test_thePVCreditNetsThePending() public {
        uint64[] memory pv = new uint64[](16);
        pv[5] = 1_000;
        oracle.accept(_signPv(oracle, PV_KEY, _forecast(address(account), uint64(block.timestamp), GENESIS, pv)));
        vm.recordLogs();
        _sellWith(5, 1_400, _battery(0));
        assertEq(_lastResult().valueAfter, 422); // 400 beyond the PV, over 95 %
    }

    // ------------------------------------------------------------------
    // What adds no cycling, and what cannot be judged
    // ------------------------------------------------------------------

    function test_aBidIsNeverJudgedAndNeedsNoReading() public {
        _submitWith(_placeCall(Side.BUY, 4, 1_000, PRICE), new SignedReading[](0));
        assertEq(market.orderCount(), 1);
    }

    function test_aCancellationPassesEvenOverTheCap() public {
        _sellWith(4, 1_400, _battery(10_000));
        bytes32 sale = bytes32(market.orderCount());
        _nextSlot();
        // The house alone has discharged 6,000 Wh: over the cap already.
        _submitWith(abi.encodeCall(MockEnergyMarket.cancelOrder, (sale)), _battery(16_000));
        assertFalse(market.isOpen(sale));
    }

    function test_overTheCapAnyFurtherSaleIsRefused() public {
        _sellWith(4, 100, _battery(10_000));
        _nextSlot();
        _submitWith(_placeCall(Side.BUY, 6, 100, PRICE), _battery(16_000));
        _sellWith(8, 1, new SignedReading[](0));
        assertEq(market.orderCount(), 2);
    }

    function test_aSaleWithoutAFreshReadingIsRefused() public {
        vm.recordLogs();
        _sellWith(4, 100, new SignedReading[](0));
        assertEq(market.orderCount(), 0);
        assertEq(_lastResult().valueAfter, type(uint256).max);
    }

    function test_aSaleBeyondTheHorizonIsRefused() public {
        _sellWith(16, 100, _battery(0));
        assertEq(market.orderCount(), 0);
        _sellWith(15, 100, new SignedReading[](0));
        assertEq(market.orderCount(), 1);
    }

    function test_aNewBatteryOdometerStartsAgainWithoutCounting() public {
        _sellWith(4, 100, _battery(50_000));
        // A new BMS: its odometer starts near zero.
        vm.prank(owner);
        account.execute(
            address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.BMS, vm.addr(OTHER_KEY), SLOT_SECONDS))
        );
        _nextSlot();
        SignedReading[] memory fresh = new SignedReading[](1);
        fresh[0] = _signBms(oracle, OTHER_KEY, _bms(address(account), market.slotStart(market.currentSlot()), 3_000, 300));
        _submitWith(_placeCall(Side.BUY, 6, 100, PRICE), fresh);
        (uint64 used,) = s4.usedOf(address(account), S4);
        assertEq(used, 0);
        assertEq(s4.instanceOf(address(account), S4).lastOdometerWh, 300);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_malformedConfigurationsAreInvalid() public view {
        CyclePolicy.Config[5] memory bad = [_config(), _config(), _config(), _config(), _config()];
        bad[0].softWh = CAP_WH + 1;
        bad[1].horizonSlots = 0;
        bad[2].horizonSlots = 97;
        bad[3].etaDischargeBps = 0;
        bad[4].window.buckets = 0;
        for (uint256 i = 0; i < bad.length; ++i) {
            assertEq(uint8(s4.classifyConfig(address(account), S4, abi.encode(bad[i]))), uint8(ConfigChange.INVALID));
        }
    }

    function test_whatLoosensWidensAndWhatTightensTightens() public view {
        CyclePolicy.Config[6] memory looser = [_config(), _config(), _config(), _config(), _config(), _config()];
        looser[0].window.cap = CAP_WH + 1;
        looser[1].softWh = SOFT_WH + 1;
        looser[2].window.buckets = 47; // another window shape
        looser[3].horizonSlots = 17;
        looser[4].etaDischargeBps = 9_600;
        looser[5].window.step = 900;
        for (uint256 i = 0; i < looser.length; ++i) {
            assertEq(uint8(s4.classifyConfig(address(account), S4, abi.encode(looser[i]))), uint8(ConfigChange.WIDEN));
        }
        CyclePolicy.Config memory tighter = _config();
        tighter.window.cap = 4_500;
        tighter.softWh = 3_000;
        tighter.etaDischargeBps = 9_000;
        tighter.pvCreditBps = 5_000;
        assertEq(uint8(s4.classifyConfig(address(account), S4, abi.encode(tighter))), uint8(ConfigChange.TIGHTEN));
    }

    function test_onlyTheGateConfiguresAndCommits() public {
        vm.expectRevert();
        s4.configure(address(account), S4, abi.encode(_config()));
        vm.expectRevert();
        s4.deconfigure(address(account), S4);
    }
}
