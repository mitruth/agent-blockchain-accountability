// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GateFixture} from "./GateFixture.sol";
import {MiniAccount} from "../../contracts/demo/MiniAccount.sol";
import {
    StubMarket, StubDecoder, NullDecoder, LeglessDecoder, CapPolicy, RelayTarget, ReentrantTarget
} from "./mocks/GateMocks.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {GateBase} from "../../contracts/gate/GateBase.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {AgentRegistry} from "../../contracts/gate/AgentRegistry.sol";
import {DecoderRegistry} from "../../contracts/gate/DecoderRegistry.sol";
import {ConfigManager} from "../../contracts/gate/ConfigManager.sol";
import {IOrderDecoder} from "../../contracts/interfaces/IOrderDecoder.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {Order, OrderKind, Side} from "../../contracts/gate/GateTypes.sol";

/// Step 1 of the v0.1 build order: the key model.
///
/// The agent holds no key on the prosumer account. Its authority is one entry
/// in the gate's AgentRegistry, and the only thing that entry buys is `submit`
/// on calls the owner approved. These tests assert the permission table one row
/// at a time, and then the escalation paths: every way an agent might turn
/// `submit` into module management, a registry write or a configuration change.
///
/// | Actor    | May                                         | May not                                   |
/// |----------|---------------------------------------------|-------------------------------------------|
/// | Owner    | install and uninstall the gate; register    | make the account or the gate a target     |
/// |          | and revoke agents; approve market calls;    |                                           |
/// |          | add and configure policies                  |                                           |
/// | Agent    | submit approved calls while registered and  | install or uninstall a module; write any  |
/// |          | unexpired                                   | registry; configure a policy; reach any   |
/// |          |                                             | of those through the gate                 |
/// | Stranger | nothing on this account                     | everything                                |
///
/// These run against MiniAccount. The same properties on the real account
/// implementations are in test/accounts/, through ModuleKit.
contract KeyModelTest is GateFixture {
    address internal evilModule = makeAddr("evilModule");

    // ------------------------------------------------------------------
    // The row that must work
    // ------------------------------------------------------------------

    function test_registeredAgentOrderIsExecutedByTheAccount() public {
        bytes memory call = _order(1500);
        bytes32 orderHash = keccak256(
            abi.encode(block.chainid, address(gate), address(account), uint256(0), address(market), keccak256(call))
        );
        Order[] memory expected = new Order[](1);
        expected[0] = Order({
            kind: OrderKind.PLACE,
            side: Side.BUY,
            slot: 100,
            qtyWh: 1500,
            price: 250_000,
            value: 375_000,
            orderId: bytes32(0)
        });

        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.OrderSubmitted(
            address(account), agent, address(market), StubMarket.placeOrder.selector, expected, orderHash
        );
        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.Executed(address(account), orderHash);

        vm.prank(agent);
        bytes32 returned = gate.submit(address(account), address(market), call);

        assertEq(returned, orderHash);
        assertEq(market.orderCount(), 1);
        // The market saw the account, not the agent and not the gate.
        assertEq(market.lastCaller(), address(account));
        assertEq(gate.submissionCount(address(account)), 1);
        // And the order is booked against the account.
        assertEq(ledger.openOrderCount(address(account)), 1);
    }

    function test_orderHashesAreDistinctForIdenticalCalls() public {
        vm.startPrank(agent);
        bytes32 first = gate.submit(address(account), address(market), _order(1500));
        bytes32 second = gate.submit(address(account), address(market), _order(1500));
        vm.stopPrank();

        assertTrue(first != second);
    }

    // ------------------------------------------------------------------
    // A8: who may submit
    // ------------------------------------------------------------------

    function test_unregisteredAgentIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(account), stranger)
        );
        vm.prank(stranger);
        gate.submit(address(account), address(market), _order(1500));

        assertEq(market.orderCount(), 0);
    }

    function test_ownerKeyIsNotAnAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(account), owner)
        );
        vm.prank(owner);
        gate.submit(address(account), address(market), _order(1500));
    }

    function test_agentIsValidThroughItsLastSecondAndNotAfter() public {
        vm.warp(agentValidUntil);
        vm.prank(agent);
        gate.submit(address(account), address(market), _order(1500));
        assertEq(market.orderCount(), 1);

        vm.warp(uint256(agentValidUntil) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(account), agent)
        );
        vm.prank(agent);
        gate.submit(address(account), address(market), _order(1500));
        assertEq(market.orderCount(), 1);
    }

    function test_revocationTakesEffectAtOnce() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit AgentRegistry.AgentRevoked(address(account), agent);
        _asAccount(abi.encodeCall(gate.revokeAgent, (agent)));

        assertFalse(gate.isAgentActive(address(account), agent));
        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(account), agent)
        );
        vm.prank(agent);
        gate.submit(address(account), address(market), _order(1500));
    }

    function test_agentOfOneAccountHasNoAuthorityOnAnother() public {
        address otherOwner = makeAddr("otherOwner");
        address otherAgent = makeAddr("otherAgent");
        MiniAccount other = new MiniAccount(otherOwner);

        vm.startPrank(otherOwner);
        other.installModule(EXECUTOR, address(gate), "");
        other.execute(address(ledger), 0, abi.encodeCall(ledger.setWriter, (address(gate), true)));
        other.execute(address(gate), 0, abi.encodeCall(gate.registerAgent, (otherAgent, agentValidUntil)));
        other.execute(
            address(gate), 0, abi.encodeCall(gate.setDecoder, (address(market), StubMarket.placeOrder.selector, decoder))
        );
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(account), otherAgent)
        );
        vm.prank(otherAgent);
        gate.submit(address(account), address(market), _order(1500));

        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(other), agent)
        );
        vm.prank(agent);
        gate.submit(address(other), address(market), _order(1500));

        // Each agent still works on its own account.
        vm.prank(otherAgent);
        gate.submit(address(other), address(market), _order(1500));
        assertEq(market.lastCaller(), address(other));
    }

    function test_registerAgentRefusesTheAccountTheGateAndZero() public {
        address[3] memory bad = [address(account), address(gate), address(0)];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry_InvalidAgent.selector, bad[i]));
            _asAccount(abi.encodeCall(gate.registerAgent, (bad[i], agentValidUntil)));
        }
    }

    function test_registerAgentRefusesAnExpiryInThePast() public {
        uint48 past = uint48(block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry_AlreadyExpired.selector, past));
        _asAccount(abi.encodeCall(gate.registerAgent, (stranger, past)));
    }

    // ------------------------------------------------------------------
    // A7: what may be submitted
    // ------------------------------------------------------------------

    function test_unapprovedFunctionOnAnApprovedMarketIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyGate.PolicyGate_UnknownCall.selector, address(market), StubMarket.withdrawAll.selector
            )
        );
        vm.prank(agent);
        gate.submit(address(account), address(market), abi.encodeCall(StubMarket.withdrawAll, ()));

        assertEq(market.withdrawals(), 0);
    }

    function test_unapprovedMarketIsRejected() public {
        StubMarket other = new StubMarket();

        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyGate.PolicyGate_UnknownCall.selector, address(other), StubMarket.placeOrder.selector
            )
        );
        vm.prank(agent);
        gate.submit(address(account), address(other), _order(1500));

        assertEq(other.orderCount(), 0);
    }

    function test_removingAnApprovalTakesEffectAtOnce() public {
        _asAccount(abi.encodeCall(gate.removeDecoder, (address(market), StubMarket.placeOrder.selector)));

        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyGate.PolicyGate_UnknownCall.selector, address(market), StubMarket.placeOrder.selector
            )
        );
        vm.prank(agent);
        gate.submit(address(account), address(market), _order(1500));
    }

    /// Every approved call must be an order of at least one leg and at most
    /// `maxLegs`. A call read as no order at all would pass every policy
    /// unchecked; the upper bound bounds the booking loop.
    function test_aCallWithNoLegsOrTooManyIsRejected() public {
        uint256[2] memory counts = [uint256(0), MAX_LEGS + 1];
        for (uint256 i = 0; i < counts.length; ++i) {
            _asAccount(
                abi.encodeCall(
                    gate.setDecoder,
                    (address(market), StubMarket.withdrawAll.selector, new LeglessDecoder(counts[i]))
                )
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    PolicyGate.PolicyGate_NotAnOrder.selector, address(market), StubMarket.withdrawAll.selector
                )
            );
            vm.prank(agent);
            gate.submit(address(account), address(market), abi.encodeCall(StubMarket.withdrawAll, ()));
        }
        assertEq(market.withdrawals(), 0);
    }

    function test_theLegLimitIsAtLeastTwo() public {
        assertEq(gate.maxLegs(), MAX_LEGS);
        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_MaxLegsTooSmall.selector, 1));
        new PolicyGate(ledger, 1);
    }

    function test_callDataShorterThanASelectorIsRejected() public {
        vm.expectRevert(PolicyGate.PolicyGate_CallDataTooShort.selector);
        vm.prank(agent);
        gate.submit(address(account), address(market), hex"aabbcc");
    }

    function test_aRevertingMarketCallRevertsTheWholeSubmission() public {
        vm.expectRevert(StubMarket.StubMarket_ZeroQuantity.selector);
        vm.prank(agent);
        gate.submit(address(account), address(market), _order(0));

        assertEq(gate.submissionCount(address(account)), 0);
    }

    // ------------------------------------------------------------------
    // Escalation: module management
    // ------------------------------------------------------------------

    function test_agentCannotInstallOrUninstallAModuleDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(MiniAccount.MiniAccount_Unauthorized.selector, agent));
        vm.prank(agent);
        account.installModule(EXECUTOR, evilModule, "");

        vm.expectRevert(abi.encodeWithSelector(MiniAccount.MiniAccount_Unauthorized.selector, agent));
        vm.prank(agent);
        account.uninstallModule(EXECUTOR, address(gate), "");

        _assertAuthorityUnchanged();
    }

    function test_agentCannotExecuteFromTheAccountDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(MiniAccount.MiniAccount_Unauthorized.selector, agent));
        vm.prank(agent);
        account.execute(address(market), 0, _order(1500));

        vm.expectRevert(abi.encodeWithSelector(MiniAccount.MiniAccount_Unauthorized.selector, agent));
        vm.prank(agent);
        account.executeFromExecutor(bytes32(0), abi.encodePacked(address(market), uint256(0), _order(1500)));
    }

    /// The nested self-call. The account accepts `installModule` from itself,
    /// and `submit` makes the account call things, so the account must never be
    /// what it calls.
    function test_accountIsNeverATargetWhateverTheCall() public {
        bytes[3] memory calls = [
            abi.encodeCall(MiniAccount.installModule, (EXECUTOR, evilModule, "")),
            abi.encodeCall(MiniAccount.uninstallModule, (EXECUTOR, address(gate), "")),
            abi.encodeCall(MiniAccount.execute, (address(market), 0, _order(1500)))
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(account)));
            vm.prank(agent);
            gate.submit(address(account), address(account), calls[i]);
        }
        _assertAuthorityUnchanged();
    }

    /// The owner cannot open that door either, by mistake or under persuasion.
    function test_ownerCannotApproveTheAccountOrTheGateAsATarget() public {
        address[4] memory bad = [address(account), address(gate), address(ledger), address(0)];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(DecoderRegistry.DecoderRegistry_ForbiddenTarget.selector, bad[i]));
            _asAccount(abi.encodeCall(gate.setDecoder, (bad[i], MiniAccount.installModule.selector, decoder)));
        }
    }

    function test_ownerCannotRegisterAZeroDecoder() public {
        vm.expectRevert(DecoderRegistry.DecoderRegistry_ZeroDecoder.selector);
        _asAccount(
            abi.encodeCall(gate.setDecoder, (address(market), StubMarket.withdrawAll.selector, IOrderDecoder(address(0))))
        );
    }

    // ------------------------------------------------------------------
    // Escalation: registries and configuration
    // ------------------------------------------------------------------

    function test_agentCannotWriteAnyRegistryDirectly() public {
        bytes[10] memory writes = _ownerPathCalls();
        for (uint256 i = 0; i < writes.length; ++i) {
            vm.prank(agent);
            (bool ok, bytes memory err) = address(gate).call(writes[i]);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(GateBase.Gate_NotInstalled.selector, agent));
        }
        _assertAuthorityUnchanged();
    }

    /// The other nested self-call: have the account call the gate, where it
    /// would arrive on the owner path.
    function test_gateIsNeverATargetWhateverTheCall() public {
        bytes[10] memory writes = _ownerPathCalls();
        for (uint256 i = 0; i < writes.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(gate)));
            vm.prank(agent);
            gate.submit(address(account), address(gate), writes[i]);
        }
        _assertAuthorityUnchanged();
    }

    /// The ledger takes its writer list from "the caller is the account", so a
    /// call routed through the gate to the ledger would let the agent appoint
    /// a writer. It is never a target.
    function test_ledgerIsNeverATarget() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(ledger)));
        vm.prank(agent);
        gate.submit(address(account), address(ledger), abi.encodeCall(ledger.setWriter, (agent, true)));

        assertFalse(ledger.isWriter(address(account), agent));
    }

    function test_agentCannotWriteTheLedgerDirectly() public {
        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_NotWriter.selector, address(account), agent)
        );
        vm.prank(agent);
        ledger.reconcile(address(account), address(market), bytes32(uint256(1)));
    }

    function test_agentCannotConfigureAPolicyDirectly() public {
        vm.expectRevert(CapPolicy.CapPolicy_OnlyGate.selector);
        vm.prank(agent);
        policy.configure(address(account), POLICY_ID, _caps(type(uint64).max, type(uint64).max));

        vm.expectRevert(CapPolicy.CapPolicy_OnlyGate.selector);
        vm.prank(agent);
        policy.deconfigure(address(account), POLICY_ID);

        _assertAuthorityUnchanged();
    }

    /// Suppose the owner approved a policy contract as a target. The call would
    /// reach the policy from the account, and a policy listens to the gate
    /// only.
    function test_policyRefusesConfigurationEvenFromTheAccount() public {
        _asAccount(abi.encodeCall(gate.setDecoder, (address(policy), IPolicy.configure.selector, new NullDecoder())));

        vm.expectRevert(CapPolicy.CapPolicy_OnlyGate.selector);
        vm.prank(agent);
        gate.submit(
            address(account),
            address(policy),
            abi.encodeCall(IPolicy.configure, (address(account), POLICY_ID, _caps(type(uint64).max, type(uint64).max)))
        );

        assertEq(_hardCap(), HARD);
    }

    /// Whatever bytes an agent sends, to whichever contract, the account's
    /// modules, the registries and the configuration are as they were.
    function testFuzz_noSubmissionChangesAuthority(uint8 which, bytes calldata data) public {
        address[5] memory targets =
            [address(account), address(gate), address(market), address(policy), address(ledger)];

        vm.prank(agent);
        try gate.submit(address(account), targets[which % 5], data) {} catch {}

        _assertAuthorityUnchanged();
    }

    // ------------------------------------------------------------------
    // Escalation: hostile targets
    // ------------------------------------------------------------------

    /// A forwarding target is never to be registered. If one is, the calls it
    /// forwards arrive from the forwarder, not from the account, and carry no
    /// authority.
    function test_forwardingTargetCarriesNoAuthority() public {
        RelayTarget relay = new RelayTarget();
        _asAccount(abi.encodeCall(gate.setDecoder, (address(relay), RelayTarget.forward.selector, new NullDecoder())));

        bytes[3] memory attempts = [
            abi.encodeCall(
                RelayTarget.forward,
                (address(account), abi.encodeCall(MiniAccount.installModule, (EXECUTOR, evilModule, "")))
            ),
            abi.encodeCall(
                RelayTarget.forward,
                (address(account), abi.encodeCall(MiniAccount.uninstallModule, (EXECUTOR, address(gate), "")))
            ),
            abi.encodeCall(
                RelayTarget.forward, (address(gate), abi.encodeCall(gate.registerAgent, (stranger, agentValidUntil)))
            )
        ];
        for (uint256 i = 0; i < attempts.length; ++i) {
            vm.prank(agent);
            gate.submit(address(account), address(relay), attempts[i]);
            assertFalse(relay.lastOk());
        }

        _asAccount(abi.encodeCall(gate.removeDecoder, (address(relay), RelayTarget.forward.selector)));
        _assertAuthorityUnchanged();
    }

    /// A target that is also an agent calls `submit` again while the account is
    /// calling it. The lock refuses the inner call.
    function test_targetCannotReenterSubmit() public {
        ReentrantTarget hostile = new ReentrantTarget(gate);
        _asAccount(
            abi.encodeCall(gate.setDecoder, (address(hostile), ReentrantTarget.poke.selector, new NullDecoder()))
        );
        _asAccount(abi.encodeCall(gate.registerAgent, (address(hostile), agentValidUntil)));

        vm.prank(agent);
        gate.submit(
            address(account),
            address(hostile),
            abi.encodeCall(ReentrantTarget.poke, (address(account), address(market), _order(1500)))
        );

        assertFalse(hostile.reentryOk());
        assertEq(hostile.reentryError(), abi.encodeWithSelector(GateBase.Gate_Reentrancy.selector));
        assertEq(market.orderCount(), 0);
    }

    // ------------------------------------------------------------------
    // Install and uninstall
    // ------------------------------------------------------------------

    function test_gateReportsItselfAsAnExecutorOnly() public view {
        assertTrue(gate.isModuleType(2));
        assertFalse(gate.isModuleType(1));
        assertFalse(gate.isModuleType(3));
        assertFalse(gate.isModuleType(4));
        assertTrue(gate.isInitialized(address(account)));
        assertFalse(gate.isInitialized(stranger));
    }

    function test_installingTheGateGrantsNobodyAnything() public {
        MiniAccount fresh = new MiniAccount(owner);

        vm.expectEmit(true, true, true, true, address(gate));
        emit GateBase.GateInstalled(address(fresh), 1);
        vm.prank(owner);
        fresh.installModule(EXECUTOR, address(gate), "");

        assertFalse(gate.isAgentActive(address(fresh), agent));
        assertEq(address(gate.decoderOf(address(fresh), address(market), StubMarket.placeOrder.selector)), address(0));
        assertEq(gate.policiesOf(address(fresh)).length, 0);
    }

    /// Anyone may call onInstall. It gives them a namespace of their own and no
    /// hold on any real account.
    function test_strangerCallingOnInstallGainsNothingOverTheAccount() public {
        vm.startPrank(stranger);
        gate.onInstall("");
        gate.registerAgent(agent, agentValidUntil);
        gate.setDecoder(address(market), StubMarket.withdrawAll.selector, decoder);
        vm.stopPrank();

        _assertAuthorityUnchanged();

        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(account), stranger)
        );
        vm.prank(stranger);
        gate.submit(address(account), address(market), _order(1500));
    }

    function test_installTwiceIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(GateBase.Gate_AlreadyInstalled.selector, address(account)));
        vm.prank(address(account));
        gate.onInstall("");
    }

    function test_uninstallWithdrawsTheAgentAndReinstallStartsEmpty() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit GateBase.GateUninstalled(address(account), 1);
        vm.prank(owner);
        account.uninstallModule(EXECUTOR, address(gate), "");

        assertFalse(gate.isAgentActive(address(account), agent));
        // The policy was told to drop its state.
        (bool set,,) = policy.caps(address(account), POLICY_ID);
        assertFalse(set);

        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_AgentNotAuthorized.selector, address(account), agent)
        );
        vm.prank(agent);
        gate.submit(address(account), address(market), _order(1500));

        vm.expectEmit(true, true, true, true, address(gate));
        emit GateBase.GateInstalled(address(account), 2);
        vm.prank(owner);
        account.installModule(EXECUTOR, address(gate), "");

        // Nothing registered under the first installation carries over.
        assertEq(gate.agentValidUntil(address(account), agent), 0);
        assertFalse(gate.isAgentActive(address(account), agent));
        assertEq(address(gate.decoderOf(address(account), address(market), StubMarket.placeOrder.selector)), address(0));
        assertEq(gate.policiesOf(address(account)).length, 0);
        assertFalse(gate.hasPolicy(address(account), policy, POLICY_ID));
    }

    function test_uninstallSucceedsEvenIfAPolicyRefusesToLetGo() public {
        policy.setRevertOnDeconfigure(true);

        vm.prank(owner);
        account.uninstallModule(EXECUTOR, address(gate), "");

        assertFalse(gate.isInstalled(address(account)));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Every state-changing owner-path function of the gate, with
    ///      arguments that would hand the agent more than it has.
    function _ownerPathCalls() internal view returns (bytes[10] memory calls) {
        bytes memory wide = _caps(type(uint64).max, type(uint64).max);
        calls[0] = abi.encodeCall(gate.registerAgent, (stranger, type(uint48).max));
        calls[1] = abi.encodeCall(gate.revokeAgent, (agent));
        calls[2] = abi.encodeCall(gate.setDecoder, (address(market), StubMarket.withdrawAll.selector, decoder));
        calls[3] = abi.encodeCall(gate.removeDecoder, (address(market), StubMarket.placeOrder.selector));
        calls[4] = abi.encodeCall(gate.addPolicy, (policy, keccak256("second"), wide));
        calls[5] = abi.encodeCall(gate.setConfig, (policy, POLICY_ID, wide));
        calls[6] = abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, wide));
        calls[7] = abi.encodeCall(gate.proposeRemovePolicy, (policy, POLICY_ID));
        calls[8] = abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID));
        calls[9] = abi.encodeCall(gate.cancelProposal, (policy, POLICY_ID));
    }

    function _assertAuthorityUnchanged() internal view {
        // The account's modules.
        assertTrue(account.isModuleInstalled(EXECUTOR, address(gate), ""));
        assertFalse(account.isModuleInstalled(EXECUTOR, evilModule, ""));
        assertTrue(gate.isInstalled(address(account)));
        assertEq(gate.generationOf(address(account)), 1);

        // Agents.
        assertEq(gate.agentValidUntil(address(account), agent), agentValidUntil);
        assertEq(gate.agentValidUntil(address(account), stranger), 0);

        // Approved calls.
        assertEq(
            address(gate.decoderOf(address(account), address(market), StubMarket.placeOrder.selector)),
            address(decoder)
        );
        assertEq(address(gate.decoderOf(address(account), address(market), StubMarket.withdrawAll.selector)), address(0));

        // Who may write the account's positions.
        assertTrue(ledger.isWriter(address(account), address(gate)));
        assertFalse(ledger.isWriter(address(account), agent));

        // Policies and their parameters.
        ConfigManager.PolicyRef[] memory list = gate.policiesOf(address(account));
        assertEq(list.length, 1);
        assertEq(address(list[0].policy), address(policy));
        assertEq(list[0].policyId, POLICY_ID);
        assertEq(_softCap(), SOFT);
        assertEq(_hardCap(), HARD);
        assertEq(
            uint8(gate.proposalOf(address(account), policy, POLICY_ID).kind), uint8(ConfigManager.ProposalKind.NONE)
        );
    }
}
