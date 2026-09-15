// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {PolicyConfig} from "../contracts/PolicyConfig.sol";
import {SpendLedger} from "../contracts/SpendLedger.sol";
import {SpendValidator} from "../contracts/SpendValidator.sol";
import {SmartAccount} from "../contracts/SmartAccount.sol";

/// Bounded storage: the ledger holds the most recent RETENTION_DAYS in a ring
/// and nothing older. The event log remains the complete, unbounded history.
///
/// The danger the ring introduces is silent: a slot that wraps holds a record
/// from exactly RETENTION_DAYS ago, and reading it as if it were current would
/// give a wrong window sum with no error anywhere. Everything here exists to
/// pin that shut.
contract RetentionTest is Test {
    PolicyConfig internal config;
    SpendLedger internal ledger;
    SpendValidator internal validator;
    SmartAccount internal account;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agentSessionKey");
    address internal guardian = makeAddr("guardian");

    int256 internal constant CAP = 1_000_000;
    uint32 internal constant WINDOW_DAYS = 7;
    uint32 internal constant PAUSE_EXPIRY = 72 hours;
    uint32 internal constant UNPAUSE_DELAY = 6 hours;

    uint64 internal constant ANCHOR_DAY = 20000;

    function setUp() public {
        vm.warp(uint256(ANCHOR_DAY) * 86400);
        vm.startPrank(owner);
        config = new PolicyConfig(guardian, agent, CAP, WINDOW_DAYS, PAUSE_EXPIRY, UNPAUSE_DELAY);
        ledger = new SpendLedger();
        account = new SmartAccount(config, ledger);
        validator = new SpendValidator(config, ledger, address(account), 0);
        account.installModule(address(validator));
        account.setSpendValidator(address(validator));
        ledger.setWriter(address(this), true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // The two constants must agree
    // ------------------------------------------------------------------

    /// The ledger keeps RETENTION_DAYS of history; PolicyConfig refuses a window
    /// longer than MAX_WINDOW_DAYS. If MAX_WINDOW_DAYS ever exceeded
    /// RETENTION_DAYS, a window would reach past the wrap and read evicted days
    /// as zero -- understating the sum, with nothing raising an error. The two
    /// constants live in different contracts, so this is the only thing keeping
    /// them in step.
    function test_retentionAndMaxWindowAgree() public view {
        assertEq(
            uint256(ledger.RETENTION_DAYS()),
            uint256(config.MAX_WINDOW_DAYS()),
            "SpendLedger.RETENTION_DAYS must equal PolicyConfig.MAX_WINDOW_DAYS"
        );
    }

    function test_windowDaysAtTheBoundIsAccepted() public {
        // Read the constant first: an external call here would consume the
        // prank before setPolicy ever runs.
        uint32 retention = uint32(ledger.RETENTION_DAYS());

        vm.prank(owner);
        config.setPolicy(CAP, retention);
        assertEq(uint256(config.windowDaysAt(config.todayIndex())), uint256(retention));
    }

    function test_windowDaysBeyondTheBoundIsRejected() public {
        uint32 tooLong = uint32(ledger.RETENTION_DAYS()) + 1;

        vm.prank(owner);
        vm.expectRevert(bytes("PolicyConfig: windowDays exceeds ledger retention"));
        config.setPolicy(CAP, tooLong);
    }

    function test_constructorRejectsWindowDaysBeyondTheBound() public {
        vm.prank(owner);
        vm.expectRevert(bytes("PolicyConfig: windowDays exceeds ledger retention"));
        new PolicyConfig(guardian, agent, CAP, 100_000, PAUSE_EXPIRY, UNPAUSE_DELAY);
    }

    // ------------------------------------------------------------------
    // Eviction
    // ------------------------------------------------------------------

    /// A day exactly RETENTION_DAYS later lands on the same ring slot.
    function test_writeExactlyOneRetentionLaterEvictsTheOlderDay() public {
        uint64 older = ANCHOR_DAY;
        uint64 newer = ANCHOR_DAY + uint64(ledger.RETENTION_DAYS());
        assertEq(older % ledger.RETENTION_DAYS(), newer % ledger.RETENTION_DAYS(), "same slot");

        ledger.recordDay(older, 5000, 1, false);
        assertTrue(ledger.isRecorded(older));
        assertEq(ledger.netSpendOf(older), 5000);

        ledger.recordDay(newer, 111, 1, false);

        // The newer day is live.
        assertTrue(ledger.isRecorded(newer));
        assertEq(ledger.netSpendOf(newer), 111);

        // The older day is gone from storage, and does NOT read as the newer
        // day's value. This is the failure the ring could have introduced.
        assertFalse(ledger.isRecorded(older), "evicted day must not read as recorded");
        assertEq(ledger.netSpendOf(older), 0, "evicted day must not leak the new value");
    }

    function test_evictionIsAnnounced() public {
        uint64 older = ANCHOR_DAY;
        uint64 newer = ANCHOR_DAY + uint64(ledger.RETENTION_DAYS());

        ledger.recordDay(older, 5000, 1, false);

        vm.expectEmit(true, true, false, false, address(ledger));
        emit SpendLedger.DayEvicted(older, newer);
        ledger.recordDay(newer, 111, 1, false);
    }

    /// Writing a fresh day into a slot that was never used emits no eviction.
    function test_noEvictionEventOnAVirginSlot() public {
        vm.recordLogs();
        ledger.recordDay(ANCHOR_DAY, 5000, 1, false);

        bytes32 sig = keccak256("DayEvicted(uint64,uint64)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != sig, "no eviction expected on a virgin slot");
        }
    }

    // ------------------------------------------------------------------
    // A wrapped slot must not contaminate the window
    // ------------------------------------------------------------------

    /// The window at a day just after a wrap must not pick up the year-old
    /// records still physically present in other ring slots.
    function test_windowIgnoresWrappedLeftovers() public {
        uint64 retention = uint64(ledger.RETENTION_DAYS());

        // A year ago: seven consecutive heavy days.
        for (uint64 i = 0; i < 7; i++) {
            ledger.recordDay(ANCHOR_DAY + i, 90000, 1, false);
        }
        assertEq(validator.windowSum(ANCHOR_DAY + 6), 630000);

        // A year later, one light day landing on the first of those slots.
        uint64 newDay = ANCHOR_DAY + retention;
        ledger.recordDay(newDay, 10, 1, false);

        // The other six year-old records are still in the ring, at slots the
        // new window covers. They must not be counted.
        assertEq(validator.windowSum(newDay), 10, "window must see only the live day");
    }

    function test_evictedDaysReadAsAbsentInRecordRange() public {
        uint64 retention = uint64(ledger.RETENTION_DAYS());
        ledger.recordDay(ANCHOR_DAY, 5000, 1, false);
        ledger.recordDay(ANCHOR_DAY + retention, 111, 1, false);

        SpendLedger.DayRecord[] memory rows = ledger.recordRange(ANCHOR_DAY, ANCHOR_DAY + 1);
        assertFalse(rows[0].recorded, "evicted day must report recorded = false");
        assertEq(rows[0].netSpend, 0);
        assertEq(rows[0].dayIndex, ANCHOR_DAY, "range still reports which day it is");
    }

    // ------------------------------------------------------------------
    // Day zero
    // ------------------------------------------------------------------

    /// An empty slot and a genuine record for day 0 both carry dayIndex 0. The
    /// `recorded` flag is what separates them, which is why it is kept even
    /// though the dayIndex check covers every other day.
    function test_dayZeroIsDistinguishableFromAnEmptySlot() public {
        assertFalse(ledger.isRecorded(0), "nothing recorded yet");

        ledger.recordDay(0, 1234, 1, false);

        assertTrue(ledger.isRecorded(0), "day 0 is a real day");
        assertEq(ledger.netSpendOf(0), 1234);

        // Day 365 shares slot 0 and must not inherit day 0's record.
        assertFalse(ledger.isRecorded(uint64(ledger.RETENTION_DAYS())));
        assertEq(ledger.netSpendOf(uint64(ledger.RETENTION_DAYS())), 0);
    }

    // ------------------------------------------------------------------
    // Retention bookkeeping
    // ------------------------------------------------------------------

    function test_retentionHorizonReported() public {
        uint64 retention = uint64(ledger.RETENTION_DAYS());

        ledger.recordDay(ANCHOR_DAY, 100, 1, false);
        assertEq(ledger.oldestRetainedDay(), ANCHOR_DAY, "nothing evicted yet");
        assertTrue(ledger.isWithinRetention(ANCHOR_DAY));

        uint64 far = ANCHOR_DAY + retention + 10;
        ledger.recordDay(far, 100, 1, false);

        assertEq(ledger.oldestRetainedDay(), far + 1 - retention);
        assertFalse(ledger.isWithinRetention(ANCHOR_DAY), "a year and ten days back is gone");
        assertTrue(ledger.isWithinRetention(far));
    }

    // ------------------------------------------------------------------
    // Three years of daily records, fixed footprint
    // ------------------------------------------------------------------

    /// Writes 1,095 consecutive days. Under the previous unbounded mapping this
    /// would have allocated a fresh slot every day forever. Here the last
    /// RETENTION_DAYS stay readable, everything older is gone, and nothing in
    /// between reads as a stale value.
    function test_threeYearsOfRecordsKeepsOnlyTheLastYear() public {
        uint64 retention = uint64(ledger.RETENTION_DAYS());
        uint64 total = retention * 3;

        for (uint64 i = 0; i < total; i++) {
            ledger.recordDay(ANCHOR_DAY + i, int256(uint256(i)) + 1, 1, false);
        }

        uint64 lastDay = ANCHOR_DAY + total - 1;
        assertEq(ledger.lastRecordedDay(), lastDay);

        // The most recent year is intact and carries its own values.
        for (uint64 i = 0; i < retention; i++) {
            uint64 day = lastDay - i;
            assertTrue(ledger.isRecorded(day), "recent year must be retained");
            assertEq(ledger.netSpendOf(day), int256(uint256(day - ANCHOR_DAY)) + 1);
        }

        // Everything before that is gone, and reads as absent rather than as
        // whichever record now occupies its slot.
        for (uint64 i = 1; i <= 20; i++) {
            uint64 day = lastDay - retention - i + 1;
            assertFalse(ledger.isRecorded(day), "beyond retention must read absent");
            assertEq(ledger.netSpendOf(day), 0);
        }
    }

    // ------------------------------------------------------------------
    // Gas, for the evaluation's overhead numbers
    // ------------------------------------------------------------------

    /// Not an assertion, a measurement. The first write to a ring slot pays for
    /// zero-to-non-zero storage; once the ring has filled, every later write to
    /// that slot is an overwrite and costs substantially less. Reported here so
    /// the evaluation quotes a measured steady-state figure rather than the
    /// cold-start one.
    function test_reportGasFirstWriteVersusOverwrite() public {
        uint64 retention = uint64(ledger.RETENTION_DAYS());

        uint256 before = gasleft();
        ledger.recordDay(ANCHOR_DAY, 5000, 1, false);
        uint256 coldWrite = before - gasleft();

        before = gasleft();
        ledger.recordDay(ANCHOR_DAY + retention, 5000, 1, false);
        uint256 warmWrite = before - gasleft();

        console.log("gas, first write to a virgin ring slot:");
        console.log(coldWrite);
        console.log("gas, overwrite after one full retention period:");
        console.log(warmWrite);

        assertLt(warmWrite, coldWrite, "steady-state writes should be cheaper than cold ones");
    }
}
