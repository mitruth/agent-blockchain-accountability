// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {PolicyConfig} from "../contracts/PolicyConfig.sol";
import {SpendLedger} from "../contracts/SpendLedger.sol";
import {SpendValidator} from "../contracts/SpendValidator.sol";
import {SmartAccount} from "../contracts/SmartAccount.sol";

/// Step 2: the validator, wired.
///
/// The rule under test:
///     windowSum(day) = sum of netSpend over [day - windowDays + 1, day]
///     require(windowSum <= capAt(day))
/// Oldest day included. Equality at the cap passes.
///
/// These are the on-chain side only. The independent verifier (step 3) is
/// written from the specification without this source in context, and the two
/// are then run against the same records. A test passing here says the contract
/// agrees with itself, which is exactly the thing F2 warns about.
contract EnforcementTest is Test {
    PolicyConfig internal config;
    SpendLedger internal ledger;
    SpendValidator internal validator;
    SmartAccount internal account;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agentSessionKey");
    address internal guardian = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");

    int256 internal constant CAP = 10000; // milli-USD
    uint32 internal constant WINDOW_DAYS = 7;
    uint32 internal constant PAUSE_EXPIRY = 72 hours;
    uint32 internal constant UNPAUSE_DELAY = 6 hours;

    uint64 internal constant ANCHOR_DAY = 20000;

    function setUp() public {
        warpToDay(ANCHOR_DAY);

        vm.startPrank(owner);
        config = new PolicyConfig(guardian, agent, CAP, WINDOW_DAYS, PAUSE_EXPIRY, UNPAUSE_DELAY);
        ledger = new SpendLedger();
        account = new SmartAccount(config, ledger);
        validator = new SpendValidator(config, ledger, address(account));

        account.installModule(address(validator));
        account.setSpendValidator(address(validator));
        // Write authority comes from the allowlist, never from the install above.
        ledger.setWriter(address(validator), true);
        vm.stopPrank();
    }

    function warpToDay(uint64 day) internal {
        vm.warp(uint256(day) * 86400);
    }

    function submit(uint64 day, int256 netSpend) internal {
        warpToDay(day);
        vm.prank(agent);
        validator.submitDay(netSpend);
    }

    // ------------------------------------------------------------------
    // The permission-table row that needed the validator
    // ------------------------------------------------------------------

    function test_agent_maySubmitDailyRecordsThroughValidator() public {
        submit(ANCHOR_DAY, 1234);

        assertTrue(ledger.isRecorded(ANCHOR_DAY));
        assertEq(ledger.netSpendOf(ANCHOR_DAY), 1234);
        assertEq(validator.windowSum(ANCHOR_DAY), 1234);
    }

    function test_nonAgent_mayNotSubmit() public {
        warpToDay(ANCHOR_DAY);

        vm.prank(owner);
        vm.expectRevert(SpendValidator.SpendValidator_OnlySessionKey.selector);
        validator.submitDay(1000);

        vm.prank(guardian);
        vm.expectRevert(SpendValidator.SpendValidator_OnlySessionKey.selector);
        validator.submitDay(1000);

        vm.prank(attacker);
        vm.expectRevert(SpendValidator.SpendValidator_OnlySessionKey.selector);
        validator.submitDay(1000);
    }

    /// Revoking the session key stops submissions immediately.
    function test_revokedSessionKeyMayNotSubmit() public {
        submit(ANCHOR_DAY, 1000);

        vm.prank(owner);
        config.setSessionKey(address(0));

        warpToDay(ANCHOR_DAY + 1);
        vm.prank(agent);
        vm.expectRevert(SpendValidator.SpendValidator_OnlySessionKey.selector);
        validator.submitDay(1000);
    }

    // ------------------------------------------------------------------
    // The rule
    // ------------------------------------------------------------------

    function test_equalityAtCapPasses() public {
        // Six days of 1000, then exactly the remaining 4000 on the seventh.
        for (uint64 i = 0; i < 6; i++) {
            submit(ANCHOR_DAY + i, 1000);
        }
        submit(ANCHOR_DAY + 6, 4000);

        assertEq(validator.windowSum(ANCHOR_DAY + 6), CAP, "window should sit exactly at the cap");
    }

    function test_oneOverCapReverts() public {
        for (uint64 i = 0; i < 6; i++) {
            submit(ANCHOR_DAY + i, 1000);
        }

        warpToDay(ANCHOR_DAY + 6);
        vm.prank(agent);
        vm.expectRevert(SpendValidator.SpendValidator_CapExceeded.selector);
        validator.submitDay(4001);

        // The rejected day left no trace.
        assertFalse(ledger.isRecorded(ANCHOR_DAY + 6));
        assertEq(validator.windowSum(ANCHOR_DAY + 5), 6000);
    }

    /// The oldest day of the window is INCLUDED. With windowDays = 7, the window
    /// at day D covers [D-6, D].
    ///
    /// Discriminating by construction: all the spend sits on the oldest day. If
    /// that day were excluded the window would read 1 and the submission would
    /// pass.
    function test_oldestDayIsIncludedInWindow() public {
        vm.prank(owner);
        config.setPolicy(1000, WINDOW_DAYS);

        submit(ANCHOR_DAY, 1000);
        for (uint64 i = 1; i <= 5; i++) {
            submit(ANCHOR_DAY + i, 0);
        }

        assertEq(validator.windowSum(ANCHOR_DAY + 6), 1000, "day D-6 must still count");

        warpToDay(ANCHOR_DAY + 6);
        vm.prank(agent);
        vm.expectRevert(SpendValidator.SpendValidator_CapExceeded.selector);
        validator.submitDay(1);
    }

    /// One day later the oldest day has left the window.
    function test_dayLeavesWindowAfterWindowDays() public {
        submit(ANCHOR_DAY, 5000);
        for (uint64 i = 1; i <= 6; i++) {
            submit(ANCHOR_DAY + i, 0);
        }
        assertEq(validator.windowSum(ANCHOR_DAY + 6), 5000);

        // At D+7 the window is [D+1, D+7]; the 5000 on day D has dropped out.
        assertEq(validator.windowSum(ANCHOR_DAY + 7), 0, "oldest day should have expired");
    }

    // ------------------------------------------------------------------
    // F3: export credit
    // ------------------------------------------------------------------

    function test_negativeDayReducesWindowSum() public {
        submit(ANCHOR_DAY, 5000);
        submit(ANCHOR_DAY + 1, -2000);

        assertEq(validator.windowSum(ANCHOR_DAY + 1), 3000, "export credit must reduce the sum");
        assertEq(ledger.netSpendOf(ANCHOR_DAY + 1), -2000, "sign must survive into storage");
    }

    /// Credit genuinely buys headroom: without it this sequence breaches.
    function test_exportCreditRestoresHeadroom() public {
        submit(ANCHOR_DAY, 9000);
        submit(ANCHOR_DAY + 1, -3000); // window now 6000

        // 4000 more would be 10000 exactly. Under clamping the window would
        // read 9000 and this would revert.
        submit(ANCHOR_DAY + 2, 4000);
        assertEq(validator.windowSum(ANCHOR_DAY + 2), CAP);
    }

    function test_windowMayGoNegative() public {
        submit(ANCHOR_DAY, -1500);
        assertEq(validator.windowSum(ANCHOR_DAY), -1500);
    }

    // ------------------------------------------------------------------
    // Records bind the policy they were checked against
    // ------------------------------------------------------------------

    function test_recordBindsPolicyVersionInForce() public {
        submit(ANCHOR_DAY, 1000);
        assertEq(ledger.recordOf(ANCHOR_DAY).policyVersion, 1);

        vm.prank(owner);
        config.setPolicy(CAP - 5000, WINDOW_DAYS); // a lowering: immediate
        assertEq(config.policyVersion(), 2);

        submit(ANCHOR_DAY + 1, 100);
        assertEq(ledger.recordOf(ANCHOR_DAY + 1).policyVersion, 2);
    }

    /// Lowering below the current window sum blocks further spend but is not a
    /// retroactive breach: the earlier day stays recorded and untouched.
    function test_loweringBelowWindowSumBlocksButDoesNotRewriteHistory() public {
        submit(ANCHOR_DAY, 8000);

        vm.prank(owner);
        config.setPolicy(5000, WINDOW_DAYS);

        assertEq(ledger.netSpendOf(ANCHOR_DAY), 8000, "history must be untouched");
        assertEq(ledger.recordOf(ANCHOR_DAY).policyVersion, 1, "checked against the old cap");

        warpToDay(ANCHOR_DAY + 1);
        vm.prank(agent);
        vm.expectRevert(SpendValidator.SpendValidator_CapExceeded.selector);
        validator.submitDay(1);
    }

    // ------------------------------------------------------------------
    // capAt must be the cap in force on that day, not the latest cap
    // ------------------------------------------------------------------

    function test_raiseAppliesAtBoundaryNotImmediately() public {
        uint64 boundary = config.nextWindowBoundary(ANCHOR_DAY, WINDOW_DAYS);
        assertGt(boundary, ANCHOR_DAY);

        vm.prank(owner);
        config.setPolicy(CAP * 5, WINDOW_DAYS);

        // Today still sees the old cap.
        assertEq(config.capAt(ANCHOR_DAY), CAP, "raise must not apply today");
        assertEq(config.capAt(boundary), CAP * 5, "raise must apply from the boundary");

        warpToDay(ANCHOR_DAY);
        vm.prank(agent);
        vm.expectRevert(SpendValidator.SpendValidator_CapExceeded.selector);
        validator.submitDay(CAP + 1);
    }

    function test_loweringAppliesImmediately() public {
        vm.prank(owner);
        config.setPolicy(500, WINDOW_DAYS);

        assertEq(config.capAt(ANCHOR_DAY), 500, "lowering must apply today");
    }

    /// D4.3: a lowering cancels a raise still pending at a future boundary,
    /// otherwise yesterday's queued raise resurrects itself.
    function test_loweringCancelsPendingRaise() public {
        uint64 boundary = config.nextWindowBoundary(ANCHOR_DAY, WINDOW_DAYS);

        vm.prank(owner);
        config.setPolicy(CAP * 5, WINDOW_DAYS); // queued at the boundary
        assertEq(config.capAt(boundary), CAP * 5);

        vm.prank(owner);
        config.setPolicy(2000, WINDOW_DAYS); // lowering, today

        assertEq(config.capAt(ANCHOR_DAY), 2000);
        assertEq(config.capAt(boundary), 2000, "the pending raise must not resurrect");
        assertEq(config.capAt(boundary + 365), 2000);
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    function test_pausedSpendsForceAZeroSpendDay() public {
        vm.prank(guardian);
        config.pauseSpends();

        submit(ANCHOR_DAY, 5000);

        assertTrue(ledger.isRecorded(ANCHOR_DAY), "a paused day is recorded, not skipped");
        assertEq(ledger.netSpendOf(ANCHOR_DAY), 0, "paused day is a zero-spend day");
        assertTrue(ledger.recordOf(ANCHOR_DAY).paused, "and is flagged as such");
    }

    /// The window still advances across a paused day.
    function test_windowAdvancesAcrossPausedDay() public {
        submit(ANCHOR_DAY, 5000);

        vm.prank(guardian);
        config.pauseSpends();
        submit(ANCHOR_DAY + 1, 9999); // forced to zero

        assertEq(validator.windowSum(ANCHOR_DAY + 1), 5000);
    }

    function test_pausedSpendsBlockExecute() public {
        vm.prank(guardian);
        config.pauseSpends();

        vm.deal(address(account), 1 ether);
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount_SpendsPaused.selector);
        account.execute(makeAddr("dest"), 1);
    }

    // ------------------------------------------------------------------
    // Decision 3: a validator upgrade never resets the window
    // ------------------------------------------------------------------

    function test_validatorSwapCarriesTheWindow() public {
        for (uint64 i = 0; i < 5; i++) {
            submit(ANCHOR_DAY + i, 1500);
        }
        assertEq(validator.windowSum(ANCHOR_DAY + 4), 7500);

        // Swap in a fresh validator against the same, never-redeployed ledger.
        vm.startPrank(owner);
        SpendValidator validator2 = new SpendValidator(config, ledger, address(account));
        account.installModule(address(validator2));
        account.setSpendValidator(address(validator2));
        ledger.setWriter(address(validator2), true);

        account.uninstallModule(address(validator));
        ledger.setWriter(address(validator), false);
        vm.stopPrank();

        assertEq(validator2.windowSum(ANCHOR_DAY + 4), 7500, "upgrade must not mint capacity");

        // And the cap still binds across the swap: 2500 fits, 2501 does not.
        warpToDay(ANCHOR_DAY + 5);
        vm.prank(agent);
        vm.expectRevert(SpendValidator.SpendValidator_CapExceeded.selector);
        validator2.submitDay(2501);

        vm.prank(agent);
        validator2.submitDay(2500);
        assertEq(validator2.windowSum(ANCHOR_DAY + 5), CAP);
    }

    /// A validator that is installed but not allowlisted cannot write. This is
    /// D1.3 from the validator's side.
    function test_validatorWithoutAllowlistEntryCannotRecord() public {
        vm.startPrank(owner);
        SpendValidator orphan = new SpendValidator(config, ledger, address(account));
        account.installModule(address(orphan));
        vm.stopPrank();

        warpToDay(ANCHOR_DAY);
        vm.prank(agent);
        vm.expectRevert(bytes("SpendLedger: not an allowlisted writer"));
        orphan.submitDay(1000);
    }

    // ------------------------------------------------------------------
    // Upgrade path must not be blockable by a stranger
    // ------------------------------------------------------------------

    /// onInstall is unpermissioned, so anyone may call it and become the
    /// recorded smartAccount. onUninstall then requires msg.sender to be that
    /// address, so the real account's uninstall reverts -- permanently pinning
    /// the module in place. The owner's upgrade path is the one thing that must
    /// not be griefable by a stranger.
    function test_strangerCannotBlockUninstall() public {
        vm.prank(attacker);
        vm.expectRevert(SpendValidator.SpendValidator_OnlySmartAccount.selector);
        validator.onInstall("");

        vm.prank(owner);
        account.uninstallModule(address(validator));

        assertFalse(account.installedModules(address(validator)));
    }
}
