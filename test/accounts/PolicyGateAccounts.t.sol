// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ModuleKitHelpers, AccountInstance, AccountType} from "modulekit/ModuleKit.sol";
import {MODULE_TYPE_EXECUTOR} from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
import {MockExecutor} from "modulekit/Mocks.sol";
import {Session} from "modulekit/integrations/interfaces/ISmartSession.sol";

import {SessionFixture} from "./SessionFixture.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {GateBase} from "../../contracts/gate/GateBase.sol";
import {DecoderRegistry} from "../../contracts/gate/DecoderRegistry.sol";
import {StubMarket, StubDecoder, CapPolicy} from "../gate/mocks/GateMocks.sol";
import {SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";

interface IAccountId {
    function accountId() external view returns (string memory);
}

/// The key model on real account implementations, through ModuleKit.
///
/// test/gate/ asserts it against a minimal account whose sessions stand in for
/// Smart Sessions. This file installs the same gate, as an executor module, on
/// the ERC-7579 reference account, Safe7579, Nexus and Kernel, gives the agent
/// a real Rhinestone Smart Session whose only action is the gate's `submit`
/// (decision D1, option 3), and repeats the properties that depend on how an
/// account behaves: who the market sees, whether the account's own module
/// management can be reached, and that configuration arrives only through the
/// account.
///
/// Foundry only: ModuleKit does not build under Hardhat.
///
/// ModuleKit's default validator accepts any signature. It stands in for the
/// owner's root validator here; a userOp sent through `instance.exec` is the
/// owner path. That the agent's session cannot sign for the account is shown
/// in SessionGate.t.sol.
contract PolicyGateAccountsTest is SessionFixture {
    using ModuleKitHelpers for *;

    bytes32 internal constant POLICY_ID = keccak256("cap");
    uint64 internal constant SOFT = 800;
    uint64 internal constant HARD = 1000;

    PositionLedger internal ledger;
    PolicyGate internal gate;
    StubMarket internal market;
    StubDecoder internal decoder;
    CapPolicy internal policy;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_760_000_000);

        ledger = new PositionLedger();
        gate = new PolicyGate(ledger, new OracleVerifier(), 48);
        market = new StubMarket();
        decoder = new StubDecoder();
        policy = new CapPolicy(address(gate));
        _setUpSessions();

        // Deploys ModuleKit's factories and auxiliary contracts. Done here so
        // that switching account type inside a test finds them in place.
        makeAccountInstance("warmup");
    }

    function test_referenceAccount() public {
        _scenario(AccountType.DEFAULT, "uMSA.advanced/withHook.v0.1");
    }

    function test_safe7579() public {
        _scenario(AccountType.SAFE, "rhinestone.safe7579.v1.0.0");
    }

    function test_nexus() public {
        _scenario(AccountType.NEXUS, "biconomy.nexus.1.0.0");
    }

    function test_kernel() public {
        _scenario(AccountType.KERNEL, "kernel.advanced.v0.3.1");
    }

    function _scenario(AccountType env, string memory expectedAccountId) internal {
        ModuleKitHelpers.setAccountEnv(env);
        AccountInstance memory instance = makeAccountInstance("policy-gate");
        assertEq(uint8(instance.accountType), uint8(env), "account type");
        address account = instance.account;
        vm.deal(account, 10 ether);

        // The account says which implementation it is. Without this, a test
        // that silently ran on the wrong account type would still pass.
        instance.deployAccount();
        assertEq(IAccountId(account).accountId(), expectedAccountId, "account implementation");

        // The owner installs the gate and sets it up.
        instance.installModule({moduleTypeId: MODULE_TYPE_EXECUTOR, module: address(gate), data: ""});
        instance.exec(address(ledger), abi.encodeCall(ledger.setWriter, (address(gate), true)));
        assertTrue(instance.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(gate)), "gate installed");
        assertTrue(gate.isInstalled(account));

        instance.exec(
            address(gate), abi.encodeCall(gate.setDecoder, (address(market), StubMarket.placeOrder.selector, decoder))
        );
        instance.exec(address(gate), abi.encodeCall(gate.addPolicy, (policy, POLICY_ID, abi.encode(SOFT, HARD))));
        assertTrue(gate.hasPolicy(account, policy, POLICY_ID), "policy added through the account");

        // The owner gives the agent its session: the gate's submit, nothing else.
        Session memory agent = _session(instance, "agent", _only(address(gate), PolicyGate.submit.selector), _noSigning());
        _enableSession(instance, agent);

        // Through its session, the agent's approved call is made by the account.
        bytes memory order = abi.encodeCall(StubMarket.placeOrder, (0, 100, 1500, 250_000));
        _sessionOp(instance, agent, address(gate), abi.encodeCall(gate.submit, (address(market), order, new SignedReading[](0))));
        assertEq(market.orderCount(), 1);
        assertEq(market.lastCaller(), account, "the market sees the account");
        assertEq(ledger.openOrderCount(account), 1, "the order is booked against the account");

        // Nobody but the account may call submit.
        vm.expectRevert(abi.encodeWithSelector(GateBase.Gate_NotInstalled.selector, stranger));
        vm.prank(stranger);
        gate.submit(address(market), order, new SignedReading[](0));

        // An unapproved function of an approved market is rejected.
        _expectSessionRefused(
            instance, agent, address(gate), abi.encodeCall(gate.submit, (address(market), abi.encodeCall(StubMarket.withdrawAll, ()), new SignedReading[](0)))
        );

        // The session reaches nothing but submit: not the market directly, not
        // the gate's owner path, not the account's module management.
        MockExecutor rogue = new MockExecutor();
        bytes memory install = abi.encodeWithSignature(
            "installModule(uint256,address,bytes)", MODULE_TYPE_EXECUTOR, address(rogue), bytes("")
        );
        bytes memory uninstall = abi.encodeWithSignature(
            "uninstallModule(uint256,address,bytes)", MODULE_TYPE_EXECUTOR, address(gate), bytes("")
        );
        _expectSessionRefused(instance, agent, address(market), order);
        _expectSessionRefused(
            instance, agent, address(gate), abi.encodeCall(gate.setDecoder, (address(market), StubMarket.withdrawAll.selector, decoder))
        );
        _expectSessionRefused(instance, agent, account, install);
        _expectSessionRefused(instance, agent, account, uninstall);

        // Nor through submit: the account is never a target.
        _expectSessionRefused(instance, agent, address(gate), abi.encodeCall(gate.submit, (account, install, new SignedReading[](0))));
        _expectSessionRefused(instance, agent, address(gate), abi.encodeCall(gate.submit, (account, uninstall, new SignedReading[](0))));

        // Nor can the owner open those doors: the account and the gate are never
        // approved as targets, and an unapproved function fails as unknown.
        _expectOwnerRefused(instance, DecoderRegistry.DecoderRegistry_ForbiddenTarget.selector);
        instance.exec(address(gate), abi.encodeCall(gate.setDecoder, (account, bytes4(install), decoder)));
        _expectOwnerRefused(instance, DecoderRegistry.DecoderRegistry_ForbiddenTarget.selector);
        instance.exec(address(gate), abi.encodeCall(gate.setDecoder, (address(gate), DecoderRegistry.setDecoder.selector, decoder)));
        // ModuleKit checks a revert's reason only when there is one: check
        // that nothing was approved.
        assertEq(address(gate.decoderOf(account, account, bytes4(install))), address(0), "the account is no target");
        assertEq(
            address(gate.decoderOf(account, address(gate), DecoderRegistry.setDecoder.selector)), address(0), "the gate is no target"
        );
        _expectOwnerRefused(instance, PolicyGate.PolicyGate_UnknownCall.selector);
        instance.exec(
            address(gate),
            abi.encodeCall(gate.submit, (address(market), abi.encodeCall(StubMarket.withdrawAll, ()), new SignedReading[](0)))
        );

        assertEq(market.orderCount(), 1, "nothing else reached the market");
        assertFalse(instance.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(rogue)), "rogue module not installed");
        assertTrue(instance.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(gate)), "gate still installed");

        // The owner widens: proposed now, in force only after the delay, and
        // only the owner can apply it.
        bytes memory widen = abi.encode(SOFT, uint64(2000));
        instance.exec(address(gate), abi.encodeCall(gate.setConfig, (policy, POLICY_ID, widen)));
        assertEq(_hardCap(account), HARD, "widening not in force at once");

        vm.warp(block.timestamp + gate.WIDEN_DELAY());
        _expectSessionRefused(instance, agent, address(gate), abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, widen)));
        assertEq(_hardCap(account), HARD, "the agent cannot finish the owner's widening");

        instance.exec(address(gate), abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, widen)));
        assertEq(_hardCap(account), 2000, "widening in force after the delay");

        // The owner uninstalls; the session can no longer reach anything.
        instance.uninstallModule({moduleTypeId: MODULE_TYPE_EXECUTOR, module: address(gate), data: ""});
        assertFalse(gate.isInstalled(account));
        _expectSessionRefused(instance, agent, address(gate), abi.encodeCall(gate.submit, (address(market), order, new SignedReading[](0))));
        assertEq(market.orderCount(), 1);
    }

    /// @dev The reference account and Nexus pass the gate's own error up as it
    ///      is; Safe7579 and Kernel wrap it in theirs. Where it comes through,
    ///      it must be the expected one.
    function _expectOwnerRefused(AccountInstance memory instance, bytes4 selector) internal {
        if (instance.accountType == AccountType.DEFAULT || instance.accountType == AccountType.NEXUS) {
            instance.expect4337Revert(selector);
        } else {
            instance.expect4337Revert();
        }
    }

    function _hardCap(address account) internal view returns (uint64 hard) {
        (,, hard) = policy.caps(account, POLICY_ID);
    }
}
