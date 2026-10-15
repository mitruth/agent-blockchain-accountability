// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {RhinestoneModuleKit, ModuleKitHelpers, AccountInstance, AccountType, UserOpData} from "modulekit/ModuleKit.sol";
import {ExecutionReturnData} from "modulekit/test/RhinestoneModuleKit.sol";
import {EncodeLib} from "modulekit/test/helpers/SmartSessionHelpers.sol";
import {MODULE_TYPE_HOOK} from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
import {KernelHelpers} from "modulekit/test/helpers/KernelHelpers.sol";
import {MockPolicy} from "modulekit/Mocks.sol";
import {
    Session,
    PermissionId,
    ActionData,
    PolicyData,
    ERC7739Data,
    ISessionValidator
} from "modulekit/integrations/interfaces/ISmartSession.sol";

/// Rhinestone Smart Sessions on ModuleKit's accounts, for the agent's entry
/// point (decision D1, option 3): a session whose only action is one function
/// of one contract, and that can sign nothing.
///
/// Foundry only. ModuleKit 0.5.9 bundles a Smart Sessions build of September
/// 2024; its session validator is a mock that accepts any signature, so what
/// these tests exercise is the session's scope, not its cryptography.
abstract contract SessionFixture is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;

    /// The policy on every action: allows everything. The scoping is the
    /// action itself, a (target, selector) pair.
    MockPolicy internal allow;

    function _setUpSessions() internal {
        allow = new MockPolicy();
    }

    function _session(
        AccountInstance memory instance,
        bytes32 salt,
        ActionData[] memory actions,
        ERC7739Data memory erc7739
    )
        internal
        pure
        returns (Session memory)
    {
        return Session({
            sessionValidator: ISessionValidator(address(instance.defaultSessionValidator)),
            sessionValidatorInitData: "mockInitData",
            salt: salt,
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: erc7739,
            actions: actions
        });
    }

    /// One action: `selector` on `target`.
    function _only(address target, bytes4 selector) internal view returns (ActionData[] memory actions) {
        PolicyData[] memory policies = new PolicyData[](1);
        policies[0] = PolicyData({policy: address(allow), initData: ""});
        actions = new ActionData[](1);
        actions[0] = ActionData({actionTargetSelector: selector, actionTarget: target, actionPolicies: policies});
    }

    /// The agent's session: no ERC-7739 content, no ERC-1271 policy.
    function _noSigning() internal pure returns (ERC7739Data memory) {
        return ERC7739Data({allowedERC7739Content: new string[](0), erc1271Policies: new PolicyData[](0)});
    }

    /// Install Smart Sessions if needed and enable `session`. On Kernel the
    /// validator is installed without a hook: Kernel runs a hooked
    /// validator's operations through executeUserOp, which Smart Sessions
    /// refuses.
    function _enableSession(AccountInstance memory instance, Session memory session) internal returns (PermissionId) {
        address hook = _unhookKernel(instance);
        PermissionId id = instance.addSession(session);
        _rehookKernel(instance, hook);
        return id;
    }

    /// One user operation signed with the session, returning its logs.
    /// (ModuleKit records the logs of every operation it sends, so a test
    /// cannot record them around `useSession` itself.)
    function _sessionOp(AccountInstance memory instance, Session memory session, address target, bytes memory data)
        internal
        returns (Vm.Log[] memory)
    {
        address hook = _unhookKernel(instance);
        UserOpData memory op = instance.getExecOps(target, 0, data, address(instance.smartSession));
        op.userOp.signature = EncodeLib.encodeUse(instance.getPermissionId(session), op.userOp.signature);
        ExecutionReturnData memory result = op.execUserOps();
        _rehookKernel(instance, hook);
        return result.logs;
    }

    /// A session operation in a call of its own, so that `vm.expectRevert`
    /// applies to the whole operation.
    function useSessionOrRevert(bytes calldata inst, bytes calldata sess, address target, bytes calldata data)
        external
    {
        AccountInstance memory instance = abi.decode(inst, (AccountInstance));
        Session memory session = abi.decode(sess, (Session));
        _sessionOp(instance, session, target, data);
    }

    function _expectSessionRefused(AccountInstance memory instance, Session memory session, address target, bytes memory data)
        internal
    {
        vm.expectRevert();
        this.useSessionOrRevert(abi.encode(instance), abi.encode(session), target, data);
    }

    /// ModuleKit's own workaround (withHookFixForKernel), for the steps it
    /// does not cover: on Kernel, take the hook multiplexer off while Smart
    /// Sessions is installed or used, and put it back after.
    function _unhookKernel(AccountInstance memory instance) internal returns (address hook) {
        if (instance.accountType != AccountType.KERNEL) return address(0);
        hook = KernelHelpers(instance.accountHelper).getHookMultiPlexer(instance);
        instance.uninstallModule(MODULE_TYPE_HOOK, hook, "");
        KernelHelpers(instance.accountHelper).setHookMultiPlexer(instance, address(1));
    }

    function _rehookKernel(AccountInstance memory instance, address hook) internal {
        if (instance.accountType != AccountType.KERNEL) return;
        KernelHelpers(instance.accountHelper).setHookMultiPlexer(instance, hook);
        instance.installModule(MODULE_TYPE_HOOK, hook, "");
    }

    /// Whether `emitter` emitted `topic0` with `account` as first indexed argument.
    function _logged(Vm.Log[] memory logs, address emitter, bytes32 topic0, address account)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length > 1 && logs[i].topics[0] == topic0
                    && logs[i].topics[1] == bytes32(uint256(uint160(account)))
            ) return true;
        }
        return false;
    }
}
