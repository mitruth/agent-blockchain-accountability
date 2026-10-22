// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {WindowLib} from "../policies/WindowLib.sol";
import {ConfigChange} from "./GateTypes.sol";

/// @title SessionBreaker
/// @notice G1, the session circuit breaker (spec v0.2, section 5): an account
///         whose submissions are rejected or flagged too often is suspended to
///         cancel-only.
///
/// A rejection returns normally, so an agent can probe a bound for the price
/// of gas, one submission at a time. Only the gate sees the outcome, and only
/// the gate can keep state on that non-reverting path, so the breaker belongs
/// to the gate: the gate deploys it, and only the gate writes it. It is a
/// separate contract because the gate's code is close to EIP-170's limit.
///
/// What it counts, per account, in two SLIDING windows:
///
///   rejects  submissions the gate refused without reverting: by a policy, by
///            the recipient lock (A9)
///   flags    submissions that went ahead with at least one soft bound crossed
///
/// After a submission it counts, the breaker suspends the account when either
/// count exceeds its cap (R_max, F_max). A clean submission is never judged.
///
/// The gate sees the account, not the agent (decision D1): suspension closes
/// the account's `submit` path, the agent's and the owner's own `submit`
/// alike. The owner still acts directly, through the root validator.
///
/// While suspended (decision D17, as answered on 21 October 2026): a
/// submission whose legs are all cancellations goes on to the policies, which
/// still judge it, so a policy that counts cancellations (S6) or rejects some
/// (A10) still applies. Anything else -- a placement, a modification, a funds
/// move, an approval -- is refused. Nothing is counted while suspended.
///
/// Reinstatement:
///
///   owner  `reinstate`, through the gate. It clears both windows: without
///          that, the next rejection would suspend again at once
///   auto   if the owner set a cooldown, the account counts as active again
///          from `suspendedAt + cooldown`; the first submission from then on
///          records it. The windows are not cleared: they empty on their own
///
/// Configuration is opt-in and on the owner path, by the rule of every
/// policy: what only tightens applies at once; what loosens anything waits
/// WIDEN_DELAY. Tighter is a lower cap, a longer cooldown (0, owner only, is
/// the tightest), or turning the breaker on. A change of a window's shape
/// starts it afresh, so it counts as loosening (spec 5.6), and so does turning
/// the breaker off. Any later write drops a pending widening. Configuration
/// events name their author, so a second configuring authority (spec v0.2
/// section 11.5) can be told apart later.
///
/// State is kept per account and gate installation generation: a reinstalled
/// gate starts with the breaker off and nothing counted.
contract SessionBreaker {
    using WindowLib for WindowLib.Window;

    uint48 public constant WIDEN_DELAY = 24 hours;

    /// @notice Longest cooldown an owner may set.
    uint32 public constant MAX_COOLDOWN = 30 days;

    uint256 private constant CONFIG_LENGTH = (7 + 7 + 1) * 32;

    enum Reason {
        REJECTS,
        FLAGS
    }

    enum Reinstatement {
        OWNER,
        AUTO
    }

    /// @param rejects         SLIDING; its cap is R_max.
    /// @param flags           SLIDING; its cap is F_max.
    /// @param cooldownSeconds T_c; 0: only the owner reinstates.
    struct Config {
        WindowLib.Config rejects;
        WindowLib.Config flags;
        uint32 cooldownSeconds;
    }

    struct State {
        bool on;
        bool suspended;
        uint48 suspendedAt;
        uint32 cooldownSeconds;
    }

    struct Proposal {
        uint48 eta;
        bytes32 configHash;
    }

    address public immutable gate;

    mapping(address account => mapping(uint64 generation => State)) private _states;
    mapping(address account => mapping(uint64 generation => WindowLib.Window)) private _rejects;
    mapping(address account => mapping(uint64 generation => WindowLib.Window)) private _flags;
    mapping(address account => mapping(uint64 generation => Proposal)) private _proposals;

    /// @notice A configuration in force, in full; empty when G1 was turned off.
    event BreakerConfigApplied(address indexed account, address indexed author, bytes config);
    /// @notice A widening queued; it applies no earlier than `eta`.
    event BreakerConfigProposed(address indexed account, address indexed author, bytes config, uint48 eta);
    event BreakerProposalDropped(address indexed account, bytes32 configHash);

    /// @notice The account is suspended to cancel-only. The counts are the
    ///         windows' after the submission that tripped it.
    event AgentSuspended(address indexed account, Reason reason, uint64 rejectsUsed, uint64 flagsUsed, uint48 at);
    event AgentReinstated(address indexed account, Reinstatement how, uint48 at);

    error Breaker_OnlyGate(address caller);
    error Breaker_InvalidConfig();
    error Breaker_NoProposal();
    error Breaker_ConfigMismatch(bytes32 proposed, bytes32 supplied);
    error Breaker_TimelockActive(uint48 eta);
    error Breaker_NotSuspended(address account);

    modifier onlyGate() {
        if (msg.sender != gate) revert Breaker_OnlyGate(msg.sender);
        _;
    }

    constructor(address gate_) {
        gate = gate_;
    }

    // ------------------------------------------------------------------
    // Owner path, through the gate
    // ------------------------------------------------------------------

    /// @notice Tighten at once, or queue a widening. `config` empty turns G1
    ///         off, which is a widening.
    /// @return applied Whether it applied at once.
    function setConfig(address account, uint64 generation, bytes calldata config)
        external
        onlyGate
        returns (bool applied)
    {
        ConfigChange change = classify(account, generation, config);
        if (change == ConfigChange.INVALID) revert Breaker_InvalidConfig();
        _dropProposal(account, generation);
        if (change == ConfigChange.TIGHTEN) {
            _apply(account, generation, config);
            return true;
        }
        uint48 eta = uint48(block.timestamp) + WIDEN_DELAY;
        _proposals[account][generation] = Proposal({eta: eta, configHash: keccak256(config)});
        emit BreakerConfigProposed(account, account, config, eta);
    }

    /// @notice Apply the queued widening, once its timelock has passed.
    function applyConfig(address account, uint64 generation, bytes calldata config) external onlyGate {
        Proposal memory p = _proposals[account][generation];
        if (p.eta == 0) revert Breaker_NoProposal();
        if (p.configHash != keccak256(config)) revert Breaker_ConfigMismatch(p.configHash, keccak256(config));
        if (block.timestamp < p.eta) revert Breaker_TimelockActive(p.eta);
        delete _proposals[account][generation];
        _apply(account, generation, config);
    }

    /// @notice The owner lifts a suspension, and both windows start empty.
    function reinstate(address account, uint64 generation) external onlyGate {
        State storage s = _states[account][generation];
        if (!s.suspended) revert Breaker_NotSuspended(account);
        s.suspended = false;
        _rejects[account][generation].clear();
        _flags[account][generation].clear();
        emit AgentReinstated(account, Reinstatement.OWNER, uint48(block.timestamp));
    }

    // ------------------------------------------------------------------
    // The gate's submission path
    // ------------------------------------------------------------------

    /// @notice Whether a submission may go on to the policies. A suspended
    ///         account passes only a submission of cancellations. Records an
    ///         automatic reinstatement when the cooldown has run out.
    function admit(address account, uint64 generation, bool onlyCancels) external onlyGate returns (bool) {
        State storage s = _states[account][generation];
        if (!s.suspended) return true;
        if (s.cooldownSeconds != 0 && block.timestamp >= uint256(s.suspendedAt) + s.cooldownSeconds) {
            s.suspended = false;
            emit AgentReinstated(account, Reinstatement.AUTO, uint48(block.timestamp));
            return true;
        }
        return onlyCancels;
    }

    /// @notice Count a submission the gate rejected or flagged, and suspend if
    ///         a cap is exceeded. Nothing is counted while G1 is off or the
    ///         account is suspended.
    function record(address account, uint64 generation, bool rejected, bool flagged) external onlyGate {
        State storage s = _states[account][generation];
        if (!s.on || s.suspended) return;
        WindowLib.Window storage r = _rejects[account][generation];
        WindowLib.Window storage f = _flags[account][generation];
        if (rejected) r.add(block.timestamp, 1);
        if (flagged) f.add(block.timestamp, 1);
        uint64 rejectsUsed = r.used(block.timestamp);
        uint64 flagsUsed = f.used(block.timestamp);
        bool overRejects = rejectsUsed > r.config.cap;
        bool overFlags = flagsUsed > f.config.cap;
        if (!overRejects && !overFlags) return;
        s.suspended = true;
        s.suspendedAt = uint48(block.timestamp);
        emit AgentSuspended(
            account, overRejects ? Reason.REJECTS : Reason.FLAGS, rejectsUsed, flagsUsed, uint48(block.timestamp)
        );
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed; a window that is not SLIDING or that
    ///         WindowLib refuses; a cooldown above MAX_COOLDOWN.
    ///         TIGHTEN: turning G1 on; or nothing looser than in force.
    ///         WIDEN: turning it off; a higher cap; another window shape; a
    ///         cooldown that reinstates sooner (from 0, any).
    function classify(address account, uint64 generation, bytes calldata config) public view returns (ConfigChange) {
        State memory s = _states[account][generation];
        if (config.length == 0) return s.on ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (!_isSliding(n.rejects) || !_isSliding(n.flags) || n.cooldownSeconds > MAX_COOLDOWN) {
            return ConfigChange.INVALID;
        }
        if (!s.on) return ConfigChange.TIGHTEN;

        WindowLib.Config memory r = _rejects[account][generation].config;
        WindowLib.Config memory f = _flags[account][generation].config;
        bool wider = _looser(n.rejects, r) || _looser(n.flags, f)
            || (n.cooldownSeconds != 0 && (s.cooldownSeconds == 0 || n.cooldownSeconds < s.cooldownSeconds));
        return wider ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function stateOf(address account, uint64 generation) external view returns (State memory) {
        return _states[account][generation];
    }

    function usedOf(address account, uint64 generation) external view returns (uint64 rejectsUsed, uint64 flagsUsed) {
        rejectsUsed = _rejects[account][generation].used(block.timestamp);
        flagsUsed = _flags[account][generation].used(block.timestamp);
    }

    function configOf(address account, uint64 generation) external view returns (Config memory c) {
        c.rejects = _rejects[account][generation].config;
        c.flags = _flags[account][generation].config;
        c.cooldownSeconds = _states[account][generation].cooldownSeconds;
    }

    function proposalOf(address account, uint64 generation) external view returns (Proposal memory) {
        return _proposals[account][generation];
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev A well-formed SLIDING window, with the fields only other classes
    ///      use left at zero: so a window's shape is its step and buckets.
    function _isSliding(WindowLib.Config memory c) private pure returns (bool) {
        return c.kind == WindowLib.Kind.SLIDING && WindowLib.isValid(c) && c.anchor == 0 && c.rate == 0 && c.initial == 0;
    }

    function _looser(WindowLib.Config memory next, WindowLib.Config memory current) private pure returns (bool) {
        return next.step != current.step || next.buckets != current.buckets || next.cap > current.cap;
    }

    function _apply(address account, uint64 generation, bytes calldata config) private {
        State storage s = _states[account][generation];
        if (config.length == 0) {
            s.on = false;
            s.suspended = false;
            s.cooldownSeconds = 0;
            _rejects[account][generation].clear();
            _flags[account][generation].clear();
        } else {
            Config memory c = abi.decode(config, (Config));
            _rejects[account][generation].configure(c.rejects);
            _flags[account][generation].configure(c.flags);
            s.on = true;
            s.cooldownSeconds = c.cooldownSeconds;
        }
        emit BreakerConfigApplied(account, account, config);
    }

    function _dropProposal(address account, uint64 generation) private {
        Proposal memory p = _proposals[account][generation];
        if (p.eta == 0) return;
        delete _proposals[account][generation];
        emit BreakerProposalDropped(account, p.configHash);
    }
}
