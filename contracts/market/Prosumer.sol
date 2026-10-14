// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {MarketManager} from "./MarketManager.sol";
import {MarketSession} from "./MarketSession.sol";
import {LockableERC1155} from "./LockableERC1155.sol";

/// @title Prosumer
/// @notice One prosumer's contract on the market: places its orders, locks its
///         collateral, holds its commitments per slot, and is settled against
///         measured energy. After BRIGHT's `EFlexibleEntity` and DEDALUS's
///         `Apartment`.
///
/// Its owner is the prosumer's smart account (decision log 2.31). The agent
/// reaches the order functions only through PolicyGate, as calls the account
/// makes. Payment and energy tokens stay in the account; the account grants this
/// contract a payment allowance, to lock collateral, and approval over its
/// energy tokens, to deliver and burn them.
///
/// Who calls what:
///
///   owner (the account)   placeBids, placeOffers, cancelOrder, modifyOrder
///   the order's session   onOfferMatched, onBidMatched, onExpired
///   the sensor            settle
///
/// Collateral, as in the source projects: a bid locks its value at the limit
/// price, which pays the seller when matched; an offer locks its value at the
/// real-time price, which guarantees delivery until the slot is settled.
contract Prosumer is ReentrancyGuard {
    struct OrderInfo {
        MarketSession session;
        MarketTypes.Side side;
        uint32 slot;
        uint64 quantity;
        uint64 matched;
        /// @dev Price per kWh the collateral was locked at: the limit price
        ///      for a bid, the real-time price for an offer.
        uint64 collateralRate;
        /// @dev Collateral still held for the order's unmatched part.
        uint256 collateral;
        uint256 tokenId;
    }

    /// @notice What the prosumer committed to in one slot, from its trades.
    struct Commitment {
        uint64 boughtWh;
        uint64 soldWh;
        uint256 paid;
        uint256 received;
        /// @dev Sellers' delivery collateral, held until settlement.
        uint256 collateral;
        bool settled;
    }

    address public immutable owner;
    MarketManager public immutable manager;
    LockableERC1155 public immutable token;

    mapping(bytes32 id => OrderInfo) internal _orders;
    mapping(uint32 slot => Commitment) internal _commitments;

    event OrderBooked(
        bytes32 indexed id,
        address indexed session,
        MarketTypes.Side side,
        uint32 indexed slot,
        uint64 quantity,
        uint64 price,
        uint256 collateral,
        uint256 tokenId
    );
    event CollateralReleased(bytes32 indexed id, uint256 amount);
    event Committed(
        uint32 indexed slot, bytes32 indexed id, MarketTypes.Side side, uint64 quantity, uint64 price, uint256 value
    );
    event Settled(
        uint32 indexed slot,
        int256 committedNetWh,
        int256 measuredNetWh,
        uint256 deviationWh,
        uint256 penalty,
        uint256 paidFromCollateral,
        uint256 paidFromBalance,
        uint256 shortfall,
        uint256 released
    );

    error Prosumer_OnlyOwner(address caller);
    error Prosumer_OnlySession(bytes32 id, address caller);
    error Prosumer_OnlySensor(address caller);
    error Prosumer_NoSession(MarketTypes.EnergyType energyType);
    error Prosumer_EmptyBatch();
    error Prosumer_BadSlot(uint16 slot, uint16 slotCount);
    error Prosumer_UnknownOrder(bytes32 id);
    error Prosumer_SlotNotOver(uint32 slot);
    error Prosumer_NothingToSettle(uint32 slot);
    error Prosumer_AlreadySettled(uint32 slot);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Prosumer_OnlyOwner(msg.sender);
        _;
    }

    constructor(address owner_, MarketManager manager_) {
        owner = owner_;
        manager = manager_;
        token = manager_.token();
    }

    // ------------------------------------------------------------------
    // Orders: the owner
    // ------------------------------------------------------------------

    /// @notice Place a batch of bids in the current session for `energyType`.
    /// @return ids One per request, in order.
    function placeBids(MarketTypes.EnergyType energyType, MarketTypes.OrderRequest[] calldata requests)
        external
        onlyOwner
        nonReentrant
        returns (bytes32[] memory ids)
    {
        return _placeBatch(energyType, MarketTypes.Side.BID, requests);
    }

    /// @notice Place a batch of offers in the current session for
    ///         `energyType`. Each offer mints its energy token to the owner.
    function placeOffers(MarketTypes.EnergyType energyType, MarketTypes.OrderRequest[] calldata requests)
        external
        onlyOwner
        nonReentrant
        returns (bytes32[] memory ids)
    {
        return _placeBatch(energyType, MarketTypes.Side.OFFER, requests);
    }

    /// @notice Withdraw an order while its session is trading.
    function cancelOrder(bytes32 id) external onlyOwner nonReentrant {
        _cancel(id);
    }

    /// @notice Replace an order with a new quantity, price or slot in the same
    ///         session and on the same side: a cancellation and a placement in
    ///         one call (decision log 2.25).
    function modifyOrder(bytes32 id, MarketTypes.OrderRequest calldata request)
        external
        onlyOwner
        nonReentrant
        returns (bytes32 newId)
    {
        OrderInfo storage info = _known(id);
        MarketSession session = info.session;
        MarketTypes.Side side = info.side;
        _cancel(id);
        newId = _place(session, session.config().energyType, side, request);
    }

    // ------------------------------------------------------------------
    // Matching: the order's session
    // ------------------------------------------------------------------

    /// @notice An offer of this prosumer was matched: deliver the energy token
    ///         to the buyer and hold the matched part's collateral until the
    ///         slot is settled.
    function onOfferMatched(bytes32 id, uint64 quantity, uint64 price, address buyerAccount) external nonReentrant {
        OrderInfo storage info = _fromSession(id);
        info.matched += quantity;

        token.safeTransferFrom(owner, buyerAccount, info.tokenId, quantity, "");

        uint256 portion = info.matched == info.quantity
            ? info.collateral
            : _min(MarketTypes.valueDown(quantity, info.collateralRate), info.collateral);
        info.collateral -= portion;

        uint256 received = MarketTypes.valueDown(quantity, price);
        Commitment storage c = _commitments[info.slot];
        c.soldWh += quantity;
        c.received += received;
        c.collateral += portion;
        emit Committed(info.slot, id, MarketTypes.Side.OFFER, quantity, price, received);
    }

    /// @notice A bid of this prosumer was matched: pay the seller at the trade
    ///         price out of the bid's collateral.
    ///
    /// The payment rounds down, so that however many partial trades a bid is
    /// matched by, they never add up to more than the collateral, which rounded
    /// up (decision log 2.42).
    function onBidMatched(bytes32 id, uint64 quantity, uint64 price, address sellerAccount) external nonReentrant {
        OrderInfo storage info = _fromSession(id);
        info.matched += quantity;

        uint256 pay = MarketTypes.valueDown(quantity, price);
        info.collateral -= pay;
        if (pay != 0) token.unlock(owner, address(this), pay, sellerAccount);

        Commitment storage c = _commitments[info.slot];
        c.boughtWh += quantity;
        c.paid += pay;
        emit Committed(info.slot, id, MarketTypes.Side.BID, quantity, price, pay);

        // Fully matched: what the limit price over-reserved comes back now.
        if (info.matched == info.quantity) _releaseCollateral(id, info);
    }

    /// @notice The order's session was finalised with this order partly or
    ///         wholly unmatched: release its collateral and burn an offer's
    ///         unmatched energy.
    function onExpired(bytes32 id, uint64 unmatched) external nonReentrant {
        OrderInfo storage info = _fromSession(id);
        _releaseCollateral(id, info);
        if (info.side == MarketTypes.Side.OFFER && unmatched != 0) {
            token.burnEnergy(owner, info.tokenId, unmatched);
        }
    }

    // ------------------------------------------------------------------
    // Settlement: the sensor
    // ------------------------------------------------------------------

    /// @notice Settle one slot against the energy the sensor measured
    ///         (thesis, steps 9 to 11; decision log 2.27).
    ///
    /// The committed net export (sold − bought) is compared with the measured
    /// net export (exported − imported). The settlement rule prices the
    /// deviation. The penalty is paid to the manager from the slot's delivery
    /// collateral first, then from the owner's unlocked balance as far as the
    /// allowance reaches; what cannot be collected is reported as a shortfall,
    /// never a revert, so a prosumer cannot block its own settlement. Any
    /// collateral left is released.
    function settle(uint32 slot, uint64 exportedWh, uint64 importedWh) external nonReentrant {
        address sensor = manager.sensorOf(address(this));
        if (sensor == address(0) || msg.sender != sensor) revert Prosumer_OnlySensor(msg.sender);
        if (block.timestamp < manager.slotStart(slot + 1)) revert Prosumer_SlotNotOver(slot);

        Commitment storage c = _commitments[slot];
        if (c.boughtWh == 0 && c.soldWh == 0) revert Prosumer_NothingToSettle(slot);
        if (c.settled) revert Prosumer_AlreadySettled(slot);
        c.settled = true;

        int256 committedNet = int256(uint256(c.soldWh)) - int256(uint256(c.boughtWh));
        int256 measuredNet = int256(uint256(exportedWh)) - int256(uint256(importedWh));
        uint256 deviation = _abs(measuredNet - committedNet);
        uint256 penalty = manager.settlementRule().penalty(manager.realTimePrice(), deviation, _abs(committedNet));

        uint256 fromCollateral = _min(penalty, c.collateral);
        uint256 released = c.collateral - fromCollateral;
        c.collateral = 0;
        if (fromCollateral != 0) token.unlock(owner, address(this), fromCollateral, address(manager));
        if (released != 0) token.unlock(owner, address(this), released, address(0));

        uint256 shortfall = penalty - fromCollateral;
        uint256 fromBalance;
        if (shortfall != 0) {
            fromBalance = _min(
                shortfall, _min(token.unlockedBalanceOf(owner), token.paymentAllowance(owner, address(this)))
            );
            if (fromBalance != 0) {
                token.lock(owner, fromBalance, address(this));
                token.unlock(owner, address(this), fromBalance, address(manager));
            }
            shortfall -= fromBalance;
        }

        emit Settled(
            slot, committedNet, measuredNet, deviation, penalty, fromCollateral, fromBalance, shortfall, released
        );
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function orderInfo(bytes32 id) external view returns (OrderInfo memory) {
        return _orders[id];
    }

    function commitmentOf(uint32 slot) external view returns (Commitment memory) {
        return _commitments[slot];
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _placeBatch(
        MarketTypes.EnergyType energyType,
        MarketTypes.Side side,
        MarketTypes.OrderRequest[] calldata requests
    ) private returns (bytes32[] memory ids) {
        MarketSession session = manager.currentSession(energyType);
        if (address(session) == address(0)) revert Prosumer_NoSession(energyType);
        if (requests.length == 0) revert Prosumer_EmptyBatch();

        ids = new bytes32[](requests.length);
        for (uint256 i = 0; i < requests.length; ++i) {
            ids[i] = _place(session, energyType, side, requests[i]);
        }
    }

    function _place(
        MarketSession session,
        MarketTypes.EnergyType energyType,
        MarketTypes.Side side,
        MarketTypes.OrderRequest calldata request
    ) private returns (bytes32 id) {
        MarketTypes.SessionConfig memory config = session.config();
        if (request.slot >= config.slotCount) revert Prosumer_BadSlot(request.slot, config.slotCount);
        uint32 slot = config.firstSlot + request.slot;

        uint64 rate;
        uint256 tokenId;
        if (side == MarketTypes.Side.OFFER) {
            rate = manager.realTimePrice();
            tokenId = token.mintEnergy(owner, uint40(manager.slotStart(slot)), energyType, request.quantity);
        } else {
            rate = request.price;
        }
        uint256 collateral = MarketTypes.value(request.quantity, rate);
        token.lock(owner, collateral, address(this));

        id = session.place(side, request, tokenId);
        _orders[id] = OrderInfo({
            session: session,
            side: side,
            slot: slot,
            quantity: request.quantity,
            matched: 0,
            collateralRate: rate,
            collateral: collateral,
            tokenId: tokenId
        });
        emit OrderBooked(id, address(session), side, slot, request.quantity, request.price, collateral, tokenId);
    }

    function _cancel(bytes32 id) private {
        OrderInfo storage info = _known(id);
        info.session.cancel(id);
        uint64 unmatched = info.quantity - info.matched;
        _releaseCollateral(id, info);
        if (info.side == MarketTypes.Side.OFFER && unmatched != 0) {
            token.burnEnergy(owner, info.tokenId, unmatched);
        }
    }

    function _releaseCollateral(bytes32 id, OrderInfo storage info) private {
        uint256 amount = info.collateral;
        if (amount == 0) return;
        info.collateral = 0;
        token.unlock(owner, address(this), amount, address(0));
        emit CollateralReleased(id, amount);
    }

    function _known(bytes32 id) private view returns (OrderInfo storage info) {
        info = _orders[id];
        if (address(info.session) == address(0)) revert Prosumer_UnknownOrder(id);
    }

    function _fromSession(bytes32 id) private view returns (OrderInfo storage info) {
        info = _orders[id];
        if (address(info.session) == address(0) || msg.sender != address(info.session)) {
            revert Prosumer_OnlySession(id, msg.sender);
        }
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
