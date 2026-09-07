// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IModule} from "./interfaces/IModule.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {PolicyConfig} from "./PolicyConfig.sol";
import {SpendLedger} from "./SpendLedger.sol";

/// @title SpendValidator
/// @notice Upgradeable enforcement module. Holds no durable spend state.
///
/// Reads PolicyConfig (caps, pause, session key) and SpendLedger (raw days).
/// A swap of this module must not reset the rolling window: the ledger is
/// deployed once and this contract only recomputes sums from raw days.
///
/// Write authority onto the ledger is the owner-controlled allowlist on
/// SpendLedger, not install status on the account. Owner must setWriter(this)
/// after deploy; installing the module alone grants nothing.
contract SpendValidator is IValidator {
    uint256 public constant MODULE_TYPE_VALIDATOR = 1;

    PolicyConfig public immutable config;
    SpendLedger public immutable ledger;

    /// @notice The account this module serves. Bound at construction and never
    ///         mutable: an unpermissioned onInstall lets any stranger claim this
    ///         slot, and onUninstall then reverts for the real account, pinning
    ///         the module in place permanently. The owner's upgrade path must
    ///         not be griefable by a stranger.
    address public immutable smartAccount;

    event DaySubmitted(
        uint64 indexed dayIndex,
        int256 netSpend,
        int256 windowSumAfter,
        uint256 policyVersion,
        bool paused
    );

    error SpendValidator_OnlySessionKey();
    error SpendValidator_OnlySmartAccount();
    error SpendValidator_AgentPaused();
    error SpendValidator_CapExceeded();
    error SpendValidator_WindowDaysZero();

    constructor(PolicyConfig config_, SpendLedger ledger_, address smartAccount_) {
        config = config_;
        ledger = ledger_;
        smartAccount = smartAccount_;
    }

    /// @inheritdoc IModule
    /// @dev Holds no state. The account binding is immutable, so install and
    ///      uninstall only verify the caller and can never be hijacked.
    function onInstall(bytes calldata) external view override {
        if (msg.sender != smartAccount) revert SpendValidator_OnlySmartAccount();
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external view override {
        if (msg.sender != smartAccount) revert SpendValidator_OnlySmartAccount();
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    function isInitialized(address account) external view returns (bool) {
        return smartAccount == account;
    }

    // ------------------------------------------------------------------
    // Window
    // ------------------------------------------------------------------

    /// @notice Inclusive rolling sum over [day - (windowDays - 1), day].
    ///         Missing days contribute 0. Negative days reduce the sum.
    ///         Bounded by windowDays from config — never by agent-grown storage.
    function windowSum(uint64 day) public view returns (int256 total) {
        uint32 windowDays = config.windowDaysAt(day);
        if (windowDays == 0) revert SpendValidator_WindowDaysZero();

        uint64 startDay;
        unchecked {
            // windowDays >= 1 by PolicyConfig construction / setPolicy.
            uint64 span = uint64(windowDays - 1);
            startDay = day >= span ? day - span : 0;
        }

        for (uint64 d = startDay; d <= day; ) {
            total += ledger.netSpendOf(d);
            unchecked {
                ++d;
            }
        }
    }

    // ------------------------------------------------------------------
    // Session key: daily records
    // ------------------------------------------------------------------

    /// @notice Submit today's net spend (or a pause-imposed zero day).
    ///
    /// Day index comes from PolicyConfig.todayIndex() — never from the caller —
    /// so the agent cannot backdate or skip the UTC calendar.
    ///
    /// Same-day resubmission accumulates via SpendLedger.recordDay. The post-
    /// write window must not exceed the cap in force today; equality is allowed.
    function submitDay(int256 netSpend) external {
        if (msg.sender != config.sessionKey()) revert SpendValidator_OnlySessionKey();
        if (config.agentCurrentlyPaused()) revert SpendValidator_AgentPaused();

        uint64 day = config.todayIndex();
        PolicyConfig.CapEpoch memory regime = config.regimeAt(day);

        bool paused = config.spendsCurrentlyPaused();
        int256 amount = paused ? int256(0) : netSpend;

        int256 sumAfter = windowSum(day) + amount;
        if (sumAfter > regime.cap) revert SpendValidator_CapExceeded();

        ledger.recordDay(day, amount, regime.policyVersion, paused);
        emit DaySubmitted(day, amount, sumAfter, regime.policyVersion, paused);
    }

    // ------------------------------------------------------------------
    // Account hook
    // ------------------------------------------------------------------

    /// @inheritdoc IValidator
    /// @dev `value` is prospective spend in milli-USD minor units, not wei.
    function validateTransaction(
        address,
        address,
        uint256 value
    ) external view override returns (bool) {
        if (config.spendsCurrentlyPaused()) {
            return false;
        }
        if (value > uint256(type(int256).max)) {
            return false;
        }

        int256 amount = int256(value);
        uint64 day = config.todayIndex();
        int256 cap = config.capAt(day);

        // Equality at the cap is allowed (reject only when strictly greater).
        if (windowSum(day) + amount > cap) {
            return false;
        }
        return true;
    }
}
