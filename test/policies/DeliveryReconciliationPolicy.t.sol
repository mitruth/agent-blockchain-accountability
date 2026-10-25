// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PolicyFixture} from "./PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {DeliveryReconciliationPolicy} from "../../contracts/policies/DeliveryReconciliationPolicy.sol";
import {DeliverabilityPolicy} from "../../contracts/policies/DeliverabilityPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {GateBase} from "../../contracts/gate/GateBase.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, MeterReading, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {Side, ConfigChange, Verdict, CheckResult} from "../../contracts/gate/GateTypes.sol";

/// @notice S9 through the gate on the mock market, with the account's meter
///         registered on the market's half-hour grid.
///
/// The configuration: k = 100 Wh of slack a slot, an alarm above h = 1,000 Wh;
/// a penalty of 24 h; escalation within 7 days; a slot settles one slot after
/// it ends, and a reading may be missing for 2 h more; level 1 caps sells at
/// 2,500 Wh over a sliding day; 8 slots a call. Slot 10 runs from 14:00 to
/// 14:30, five hours after genesis; it settles at 15:00, and without its
/// reading SELLs stop at 17:00.
abstract contract DeliveryFixture is PolicyFixture, OracleFixture {
    bytes32 internal constant S9 = keccak256("S9");
    uint64 internal constant K_SLACK = 100;
    uint64 internal constant H = 1_000;
    uint64 internal constant H_PEN = 2_500;
    uint32 internal constant LAG = 1_800;
    uint32 internal constant GRACE = 7_200;

    DeliveryReconciliationPolicy internal s9;
    OracleVerifier internal oracle;

    function setUp() public virtual override {
        super.setUp();
        oracle = gate.oracle();
        s9 = new DeliveryReconciliationPolicy(address(gate));
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setMeter, (meterSigner, SLOT_SECONDS)));
        if (_installS9()) _addPolicy(s9, S9, abi.encode(_config()));
    }

    function _installS9() internal pure virtual returns (bool) {
        return true;
    }

    function _config() internal pure returns (DeliveryReconciliationPolicy.Config memory c) {
        c.k = K_SLACK;
        c.h = H;
        c.penaltySeconds = 1 days;
        c.escalationSeconds = 7 days;
        c.settlementLagSeconds = LAG;
        c.graceSeconds = GRACE;
        c.maxProcess = 8;
        c.window = WindowLib.Config({kind: WindowLib.Kind.SLIDING, step: 1800, buckets: 48, anchor: 0, cap: H_PEN, rate: 0, initial: 0});
    }

    /// @dev A sale for `slot`, filled in full and reconciled.
    function _sold(uint32 slot, uint64 qtyWh) internal returns (bytes32 id) {
        id = _place(Side.SELL, slot, qtyWh, PRICE);
        assertTrue(id != bytes32(0), "the sale was placed");
        vm.prank(operator);
        market.fill(id, qtyWh, PRICE);
        _reconcile(id);
    }

    function _meter(uint32 slot, uint64 importWh, uint64 exportWh) internal {
        oracle.accept(
            _signMeter(
                oracle,
                METER_KEY,
                MeterReading({account: address(account), slotStart: market.slotStart(slot), importWh: importWh, exportWh: exportWh})
            )
        );
    }

    /// @dev To the moment `slot` settles: its end plus the lag.
    function _toSettled(uint32 slot) internal {
        vm.warp(market.slotStart(slot) + SLOT_SECONDS + LAG);
    }

    function _poke() internal returns (uint256) {
        return gate.poke(address(account), s9, S9);
    }

    /// @dev Poke until there is nothing left to take in. A poke that never
    ///      gets there (it persists nothing) fails rather than hangs.
    function _catchUp() internal {
        for (uint256 i = 0; i < 500; ++i) {
            if (_poke() == 0) return;
        }
        fail();
    }

    function _state() internal view returns (DeliveryReconciliationPolicy.State memory) {
        return s9.stateOf(address(account), S9);
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(s9));
        return all[all.length - 1];
    }

    /// @dev A slot well ahead of now, still open for trading.
    function _ahead() internal view returns (uint32) {
        return market.currentSlot() + 4;
    }
}

contract DeliveryReconciliationPolicyTest is DeliveryFixture {
    // ------------------------------------------------------------------
    // The arithmetic
    // ------------------------------------------------------------------

    /// @dev 1,000 Wh sold, 400 delivered: s = 600, C = 600 - 100 = 500.
    function test_aShortfallCountsIntoTheCusum() public {
        _sold(10, 1_000);
        _toSettled(10);
        _meter(10, 0, 400);
        _catchUp();
        assertEq(_state().cusum, 500);
    }

    /// @dev Then 1,000 sold and 1,200 delivered: s = 0, C falls by k.
    function test_deliveringInFullLetsTheCusumFall() public {
        _sold(10, 1_000);
        _sold(11, 1_000);
        _toSettled(11);
        _meter(10, 0, 400);
        _meter(11, 0, 1_200);
        _catchUp();
        assertEq(_state().cusum, 400);
    }

    /// @dev Sold 1,000 and imported on net: the shortfall is the whole sale,
    ///      never more. 900 after k.
    function test_theShortfallIsAtMostTheSale() public {
        _sold(10, 1_000);
        _toSettled(10);
        _meter(10, 5_000, 0);
        _catchUp();
        assertEq(_state().cusum, 900);
    }

    /// @dev A slot with nothing sold needs no reading and counts nothing, even
    ///      when the house imports.
    function test_aSlotWithNothingSoldNeedsNoReading() public {
        bytes32 bid = _place(Side.BUY, 10, 2_000, PRICE);
        vm.prank(operator);
        market.fill(bid, 2_000, PRICE);
        _reconcile(bid);
        _toSettled(12);
        _catchUp();
        DeliveryReconciliationPolicy.State memory st = _state();
        assertEq(st.next, 13, "slots 0 to 12 taken in, no reading needed");
        assertEq(st.cusum, 0);
    }

    /// @dev Contracted export is net: 1,000 sold and 600 bought in the slot
    ///      is 400 contracted; 400 delivered is no shortfall.
    function test_contractedExportIsNetOfBuys() public {
        _sold(10, 1_000);
        bytes32 bid = _place(Side.BUY, 10, 600, PRICE);
        vm.prank(operator);
        market.fill(bid, 600, PRICE);
        _reconcile(bid);
        _toSettled(10);
        _meter(10, 0, 400);
        _catchUp();
        assertEq(_state().cusum, 0);
    }

    // ------------------------------------------------------------------
    // When a slot is taken in
    // ------------------------------------------------------------------

    /// @dev Not before it settles: at the second before, slots 0 to 9; at it,
    ///      slot 10.
    function test_aSlotIsTakenInOnceSettled() public {
        _sold(10, 1_000);
        vm.warp(market.slotStart(10) + SLOT_SECONDS + LAG - 1);
        (, uint256 processed,,) = s9.pending(address(account), S9);
        assertEq(processed, 8, "one call takes 8 slots");
        _catchUp();
        assertEq(_state().next, 10, "slot 10 waits for settlement");
        vm.warp(block.timestamp + 1);
        _meter(10, 0, 1_000);
        _catchUp();
        assertEq(_state().next, 11);
    }

    /// @dev A filled sale whose fill the ledger has not booked yet: the slot
    ///      waits, and S9 never takes it as nothing sold.
    function test_anUnreconciledSlotWaits() public {
        bytes32 id = _place(Side.SELL, 10, 1_000, PRICE);
        vm.prank(operator);
        market.fill(id, 1_000, PRICE);
        _toSettled(10);
        _meter(10, 0, 0);
        _catchUp();
        assertEq(_state().next, 10, "waits for the reconcile");
        _reconcile(id);
        _catchUp();
        assertEq(_state().next, 11);
        assertEq(_state().cusum, 900, "the sale counted in full");
    }

    /// @dev At most maxProcess slots a call: 14 settled slots take two pokes.
    function test_maxProcessBoundsOneCall() public {
        _toSettled(13);
        assertEq(_poke(), 8);
        assertEq(_poke(), 6);
        assertEq(_poke(), 0);
        assertEq(_state().next, 14);
    }

    /// @dev A new instance starts at the first slot beginning at or after it:
    ///      the slot in progress, and every slot before, are not its business.
    function test_aNewInstanceStartsAtTheNextSlot() public {
        vm.warp(market.slotStart(3) + 1);
        DeliveryReconciliationPolicy fresh = new DeliveryReconciliationPolicy(address(gate));
        _addPolicy(fresh, keccak256("S9b"), abi.encode(_config()));
        _toSettled(5);
        assertEq(gate.poke(address(account), fresh, keccak256("S9b")), 2, "slots 4 and 5 only");
        assertEq(fresh.stateOf(address(account), keccak256("S9b")).next, 6);
    }

    // ------------------------------------------------------------------
    // Alarms and penalties
    // ------------------------------------------------------------------

    /// @dev Sales of 1,000 for slots 10 to 13, filled. Caught up to slot 9;
    ///      then slots 10 and 11 settle with nothing delivered: C = 900, then
    ///      1,800 > h, an alarm on slot 11.
    function _fourSalesTwoSettled() internal {
        for (uint32 s = 10; s < 14; ++s) _sold(s, 1_000);
        _toSettled(9);
        _catchUp();
        _toSettled(11);
        _meter(10, 0, 0);
        _meter(11, 0, 0);
    }

    function test_anAlarmStartsLevel1() public {
        _fourSalesTwoSettled();
        vm.recordLogs();
        _catchUp();
        DeliveryReconciliationPolicy.State memory st = _state();
        assertEq(st.level, 1);
        assertEq(st.cusum, 0);
        assertEq(st.penaltyUntil, block.timestamp + 1 days);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 alarms;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == DeliveryReconciliationPolicy.DeliveryAlarm.selector) {
                (uint32 slot, uint8 level, uint64 c,) = abi.decode(logs[i].data, (uint32, uint8, uint64, uint64));
                assertEq(slot, 11);
                assertEq(level, 1);
                assertEq(c, 1_800);
                ++alarms;
            }
        }
        assertEq(alarms, 1);
    }

    /// @dev Level 1: sells over the sliding day are capped at 2,500 Wh. With
    ///      4,000 already counted, not even 1 Wh more.
    function test_level1CapsSellingAtH_pen() public {
        _fourSalesTwoSettled();
        _catchUp();
        vm.recordLogs();
        assertEq(_place(Side.SELL, _ahead(), 1, PRICE), bytes32(0));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.REJECT));
    }

    /// @dev Two slots of 600 sold and missed bring C to 1,000: at h, not above
    ///      it, so no alarm. A third of 1,000 raises it, with 2,200 counted.
    ///      H_pen is inclusive: 300 more fits the 2,500, 1 Wh beyond does not.
    ///      A released sale is given back: cancelling the 300 makes room for
    ///      it again.
    function test_level1IsInclusiveAtH_pen() public {
        _sold(10, 600);
        _sold(11, 600);
        _sold(12, 1_000);
        _toSettled(9);
        _catchUp();
        _toSettled(11);
        _meter(10, 0, 0);
        _meter(11, 0, 0);
        _catchUp();
        assertEq(_state().cusum, 1_000);
        assertEq(_state().level, 0, "C at h is not an alarm");
        _toSettled(12);
        _meter(12, 0, 0);
        _catchUp();
        assertEq(_state().level, 1);
        bytes32 last = _place(Side.SELL, _ahead(), 300, PRICE);
        assertTrue(last != bytes32(0), "up to H_pen");
        assertEq(_place(Side.SELL, _ahead(), 1, PRICE), bytes32(0));
        _cancel(last);
        assertTrue(_place(Side.SELL, _ahead(), 300, PRICE) != bytes32(0), "the released 300 given back");
    }

    /// @dev A second alarm while level 1 holds: level 2, no SELL at all; a
    ///      BUY and a cancellation pass (D10).
    function test_aSecondAlarmIsLevel2() public {
        bytes32 open = _place(Side.SELL, 30, 100, PRICE);
        _fourSalesTwoSettled();
        _catchUp();
        _toSettled(13);
        _meter(12, 0, 0);
        _meter(13, 0, 0);
        _catchUp();
        assertEq(s9.levelOf(address(account), S9), 2);
        assertEq(_place(Side.SELL, _ahead(), 1, PRICE), bytes32(0), "no selling");
        assertTrue(_place(Side.BUY, _ahead(), 1_000, PRICE) != bytes32(0), "a buy passes");
        _cancel(open);
        assertFalse(market.isOpen(open), "a cancellation passes");
    }

    /// @dev The penalty ends after T_pen: selling opens again.
    function test_thePenaltyEnds() public {
        _fourSalesTwoSettled();
        _catchUp();
        vm.warp(block.timestamp + 1 days);
        _meter(12, 0, 1_000);
        _meter(13, 0, 1_000);
        _catchUp();
        assertTrue(_place(Side.SELL, _ahead(), 3_000, PRICE) != bytes32(0));
    }

    /// @dev W_esc after an alarm, the level has fallen back: a new alarm is
    ///      level 1 again, not 2.
    function test_theLevelDecays() public {
        _fourSalesTwoSettled();
        _catchUp();
        uint256 alarmAt = block.timestamp;
        _toSettled(13);
        _meter(12, 0, 1_000);
        _meter(13, 0, 1_000);
        _catchUp();
        vm.warp(alarmAt + 7 days);
        assertEq(s9.levelOf(address(account), S9), 0);
        uint32 s = _ahead();
        _sold(s, 1_000);
        _sold(s + 1, 1_000);
        _toSettled(s + 1);
        _meter(s, 0, 0);
        _meter(s + 1, 0, 0);
        _catchUp();
        assertEq(_state().level, 1);
    }

    /// @dev Our reading of the spec: a submission whose processing raises an
    ///      alarm is flagged, and persists the alarm.
    function test_theSubmissionThatFindsTheAlarmIsFlagged() public {
        _fourSalesTwoSettled();
        vm.recordLogs();
        assertTrue(_place(Side.BUY, _ahead(), 100, PRICE) != bytes32(0));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.FLAG));
        assertEq(_state().level, 1, "the alarm persisted with it");
    }

    // ------------------------------------------------------------------
    // Fail closed on a missing reading (D16)
    // ------------------------------------------------------------------

    function test_aMissingReadingStopsSellingAfterGrace() public {
        bytes32 open = _place(Side.SELL, 30, 100, PRICE);
        _sold(10, 1_000);
        _toSettled(9);
        _catchUp();
        vm.warp(market.slotStart(10) + SLOT_SECONDS + LAG + GRACE - 1);
        assertTrue(_place(Side.SELL, _ahead(), 100, PRICE) != bytes32(0), "within grace");
        vm.warp(block.timestamp + 1);
        vm.recordLogs();
        assertEq(_place(Side.SELL, _ahead(), 100, PRICE), bytes32(0), "past grace, no reading");
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.REJECT));
        assertTrue(_place(Side.BUY, _ahead(), 100, PRICE) != bytes32(0), "a buy passes");
        _cancel(open);
        assertFalse(market.isOpen(open), "a cancellation passes");

        _meter(10, 0, 1_000);
        assertTrue(_place(Side.SELL, _ahead(), 100, PRICE) != bytes32(0), "the reading arrived");
    }

    /// @dev A meter on another slot length cannot be read on the grid: as
    ///      missing.
    function test_aMeterOffTheGridCountsAsMissing() public {
        _sold(10, 1_000);
        _toSettled(9);
        _catchUp();
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setMeter, (meterSigner, 3600)));
        vm.warp(market.slotStart(10) + SLOT_SECONDS + LAG + GRACE);
        assertEq(_place(Side.SELL, _ahead(), 100, PRICE), bytes32(0));
    }

    // ------------------------------------------------------------------
    // Persistence, poke, reset
    // ------------------------------------------------------------------

    /// @dev A submission S9 itself rejects persists nothing: the second alarm
    ///      it finds is found again, and persisted, by the next poke.
    function test_aRejectedSubmissionPersistsNothing() public {
        _fourSalesTwoSettled();
        _catchUp();
        _toSettled(13);
        _meter(12, 0, 0);
        _meter(13, 0, 0);
        DeliveryReconciliationPolicy.State memory before = _state();
        assertEq(_place(Side.SELL, _ahead(), 1, PRICE), bytes32(0), "refused");
        DeliveryReconciliationPolicy.State memory after_ = _state();
        assertEq(after_.next, before.next, "pointer unchanged");
        assertEq(after_.level, 1, "level unchanged");
        _catchUp();
        assertEq(_state().level, 2);
    }

    /// @dev Spec 11.6: poke persists an alarm without a market call, whoever
    ///      calls it.
    function test_pokePersistsAnAlarmWithoutAMarketCall() public {
        _fourSalesTwoSettled();
        uint256 orders = market.orderCount();
        vm.prank(makeAddr("anyone"));
        gate.poke(address(account), s9, S9);
        assertEq(_state().level, 1);
        assertEq(market.orderCount(), orders);
    }

    function test_pokeNeedsAnInstalledInstance() public {
        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_NoSuchPolicy.selector, address(account), address(s9), keccak256("x"))
        );
        gate.poke(address(account), s9, keccak256("x"));
    }

    /// @dev The owner resets: an alarm raised (level 1), and slot 12 sold with
    ///      no reading past its grace (blocked). After the reset: no penalty,
    ///      C at 0, and the pointer past slot 12, so selling opens again.
    function test_theOwnerResets() public {
        _fourSalesTwoSettled();
        _catchUp();
        assertEq(_state().level, 1);
        vm.warp(market.slotStart(12) + SLOT_SECONDS + LAG + GRACE);
        assertEq(_place(Side.SELL, _ahead(), 100, PRICE), bytes32(0), "blocked");
        _asAccount(abi.encodeCall(gate.resetPolicy, (IPolicy(address(s9)), S9)));
        DeliveryReconciliationPolicy.State memory st = _state();
        assertEq(st.level, 0);
        assertEq(st.cusum, 0);
        assertEq(st.penaltyUntil, 0);
        assertGt(st.next, 12, "past the slot without a reading");
        assertTrue(_place(Side.SELL, _ahead(), 100, PRICE) != bytes32(0));
    }

    function test_onlyAnAccountResets() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(GateBase.Gate_NotInstalled.selector, stranger));
        vm.prank(stranger);
        gate.resetPolicy(s9, S9);
    }

    function test_onlyTheGateWritesThePolicy() public {
        vm.expectRevert();
        s9.poke(address(account), S9);
        vm.expectRevert();
        s9.reset(address(account), S9);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_configurationDirections() public view {
        DeliveryReconciliationPolicy.Config memory c = _config();
        assertEq(uint8(_classify(c)), uint8(ConfigChange.TIGHTEN), "the same");
        c.k = K_SLACK - 1;
        c.h = H - 1;
        c.penaltySeconds = 2 days;
        c.escalationSeconds = 8 days;
        c.graceSeconds = GRACE - 1;
        c.window.cap = H_PEN - 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.TIGHTEN), "every one tighter");

        c = _config();
        c.k = K_SLACK + 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "a higher k");
        c = _config();
        c.h = H + 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "a higher h");
        c = _config();
        c.penaltySeconds = 1 days - 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "a shorter penalty");
        c = _config();
        c.escalationSeconds = 7 days - 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "a shorter escalation");
        c = _config();
        c.graceSeconds = GRACE + 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "a longer grace");
        c = _config();
        c.settlementLagSeconds = LAG - 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "another lag");
        c = _config();
        c.maxProcess = 4;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "another maxProcess");
        c = _config();
        c.window.cap = H_PEN + 1;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "a higher H_pen");
        c = _config();
        c.window.buckets = 24;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.WIDEN), "another window shape");

        c = _config();
        c.maxProcess = 0;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.INVALID), "no processing");
        c.maxProcess = 33;
        assertEq(uint8(_classify(c)), uint8(ConfigChange.INVALID), "beyond MAX_PROCESS");
        assertEq(uint8(s9.classifyConfig(address(account), S9, hex"00")), uint8(ConfigChange.INVALID));
    }

    function _classify(DeliveryReconciliationPolicy.Config memory c) internal view returns (ConfigChange) {
        return s9.classifyConfig(address(account), S9, abi.encode(c));
    }

    // ------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------

    function _gasOfSell(uint32 slot) internal returns (uint256 used) {
        bytes memory sub =
            abi.encodeCall(gate.submit, (address(market), _placeCall(Side.SELL, slot, 10, PRICE), new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        account.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }

    /// @dev Sixteen slots with a sale and a reading, settled: a sell that
    ///      takes in 8 of them, a poke of the other 8, then a sell with nothing
    ///      to take in (the second of two).
    function test_gas_processing() public {
        for (uint32 s = 10; s < 26; ++s) _sold(s, 100);
        _toSettled(9);
        _catchUp();
        _toSettled(25);
        for (uint32 s = 10; s < 26; ++s) _meter(s, 0, 100);
        console.log("S9, a sell taking in 8 slots:", _gasOfSell(_ahead()));
        uint256 before = gasleft();
        _poke();
        console.log("S9, a poke taking in 8 slots:", before - gasleft());
        _gasOfSell(_ahead());
        console.log("S9, a sell with nothing to take in:", _gasOfSell(_ahead()));
        assertEq(_state().next, 26);
    }

    // ------------------------------------------------------------------
    // Spec section 7: meter withholding
    // ------------------------------------------------------------------

    /// @dev The keeper stops posting readings. Selling stops 2 h after the
    ///      first slot with a sale settles; buying goes on.
    function test_meterWithholding_failsClosed() public {
        _sold(10, 1_000);
        _sold(11, 1_000);
        _toSettled(9);
        _catchUp();
        vm.warp(market.slotStart(10) + SLOT_SECONDS + LAG + GRACE);
        assertEq(_place(Side.SELL, _ahead(), 100, PRICE), bytes32(0));
        assertTrue(_place(Side.BUY, _ahead(), 100, PRICE) != bytes32(0));
    }
}

/// @notice Spec section 7, chronic oversell: the agent sells against an
///         inflated state of charge from a compromised BMS signer. S3 trusts
///         the reading and passes every sale; the meter shows nothing
///         exported. With S9, an alarm on the second slot, then level 1 caps
///         further selling; without S9 the agent goes on selling.
abstract contract OversellFixture is DeliveryFixture {
    bytes32 internal constant S3 = keccak256("S3");
    DeliverabilityPolicy internal s3;

    function setUp() public override {
        super.setUp();
        s3 = new DeliverabilityPolicy(address(gate));
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.BMS, bmsSigner, SLOT_SECONDS)));
        uint16[24] memory floor;
        for (uint256 i = 0; i < 24; ++i) floor[i] = 1_000;
        _addPolicy(
            s3,
            S3,
            abi.encode(
                DeliverabilityPolicy.Config({
                    horizonSlots: 48,
                    capacityWh: 5_000,
                    socMinProfileBps: floor,
                    socMaxBps: 10_000,
                    chargePowerW: 3_000,
                    dischargePowerW: 3_000,
                    etaChargeBps: 9_500,
                    etaDischargeBps: 9_500,
                    pvCreditBps: 10_000,
                    reserveLoadWh: 0
                })
            )
        );
    }

    /// @dev The compromised BMS says the battery is full, at every submission.
    function _fullBattery() internal view returns (SignedReading[] memory one) {
        one = new SignedReading[](1);
        one[0] = _signBms(oracle, BMS_KEY, _bms(address(account), market.slotStart(market.currentSlot()), 5_000, 0));
    }

    function _sellWithReading(uint32 slot, uint64 qtyWh) internal returns (bytes32) {
        uint256 before = market.orderCount();
        SignedReading[] memory reading = _fullBattery();
        vm.prank(agent);
        account.executeAsSession(
            address(gate), abi.encodeCall(gate.submit, (address(market), _placeCall(Side.SELL, slot, qtyWh, PRICE), reading))
        );
        return market.orderCount() > before ? bytes32(market.orderCount()) : bytes32(0);
    }

    /// @dev Four sales of 1,000 Wh for slots 10 to 13, each passing S3; each
    ///      filled; the meter shows no export. Once slots 10 and 11 settle,
    ///      is a further 1,000 Wh sale placed?
    function _oversell() internal returns (bool furtherSalePlaced) {
        for (uint32 s = 10; s < 14; ++s) {
            bytes32 id = _sellWithReading(s, 1_000);
            assertTrue(id != bytes32(0), "S3 passes against the inflated reading");
            vm.prank(operator);
            market.fill(id, 1_000, PRICE);
            _reconcile(id);
        }
        if (_installS9()) {
            _toSettled(9);
            _catchUp();
        }
        _toSettled(11);
        _meter(10, 0, 0);
        _meter(11, 0, 0);
        if (_installS9()) _catchUp();
        return _sellWithReading(_ahead(), 1_000) != bytes32(0);
    }
}

contract ChronicOversellTest is OversellFixture {
    function test_chronicOversell_isStoppedByS9() public {
        assertFalse(_oversell(), "level 1: 4,000 Wh sold today is past H_pen");
        assertEq(_state().level, 1, "the alarm, on the second slot");
    }
}

/// @notice Spec section 7, meter withholding, with S9 removed: the readings
///         stop and selling goes on.
contract MeterWithholdingWithoutS9Test is DeliveryFixture {
    function _installS9() internal pure override returns (bool) {
        return false;
    }

    function test_meterWithholding_passesWithoutS9() public {
        _sold(10, 1_000);
        _sold(11, 1_000);
        vm.warp(market.slotStart(10) + SLOT_SECONDS + LAG + GRACE);
        assertTrue(_place(Side.SELL, _ahead(), 100, PRICE) != bytes32(0));
    }
}

contract ChronicOversellWithoutS9Test is OversellFixture {
    function _installS9() internal pure override returns (bool) {
        return false;
    }

    function test_chronicOversell_passesWithoutS9() public {
        assertTrue(_oversell(), "S3 alone keeps passing");
    }
}
