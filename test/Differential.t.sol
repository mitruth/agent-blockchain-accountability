// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {PolicyConfig} from "../contracts/PolicyConfig.sol";
import {SpendLedger} from "../contracts/SpendLedger.sol";
import {SpendValidator} from "../contracts/SpendValidator.sol";
import {SmartAccount} from "../contracts/SmartAccount.sol";
import {ArmData} from "./ArmData.sol";

/// Step 3, on-chain half. Emits the chain's verdict as CSV on stdout for
/// differential/run_diff.py to parse and compare against the independent
/// verifier.
///
/// Records are written straight into the ledger from an allowlisted test
/// writer rather than through submitDay. That is deliberate: submitDay reverts
/// on a breach, which would stop a replay at the first one, and the quantity
/// under comparison here is the *rule* -- windowSum and capAt on every day --
/// not the revert. Enforcement behaviour is covered in Enforcement.t.sol.
///
/// Policy events are captured from the real PolicyUpdated log rather than read
/// back out of storage, so the verifier consumes exactly what a third party
/// watching the chain would see.
contract DifferentialTest is Test {
    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agentSessionKey");
    address internal guardian = makeAddr("guardian");

    uint32 internal constant PAUSE_EXPIRY = 72 hours;
    uint32 internal constant UNPAUSE_DELAY = 6 hours;

    // PolicyUpdated(uint256 indexed, int256, uint32, uint64, uint64, address)
    bytes32 internal constant POLICY_UPDATED_SIG =
        keccak256("PolicyUpdated(uint256,int256,uint32,uint64,uint64,address)");

    PolicyConfig internal config;
    SpendLedger internal ledger;
    SpendValidator internal validator;
    SmartAccount internal account;

    function _deploy(int256 cap, uint32 windowDays) internal {
        vm.startPrank(owner);
        config = new PolicyConfig(guardian, agent, cap, windowDays, PAUSE_EXPIRY, UNPAUSE_DELAY);
        ledger = new SpendLedger();
        account = new SmartAccount(config, ledger);
        validator = new SpendValidator(config, ledger, address(account));
        account.installModule(address(validator));
        account.setSpendValidator(address(validator));
        // The test writes records directly; see the note above.
        ledger.setWriter(address(this), true);
        vm.stopPrank();
    }

    function warpToDay(uint64 day) internal {
        vm.warp(uint256(day) * 86400);
    }

    // ------------------------------------------------------------------
    // Emitters
    // ------------------------------------------------------------------

    function _emitPolicyEvents(string memory scenario) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seq = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != POLICY_UPDATED_SIG) continue;

            uint256 version = uint256(logs[i].topics[1]);
            (int256 cap, uint32 windowDays, uint64 submittedOnDay, uint64 effectiveFromDay, address setBy) =
                abi.decode(logs[i].data, (int256, uint32, uint64, uint64, address));

            console.log(
                string.concat(
                    "POLICY,", scenario,
                    ",", vm.toString(seq),
                    ",", vm.toString(version),
                    ",", vm.toString(cap),
                    ",", vm.toString(uint256(windowDays)),
                    ",", vm.toString(uint256(submittedOnDay)),
                    ",", vm.toString(uint256(effectiveFromDay)),
                    ",", vm.toString(setBy)
                )
            );
            seq++;
        }

        // Every scenario deploys a PolicyConfig, which emits a genesis
        // PolicyUpdated. Capturing none means the event signature this test
        // filters on no longer matches the one the contract emits -- a silent
        // failure that otherwise leaves the suite green while the differential
        // compares against nothing.
        require(seq > 0, "Differential: no PolicyUpdated captured; event signature drift?");
    }

    function _emitDays(string memory scenario, uint64 firstDay, uint64 lastDay) internal view {
        for (uint64 d = firstDay; d <= lastDay; d++) {
            if (!ledger.isRecorded(d)) continue;
            SpendLedger.DayRecord memory rec = ledger.recordOf(d);
            int256 sum = validator.windowSum(d);
            int256 cap = config.capAt(d);
            uint32 w = config.windowDaysAt(d);
            console.log(
                string.concat(
                    "DAY,", scenario,
                    ",", vm.toString(uint256(d)),
                    ",", vm.toString(rec.netSpend),
                    ",", vm.toString(sum),
                    ",", vm.toString(cap),
                    ",", vm.toString(uint256(w)),
                    ",", (sum <= cap ? "1" : "0"),
                    ",", vm.toString(rec.policyVersion),
                    ",", (rec.paused ? "1" : "0")
                )
            );
        }
    }

    function _record(uint64 day, int256 netSpend) internal {
        ledger.recordDay(day, netSpend, config.regimeAt(day).policyVersion, false);
    }

    // ------------------------------------------------------------------
    // Scenarios: the three real arms, one genesis policy, 365 days
    // ------------------------------------------------------------------

    function _runArm(string memory arm, int256 cap, string memory label) internal {
        vm.recordLogs();
        _deploy(cap, 7);

        bytes memory blob = ArmData.data(arm);
        // Day 0 is 2022-01-01 in the source data. Offset is irrelevant to the
        // rule; both sides see identical indices.
        for (uint256 i = 0; i < ArmData.dayCount(); i++) {
            _record(uint64(i), ArmData.at(blob, i));
        }

        _emitPolicyEvents(label);
        _emitDays(label, 0, uint64(ArmData.dayCount() - 1));
    }

    function test_diff_armB0() public {
        _runArm("B0", 100000, "B0");
    }

    function test_diff_armB1() public {
        _runArm("B1", 100000, "B1");
    }

    function test_diff_armB2() public {
        _runArm("B2", 100000, "B2");
    }

    /// Strict cap, so a large fraction of days breach. Exercises the far side
    /// of the comparison on real data rather than only the compliant side.
    function test_diff_armB0_strictCap() public {
        _runArm("B0", 18096, "B0strict");
    }

    // ------------------------------------------------------------------
    // Scenario: policy churn
    //
    // Aimed squarely at enforcement-rule.md section 5 -- deferral, cancellation, same-day
    // precedence, boundary-day writes, and a windowDays change. Day 19999 is a
    // boundary under w=7 (19999 = 7 * 2857), so 20006, 20013 and 20020 are the
    // boundaries that follow.
    // ------------------------------------------------------------------

    function test_diff_policyChurn() public {
        uint64 start = 20000;
        warpToDay(start);

        vm.recordLogs();
        _deploy(10000, 7);

        // A raise: defers to the next boundary (20006).
        warpToDay(start + 1);
        vm.prank(owner);
        config.setPolicy(30000, 7);

        // Another raise before that boundary: same effective day, later wins.
        warpToDay(start + 2);
        vm.prank(owner);
        config.setPolicy(20000, 7);

        // A lowering: immediate, and cancels anything still pending.
        warpToDay(start + 3);
        vm.prank(owner);
        config.setPolicy(4000, 7);

        // A raise made ON a boundary day (20006) -- the case enforcement-rule.md section 5.5
        // defers a full window rather than applying at once.
        warpToDay(start + 6);
        vm.prank(owner);
        config.setPolicy(25000, 7);

        // An unchanged cap. Neither a raise nor a lowering by the strict
        // reading; enforcement-rule.md section 5 does not cover equality.
        warpToDay(start + 8);
        vm.prank(owner);
        config.setPolicy(25000, 7);

        // windowDays change only.
        warpToDay(start + 10);
        vm.prank(owner);
        config.setPolicy(25000, 3);

        // Records across the whole span, including a negative day.
        int256[21] memory spend = [
            int256(1000), 1000, 1000, 1000, 1000, 1000, 1000,
            2000, -1500, 2000, 2000, 2000, 2000, 2000,
            3000, 3000, -500, 3000, 3000, 3000, 3000
        ];
        for (uint256 i = 0; i < spend.length; i++) {
            _record(start + uint64(i), spend[i]);
        }

        _emitPolicyEvents("churn");
        _emitDays("churn", start, start + 20);
    }

    // ------------------------------------------------------------------
    // Scenario: pause
    //
    // A paused day must read as a zero-spend day, not a missing day, and the
    // window must advance across it.
    // ------------------------------------------------------------------

    function test_diff_pausedDays() public {
        uint64 start = 20000;
        warpToDay(start);

        vm.recordLogs();
        _deploy(10000, 7);

        for (uint256 i = 0; i < 10; i++) {
            uint64 d = start + uint64(i);
            bool paused = (i == 3 || i == 4);
            ledger.recordDay(
                d,
                paused ? int256(0) : int256(1500),
                config.regimeAt(d).policyVersion,
                paused
            );
        }

        _emitPolicyEvents("paused");
        _emitDays("paused", start, start + 9);
    }
}
