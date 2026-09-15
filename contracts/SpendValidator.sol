// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IModule} from "./interfaces/IModule.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {PolicyConfig} from "./PolicyConfig.sol";
import {SpendLedger} from "./SpendLedger.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {MeterReadings} from "./MeterReadings.sol";
import {SpendMath} from "./SpendMath.sol";

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

    /// @notice The first day this deployment settles. Settlement then proceeds
    ///         strictly one day at a time (D7.8). Fixed at construction so a
    ///         stranger cannot open the ledger at a later day and strand the
    ///         days before it. A replacement validator continues from the
    ///         ledger's last recorded day and never consults this.
    uint64 public immutable genesisDay;

    /// @notice One day of meter readings, as the meter signed them.
    struct DayReadings {
        uint64 dayIndex;
        uint64[48] importMWh;
        uint64[48] exportMWh;
        bytes meterSignature;
    }

    /// @notice One day of prices, as the oracle published them.
    struct DayPrices {
        int64[48] importPrices;
        int64[48] exportPrices;
    }

    /// @notice A day's measured spend, recorded whatever its value (D7.5).
    event DaySettled(
        uint64 indexed dayIndex,
        int256 spendMilliUsd,
        int256 windowSum,
        int256 cap,
        bool compliant,
        uint256 policyVersion,
        address indexed relayer
    );

    /// @notice The readings behind a settled day. With the oracle's
    ///         PricesPublished event, enough to recompute the day's spend from
    ///         the log alone.
    event MeterReadingsRecorded(uint64 indexed dayIndex, uint64[48] importMWh, uint64[48] exportMWh);

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
    error SpendValidator_DayNotEnded(uint64 dayIndex, uint64 today);
    error SpendValidator_NotNextDay(uint64 dayIndex, uint64 expected);
    error SpendValidator_MeterNotRegistered();
    error SpendValidator_OracleNotRegistered();
    error SpendValidator_NotSignedByMeter(address signer);
    error SpendValidator_ImportAndExportOverlap(uint256 halfHour);
    error SpendValidator_PricesNotPublished(uint64 dayIndex);
    error SpendValidator_PricesMismatch(uint64 dayIndex);

    constructor(PolicyConfig config_, SpendLedger ledger_, address smartAccount_, uint64 genesisDay_) {
        config = config_;
        ledger = ledger_;
        smartAccount = smartAccount_;
        genesisDay = genesisDay_;
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
    // Settlement: spend computed from measured inputs (D7.1)
    // ------------------------------------------------------------------

    /// @notice Settle one day: authenticate the meter's readings, check the
    ///         prices against the oracle, compute the day's spend, record it.
    ///
    /// Anyone may call this. Authenticity comes from the meter's signature and
    /// the oracle's commitment, not from the sender, so a day the agent would
    /// rather not report can be settled by the owner, the guardian, or anyone
    /// else holding the signed readings (D7.3).
    ///
    /// The day is recorded whatever it costs. An over-cap day is a fact about
    /// energy already consumed; refusing to record it would make the ledger
    /// show less spend than happened (D7.5).
    function settleDay(DayReadings calldata readings, DayPrices calldata prices) external {
        uint64 day = readings.dayIndex;

        _checkSequence(day);
        _checkPrices(day, prices);
        _checkMeter(readings);

        int256 spend = SpendMath.dailySpendMilliUsd(
            readings.importMWh,
            readings.exportMWh,
            prices.importPrices,
            prices.exportPrices
        );

        _record(day, spend);
        emit MeterReadingsRecorded(day, readings.importMWh, readings.exportMWh);
    }

    /// @notice The next day that may be settled.
    function nextSettlementDay() public view returns (uint64) {
        return ledger.hasAnyRecord() ? ledger.lastRecordedDay() + 1 : genesisDay;
    }

    /// @dev Strictly past, strictly consecutive (D7.8). Without ordering, a
    ///      stranger with two signed days could settle the later first and make
    ///      the earlier one permanently unrecordable -- counted as zero.
    function _checkSequence(uint64 day) internal view {
        uint64 today = config.todayIndex();
        if (day >= today) revert SpendValidator_DayNotEnded(day, today);

        uint64 expected = nextSettlementDay();
        if (day != expected) revert SpendValidator_NotNextDay(day, expected);
    }

    function _checkPrices(uint64 day, DayPrices calldata prices) internal view {
        address oracleAddress = config.priceOracle();
        if (oracleAddress == address(0)) revert SpendValidator_OracleNotRegistered();

        PriceOracle oracle = PriceOracle(oracleAddress);
        if (!oracle.isPublished(day)) revert SpendValidator_PricesNotPublished(day);
        if (!oracle.verifyPrices(day, prices.importPrices, prices.exportPrices)) {
            revert SpendValidator_PricesMismatch(day);
        }
    }

    function _checkMeter(DayReadings calldata readings) internal view {
        address meter = config.meter();
        if (meter == address(0)) revert SpendValidator_MeterNotRegistered();

        (bool exclusive, uint256 firstBad) =
            MeterReadings.importAndExportAreExclusive(readings.importMWh, readings.exportMWh);
        if (!exclusive) revert SpendValidator_ImportAndExportOverlap(firstBad);

        bytes32 hash = MeterReadings.digest(
            block.chainid,
            address(ledger),
            readings.dayIndex,
            readings.importMWh,
            readings.exportMWh
        );
        address signer = MeterReadings.recover(hash, readings.meterSignature);
        if (signer != meter) revert SpendValidator_NotSignedByMeter(signer);
    }

    function _record(uint64 day, int256 spend) internal {
        PolicyConfig.CapEpoch memory regime = config.regimeAt(day);

        // The fourth argument is the ledger's pause flag. A pause no longer
        // touches accounting (D7.6); stage A4 replaces the field.
        ledger.recordDay(day, spend, regime.policyVersion, false);

        int256 sum = windowSum(day);
        emit DaySettled(day, spend, sum, regime.cap, sum <= regime.cap, regime.policyVersion, msg.sender);
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
