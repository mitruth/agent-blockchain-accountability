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
/// Two jobs:
///
///   1. Settle days. Daily spend is computed from meter readings and oracle
///      prices -- never reported by the agent -- and written to the ledger,
///      whatever it costs (D7.1, D7.5).
///
///   2. Decide whether the agent may act. The agent is authorised only while
///      the rolling window of settled spend is within the cap, settlement is
///      up to date, and no pause is in force. SmartAccount asks this module
///      before every transfer the agent attempts.
///
/// Enforcement therefore acts on what the agent may do next, not on the record
/// of what happened. The previous design refused to record an over-cap day,
/// which left a hole counted as zero and handed the agent more headroom after a
/// breach.
///
/// A swap of this module must not reset the rolling window: the ledger is
/// deployed once and this contract only recomputes sums from raw days. Write
/// authority onto the ledger is the owner-controlled allowlist on SpendLedger,
/// not install status on the account.
contract SpendValidator is IValidator {
    uint256 public constant MODULE_TYPE_VALIDATOR = 1;

    /// @notice How far settlement may fall behind before the agent loses
    ///         authority. A day must end, its prices and readings be signed,
    ///         and a relay land; two days allows for that. Past it, the window
    ///         no longer describes what the agent is spending, so the failure
    ///         is closed (D7.11).
    uint64 public constant MAX_SETTLEMENT_LAG_DAYS = 2;

    PolicyConfig public immutable config;
    SpendLedger public immutable ledger;

    /// @notice The account this module serves. Bound at construction and never
    ///         mutable: an unpermissioned onInstall lets any stranger claim this
    ///         slot, and onUninstall then reverts for the real account, pinning
    ///         the module in place permanently.
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

    /// @notice Why the agent may or may not act; the first failing reason wins.
    enum Authorization {
        Authorized,
        NoSessionKey,
        AgentPaused,
        SettlementStale,
        OverCap
    }

    /// @notice A day's measured spend, recorded whatever its value.
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

    error SpendValidator_OnlySmartAccount();
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

    // ------------------------------------------------------------------
    // Module hooks
    // ------------------------------------------------------------------

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
    ///         Bounded by windowDays from config -- never by agent-grown storage.
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
    /// show less spend than happened (D7.5). What changes is the agent's
    /// authorisation, which every later action checks.
    ///
    /// A pause does not alter the recorded spend. It restricts the agent's
    /// actions; metered energy was consumed regardless (D7.6).
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
        ledger.recordDay(day, spend, regime.policyVersion);

        int256 sum = windowSum(day);
        emit DaySettled(day, spend, sum, regime.cap, sum <= regime.cap, regime.policyVersion, msg.sender);
    }

    // ------------------------------------------------------------------
    // Authorisation: what the agent may do next (D7.5)
    // ------------------------------------------------------------------

    /// @notice The last day enforcement can see, or genesisDay - 1 before any
    ///         settlement. Signed so a genesis day of 0 does not underflow.
    function lastSettledDay() public view returns (int256) {
        if (ledger.hasAnyRecord()) return int256(uint256(ledger.lastRecordedDay()));
        return int256(uint256(genesisDay)) - 1;
    }

    /// @notice Whether the agent may act right now, and if not, why.
    ///
    ///   NoSessionKey     the owner revoked the agent
    ///   AgentPaused      the guardian paused the agent and the pause is live
    ///   SettlementStale  the last settled day is more than
    ///                    MAX_SETTLEMENT_LAG_DAYS before today
    ///   OverCap          the rolling window ending at the last settled day
    ///                    exceeds the cap in force today
    ///
    /// Any failing condition withdraws authority; the order only decides which
    /// reason is reported. The cap is read for today rather than for the last
    /// settled day, so an owner lowering applies to the agent at once (D4.1).
    function authorization() public view returns (Authorization) {
        if (config.sessionKey() == address(0)) return Authorization.NoSessionKey;
        if (config.agentCurrentlyPaused()) return Authorization.AgentPaused;

        uint64 today = config.todayIndex();
        if (int256(uint256(today)) > lastSettledDay() + int256(uint256(MAX_SETTLEMENT_LAG_DAYS))) {
            return Authorization.SettlementStale;
        }

        if (ledger.hasAnyRecord()) {
            if (windowSum(ledger.lastRecordedDay()) > config.capAt(today)) return Authorization.OverCap;
        }

        return Authorization.Authorized;
    }

    function isAgentAuthorized() public view returns (bool) {
        return authorization() == Authorization.Authorized;
    }

    // ------------------------------------------------------------------
    // Account hook
    // ------------------------------------------------------------------

    /// @inheritdoc IValidator
    ///
    /// @dev The owner is the principal and is not constrained here; a spend
    ///      pause still stops the owner at the account. The agent may transfer
    ///      only while authorised. Anyone else is refused.
    ///
    ///      `value` is deliberately not treated as spend. Spend is what the
    ///      meter measured; a transfer amount in wei is a different quantity in
    ///      a different unit (F6, D7.5).
    function validateTransaction(
        address from,
        address,
        uint256
    ) external view override returns (bool) {
        if (from == config.owner()) return true;
        if (from != config.sessionKey()) return false;
        return isAgentAuthorized();
    }
}
