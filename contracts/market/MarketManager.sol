// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {LockableERC1155} from "./LockableERC1155.sol";
import {MarketSession} from "./MarketSession.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {ISettlementRule} from "./ClassicSettlement.sol";

/// @notice What the manager needs from a prosumer contract at registration.
interface IProsumerOwner {
    function owner() external view returns (address);
}

/// @title MarketManager
/// @notice Operates the market: registers prosumers and their sensors,
///         registers the matching service, sets the real-time price, opens
///         sessions. After BRIGHT's `MarketsManager` and DEDALUS's `Building`
///         in its manager role (decision log 2.22).
///
/// Every write is the operator's. The operator stands for the market operator
/// of the thesis: a DSO or an aggregator, trusted for what it registers.
///
/// Penalties from settlement are paid to this contract.
contract MarketManager is ERC1155Holder {
    /// @notice Upper bound on a session's slots: two days of half-hours.
    uint16 public constant MAX_SLOTS_PER_SESSION = 96;

    struct ProsumerEntry {
        bool registered;
        address account;
        address sensor;
    }

    address public immutable operator;
    LockableERC1155 public immutable token;

    /// @notice Slot length of the whole market, the spec's Δ (amendment A2).
    ///         Slot n starts at n × slotSeconds.
    uint32 public immutable slotSeconds;

    ISettlementRule public immutable settlementRule;

    /// @notice Price per kWh for offer collateral and for settlement penalties.
    uint64 public realTimePrice;

    /// @notice The off-chain matching service, the only caller of
    ///         `registerTrades` (decision log 2.26).
    address public matcher;

    mapping(address prosumer => ProsumerEntry) public prosumers;
    mapping(MarketTypes.EnergyType => MarketSession) public currentSession;
    mapping(address => bool) public isSession;

    event MatcherSet(address indexed matcher);
    event RealTimePriceSet(uint64 pricePerKWh);
    event ProsumerRegistered(address indexed prosumer, address indexed account, address sensor);
    event ProsumerDeregistered(address indexed prosumer);
    event SensorSet(address indexed prosumer, address sensor);
    event SessionOpened(
        address indexed session,
        MarketTypes.EnergyType indexed energyType,
        uint32 firstSlot,
        uint16 slotCount,
        uint40 closesAt
    );

    error MarketManager_OnlyOperator(address caller);
    error MarketManager_ZeroSlotLength();
    error MarketManager_NoOwner(address prosumer);
    error MarketManager_AlreadyRegistered(address prosumer);
    error MarketManager_NotRegistered(address prosumer);
    error MarketManager_BadSlotCount(uint16 slotCount);
    error MarketManager_ClosesInThePast(uint40 closesAt);
    error MarketManager_ClosesAfterDeliveryStarts(uint40 closesAt, uint256 firstSlotStart);

    modifier onlyOperator() {
        if (msg.sender != operator) revert MarketManager_OnlyOperator(msg.sender);
        _;
    }

    constructor(LockableERC1155 token_, uint32 slotSeconds_, uint64 realTimePrice_, ISettlementRule settlementRule_) {
        if (slotSeconds_ == 0) revert MarketManager_ZeroSlotLength();
        operator = msg.sender;
        token = token_;
        slotSeconds = slotSeconds_;
        realTimePrice = realTimePrice_;
        settlementRule = settlementRule_;
        emit RealTimePriceSet(realTimePrice_);
    }

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Admit a prosumer contract, with the sensor that reports its
    ///         measured energy. The contract becomes an energy minter.
    ///
    /// The operator vouches for the contract's code: registration is where a
    /// prosumer contract that is not genuine would be kept out.
    function registerProsumer(address prosumer, address sensor) external onlyOperator {
        if (prosumers[prosumer].registered) revert MarketManager_AlreadyRegistered(prosumer);
        address account = IProsumerOwner(prosumer).owner();
        if (account == address(0)) revert MarketManager_NoOwner(prosumer);

        prosumers[prosumer] = ProsumerEntry({registered: true, account: account, sensor: sensor});
        token.setMinter(prosumer, true);
        emit ProsumerRegistered(prosumer, account, sensor);
    }

    function deregisterProsumer(address prosumer) external onlyOperator {
        if (!prosumers[prosumer].registered) revert MarketManager_NotRegistered(prosumer);
        prosumers[prosumer].registered = false;
        token.setMinter(prosumer, false);
        emit ProsumerDeregistered(prosumer);
    }

    function setSensor(address prosumer, address sensor) external onlyOperator {
        if (!prosumers[prosumer].registered) revert MarketManager_NotRegistered(prosumer);
        prosumers[prosumer].sensor = sensor;
        emit SensorSet(prosumer, sensor);
    }

    function setMatcher(address matcher_) external onlyOperator {
        matcher = matcher_;
        emit MatcherSet(matcher_);
    }

    function setRealTimePrice(uint64 pricePerKWh) external onlyOperator {
        realTimePrice = pricePerKWh;
        emit RealTimePriceSet(pricePerKWh);
    }

    /// @notice Open a session for one energy type. It becomes the current
    ///         session for that type; an earlier one carries on to matching,
    ///         settlement and expiry on its own.
    function openSession(MarketTypes.SessionConfig calldata config) external onlyOperator returns (MarketSession session) {
        if (config.slotCount == 0 || config.slotCount > MAX_SLOTS_PER_SESSION) {
            revert MarketManager_BadSlotCount(config.slotCount);
        }
        if (config.closesAt <= block.timestamp) revert MarketManager_ClosesInThePast(config.closesAt);
        uint256 firstStart = slotStart(config.firstSlot);
        if (config.closesAt > firstStart) revert MarketManager_ClosesAfterDeliveryStarts(config.closesAt, firstStart);

        session = new MarketSession(config);
        isSession[address(session)] = true;
        currentSession[config.energyType] = session;
        emit SessionOpened(address(session), config.energyType, config.firstSlot, config.slotCount, config.closesAt);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function slotStart(uint32 slot) public view returns (uint256) {
        return uint256(slot) * slotSeconds;
    }

    function isRegistered(address prosumer) external view returns (bool) {
        return prosumers[prosumer].registered;
    }

    function accountOf(address prosumer) external view returns (address) {
        return prosumers[prosumer].account;
    }

    function sensorOf(address prosumer) external view returns (address) {
        return prosumers[prosumer].sensor;
    }
}
