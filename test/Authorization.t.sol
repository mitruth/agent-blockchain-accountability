// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {PolicyConfig} from "../contracts/PolicyConfig.sol";
import {SpendLedger} from "../contracts/SpendLedger.sol";
import {SmartAccount} from "../contracts/SmartAccount.sol";

/// Step 1 of the enforcement rebuild: key separation.
///
/// The authorisation map is asserted here directly, one test per row, rather
/// than inferred from a deployment script. The audited implementation had
/// owner == agent as a single EOA, so the agent's own wallet could call
/// setLimits; a self-imposed policy is not delegated authority. These tests are
/// what stops that reappearing.
///
/// | Actor         | May                                          | May not                              |
/// |---------------|----------------------------------------------|--------------------------------------|
/// | Owner EOA     | write PolicyConfig; install/uninstall modules;| --                                   |
/// |               | set ledger writer allowlist; unpause after   |                                      |
/// |               | delay; revoke session key immediately        |                                      |
/// | Agent session | submit daily records through the validator   | call setPolicy; install or uninstall |
/// | key           | (covered in step 2, with the validator)      | any module; write the ledger         |
/// |               |                                              | directly; alter the allowlist        |
/// | Guardian      | pause spends and agent                       | change any config value; unpause;    |
/// |               |                                              | write the ledger                     |
contract AuthorizationTest is Test {
    PolicyConfig internal config;
    SpendLedger internal ledger;
    SmartAccount internal account;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agentSessionKey");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    // Calibrated from arm B0's 7-day rolling sums over 2022 (359 full windows).
    int256 internal constant STRICT_CAP = 18096; // milli-USD, 85th percentile
    int256 internal constant PERMISSIVE_CAP = 107567; // milli-USD, rolling max
    uint32 internal constant WINDOW_DAYS = 7;

    // Chosen and recorded here. Pause expiry sits below one window so a hostile
    // guardian cannot strand the household for a whole accounting period; the
    // unpause delay is short but non-zero so a compromised owner key cannot
    // instantly undo a legitimate pause.
    uint32 internal constant PAUSE_EXPIRY = 72 hours;
    uint32 internal constant UNPAUSE_DELAY = 6 hours;

    uint64 internal constant ANCHOR_DAY = 20000;

    function setUp() public {
        vm.warp(uint256(ANCHOR_DAY) * 86400);

        vm.startPrank(owner);
        config = new PolicyConfig(
            guardian,
            agent,
            STRICT_CAP,
            WINDOW_DAYS,
            PAUSE_EXPIRY,
            UNPAUSE_DELAY
        );
        ledger = new SpendLedger();
        account = new SmartAccount(config, ledger);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // The three keys are actually three keys
    // ------------------------------------------------------------------

    function test_ownerAgentAndGuardianAreDistinctAddresses() public view {
        assertEq(config.owner(), owner);
        assertEq(config.sessionKey(), agent);
        assertEq(config.guardian(), guardian);

        assertTrue(config.owner() != config.sessionKey(), "owner == agent");
        assertTrue(config.owner() != config.guardian(), "owner == guardian");
        assertTrue(config.sessionKey() != config.guardian(), "agent == guardian");

        // The ledger and the account answer to the same owner, and to no one else.
        assertEq(ledger.owner(), owner);
        assertEq(account.owner(), owner);
    }

    // ------------------------------------------------------------------
    // Owner MAY
    // ------------------------------------------------------------------

    function test_owner_mayWritePolicyConfig() public {
        vm.prank(owner);
        config.setPolicy(STRICT_CAP - 1000, WINDOW_DAYS);

        assertEq(config.policyVersion(), 2);
        assertEq(config.capAt(config.todayIndex()), STRICT_CAP - 1000);
    }

    function test_owner_maySetLedgerWriterAllowlist() public {
        address validator = makeAddr("validator");

        vm.prank(owner);
        ledger.setWriter(validator, true);
        assertTrue(ledger.isWriter(validator));

        vm.prank(owner);
        ledger.setWriter(validator, false);
        assertFalse(ledger.isWriter(validator));
    }

    function test_owner_mayInstallAndUninstallModules() public {
        AcceptingModule module = new AcceptingModule();

        vm.prank(owner);
        account.installModule(address(module));
        assertTrue(account.installedModules(address(module)));

        vm.prank(owner);
        account.uninstallModule(address(module));
        assertFalse(account.installedModules(address(module)));
    }

    function test_owner_mayRevokeSessionKeyImmediately() public {
        vm.prank(owner);
        config.setSessionKey(address(0));

        assertEq(config.sessionKey(), address(0));
    }

    /// Revocation must not be blocked by a pause. A pause is exactly when a
    /// compromised key most needs removing.
    function test_owner_mayRevokeSessionKeyWhilePaused() public {
        vm.prank(guardian);
        config.pauseAgent();
        assertTrue(config.agentCurrentlyPaused());

        vm.prank(owner);
        config.setSessionKey(address(0));
        assertEq(config.sessionKey(), address(0));
    }

    /// Nor may a pause block the owner from lowering the cap.
    function test_owner_mayLowerCapWhilePaused() public {
        vm.prank(guardian);
        config.pauseSpends();

        vm.prank(owner);
        config.setPolicy(1000, WINDOW_DAYS);

        assertEq(config.capAt(config.todayIndex()), 1000);
    }

    function test_owner_mayUnpauseAfterDelay() public {
        vm.prank(guardian);
        config.pauseSpends();

        vm.warp(block.timestamp + UNPAUSE_DELAY);

        vm.prank(owner);
        config.unpause();

        assertFalse(config.spendsPaused());
        assertFalse(config.spendsCurrentlyPaused());
    }

    function test_owner_mayNotUnpauseBeforeDelay() public {
        vm.prank(guardian);
        config.pauseSpends();

        vm.warp(block.timestamp + UNPAUSE_DELAY - 1);

        vm.prank(owner);
        vm.expectRevert(bytes("PolicyConfig: unpause delay not elapsed"));
        config.unpause();

        assertTrue(config.spendsCurrentlyPaused());
    }

    // ------------------------------------------------------------------
    // Agent session key MAY NOT
    // ------------------------------------------------------------------

    /// The finding that started this rebuild, in its new shape.
    function test_agent_mayNotWritePolicyConfig() public {
        vm.prank(agent);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPolicy(PERMISSIVE_CAP, WINDOW_DAYS);

        assertEq(config.capAt(config.todayIndex()), STRICT_CAP);
        assertEq(config.policyVersion(), 1);
    }

    function test_agent_mayNotChangePauseTiming() public {
        vm.prank(agent);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPauseTiming(1, 0);
    }

    /// Restricting setPolicy is the easy half. If the session key can uninstall
    /// the validator the cap is simply gone, and the setPolicy restriction never
    /// mattered. The escalation path is asserted, not assumed.
    function test_agent_mayNotInstallModule() public {
        AcceptingModule module = new AcceptingModule();

        vm.prank(agent);
        vm.expectRevert(SmartAccount.SmartAccount_OnlyOwner.selector);
        account.installModule(address(module));

        assertFalse(account.installedModules(address(module)));
    }

    function test_agent_mayNotUninstallModule() public {
        AcceptingModule module = new AcceptingModule();

        vm.prank(owner);
        account.installModule(address(module));

        vm.prank(agent);
        vm.expectRevert(SmartAccount.SmartAccount_OnlyOwner.selector);
        account.uninstallModule(address(module));

        assertTrue(account.installedModules(address(module)));
    }

    function test_agent_mayNotWriteLedgerDirectly() public {
        vm.prank(agent);
        vm.expectRevert(SpendLedger.SpendLedger_NotAWriter.selector);
        ledger.recordDay(ANCHOR_DAY, 5000, 1, false);

        assertFalse(ledger.isRecorded(ANCHOR_DAY));
    }

    function test_agent_mayNotAlterLedgerAllowlist() public {
        vm.prank(agent);
        vm.expectRevert(SpendLedger.SpendLedger_OnlyOwner.selector);
        ledger.setWriter(agent, true);

        assertFalse(ledger.isWriter(agent));
    }

    function test_agent_mayNotReassignRoles() public {
        vm.prank(agent);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setSessionKey(agent);

        vm.prank(agent);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setGuardian(agent);
    }

    function test_agent_mayNotPause() public {
        vm.prank(agent);
        vm.expectRevert(bytes("PolicyConfig: only guardian"));
        config.pauseSpends();
    }

    // ------------------------------------------------------------------
    // Guardian MAY
    // ------------------------------------------------------------------

    function test_guardian_mayPauseSpends() public {
        vm.prank(guardian);
        config.pauseSpends();

        assertTrue(config.spendsCurrentlyPaused());
        assertFalse(config.agentCurrentlyPaused());
    }

    function test_guardian_mayPauseAgent() public {
        vm.prank(guardian);
        config.pauseAgent();

        assertTrue(config.agentCurrentlyPaused());
        assertFalse(config.spendsCurrentlyPaused());
    }

    // ------------------------------------------------------------------
    // Guardian MAY NOT
    // ------------------------------------------------------------------

    function test_guardian_mayNotChangeAnyConfigValue() public {
        vm.prank(guardian);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPolicy(PERMISSIVE_CAP, WINDOW_DAYS);

        vm.prank(guardian);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPauseTiming(1 hours, 30 minutes);

        vm.prank(guardian);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setSessionKey(guardian);

        vm.prank(guardian);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setGuardian(guardian);
    }

    function test_guardian_mayNotUnpause() public {
        vm.prank(guardian);
        config.pauseSpends();

        vm.warp(block.timestamp + UNPAUSE_DELAY);

        vm.prank(guardian);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.unpause();

        assertTrue(config.spendsCurrentlyPaused());
    }

    function test_guardian_mayNotWriteLedger() public {
        vm.prank(guardian);
        vm.expectRevert(SpendLedger.SpendLedger_NotAWriter.selector);
        ledger.recordDay(ANCHOR_DAY, 5000, 1, false);
    }

    function test_guardian_mayNotAlterLedgerAllowlist() public {
        vm.prank(guardian);
        vm.expectRevert(SpendLedger.SpendLedger_OnlyOwner.selector);
        ledger.setWriter(guardian, true);
    }

    function test_guardian_mayNotInstallModule() public {
        AcceptingModule module = new AcceptingModule();

        vm.prank(guardian);
        vm.expectRevert(SmartAccount.SmartAccount_OnlyOwner.selector);
        account.installModule(address(module));
    }

    function test_account_bindsStickyPolicyPair() public view {
        assertEq(address(account.policyConfig()), address(config));
        assertEq(address(account.spendLedger()), address(ledger));
    }

    function test_uninstallRemovesModuleFromIterationList() public {
        AcceptingModule module = new AcceptingModule();

        vm.prank(owner);
        account.installModule(address(module));
        assertEq(account.getInstalledModules().length, 1);

        vm.prank(owner);
        account.uninstallModule(address(module));
        assertEq(account.getInstalledModules().length, 0);
    }

    // ------------------------------------------------------------------
    // Ledger write authority does not leak from module install status
    // ------------------------------------------------------------------

    /// If ledger writes derived from "is this module installed on the account",
    /// then permission to install a module would silently become permission to
    /// write the ledger, and the upgrade path would become the attack path.
    /// Installing a module must move the allowlist not at all.
    function test_installingModuleGrantsNoLedgerWriteAuthority() public {
        AcceptingModule module = new AcceptingModule();

        vm.prank(owner);
        account.installModule(address(module));
        assertTrue(account.installedModules(address(module)));

        assertFalse(ledger.isWriter(address(module)));

        vm.prank(address(module));
        vm.expectRevert(SpendLedger.SpendLedger_NotAWriter.selector);
        ledger.recordDay(ANCHOR_DAY, 5000, 1, false);
    }

    /// And the converse: revoking the allowlist entry stops ledger writes even
    /// while the module stays installed on the account.
    function test_allowlistRevocationStopsWritesWhileStillInstalled() public {
        AcceptingModule module = new AcceptingModule();

        vm.startPrank(owner);
        account.installModule(address(module));
        ledger.setWriter(address(module), true);
        vm.stopPrank();

        vm.prank(address(module));
        ledger.recordDay(ANCHOR_DAY, 5000, 1, false);
        assertTrue(ledger.isRecorded(ANCHOR_DAY));

        vm.prank(owner);
        ledger.setWriter(address(module), false);

        assertTrue(account.installedModules(address(module)), "still installed");

        vm.prank(address(module));
        vm.expectRevert(SpendLedger.SpendLedger_NotAWriter.selector);
        ledger.recordDay(ANCHOR_DAY + 1, 5000, 1, false);
    }

    // ------------------------------------------------------------------
    // No stray authority
    // ------------------------------------------------------------------

    function test_stranger_mayDoNothing() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPolicy(PERMISSIVE_CAP, WINDOW_DAYS);

        vm.prank(stranger);
        vm.expectRevert(bytes("PolicyConfig: only guardian"));
        config.pauseSpends();

        vm.prank(stranger);
        vm.expectRevert(SpendLedger.SpendLedger_OnlyOwner.selector);
        ledger.setWriter(stranger, true);

        vm.prank(stranger);
        vm.expectRevert(SpendLedger.SpendLedger_NotAWriter.selector);
        ledger.recordDay(ANCHOR_DAY, 1, 1, false);
    }

    /// The test contract deployed nothing as itself. It must hold no authority,
    /// or every other assertion here is measuring the wrong thing.
    function test_testContractHoldsNoAuthority() public {
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPolicy(PERMISSIVE_CAP, WINDOW_DAYS);

        vm.expectRevert(SpendLedger.SpendLedger_OnlyOwner.selector);
        ledger.setWriter(address(this), true);
    }
}

/// Minimal module used only to exercise install/uninstall authorisation.
contract AcceptingModule {
    function onInstall(bytes calldata) external {}

    function onUninstall(bytes calldata) external {}

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 1;
    }

    function validateTransaction(address, address, uint256) external pure returns (bool) {
        return true;
    }
}
