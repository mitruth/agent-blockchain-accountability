// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title PolicyConfig
/// @notice Caps, window length, pause state and the role registry for the
///         delegated-authority enforcement layer.
///
/// Split from accounting on purpose. This contract holds what the owner may
/// change; SpendLedger holds what the agent reports. The validator module is
/// upgradeable and reads both; neither of these two is redeployed with it.
///
/// Every write increments policyVersion and emits the full resulting state
/// together with the day it applies from. A third party reconstructing the cap
/// in force on any day must never have to infer it from a transaction
/// timestamp -- effectiveFromDay is always explicit in the event.
contract PolicyConfig {
    /// @notice Seconds per day. Day index is days since the Unix epoch, UTC.
    ///         Pinned here so nothing depends on a host timezone.
    uint64 public constant SECONDS_PER_DAY = 86400;

    /// @notice One cap regime, in force from `effectiveFromDay` onward until a
    ///         later epoch supersedes it.
    struct CapEpoch {
        uint64 effectiveFromDay;
        int256 cap;
        uint32 windowDays;
        uint256 policyVersion;
    }

    address public immutable owner;

    /// @notice May pause spends and the agent. Nothing else.
    address public guardian;

    /// @notice The agent's session key. Owner revokes it immediately, pause or
    ///         no pause.
    address public sessionKey;

    /// @notice Append-only in effect: strictly increasing in effectiveFromDay.
    ///         A write whose effectiveFromDay equals the last epoch's replaces
    ///         it rather than appending, so last-write-wins on a given day.
    CapEpoch[] private _capEpochs;

    uint256 public policyVersion;

    bool public spendsPaused;
    bool public agentPaused;

    /// @notice Unix seconds at which the current pause began. Zero when not paused.
    uint64 public pauseStartedAt;

    /// @notice Pause lifts itself at this time with no owner action. This is
    ///         the anti-griefing path against a malicious guardian.
    uint32 public pauseExpirySeconds;

    /// @notice Owner may not unpause before pauseStartedAt + this. Stops a
    ///         compromised owner key from instantly undoing a live guardian pause.
    uint32 public unpauseDelaySeconds;

    event PolicyUpdated(
        uint256 indexed policyVersion,
        int256 cap,
        uint32 windowDays,
        uint64 effectiveFromDay,
        address setBy
    );

    event PauseTimingUpdated(
        uint256 indexed policyVersion,
        uint32 pauseExpirySeconds,
        uint32 unpauseDelaySeconds,
        address setBy
    );

    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event SessionKeyUpdated(address indexed previousSessionKey, address indexed newSessionKey);

    event SpendsPaused(address indexed by, uint64 startedAt, uint64 expiresAt);
    event AgentPaused(address indexed by, uint64 startedAt, uint64 expiresAt);
    event Unpaused(address indexed by, bool spends, bool agent, bool viaExpiry);

    modifier onlyOwner() {
        require(msg.sender == owner, "PolicyConfig: only owner");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "PolicyConfig: only guardian");
        _;
    }

    /// @param initialCap        Cap in minor units (milli-USD), signed.
    /// @param initialWindowDays Rolling window length in days. Must be non-zero.
    constructor(
        address guardian_,
        address sessionKey_,
        int256 initialCap,
        uint32 initialWindowDays,
        uint32 pauseExpirySeconds_,
        uint32 unpauseDelaySeconds_
    ) {
        require(initialWindowDays != 0, "PolicyConfig: windowDays is zero");
        require(pauseExpirySeconds_ != 0, "PolicyConfig: pauseExpiry is zero");
        require(
            unpauseDelaySeconds_ < pauseExpirySeconds_,
            "PolicyConfig: unpause delay not below pause expiry"
        );

        owner = msg.sender;
        guardian = guardian_;
        sessionKey = sessionKey_;
        pauseExpirySeconds = pauseExpirySeconds_;
        unpauseDelaySeconds = unpauseDelaySeconds_;

        policyVersion = 1;
        _capEpochs.push(
            CapEpoch({
                effectiveFromDay: 0,
                cap: initialCap,
                windowDays: initialWindowDays,
                policyVersion: 1
            })
        );

        emit PolicyUpdated(1, initialCap, initialWindowDays, 0, msg.sender);
        emit PauseTimingUpdated(1, pauseExpirySeconds_, unpauseDelaySeconds_, msg.sender);
        emit GuardianUpdated(address(0), guardian_);
        emit SessionKeyUpdated(address(0), sessionKey_);
    }

    // ------------------------------------------------------------------
    // Day arithmetic
    // ------------------------------------------------------------------

    /// @notice Current day index, UTC, derived from block time. Never supplied
    ///         by a caller.
    function todayIndex() public view returns (uint64) {
        return uint64(block.timestamp / SECONDS_PER_DAY);
    }

    /// @notice First day of the window period strictly after `day`.
    ///         Boundaries sit at multiples of `windowDays_` measured from the
    ///         Unix epoch, so the schedule is fixed and reconstructible without
    ///         reference to when any transaction was mined.
    function nextWindowBoundary(uint64 day, uint32 windowDays_) public pure returns (uint64) {
        require(windowDays_ != 0, "PolicyConfig: windowDays is zero");
        return ((day / windowDays_) + 1) * windowDays_;
    }

    // ------------------------------------------------------------------
    // Cap history
    // ------------------------------------------------------------------

    function capEpochCount() external view returns (uint256) {
        return _capEpochs.length;
    }

    function capEpochAt(uint256 index) external view returns (CapEpoch memory) {
        return _capEpochs[index];
    }

    /// @notice The cap regime in force on `dayIndex`: the latest epoch whose
    ///         effectiveFromDay is at or before that day.
    ///
    /// Walks backward from the newest epoch. The array is short by construction
    /// (one entry per owner policy write) and strictly ordered, so this is
    /// bounded by the number of owner writes and never by anything the agent
    /// controls.
    function regimeAt(uint64 dayIndex) public view returns (CapEpoch memory) {
        uint256 i = _capEpochs.length;
        while (i > 0) {
            unchecked {
                --i;
            }
            if (_capEpochs[i].effectiveFromDay <= dayIndex) {
                return _capEpochs[i];
            }
        }
        // Epoch 0 is written in the constructor with effectiveFromDay 0, so no
        // day index can fall before the first regime.
        revert("PolicyConfig: no regime for day");
    }

    function capAt(uint64 dayIndex) external view returns (int256) {
        return regimeAt(dayIndex).cap;
    }

    function windowDaysAt(uint64 dayIndex) external view returns (uint32) {
        return regimeAt(dayIndex).windowDays;
    }

    /// @notice Cap and window in force right now.
    function currentRegime() external view returns (CapEpoch memory) {
        return regimeAt(todayIndex());
    }

    // ------------------------------------------------------------------
    // Owner: policy writes
    // ------------------------------------------------------------------

    /// @notice Set the cap and window length.
    ///
    /// A lowering takes effect today. A raise takes effect at the next window
    /// boundary, so the agent cannot be handed capacity part-way through a
    /// window it has already partly spent.
    ///
    /// A lowering also cancels any pending epoch scheduled for a future day.
    /// Without that, a raise queued yesterday would resurrect itself after a
    /// lowering made today. The verifier applies the same rule.
    ///
    /// Lowering below the current window sum blocks further spend. It is not a
    /// retroactive breach: days already recorded were checked against the cap
    /// in force when they were recorded, and stay compliant.
    ///
    /// Pause does not block this path -- the owner must always be able to lower.
    function setPolicy(int256 newCap, uint32 newWindowDays) external onlyOwner {
        require(newWindowDays != 0, "PolicyConfig: windowDays is zero");

        uint64 today = todayIndex();
        CapEpoch memory current = regimeAt(today);

        bool isLowering = newCap <= current.cap;
        uint64 effectiveFromDay = isLowering
            ? today
            : nextWindowBoundary(today, current.windowDays);

        if (isLowering) {
            // Drop every epoch scheduled for a day still in the future.
            while (
                _capEpochs.length > 0 &&
                _capEpochs[_capEpochs.length - 1].effectiveFromDay > today
            ) {
                _capEpochs.pop();
            }
        }

        uint256 nextVersion = policyVersion + 1;
        policyVersion = nextVersion;

        uint256 length = _capEpochs.length;
        if (length > 0 && _capEpochs[length - 1].effectiveFromDay == effectiveFromDay) {
            // Same effective day as the newest epoch: replace, last write wins.
            _capEpochs[length - 1] = CapEpoch({
                effectiveFromDay: effectiveFromDay,
                cap: newCap,
                windowDays: newWindowDays,
                policyVersion: nextVersion
            });
        } else {
            _capEpochs.push(
                CapEpoch({
                    effectiveFromDay: effectiveFromDay,
                    cap: newCap,
                    windowDays: newWindowDays,
                    policyVersion: nextVersion
                })
            );
        }

        emit PolicyUpdated(nextVersion, newCap, newWindowDays, effectiveFromDay, msg.sender);
    }

    function setPauseTiming(uint32 pauseExpirySeconds_, uint32 unpauseDelaySeconds_)
        external
        onlyOwner
    {
        require(pauseExpirySeconds_ != 0, "PolicyConfig: pauseExpiry is zero");
        require(
            unpauseDelaySeconds_ < pauseExpirySeconds_,
            "PolicyConfig: unpause delay not below pause expiry"
        );

        pauseExpirySeconds = pauseExpirySeconds_;
        unpauseDelaySeconds = unpauseDelaySeconds_;

        uint256 nextVersion = policyVersion + 1;
        policyVersion = nextVersion;

        emit PauseTimingUpdated(nextVersion, pauseExpirySeconds_, unpauseDelaySeconds_, msg.sender);
    }

    // ------------------------------------------------------------------
    // Owner: roles
    // ------------------------------------------------------------------

    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Revoke or rotate the agent's session key. Deliberately reachable
    ///         while paused: a pause must never trap a compromised key in place.
    function setSessionKey(address newSessionKey) external onlyOwner {
        emit SessionKeyUpdated(sessionKey, newSessionKey);
        sessionKey = newSessionKey;
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    /// @notice True once the pause has aged past its expiry. An expired pause
    ///         imposes nothing, whether or not anyone has cleared the flags.
    function pauseExpired() public view returns (bool) {
        if (pauseStartedAt == 0) {
            return false;
        }
        return block.timestamp >= uint256(pauseStartedAt) + uint256(pauseExpirySeconds);
    }

    function spendsCurrentlyPaused() public view returns (bool) {
        return spendsPaused && !pauseExpired();
    }

    function agentCurrentlyPaused() public view returns (bool) {
        return agentPaused && !pauseExpired();
    }

    function pauseSpends() external onlyGuardian {
        spendsPaused = true;
        if (pauseStartedAt == 0 || pauseExpired()) {
            pauseStartedAt = uint64(block.timestamp);
        }
        emit SpendsPaused(
            msg.sender,
            pauseStartedAt,
            pauseStartedAt + uint64(pauseExpirySeconds)
        );
    }

    function pauseAgent() external onlyGuardian {
        agentPaused = true;
        if (pauseStartedAt == 0 || pauseExpired()) {
            pauseStartedAt = uint64(block.timestamp);
        }
        emit AgentPaused(
            msg.sender,
            pauseStartedAt,
            pauseStartedAt + uint64(pauseExpirySeconds)
        );
    }

    /// @notice Owner lifts the pause, but not before the delay has run.
    function unpause() external onlyOwner {
        require(pauseStartedAt != 0, "PolicyConfig: not paused");
        require(
            block.timestamp >= uint256(pauseStartedAt) + uint256(unpauseDelaySeconds),
            "PolicyConfig: unpause delay not elapsed"
        );
        _clearPause(false);
    }

    /// @notice Clear an expired pause. Callable by anyone: the pause is already
    ///         inert by then, this only tidies the flags.
    function clearExpiredPause() external {
        require(pauseStartedAt != 0, "PolicyConfig: not paused");
        require(pauseExpired(), "PolicyConfig: pause not expired");
        _clearPause(true);
    }

    function _clearPause(bool viaExpiry) private {
        bool hadSpends = spendsPaused;
        bool hadAgent = agentPaused;
        spendsPaused = false;
        agentPaused = false;
        pauseStartedAt = 0;
        emit Unpaused(msg.sender, hadSpends, hadAgent, viaExpiry);
    }
}
