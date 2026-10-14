// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GateBase} from "./GateBase.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {ConfigChange} from "./GateTypes.sol";

/// @title ConfigManager
/// @notice The per-account list of policies and the one path by which their
///         parameters change: tighten now, widen after a timelock.
///
/// Every write here is on the owner path. A change that only tightens applies
/// in the same call. A change that loosens anything is recorded as a proposal
/// and can be applied no earlier than WIDEN_DELAY later; a change that tightens
/// one parameter and loosens another counts as loosening. Removing a policy
/// removes a constraint, so it waits too. Adding one only adds a constraint, so
/// it does not.
///
/// The timelock protects parameter edits and nothing more. The account's root
/// validator can uninstall the whole gate in one transaction, with no delay.
///
/// Each policy instance has at most one pending proposal. Any later write to
/// the same instance drops it, so a widening queued yesterday cannot come back
/// after a tightening made today.
abstract contract ConfigManager is GateBase {
    /// @notice T_w: how long a widening waits between proposal and application.
    uint48 public constant WIDEN_DELAY = 24 hours;

    /// @notice Upper bound on the policies of one account. `submit` will call
    ///         every one of them, so the list is bounded here.
    uint256 public constant MAX_POLICIES = 16;

    enum ProposalKind {
        NONE,
        CONFIG,
        REMOVE
    }

    enum RejectReason {
        INVALID,
        SUPERSEDED,
        CANCELLED
    }

    struct PolicyRef {
        IPolicy policy;
        bytes32 policyId;
    }

    struct Proposal {
        ProposalKind kind;
        uint48 eta;
        bytes32 configHash;
    }

    mapping(address account => mapping(uint64 generation => PolicyRef[])) private _policies;
    mapping(address account => mapping(uint64 generation => mapping(bytes32 key => uint256))) private _indexPlusOne;
    mapping(address account => mapping(uint64 generation => mapping(bytes32 key => Proposal))) private _proposals;

    event PolicyAdded(address indexed account, address indexed policy, bytes32 indexed policyId);
    event PolicyRemoved(address indexed account, address indexed policy, bytes32 indexed policyId);

    /// @notice A widening or a removal, queued. `config` is empty for a removal.
    event ConfigProposed(
        address indexed account,
        address indexed policy,
        bytes32 indexed policyId,
        ProposalKind kind,
        bytes config,
        uint48 eta
    );

    /// @notice A configuration put in force, in full.
    event ConfigApplied(address indexed account, address indexed policy, bytes32 indexed policyId, bytes config);

    /// @notice A configuration refused, or a proposal dropped before it applied.
    event ConfigRejected(
        address indexed account,
        address indexed policy,
        bytes32 indexed policyId,
        RejectReason reason,
        bytes32 configHash
    );

    error ConfigManager_InvalidPolicy(address policy);
    error ConfigManager_PolicyAlreadyAdded(address policy, bytes32 policyId);
    error ConfigManager_UnknownPolicy(address policy, bytes32 policyId);
    error ConfigManager_TooManyPolicies();
    error ConfigManager_NoProposal(address policy, bytes32 policyId);
    error ConfigManager_ConfigMismatch(bytes32 proposed, bytes32 supplied);
    error ConfigManager_TimelockActive(uint48 eta);

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function policiesOf(address account) public view returns (PolicyRef[] memory) {
        return _policies[account][generationOf(account)];
    }

    function hasPolicy(address account, IPolicy policy, bytes32 policyId) public view returns (bool) {
        return _indexPlusOne[account][generationOf(account)][_key(policy, policyId)] != 0;
    }

    function proposalOf(address account, IPolicy policy, bytes32 policyId) public view returns (Proposal memory) {
        return _proposals[account][generationOf(account)][_key(policy, policyId)];
    }

    // ------------------------------------------------------------------
    // Owner path: the policy list
    // ------------------------------------------------------------------

    /// @notice Add a policy instance with its first configuration. Applies at
    ///         once: a new policy can only add a constraint.
    /// @return applied False when the policy refused the configuration; the
    ///         instance is then not added and ConfigRejected says so.
    function addPolicy(IPolicy policy, bytes32 policyId, bytes calldata config)
        external
        onlyAccount
        nonReentrant
        returns (bool applied)
    {
        address account = msg.sender;
        uint64 generation = generationOf(account);
        bytes32 key = _key(policy, policyId);

        if (address(policy) == address(0) || address(policy) == account || address(policy) == address(this)) {
            revert ConfigManager_InvalidPolicy(address(policy));
        }
        if (_indexPlusOne[account][generation][key] != 0) {
            revert ConfigManager_PolicyAlreadyAdded(address(policy), policyId);
        }
        PolicyRef[] storage list = _policies[account][generation];
        if (list.length >= MAX_POLICIES) revert ConfigManager_TooManyPolicies();

        if (policy.classifyConfig(account, policyId, config) == ConfigChange.INVALID) {
            emit ConfigRejected(account, address(policy), policyId, RejectReason.INVALID, keccak256(config));
            return false;
        }

        list.push(PolicyRef({policy: policy, policyId: policyId}));
        _indexPlusOne[account][generation][key] = list.length;
        emit PolicyAdded(account, address(policy), policyId);

        policy.configure(account, policyId, config);
        emit ConfigApplied(account, address(policy), policyId, config);
        return true;
    }

    /// @notice Queue the removal of a policy instance. Removal lifts a
    ///         constraint, so it waits WIDEN_DELAY like any other widening.
    function proposeRemovePolicy(IPolicy policy, bytes32 policyId) external onlyAccount nonReentrant {
        address account = msg.sender;
        bytes32 key = _requireKnown(account, policy, policyId);

        _dropPending(account, policy, policyId, key, RejectReason.SUPERSEDED);

        uint48 eta = uint48(block.timestamp) + WIDEN_DELAY;
        _proposals[account][generationOf(account)][key] =
            Proposal({kind: ProposalKind.REMOVE, eta: eta, configHash: bytes32(0)});
        emit ConfigProposed(account, address(policy), policyId, ProposalKind.REMOVE, "", eta);
    }

    /// @notice Carry out a removal whose timelock has run.
    function applyRemovePolicy(IPolicy policy, bytes32 policyId) external onlyAccount nonReentrant {
        address account = msg.sender;
        uint64 generation = generationOf(account);
        bytes32 key = _requireKnown(account, policy, policyId);

        Proposal memory proposal = _proposals[account][generation][key];
        if (proposal.kind != ProposalKind.REMOVE) revert ConfigManager_NoProposal(address(policy), policyId);
        if (block.timestamp < proposal.eta) revert ConfigManager_TimelockActive(proposal.eta);

        delete _proposals[account][generation][key];

        // Swap the last entry into the vacated place. Order carries no meaning:
        // every policy on the list has to pass.
        PolicyRef[] storage list = _policies[account][generation];
        uint256 index = _indexPlusOne[account][generation][key] - 1;
        uint256 last = list.length - 1;
        if (index != last) {
            PolicyRef memory moved = list[last];
            list[index] = moved;
            _indexPlusOne[account][generation][_key(moved.policy, moved.policyId)] = index + 1;
        }
        list.pop();
        delete _indexPlusOne[account][generation][key];

        // A policy that reverts here must not be able to make itself permanent.
        try policy.deconfigure(account, policyId) {} catch {}
        emit PolicyRemoved(account, address(policy), policyId);
    }

    // ------------------------------------------------------------------
    // Owner path: parameters
    // ------------------------------------------------------------------

    /// @notice Change the configuration of a policy instance.
    ///
    ///   INVALID  nothing changes; ConfigRejected is emitted
    ///   TIGHTEN  applies in this call
    ///   WIDEN    recorded as a proposal; `applyConfig` puts it in force once
    ///            WIDEN_DELAY has passed
    ///
    /// @return change How the policy classified the configuration.
    function setConfig(IPolicy policy, bytes32 policyId, bytes calldata config)
        external
        onlyAccount
        nonReentrant
        returns (ConfigChange change)
    {
        address account = msg.sender;
        bytes32 key = _requireKnown(account, policy, policyId);

        _dropPending(account, policy, policyId, key, RejectReason.SUPERSEDED);

        change = policy.classifyConfig(account, policyId, config);

        if (change == ConfigChange.INVALID) {
            emit ConfigRejected(account, address(policy), policyId, RejectReason.INVALID, keccak256(config));
        } else if (change == ConfigChange.TIGHTEN) {
            policy.configure(account, policyId, config);
            emit ConfigApplied(account, address(policy), policyId, config);
        } else {
            uint48 eta = uint48(block.timestamp) + WIDEN_DELAY;
            _proposals[account][generationOf(account)][key] =
                Proposal({kind: ProposalKind.CONFIG, eta: eta, configHash: keccak256(config)});
            emit ConfigProposed(account, address(policy), policyId, ProposalKind.CONFIG, config, eta);
        }
    }

    /// @notice Put a proposed widening in force once its timelock has run.
    /// @param config The configuration as proposed, byte for byte.
    /// @return applied False when the policy now refuses it: other parameters
    ///         may have changed since the proposal. The proposal is spent
    ///         either way.
    function applyConfig(IPolicy policy, bytes32 policyId, bytes calldata config)
        external
        onlyAccount
        nonReentrant
        returns (bool applied)
    {
        address account = msg.sender;
        uint64 generation = generationOf(account);
        bytes32 key = _requireKnown(account, policy, policyId);

        Proposal memory proposal = _proposals[account][generation][key];
        if (proposal.kind != ProposalKind.CONFIG) revert ConfigManager_NoProposal(address(policy), policyId);
        if (proposal.configHash != keccak256(config)) {
            revert ConfigManager_ConfigMismatch(proposal.configHash, keccak256(config));
        }
        if (block.timestamp < proposal.eta) revert ConfigManager_TimelockActive(proposal.eta);

        delete _proposals[account][generation][key];

        if (policy.classifyConfig(account, policyId, config) == ConfigChange.INVALID) {
            emit ConfigRejected(account, address(policy), policyId, RejectReason.INVALID, proposal.configHash);
            return false;
        }

        policy.configure(account, policyId, config);
        emit ConfigApplied(account, address(policy), policyId, config);
        return true;
    }

    /// @notice Drop a pending proposal.
    function cancelProposal(IPolicy policy, bytes32 policyId) external onlyAccount nonReentrant {
        address account = msg.sender;
        bytes32 key = _requireKnown(account, policy, policyId);

        if (_proposals[account][generationOf(account)][key].kind == ProposalKind.NONE) {
            revert ConfigManager_NoProposal(address(policy), policyId);
        }
        _dropPending(account, policy, policyId, key, RejectReason.CANCELLED);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Tell every policy of `account` to drop its state. Called while the
    ///      gate is being uninstalled, so a policy that reverts must not be
    ///      able to pin the gate in place: failures are swallowed.
    function _deconfigureAll(address account) internal {
        PolicyRef[] storage list = _policies[account][generationOf(account)];
        uint256 length = list.length;
        for (uint256 i = 0; i < length; ++i) {
            try list[i].policy.deconfigure(account, list[i].policyId) {} catch {}
        }
    }

    function _dropPending(address account, IPolicy policy, bytes32 policyId, bytes32 key, RejectReason reason)
        private
    {
        uint64 generation = generationOf(account);
        Proposal memory pending = _proposals[account][generation][key];
        if (pending.kind == ProposalKind.NONE) return;

        delete _proposals[account][generation][key];
        emit ConfigRejected(account, address(policy), policyId, reason, pending.configHash);
    }

    function _requireKnown(address account, IPolicy policy, bytes32 policyId) private view returns (bytes32 key) {
        key = _key(policy, policyId);
        if (_indexPlusOne[account][generationOf(account)][key] == 0) {
            revert ConfigManager_UnknownPolicy(address(policy), policyId);
        }
    }

    function _key(IPolicy policy, bytes32 policyId) private pure returns (bytes32) {
        return keccak256(abi.encode(policy, policyId));
    }
}
