// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GateFixture} from "./GateFixture.sol";
import {CapPolicy} from "./mocks/GateMocks.sol";
import {GateBase} from "../../contracts/gate/GateBase.sol";
import {ConfigManager} from "../../contracts/gate/ConfigManager.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {ConfigChange} from "../../contracts/gate/GateTypes.sol";

/// Step 1 of the v0.1 build order: configuration.
///
/// Only the owner path configures. A change that only tightens applies in the
/// same call; anything that loosens waits WIDEN_DELAY. The fixture's policy has
/// a soft and a hard cap, lower is tighter, and starts at 800 and 1000.
contract ConfigManagerTest is GateFixture {
    bytes32 internal constant SECOND_ID = keccak256("second");

    function _proposal() internal view returns (ConfigManager.Proposal memory) {
        return gate.proposalOf(address(account), policy, POLICY_ID);
    }

    // ------------------------------------------------------------------
    // Adding a policy
    // ------------------------------------------------------------------

    function test_addPolicyAppliesAtOnce() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.PolicyAdded(address(account), address(policy), SECOND_ID);
        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigApplied(address(account), address(policy), SECOND_ID, _caps(10, 20));

        bytes memory result = _asAccount(abi.encodeCall(gate.addPolicy, (policy, SECOND_ID, _caps(10, 20))));

        assertTrue(abi.decode(result, (bool)));
        assertTrue(gate.hasPolicy(address(account), policy, SECOND_ID));
        assertEq(gate.policiesOf(address(account)).length, 2);
        (bool set, uint64 soft, uint64 hard) = policy.caps(address(account), SECOND_ID);
        assertTrue(set);
        assertEq(soft, 10);
        assertEq(hard, 20);
    }

    /// S <= H is a cross-parameter constraint, refused at configure time. The
    /// refusal is an event rather than a revert, so it stays in the log.
    function test_addPolicyWithInvalidConfigIsRejectedAndNotAdded() public {
        bytes memory softAboveHard = _caps(21, 20);

        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigRejected(
            address(account), address(policy), SECOND_ID, ConfigManager.RejectReason.INVALID, keccak256(softAboveHard)
        );
        bytes memory result = _asAccount(abi.encodeCall(gate.addPolicy, (policy, SECOND_ID, softAboveHard)));

        assertFalse(abi.decode(result, (bool)));
        assertFalse(gate.hasPolicy(address(account), policy, SECOND_ID));
        assertEq(gate.policiesOf(address(account)).length, 1);
    }

    function test_addingTheSameInstanceTwiceIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigManager.ConfigManager_PolicyAlreadyAdded.selector, address(policy), POLICY_ID
            )
        );
        _asAccount(abi.encodeCall(gate.addPolicy, (policy, POLICY_ID, _caps(1, 2))));
    }

    function test_addPolicyRefusesTheAccountTheGateAndZero() public {
        address[3] memory bad = [address(account), address(gate), address(0)];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ConfigManager.ConfigManager_InvalidPolicy.selector, bad[i]));
            _asAccount(abi.encodeCall(gate.addPolicy, (IPolicy(bad[i]), SECOND_ID, _caps(1, 2))));
        }
    }

    function test_policyListIsBounded() public {
        uint256 max = gate.MAX_POLICIES();
        for (uint256 i = 1; i < max; ++i) {
            _asAccount(abi.encodeCall(gate.addPolicy, (policy, bytes32(i), _caps(1, 2))));
        }
        assertEq(gate.policiesOf(address(account)).length, max);

        vm.expectRevert(ConfigManager.ConfigManager_TooManyPolicies.selector);
        _asAccount(abi.encodeCall(gate.addPolicy, (policy, bytes32(max), _caps(1, 2))));
    }

    // ------------------------------------------------------------------
    // Tightening
    // ------------------------------------------------------------------

    function test_tighteningAppliesAtOnce() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigApplied(address(account), address(policy), POLICY_ID, _caps(700, 900));

        bytes memory result = _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(700, 900))));

        assertEq(uint8(abi.decode(result, (ConfigChange))), uint8(ConfigChange.TIGHTEN));
        assertEq(_softCap(), 700);
        assertEq(_hardCap(), 900);
        assertEq(uint8(_proposal().kind), uint8(ConfigManager.ProposalKind.NONE));
    }

    function test_unchangedConfigCountsAsTightening() public {
        bytes memory result = _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, HARD))));
        assertEq(uint8(abi.decode(result, (ConfigChange))), uint8(ConfigChange.TIGHTEN));
    }

    function test_invalidConfigIsRejectedAndChangesNothing() public {
        bytes memory softAboveHard = _caps(1001, 1000);

        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigRejected(
            address(account), address(policy), POLICY_ID, ConfigManager.RejectReason.INVALID, keccak256(softAboveHard)
        );
        bytes memory result = _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, softAboveHard)));

        assertEq(uint8(abi.decode(result, (ConfigChange))), uint8(ConfigChange.INVALID));
        assertEq(_softCap(), SOFT);
        assertEq(_hardCap(), HARD);
    }

    function test_malformedConfigIsRejected() public {
        bytes memory result = _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, hex"deadbeef")));
        assertEq(uint8(abi.decode(result, (ConfigChange))), uint8(ConfigChange.INVALID));
        assertEq(_hardCap(), HARD);
    }

    // ------------------------------------------------------------------
    // Widening
    // ------------------------------------------------------------------

    function test_wideningIsProposedNotApplied() public {
        uint48 eta = uint48(block.timestamp) + gate.WIDEN_DELAY();

        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigProposed(
            address(account), address(policy), POLICY_ID, ConfigManager.ProposalKind.CONFIG, _caps(SOFT, 2000), eta
        );
        bytes memory result = _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));

        assertEq(uint8(abi.decode(result, (ConfigChange))), uint8(ConfigChange.WIDEN));
        assertEq(_hardCap(), HARD);

        ConfigManager.Proposal memory proposal = _proposal();
        assertEq(uint8(proposal.kind), uint8(ConfigManager.ProposalKind.CONFIG));
        assertEq(proposal.eta, eta);
        assertEq(proposal.configHash, keccak256(_caps(SOFT, 2000)));
    }

    function test_wideningDelayIsTwentyFourHours() public view {
        assertEq(gate.WIDEN_DELAY(), 24 hours);
    }

    function test_wideningCannotBeAppliedOneSecondEarly() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        uint48 eta = _proposal().eta;

        vm.warp(uint256(eta) - 1);
        vm.expectRevert(abi.encodeWithSelector(ConfigManager.ConfigManager_TimelockActive.selector, eta));
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));

        assertEq(_hardCap(), HARD);
    }

    function test_wideningAppliesOnceTheDelayHasRun() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));

        vm.warp(_proposal().eta);
        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigApplied(address(account), address(policy), POLICY_ID, _caps(SOFT, 2000));
        bytes memory result = _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));

        assertTrue(abi.decode(result, (bool)));
        assertEq(_hardCap(), 2000);
        assertEq(uint8(_proposal().kind), uint8(ConfigManager.ProposalKind.NONE));
    }

    /// Tightening the soft cap does not buy an immediate raise of the hard cap.
    function test_mixedDirectionChangeCountsAsWidening() public {
        bytes memory result = _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(100, 2000))));

        assertEq(uint8(abi.decode(result, (ConfigChange))), uint8(ConfigChange.WIDEN));
        assertEq(_softCap(), SOFT);
        assertEq(_hardCap(), HARD);
    }

    function test_applyRequiresTheProposedConfigByteForByte() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        vm.warp(_proposal().eta);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigManager.ConfigManager_ConfigMismatch.selector,
                keccak256(_caps(SOFT, 2000)),
                keccak256(_caps(SOFT, 9000))
            )
        );
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 9000))));

        assertEq(_hardCap(), HARD);
    }

    function test_aProposalAppliesOnlyOnce() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        vm.warp(_proposal().eta);
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, HARD))));

        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));

        assertEq(_hardCap(), HARD);
    }

    function test_applyWithoutAProposalIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
    }

    /// A widening queued yesterday must not come back after a tightening made
    /// today.
    function test_aLaterTighteningDropsThePendingWidening() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        uint48 eta = _proposal().eta;

        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigRejected(
            address(account),
            address(policy),
            POLICY_ID,
            ConfigManager.RejectReason.SUPERSEDED,
            keccak256(_caps(SOFT, 2000))
        );
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(400, 500))));
        assertEq(_hardCap(), 500);

        vm.warp(eta);
        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        assertEq(_hardCap(), 500);
    }

    /// Re-proposing restarts the clock: the second proposal cannot ride on the
    /// first one's elapsed time.
    function test_aNewProposalRestartsTheTimelock() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        uint48 firstEta = _proposal().eta;

        vm.warp(uint256(firstEta) - 1);
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 9000))));
        uint48 secondEta = _proposal().eta;
        assertEq(secondEta, uint48(block.timestamp) + gate.WIDEN_DELAY());

        vm.warp(firstEta);
        vm.expectRevert(abi.encodeWithSelector(ConfigManager.ConfigManager_TimelockActive.selector, secondEta));
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 9000))));
        assertEq(_hardCap(), HARD);
    }

    function test_cancelDropsTheProposal() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        uint48 eta = _proposal().eta;

        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigRejected(
            address(account),
            address(policy),
            POLICY_ID,
            ConfigManager.RejectReason.CANCELLED,
            keccak256(_caps(SOFT, 2000))
        );
        _asAccount(abi.encodeCall(gate.cancelProposal, (policy, POLICY_ID)));

        vm.warp(eta);
        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
    }

    function test_cancelWithNothingPendingIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.cancelProposal, (policy, POLICY_ID)));
    }

    /// However the owner asks and however long anyone waits short of the
    /// delay, a looser cap is not in force.
    function testFuzz_noWideningTakesEffectBeforeTheDelay(uint64 soft, uint64 hard, uint32 wait) public {
        hard = uint64(bound(hard, 0, type(uint64).max));
        soft = uint64(bound(soft, 0, hard));
        wait = uint32(bound(wait, 0, gate.WIDEN_DELAY() - 1));

        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(soft, hard))));
        vm.warp(block.timestamp + wait);
        vm.prank(owner);
        try account.execute(address(gate), 0, abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(soft, hard)))) {}
            catch {}

        assertLe(_softCap(), SOFT);
        assertLe(_hardCap(), HARD);
    }

    // ------------------------------------------------------------------
    // Removing a policy
    // ------------------------------------------------------------------

    function test_removalWaitsTheDelay() public {
        uint48 eta = uint48(block.timestamp) + gate.WIDEN_DELAY();

        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigProposed(
            address(account), address(policy), POLICY_ID, ConfigManager.ProposalKind.REMOVE, "", eta
        );
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, POLICY_ID)));
        assertTrue(gate.hasPolicy(address(account), policy, POLICY_ID));

        vm.warp(uint256(eta) - 1);
        vm.expectRevert(abi.encodeWithSelector(ConfigManager.ConfigManager_TimelockActive.selector, eta));
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID)));
        assertTrue(gate.hasPolicy(address(account), policy, POLICY_ID));

        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.PolicyRemoved(address(account), address(policy), POLICY_ID);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID)));

        assertFalse(gate.hasPolicy(address(account), policy, POLICY_ID));
        assertEq(gate.policiesOf(address(account)).length, 0);
        (bool set,,) = policy.caps(address(account), POLICY_ID);
        assertFalse(set);
    }

    function test_removalWithoutAProposalIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID)));
    }

    /// A widening proposal is not a removal proposal, and the other way round.
    function test_proposalKindsAreNotInterchangeable() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        vm.warp(_proposal().eta);

        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID)));

        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, POLICY_ID)));
        vm.warp(_proposal().eta);

        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_NoProposal.selector, address(policy), POLICY_ID)
        );
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));

        assertEq(_hardCap(), HARD);
        assertTrue(gate.hasPolicy(address(account), policy, POLICY_ID));
    }

    function test_removingOneInstanceKeepsTheOthersFindable() public {
        bytes32 third = keccak256("third");
        _asAccount(abi.encodeCall(gate.addPolicy, (policy, SECOND_ID, _caps(1, 2))));
        _asAccount(abi.encodeCall(gate.addPolicy, (policy, third, _caps(3, 4))));

        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, POLICY_ID)));
        vm.warp(_proposal().eta);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID)));

        assertEq(gate.policiesOf(address(account)).length, 2);
        assertTrue(gate.hasPolicy(address(account), policy, SECOND_ID));
        assertTrue(gate.hasPolicy(address(account), policy, third));

        // The instance moved into the vacated place can still be configured.
        _asAccount(abi.encodeCall(gate.setConfig, (policy, third, _caps(2, 3))));
        (,, uint64 hard) = policy.caps(address(account), third);
        assertEq(hard, 3);

        // And removed in its turn, from the place it now holds.
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, third)));
        vm.warp(gate.proposalOf(address(account), policy, third).eta);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, third)));

        ConfigManager.PolicyRef[] memory list = gate.policiesOf(address(account));
        assertEq(list.length, 1);
        assertEq(list[0].policyId, SECOND_ID);
        assertFalse(gate.hasPolicy(address(account), policy, third));
        assertTrue(gate.hasPolicy(address(account), policy, SECOND_ID));
    }

    /// A removal proposal replaces a pending widening, and the log says so:
    /// the widening is reported as dropped rather than silently overwritten.
    function test_removalProposalSupersedesAPendingWidening() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));

        vm.expectEmit(true, true, true, true, address(gate));
        emit ConfigManager.ConfigRejected(
            address(account),
            address(policy),
            POLICY_ID,
            ConfigManager.RejectReason.SUPERSEDED,
            keccak256(_caps(SOFT, 2000))
        );
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, POLICY_ID)));

        assertEq(uint8(_proposal().kind), uint8(ConfigManager.ProposalKind.REMOVE));
    }

    function test_aPolicyThatRefusesToLetGoIsStillRemoved() public {
        policy.setRevertOnDeconfigure(true);

        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, POLICY_ID)));
        vm.warp(_proposal().eta);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID)));

        assertFalse(gate.hasPolicy(address(account), policy, POLICY_ID));
    }

    function test_unknownPolicyCannotBeConfiguredOrRemoved() public {
        bytes memory unknown =
            abi.encodeWithSelector(ConfigManager.ConfigManager_UnknownPolicy.selector, address(policy), SECOND_ID);

        vm.expectRevert(unknown);
        _asAccount(abi.encodeCall(gate.setConfig, (policy, SECOND_ID, _caps(1, 2))));
        vm.expectRevert(unknown);
        _asAccount(abi.encodeCall(gate.applyConfig, (policy, SECOND_ID, _caps(1, 2))));
        vm.expectRevert(unknown);
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, SECOND_ID)));
        vm.expectRevert(unknown);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, SECOND_ID)));
        vm.expectRevert(unknown);
        _asAccount(abi.encodeCall(gate.cancelProposal, (policy, SECOND_ID)));
    }

    // ------------------------------------------------------------------
    // Only the owner path configures
    // ------------------------------------------------------------------

    /// Not the agent, not a stranger, and not the owner's key acting on its
    /// own: the caller has to be the account.
    function test_onlyTheAccountConfigures() public {
        address[3] memory callers = [agent, stranger, owner];
        bytes[6] memory calls = [
            abi.encodeCall(gate.addPolicy, (policy, SECOND_ID, _caps(1, 2))),
            abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))),
            abi.encodeCall(gate.applyConfig, (policy, POLICY_ID, _caps(SOFT, 2000))),
            abi.encodeCall(gate.proposeRemovePolicy, (policy, POLICY_ID)),
            abi.encodeCall(gate.applyRemovePolicy, (policy, POLICY_ID)),
            abi.encodeCall(gate.cancelProposal, (policy, POLICY_ID))
        ];

        for (uint256 c = 0; c < callers.length; ++c) {
            for (uint256 i = 0; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok, bytes memory err) = address(gate).call(calls[i]);
                assertFalse(ok);
                assertEq(err, abi.encodeWithSelector(GateBase.Gate_NotInstalled.selector, callers[c]));
            }
        }

        assertEq(_hardCap(), HARD);
        assertEq(gate.policiesOf(address(account)).length, 1);
    }

    /// The agent cannot finish a widening the owner started, even after the
    /// delay.
    function test_agentCannotApplyAnOwnerProposal() public {
        _asAccount(abi.encodeCall(gate.setConfig, (policy, POLICY_ID, _caps(SOFT, 2000))));
        vm.warp(_proposal().eta);

        vm.expectRevert(abi.encodeWithSelector(GateBase.Gate_NotInstalled.selector, agent));
        vm.prank(agent);
        gate.applyConfig(policy, POLICY_ID, _caps(SOFT, 2000));

        assertEq(_hardCap(), HARD);
    }

    /// The policy takes configuration from the gate alone: the account calling
    /// it directly, on the owner's authority, is refused too.
    function test_policyIsConfiguredOnlyThroughTheGate() public {
        vm.expectRevert(CapPolicy.CapPolicy_OnlyGate.selector);
        vm.prank(owner);
        account.execute(
            address(policy), 0, abi.encodeCall(IPolicy.configure, (address(account), POLICY_ID, _caps(SOFT, 2000)))
        );

        assertEq(_hardCap(), HARD);
    }

    /// One account's configuration is its own.
    function test_anotherAccountCannotConfigureThisOne() public {
        vm.startPrank(stranger);
        gate.onInstall("");
        vm.expectRevert(
            abi.encodeWithSelector(ConfigManager.ConfigManager_UnknownPolicy.selector, address(policy), POLICY_ID)
        );
        gate.setConfig(policy, POLICY_ID, _caps(SOFT, 2000));

        // It can add the same policy contract for itself; the state is keyed by
        // account and this one's caps do not move.
        gate.addPolicy(policy, POLICY_ID, _caps(5000, 9000));
        vm.stopPrank();

        assertEq(_softCap(), SOFT);
        assertEq(_hardCap(), HARD);
    }
}
