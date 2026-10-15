// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {RhinestoneModuleKit, ModuleKitHelpers, AccountInstance, AccountType, UserOpData} from "modulekit/ModuleKit.sol";
import {ExecutionReturnData} from "modulekit/test/RhinestoneModuleKit.sol";
import {EncodeLib} from "modulekit/test/helpers/SmartSessionHelpers.sol";
import {MODULE_TYPE_EXECUTOR, MODULE_TYPE_HOOK} from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
import {KernelHelpers} from "modulekit/test/helpers/KernelHelpers.sol";
import {MockPolicy, MockExecutor} from "modulekit/Mocks.sol";
import {
    Session,
    PermissionId,
    ActionData,
    PolicyData,
    ERC7739Data,
    ISessionValidator
} from "modulekit/integrations/interfaces/ISmartSession.sol";

import {IERC7579Module, IERC7579Execution} from "../../contracts/interfaces/IERC7579.sol";
import {StubMarket} from "../gate/mocks/GateMocks.sol";

/// The entry point of option 3 for decision D1, on real accounts: the agent
/// holds a Rhinestone Smart Session on the account, scoped to one function of
/// the gate, and the gate, an executor, does the rest (docs/analysis/
/// delegation-architecture.md, check 3).
///
/// What must hold for option 3 to be sound, on each account implementation:
///
///   1  through its session, the agent can reach the gate's `submit`, and the
///      gate can make the account call the market from inside that same
///      execution (the account is re-entered through executeFromExecutor);
///   2  a refusal by the gate is recorded on chain: the user operation
///      succeeds and the refusal's event is in the log;
///   3  the session can call nothing else: not the market directly, not the
///      gate's owner functions, not the account's module management, not the
///      account's own execute;
///   4  the session cannot sign for the account (ERC-1271). On Nexus a
///      session configured to sign does sign, with the same signature format
///      (the positive control: the refusal is the session's scope, not a
///      malformed signature). On the other three no session can sign at all,
///      for the reasons below; the agent's session a fortiori.
///
/// Facts about the accounts, found by this test:
///   - Kernel runs a hooked validator's user operations through executeUserOp,
///     which Smart Sessions refuses: the Smart Sessions validator must be
///     installed on Kernel without a hook.
///   - Kernel hands a validator its own wrapped hash for ERC-1271, so Smart
///     Sessions cannot rebuild the ERC-7739 hash and refuses the signature.
///   - The reference account and Safe7579, as ModuleKit deploys them, have no
///     eip712Domain(), which Smart Sessions reads to check a session
///     signature, so the check reverts.
///
/// `SessionGateProbe` stands in for the gate as option 3 would change it:
/// `submit` is called by the account itself. It is a test double; the real
/// gate is not changed until D1 is decided.
///
/// Foundry only. ModuleKit 0.5.9 bundles a Smart Sessions build older than
/// v1.0.0; the source of v1.0.0 and of main was read for the same properties.
contract SessionGateTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;

    SessionGateProbe internal gate;
    StubMarket internal market;
    MockPolicy internal allow;

    function setUp() public {
        vm.warp(1_760_000_000);
        gate = new SessionGateProbe();
        market = new StubMarket();
        allow = new MockPolicy();
        makeAccountInstance("warmup");
    }

    function test_referenceAccount() public {
        _scenario(AccountType.DEFAULT, false);
    }

    function test_safe7579() public {
        _scenario(AccountType.SAFE, false);
    }

    function test_nexus() public {
        _scenario(AccountType.NEXUS, true);
    }

    function test_kernel() public {
        _scenario(AccountType.KERNEL, false);
    }

    // ------------------------------------------------------------------

    /// `sessionsCanSign`: whether any session's ERC-1271 signature can verify
    /// on this account at all (see the notes above the contract).
    function _scenario(AccountType env, bool sessionsCanSign) internal {
        ModuleKitHelpers.setAccountEnv(env);
        AccountInstance memory instance = makeAccountInstance("session-gate");
        address account = instance.account;
        vm.deal(account, 10 ether);
        instance.deployAccount();

        // The owner installs the gate (an executor) and gives the agent a
        // session that may call one function: gate.submit.
        instance.installModule({moduleTypeId: MODULE_TYPE_EXECUTOR, module: address(gate), data: ""});
        Session memory agent = _session(instance, "agent", _onlySubmit(), _noSigning());
        address hook = _unhookKernel(instance); // Smart Sessions installed without a hook on Kernel
        instance.addSession(agent);
        _rehookKernel(instance, hook);

        // 1. Through the session, submit reaches the market as the account.
        bytes memory order = abi.encodeCall(StubMarket.placeOrder, (0, 100, 1500, 250_000));
        instance.useSession(agent, address(gate), 0, abi.encodeCall(gate.submit, (address(market), order)));
        assertEq(market.orderCount(), 1, "the order reached the market");
        assertEq(market.lastCaller(), account, "the market sees the account");

        // 2. A refusal is recorded, and the user operation still succeeds.
        bytes memory refused = abi.encodeCall(StubMarket.withdrawAll, ());
        Vm.Log[] memory logs =
            _sessionOp(instance, agent, address(gate), abi.encodeCall(gate.submit, (address(market), refused)));
        assertTrue(_logged(logs, address(gate), SessionGateProbe.Refused.selector, account), "the refusal is in the log");
        assertEq(market.orderCount(), 1, "the refused call did not reach the market");
        assertEq(gate.refusals(account), 1, "the refusal is on chain");

        // 3. The session can call nothing else.
        bytes memory inst = abi.encode(instance);
        bytes memory sess = abi.encode(agent);
        MockExecutor rogue = new MockExecutor();

        vm.expectRevert();
        this.useSessionOrRevert(inst, sess, address(market), order);

        vm.expectRevert();
        this.useSessionOrRevert(inst, sess, address(gate), abi.encodeCall(gate.setCap, (type(uint256).max)));

        vm.expectRevert();
        this.useSessionOrRevert(
            inst,
            sess,
            account,
            abi.encodeWithSignature(
                "installModule(uint256,address,bytes)", MODULE_TYPE_EXECUTOR, address(rogue), bytes("")
            )
        );

        vm.expectRevert();
        this.useSessionOrRevert(
            inst,
            sess,
            account,
            abi.encodeWithSignature(
                "uninstallModule(uint256,address,bytes)", MODULE_TYPE_EXECUTOR, address(gate), bytes("")
            )
        );

        vm.expectRevert();
        this.useSessionOrRevert(
            inst,
            sess,
            account,
            abi.encodeWithSignature(
                "execute(bytes32,bytes)", bytes32(0), abi.encodePacked(address(market), uint256(0), order)
            )
        );

        assertEq(market.orderCount(), 1, "nothing else reached the market");
        assertEq(gate.cap(), 0, "the gate's owner function was not reached");
        assertFalse(instance.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(rogue)), "no module installed");
        assertTrue(instance.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(gate)), "the gate is still installed");

        // 4. The agent's session cannot sign for the account; a session made
        //    to sign can, with a signature built the same way.
        Session memory signer = _session(instance, "signer", _onlySubmit(), _signing());
        PermissionId signerId = instance.addSession(signer);
        PermissionId agentId = instance.getPermissionId(agent);

        if (sessionsCanSign) {
            assertTrue(_signs(instance, signerId), "positive control: a session configured to sign does sign");
        } else {
            assertFalse(_signs(instance, signerId), "on this account no session signs, not even the signer");
        }
        assertFalse(_signs(instance, agentId), "the agent's session cannot sign for the account");
    }

    /// A session operation in a call of its own, so that `vm.expectRevert`
    /// applies to the whole operation.
    function useSessionOrRevert(bytes calldata inst, bytes calldata sess, address target, bytes calldata data)
        external
    {
        AccountInstance memory instance = abi.decode(inst, (AccountInstance));
        Session memory session = abi.decode(sess, (Session));
        instance.useSession(session, target, 0, data);
    }

    /// One user operation signed with the session, as `useSession` sends it,
    /// returning its logs. (ModuleKit records the logs of every operation it
    /// sends, so a test cannot record them around `useSession` itself.)
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

    // --- sessions ---------------------------------------------------------

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

    /// One action: gate.submit. The policy on it allows everything; the
    /// scoping is the action itself, a (target, selector) pair.
    function _onlySubmit() internal view returns (ActionData[] memory actions) {
        PolicyData[] memory policies = new PolicyData[](1);
        policies[0] = PolicyData({policy: address(allow), initData: ""});
        actions = new ActionData[](1);
        actions[0] = ActionData({
            actionTargetSelector: SessionGateProbe.submit.selector,
            actionTarget: address(gate),
            actionPolicies: policies
        });
    }

    /// The agent's session: no ERC-7739 content, no ERC-1271 policy.
    function _noSigning() internal pure returns (ERC7739Data memory) {
        return ERC7739Data({allowedERC7739Content: new string[](0), erc1271Policies: new PolicyData[](0)});
    }

    /// The positive control: one content type allowed, and a policy that
    /// accepts every signature.
    function _signing() internal view returns (ERC7739Data memory data) {
        data.allowedERC7739Content = new string[](1);
        data.allowedERC7739Content[0] = CONTENTS_TYPE;
        data.erc1271Policies = new PolicyData[](1);
        data.erc1271Policies[0] = PolicyData({policy: address(allow), initData: ""});
    }

    // --- ERC-1271 ---------------------------------------------------------

    string internal constant CONTENTS_TYPE = "Permit(address spender,uint256 value)";

    /// Whether the account accepts, from the session `id`, a signature over
    /// an EIP-712 permit: the hash an application would ask the account to
    /// approve, `keccak256(0x1901 ‖ domain separator ‖ struct hash)`, in
    /// ERC-7739's nested typed-data form (the permission id, the inner
    /// signature, then the domain separator, the struct hash, the contents
    /// type and its length). The session validator is ModuleKit's mock, which
    /// accepts any inner signature: what is tested is the session's scope.
    function _signs(AccountInstance memory instance, PermissionId id) internal returns (bool) {
        bytes32 domainSeparator = keccak256("an application's domain separator");
        bytes32 structHash = keccak256("the permit's struct hash");
        bytes32 hash = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
        bytes memory contentsType = bytes(CONTENTS_TYPE);
        bytes memory signature = abi.encodePacked(
            PermissionId.unwrap(id),
            bytes("session-validator-signature"),
            domainSeparator,
            structHash,
            contentsType,
            uint16(contentsType.length)
        );
        try this.isValidSignatureExternal(abi.encode(instance), hash, signature) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function isValidSignatureExternal(bytes calldata inst, bytes32 hash, bytes calldata signature)
        external
        returns (bool)
    {
        AccountInstance memory instance = abi.decode(inst, (AccountInstance));
        return instance.isValidSignature(address(instance.smartSession), hash, signature);
    }
}

/// The gate as option 3 would make it, reduced to what check 3 needs: the
/// account calls `submit`; the gate either records a refusal and returns, or
/// makes the account call the target through executeFromExecutor.
contract SessionGateProbe is IERC7579Module {
    event Submitted(address indexed account, address target, bytes4 selector);
    event Refused(address indexed account, address target, bytes4 selector);

    mapping(address account => bool) public installed;
    mapping(address account => uint256) public refusals;
    uint256 public cap;

    error SessionGateProbe_NotInstalled(address caller);

    function onInstall(bytes calldata) external {
        installed[msg.sender] = true;
    }

    function onUninstall(bytes calldata) external {
        installed[msg.sender] = false;
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function isInitialized(address account) external view returns (bool) {
        return installed[account];
    }

    /// Stands in for the gate's owner functions: the session must not reach it.
    function setCap(uint256 value) external {
        if (!installed[msg.sender]) revert SessionGateProbe_NotInstalled(msg.sender);
        cap = value;
    }

    /// The account, acting for its agent's session, submits a call. A call to
    /// `withdrawAll` stands for an order a policy refuses.
    function submit(address target, bytes calldata callData) external returns (bool) {
        if (!installed[msg.sender]) revert SessionGateProbe_NotInstalled(msg.sender);
        bytes4 selector = bytes4(callData[:4]);
        if (selector == StubMarket.withdrawAll.selector) {
            refusals[msg.sender] += 1;
            emit Refused(msg.sender, target, selector);
            return false;
        }
        IERC7579Execution(msg.sender).executeFromExecutor(bytes32(0), abi.encodePacked(target, uint256(0), callData));
        emit Submitted(msg.sender, target, selector);
        return true;
    }
}
