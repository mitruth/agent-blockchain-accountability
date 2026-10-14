// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PolicyConfig} from "../../contracts/earlier-design/PolicyConfig.sol";
import {SpendLedger} from "../../contracts/earlier-design/SpendLedger.sol";
import {SpendValidator} from "../../contracts/earlier-design/SpendValidator.sol";
import {SmartAccount} from "../../contracts/earlier-design/SmartAccount.sol";
import {PriceOracle} from "../../contracts/earlier-design/PriceOracle.sol";
import {MeterReadings} from "../../contracts/earlier-design/MeterReadings.sol";

/// Stage A4: record the measured day, then restrict the agent.
///
/// The rule:
///     windowSum(day) = sum of settled spend over [day - windowDays + 1, day]
///     the agent is authorised only while
///         windowSum(last settled day) <= cap in force today
///         and settlement is no more than 2 days behind
///         and the agent is not paused and its key is not revoked
/// Oldest day included. Equality at the cap passes.
///
/// Every settled day is recorded, whatever it cost. Enforcement acts on what
/// the agent may do next: SmartAccount.execute is refused to the agent while it
/// is not authorised (D7.5).
///
/// These tests assert the contract against itself. The independent verifier
/// (stage A5) is what checks the contract against the specification.
contract EnforcementTest is Test {
    PolicyConfig internal config;
    SpendLedger internal ledger;
    SpendValidator internal validator;
    SmartAccount internal account;
    PriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agentSessionKey");
    address internal guardian = makeAddr("guardian");
    address internal publisher = makeAddr("pricePublisher");
    address internal stranger = makeAddr("stranger");
    address internal payee = makeAddr("payee");
    address internal meter;
    uint256 internal meterKey;

    int256 internal constant CAP = 10000; // milli-USD over 7 days
    uint32 internal constant WINDOW_DAYS = 7;
    uint32 internal constant PAUSE_EXPIRY = 72 hours;
    uint32 internal constant UNPAUSE_DELAY = 6 hours;

    uint64 internal constant ANCHOR_DAY = 20000;

    function setUp() public {
        (meter, meterKey) = makeAddrAndKey("meter");
        warpToDay(ANCHOR_DAY);

        vm.prank(publisher);
        oracle = new PriceOracle(publisher);

        vm.startPrank(owner);
        config = new PolicyConfig(guardian, agent, CAP, WINDOW_DAYS, PAUSE_EXPIRY, UNPAUSE_DELAY);
        ledger = new SpendLedger();
        account = new SmartAccount(config, ledger);
        validator = new SpendValidator(config, ledger, address(account), ANCHOR_DAY);

        account.installModule(address(validator));
        account.setSpendValidator(address(validator));
        // Write authority comes from the allowlist, never from the install above.
        ledger.setWriter(address(validator), true);
        config.setPriceOracle(address(oracle));
        config.setMeter(meter);
        vm.stopPrank();

        vm.deal(address(account), 10 ether);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function warpToDay(uint64 day) internal {
        vm.warp(uint256(day) * 86400 + 3600); // 01:00 UTC
    }

    /// Settle `day` through the real path: oracle prices, meter signature,
    /// on-chain arithmetic. A single half-hour carries the whole day at
    /// 1 USD/kWh, so |spend| x 1000 mWh is |spend| milli-USD. A negative spend
    /// is exported.
    function settle(uint64 day, int256 spendMilliUsd) internal {
        uint64[48] memory imp;
        uint64[48] memory exp;
        int64[48] memory pi;
        int64[48] memory pe;
        pi[0] = 100_000_000;
        pe[0] = 100_000_000;
        if (spendMilliUsd >= 0) imp[0] = uint64(uint256(spendMilliUsd)) * 1000;
        else exp[0] = uint64(uint256(-spendMilliUsd)) * 1000;

        vm.prank(publisher);
        oracle.publishDay(day, pi, pe);

        bytes32 hash = MeterReadings.digest(block.chainid, address(ledger), day, imp, exp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(meterKey, hash);

        if (config.todayIndex() <= day) warpToDay(day + 1);
        validator.settleDay(
            SpendValidator.DayReadings(day, imp, exp, abi.encodePacked(r, s, v)),
            SpendValidator.DayPrices(pi, pe)
        );
    }

    /// Settle consecutive days from the next settlement day, then stand on the
    /// day after the last so settlement is current.
    function settleRun(int256[] memory spends) internal returns (uint64 lastDay) {
        for (uint256 i = 0; i < spends.length; i++) {
            lastDay = validator.nextSettlementDay();
            settle(lastDay, spends[i]);
        }
        warpToDay(lastDay + 1);
    }

    function run(int256 a) internal pure returns (int256[] memory x) {
        x = new int256[](1);
        x[0] = a;
    }

    function runN(int256 value, uint256 n) internal pure returns (int256[] memory x) {
        x = new int256[](n);
        for (uint256 i = 0; i < n; i++) x[i] = value;
    }

    function authorizationIs(SpendValidator.Authorization expected) internal view {
        assertEq(uint256(validator.authorization()), uint256(expected));
    }

    function agentTransfer() internal {
        vm.prank(agent);
        account.execute(payee, 1 wei);
    }

    function expectAgentRefused() internal {
        vm.prank(agent);
        vm.expectRevert(SmartAccount.SmartAccount_RejectedByModule.selector);
        account.execute(payee, 1 wei);
    }

    // ------------------------------------------------------------------
    // The agent acts while authorised
    // ------------------------------------------------------------------

    function test_agentMayTransferWhileAuthorised() public {
        settleRun(run(1200));
        assertTrue(validator.isAgentAuthorized());

        agentTransfer();
        assertEq(payee.balance, 1 wei);
    }

    function test_strangerMayNotExecute() public {
        vm.prank(stranger);
        vm.expectRevert(SmartAccount.SmartAccount_NotOwnerOrAgent.selector);
        account.execute(payee, 1 wei);
    }

    /// The validator refuses a stranger on its own, not only because the account
    /// checks the caller first. Found by a mutation: a validator waving anyone
    /// through passed every test, leaving the account's check as the only layer.
    function test_validatorRefusesAStrangerIndependently() public {
        settleRun(run(100));
        assertFalse(validator.validateTransaction(stranger, payee, 1 wei));
        assertFalse(validator.validateTransaction(guardian, payee, 1 wei));
        assertTrue(validator.validateTransaction(agent, payee, 1 wei));
        assertTrue(validator.validateTransaction(owner, payee, 1 wei));
    }

    function test_revokedSessionKeyMayNotExecute() public {
        vm.prank(owner);
        config.setSessionKey(address(0));
        authorizationIs(SpendValidator.Authorization.NoSessionKey);

        vm.prank(agent);
        vm.expectRevert(SmartAccount.SmartAccount_NotOwnerOrAgent.selector);
        account.execute(payee, 1 wei);
    }

    /// A transfer amount is wei, not spend. Spend is what the meter measured.
    function test_transferValueIsNotCountedAsSpend() public {
        settleRun(run(9000));
        vm.prank(agent);
        account.execute(payee, 5 ether);

        assertEq(validator.windowSum(ANCHOR_DAY), 9000, "window unchanged by the transfer");
        assertTrue(validator.isAgentAuthorized());
    }

    // ------------------------------------------------------------------
    // Over the cap: recorded, and authority withdrawn
    // ------------------------------------------------------------------

    function test_overCapWithdrawsAuthority() public {
        settleRun(run(12000));

        assertEq(ledger.netSpendOf(ANCHOR_DAY), 12000, "the breach is recorded in full");
        authorizationIs(SpendValidator.Authorization.OverCap);
        expectAgentRefused();
    }

    /// Regression test for the defect D7.5 fixed. Under submitDay an over-cap
    /// day was reverted and never written, so it read as zero and the next
    /// window had MORE headroom after a breach. A recorded breach keeps
    /// counting for the whole window.
    function test_aBreachDoesNotCreateHeadroom() public {
        int256[] memory spends = new int256[](2);
        spends[0] = 12000;
        spends[1] = 0;
        uint64 last = settleRun(spends);

        assertEq(validator.windowSum(last), 12000, "the breach day still counts the next day");
        authorizationIs(SpendValidator.Authorization.OverCap);
    }

    /// Authority returns once the breach day leaves the 7-day window.
    function test_authorityReturnsWhenTheWindowRecovers() public {
        int256[] memory spends = new int256[](7);
        spends[0] = 12000;
        uint64 last = settleRun(spends); // breach, then six zero days
        assertEq(last, ANCHOR_DAY + 6);
        authorizationIs(SpendValidator.Authorization.OverCap);

        settleRun(run(0)); // day 7: the breach leaves the window
        assertTrue(validator.isAgentAuthorized());
        agentTransfer();
    }

    /// The owner is the principal. Enforcement restricts the agent.
    function test_ownerMayTransferWhileAgentIsOverCap() public {
        settleRun(run(12000));
        vm.prank(owner);
        account.execute(payee, 1 wei);
        assertEq(payee.balance, 1 wei);
    }

    // ------------------------------------------------------------------
    // Stale settlement fails closed (D7.11)
    // ------------------------------------------------------------------

    function test_settlementTwoDaysBehindIsTolerated() public {
        settle(ANCHOR_DAY, 100);
        warpToDay(ANCHOR_DAY + 2);
        assertTrue(validator.isAgentAuthorized());
    }

    function test_settlementThreeDaysBehindWithdrawsAuthority() public {
        settle(ANCHOR_DAY, 100);
        warpToDay(ANCHOR_DAY + 3);
        authorizationIs(SpendValidator.Authorization.SettlementStale);
        expectAgentRefused();

        // Catching up restores it.
        settle(ANCHOR_DAY + 1, 100);
        assertTrue(validator.isAgentAuthorized());
    }

    /// Before the first settlement the agent has the same grace as after any
    /// other day: genesis - 1 counts as the last settled day.
    function test_genesisGraceThenStale() public {
        warpToDay(ANCHOR_DAY + 1);
        assertTrue(validator.isAgentAuthorized(), "genesis day not yet overdue");
        warpToDay(ANCHOR_DAY + 2);
        authorizationIs(SpendValidator.Authorization.SettlementStale);
    }

    /// Withholding a bad day does not preserve the agent's authority: it lapses
    /// anyway, and anyone holding the signed readings can settle the day.
    function test_withholdingADayDoesNotPreserveAuthority() public {
        settleRun(run(500));
        warpToDay(ANCHOR_DAY + 4); // nobody settles day +1
        authorizationIs(SpendValidator.Authorization.SettlementStale);
    }

    // ------------------------------------------------------------------
    // Pause gates actions, not accounting (D7.6)
    // ------------------------------------------------------------------

    function test_agentPauseWithdrawsAuthorityUntilExpiry() public {
        settleRun(run(100));
        vm.prank(guardian);
        config.pauseAgent();
        authorizationIs(SpendValidator.Authorization.AgentPaused);
        expectAgentRefused();

        // Keep settlement current across the 72h expiry.
        settle(ANCHOR_DAY + 1, 0);
        settle(ANCHOR_DAY + 2, 0);
        settle(ANCHOR_DAY + 3, 0);
        warpToDay(ANCHOR_DAY + 4);
        assertTrue(config.pauseExpired());
        assertTrue(validator.isAgentAuthorized(), "an expired pause imposes nothing");
    }

    /// A pause cannot un-consume energy. The settled day records what the meter
    /// measured.
    function test_pauseDoesNotChangeRecordedSpend() public {
        vm.startPrank(guardian);
        config.pauseSpends();
        config.pauseAgent();
        vm.stopPrank();

        settle(ANCHOR_DAY, 700);
        assertEq(ledger.netSpendOf(ANCHOR_DAY), 700, "recorded as measured, not zeroed");
    }

    function test_spendPauseStopsTheOwnerToo() public {
        vm.prank(guardian);
        config.pauseSpends();

        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount_SpendsPaused.selector);
        account.execute(payee, 1 wei);
    }

    // ------------------------------------------------------------------
    // The window rule
    // ------------------------------------------------------------------

    function test_equalityAtCapIsAuthorised() public {
        int256[] memory spends = runN(1000, 7);
        spends[6] = 4000;
        uint64 last = settleRun(spends);

        assertEq(validator.windowSum(last), CAP);
        assertTrue(validator.isAgentAuthorized(), "equality at the cap passes");
    }

    function test_oneOverCapIsNotAuthorised() public {
        int256[] memory spends = runN(1000, 7);
        spends[6] = 4001;
        settleRun(spends);
        authorizationIs(SpendValidator.Authorization.OverCap);
    }

    /// Discriminating by construction: all the spend sits on the oldest day of
    /// the window. Excluded, the window would read 0 and the agent would pass.
    function test_oldestDayIsIncludedInWindow() public {
        int256[] memory spends = new int256[](7);
        spends[0] = 10001;
        uint64 last = settleRun(spends);

        assertEq(last, ANCHOR_DAY + 6);
        assertEq(validator.windowSum(last), 10001, "day D-6 still counts");
        authorizationIs(SpendValidator.Authorization.OverCap);
    }

    function test_dayLeavesWindowAfterWindowDays() public {
        int256[] memory spends = new int256[](8);
        spends[0] = 5000;
        uint64 last = settleRun(spends);
        assertEq(validator.windowSum(last - 1), 5000);
        assertEq(validator.windowSum(last), 0, "day D has left the window at D+7");
    }

    function test_negativeDayReducesWindowSum() public {
        int256[] memory spends = new int256[](2);
        spends[0] = 5000;
        spends[1] = -2000;
        uint64 last = settleRun(spends);
        assertEq(validator.windowSum(last), 3000);
        assertEq(ledger.netSpendOf(last), -2000, "sign survives into storage");
    }

    /// Export credit buys real headroom. Under clamping the window would read
    /// 13,000 and the agent would be refused.
    function test_exportCreditRestoresHeadroom() public {
        int256[] memory spends = new int256[](3);
        spends[0] = 9000;
        spends[1] = -3000;
        spends[2] = 4000;
        uint64 last = settleRun(spends);
        assertEq(validator.windowSum(last), CAP);
        assertTrue(validator.isAgentAuthorized());
    }

    function test_windowMayGoNegative() public {
        settleRun(run(-1500));
        assertEq(validator.windowSum(ANCHOR_DAY), -1500);
    }

    // ------------------------------------------------------------------
    // Cap changes
    // ------------------------------------------------------------------

    function test_recordBindsPolicyVersionInForceOnThatDay() public {
        settle(ANCHOR_DAY, 1000);
        assertEq(ledger.recordOf(ANCHOR_DAY).policyVersion, 1);

        vm.prank(owner);
        config.setPolicy(CAP - 5000, WINDOW_DAYS); // a lowering, effective today
        settle(ANCHOR_DAY + 1, 100);
        assertEq(ledger.recordOf(ANCHOR_DAY + 1).policyVersion, 2);
    }

    /// Lowering withdraws authority at once, without rewriting history.
    function test_loweringBelowWindowSumWithdrawsAuthorityImmediately() public {
        settleRun(run(8000));
        assertTrue(validator.isAgentAuthorized());

        vm.prank(owner);
        config.setPolicy(5000, WINDOW_DAYS);

        authorizationIs(SpendValidator.Authorization.OverCap);
        assertEq(ledger.netSpendOf(ANCHOR_DAY), 8000, "history untouched");
        assertEq(ledger.recordOf(ANCHOR_DAY).policyVersion, 1, "checked against the old cap");
    }

    /// A raise does not restore authority before the boundary.
    function test_raiseDoesNotRestoreAuthorityBeforeTheBoundary() public {
        settleRun(run(12000));
        uint64 today = config.todayIndex();
        uint64 boundary = config.nextWindowBoundary(today, WINDOW_DAYS);

        vm.prank(owner);
        config.setPolicy(CAP * 5, WINDOW_DAYS);

        assertEq(config.capAt(today), CAP, "raise not in force today");
        assertEq(config.capAt(boundary), CAP * 5, "raise in force from the boundary");
        authorizationIs(SpendValidator.Authorization.OverCap);
    }

    /// F7: the event says when a write was made as well as when it applies,
    /// so a reader of the log can check the deferral rather than trust it.
    function test_policyEventCarriesSubmissionAndEffectiveDay() public {
        bytes32 sig = keccak256("PolicyUpdated(uint256,int256,uint32,uint64,uint64,address)");
        uint64 today = config.todayIndex();

        vm.recordLogs();
        vm.prank(owner);
        config.setPolicy(CAP * 2, WINDOW_DAYS); // a raise
        vm.prank(owner);
        config.setPolicy(CAP / 2, WINDOW_DAYS); // a lowering

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            (int256 cap,, uint64 submitted, uint64 effective,) =
                abi.decode(logs[i].data, (int256, uint32, uint64, uint64, address));
            assertEq(submitted, today, "submitted today");
            if (cap == CAP * 2) {
                assertEq(effective, config.nextWindowBoundary(today, WINDOW_DAYS), "raise deferred");
            } else {
                assertEq(effective, today, "lowering immediate");
            }
            found++;
        }
        assertEq(found, 2);
    }

    /// A cancelled raise is removed from storage, not merely shadowed. Found by
    /// running a chain mutation through the differential: without the removal,
    /// every observable answer is unchanged, because regimeAt walks newest-first
    /// and meets the lowering before the stale raise. What changes is the stored
    /// history -- it keeps the dead epoch and stops being ordered by effective
    /// day, which D4.6 relies on to keep that walk short.
    function test_loweringRemovesTheCancelledRaiseFromStorage() public {
        assertEq(config.capEpochCount(), 1);

        vm.prank(owner);
        config.setPolicy(CAP * 5, WINDOW_DAYS); // pending raise
        assertEq(config.capEpochCount(), 2);

        vm.prank(owner);
        config.setPolicy(2000, WINDOW_DAYS); // lowering cancels it
        assertEq(config.capEpochCount(), 2, "the raise was removed and the lowering added");
        assertEq(config.capEpochAt(1).cap, 2000);
    }

    function test_loweringCancelsPendingRaise() public {
        uint64 boundary = config.nextWindowBoundary(ANCHOR_DAY, WINDOW_DAYS);

        vm.prank(owner);
        config.setPolicy(CAP * 5, WINDOW_DAYS);
        assertEq(config.capAt(boundary), CAP * 5);

        vm.prank(owner);
        config.setPolicy(2000, WINDOW_DAYS);

        assertEq(config.capAt(ANCHOR_DAY), 2000);
        assertEq(config.capAt(boundary), 2000, "the pending raise must not resurrect");
        assertEq(config.capAt(boundary + 365), 2000);
    }

    // ------------------------------------------------------------------
    // Upgrades carry the window and the authorisation state
    // ------------------------------------------------------------------

    function test_validatorSwapCarriesTheWindow() public {
        uint64 last = settleRun(runN(1500, 5));
        assertEq(validator.windowSum(last), 7500);

        vm.startPrank(owner);
        SpendValidator validator2 = new SpendValidator(config, ledger, address(account), 0);
        account.installModule(address(validator2));
        account.setSpendValidator(address(validator2));
        ledger.setWriter(address(validator2), true);
        account.uninstallModule(address(validator));
        ledger.setWriter(address(validator), false);
        vm.stopPrank();

        assertEq(validator2.windowSum(last), 7500, "upgrade must not mint capacity");
        assertEq(validator2.nextSettlementDay(), last + 1, "continues from the ledger, ignores its genesis");

        // 2500 more would be exactly the cap; 2501 is over. Settle through the
        // new validator.
        validator = validator2;
        settleRun(run(2501));
        authorizationIs(SpendValidator.Authorization.OverCap);
        expectAgentRefused();
    }

    /// A validator installed but not allowlisted cannot write -- D1.3 from the
    /// validator's side.
    function test_validatorWithoutAllowlistEntryCannotSettle() public {
        vm.startPrank(owner);
        SpendValidator orphan = new SpendValidator(config, ledger, address(account), ANCHOR_DAY);
        account.installModule(address(orphan));
        vm.stopPrank();

        validator = orphan;
        vm.expectRevert(SpendLedger.SpendLedger_NotAWriter.selector);
        this.settleExternal(ANCHOR_DAY, 1000);
    }

    function settleExternal(uint64 day, int256 spend) external {
        settle(day, spend);
    }

    /// onInstall used to be unpermissioned: a stranger could claim the module's
    /// account slot and make the real account's uninstall revert forever. The
    /// binding is immutable now.
    function test_strangerCannotBlockUninstall() public {
        vm.prank(stranger);
        vm.expectRevert(SpendValidator.SpendValidator_OnlySmartAccount.selector);
        validator.onInstall("");

        vm.prank(owner);
        account.uninstallModule(address(validator));
        assertFalse(account.installedModules(address(validator)));
    }

    /// With no spend validator selected the account refuses everyone: removing
    /// the hook is a stop, not a bypass (D1.5).
    function test_noValidatorMeansNoTransfers() public {
        vm.prank(owner);
        account.uninstallModule(address(validator));

        vm.prank(agent);
        vm.expectRevert(SmartAccount.SmartAccount_NoSpendValidator.selector);
        account.execute(payee, 1 wei);
    }

    // ------------------------------------------------------------------
    // Ledger writers may still accumulate a day (never on the live path, D7.9)
    // ------------------------------------------------------------------

    function test_ledgerWriterTopUpAccumulates() public {
        vm.prank(owner);
        ledger.setWriter(address(this), true);

        ledger.recordDay(ANCHOR_DAY, 1200, 1);
        ledger.recordDay(ANCHOR_DAY, 800, 1);
        assertEq(ledger.netSpendOf(ANCHOR_DAY), 2000, "the sum, not the last write");

        ledger.recordDay(ANCHOR_DAY, -1500, 1);
        assertEq(ledger.netSpendOf(ANCHOR_DAY), 500, "a negative top-up nets off");
    }
}
