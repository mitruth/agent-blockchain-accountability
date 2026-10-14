// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {RhinestoneModuleKit, ModuleKitHelpers, AccountInstance, AccountType} from "modulekit/ModuleKit.sol";
import {MODULE_TYPE_EXECUTOR} from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
import {MockExecutor} from "modulekit/Mocks.sol";

import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {GateBase} from "../../contracts/gate/GateBase.sol";
import {StubMarket, StubDecoder, CapPolicy} from "../gate/mocks/GateMocks.sol";

interface IAccountId {
    function accountId() external view returns (string memory);
}

/// Step 1 on real account implementations, through ModuleKit.
///
/// test/gate/ asserts the key model against a minimal account. This file
/// installs the same gate, as an executor module, on the ERC-7579 reference
/// account, Safe7579, Nexus and Kernel, and repeats the properties that depend
/// on how an account behaves: who the market sees, whether the account's own
/// module management can be reached, and that configuration arrives only
/// through the account.
///
/// Foundry only: ModuleKit does not build under Hardhat.
///
/// ModuleKit's default validator accepts any signature. It stands in for the
/// owner's root validator here; a userOp sent through `instance.exec` is the
/// owner path.
contract PolicyGateAccountsTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;

    bytes32 internal constant POLICY_ID = keccak256("cap");
    uint64 internal constant SOFT = 800;
    uint64 internal constant HARD = 1000;

    PositionLedger internal ledger;
    PolicyGate internal gate;
    StubMarket internal market;
    StubDecoder internal decoder;
    CapPolicy internal policy;

    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_760_000_000);

        ledger = new PositionLedger();
        gate = new PolicyGate(ledger);
        market = new StubMarket();
        decoder = new StubDecoder();
        policy = new CapPolicy(address(gate));

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

        uint48 validUntil = uint48(block.timestamp + 30 days);
        instance.exec(address(gate), abi.encodeCall(gate.registerAgent, (agent, validUntil)));
        instance.exec(
            address(gate), abi.encodeCall(gate.setDecoder, (address(market), StubMarket.placeOrder.selector, decoder))
        );
        instance.exec(address(gate), abi.encodeCall(gate.addPolicy, (policy, POLICY_ID, abi.encode(SOFT, HARD))));

        assertTrue(gate.isAgentActive(account, agent), "agent registered through the account");
        assertTrue(gate.hasPolicy(account, policy, POLICY_ID), "policy added through the account");

        // A registered agent's approved call is made by the account.
        bytes memory order = abi.encodeCall(StubMarket.placeOrder, (0, 100, 1500, 250_000));
        vm.prank(agent);
        gate.submit(account, address(market), order);
        assertEq(market.orderCount(), 1);
        assertEq(market.lastCaller(), account, "the market sees the account");

        // An unregistered caller is rejected.
        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, account, stranger));
        vm.prank(stranger);
        gate.submit(account, address(market), order);

        // An unapproved function of an approved market is rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyGate.PolicyGate_UnknownCall.selector, address(market), StubMarket.withdrawAll.selector
            )
        );
        vm.prank(agent);
        gate.submit(account, address(market), abi.encodeCall(StubMarket.withdrawAll, ()));

        // The agent cannot manage modules: not by calling the account, and not
        // by having the account call itself through the gate.
        MockExecutor rogue = new MockExecutor();
        bytes memory install = abi.encodeWithSignature(
            "installModule(uint256,address,bytes)", MODULE_TYPE_EXECUTOR, address(rogue), bytes("")
        );
        bytes memory uninstall = abi.encodeWithSignature(
            "uninstallModule(uint256,address,bytes)", MODULE_TYPE_EXECUTOR, address(gate), bytes("")
        );

        vm.startPrank(agent);
        (bool ok,) = account.call(install);
        ok;
        (ok,) = account.call(uninstall);
        ok;
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, account));
        vm.prank(agent);
        gate.submit(account, account, install);

        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, account));
        vm.prank(agent);
        gate.submit(account, account, uninstall);

        assertFalse(instance.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(rogue)), "rogue module not installed");
        assertTrue(instance.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(gate)), "gate still installed");

        // The agent cannot reach the gate's registries or the configuration.
        bytes memory widen = abi.encode(SOFT, uint64(2000));

        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(gate)));
        vm.prank(agent);
        gate.submit(account, address(gate), abi.encodeCall(gate.registerAgent, (stranger, validUntil)));

        vm.expectRevert(abi.encodeWithSelector(GateBase.Gate_NotInstalled.selector, agent));
        vm.prank(agent);
        gate.setConfig(policy, POLICY_ID, widen);

        assertFalse(gate.isAgentActive(account, stranger));

        // The owner widens: proposed now, in force only after the delay.
        instance.exec(address(gate), abi.encodeCall(gate.setConfig, (policy, POLICY_ID, widen)));
        assertEq(_hardCap(account), HARD, "widening not in force at once");

        vm.warp(block.timestamp + gate.WIDEN_DELAY());

        vm.expectRevert(abi.encodeWithSelector(GateBase.Gate_NotInstalled.selector, agent));
        vm.prank(agent);
        gate.applyConfig(policy, POLICY_ID, widen);
        assertEq(_hardCap(account), HARD, "the agent cannot finish the owner's widening");

        instance.exec(address(gate), abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, widen)));
        assertEq(_hardCap(account), 2000, "widening in force after the delay");

        // The owner uninstalls; the agent's authority goes with the gate.
        instance.uninstallModule({moduleTypeId: MODULE_TYPE_EXECUTOR, module: address(gate), data: ""});
        assertFalse(gate.isInstalled(account));
        assertFalse(gate.isAgentActive(account, agent));
    }

    function _hardCap(address account) internal view returns (uint64 hard) {
        (,, hard) = policy.caps(account, POLICY_ID);
    }
}
