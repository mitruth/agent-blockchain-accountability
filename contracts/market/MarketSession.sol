// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {MarketManager} from "./MarketManager.sol";
import {Prosumer} from "./Prosumer.sol";

/// @title MarketSession
/// @notice One session of the market: the orders for a run of delivery slots,
///         and the trades matched from them. After BRIGHT's
///         `AssetMarketSession` and DEDALUS's `MarketSession`.
///
/// Life of a session:
///
///   trading     until `closesAt`: registered prosumer contracts place and
///               cancel orders
///   matching    after `closesAt`: the matcher reads the orders, matches them
///               off chain and registers the trades
///   finalised   the matcher (or the operator) declares matching done. Every
///               order with an unmatched remainder has expired; anyone may
///               then release each one with `expire`
///
/// A trade names only the two orders, a quantity and a price. Who buys and who
/// sells, the slot and the energy token are read from the stored orders: the
/// matcher cannot direct a payment or a token anywhere else (decision log
/// 2.29). A trade must respect both limit prices, and an account cannot trade
/// with itself; neither source project checked either.
contract MarketSession is ReentrancyGuard {
    /// @notice Upper bound on the orders of one session.
    uint256 public constant MAX_ORDERS = 2048;

    MarketManager public immutable manager;

    MarketTypes.SessionConfig internal _config;

    bool public finalised;
    uint256 public orderCount;

    mapping(bytes32 id => MarketTypes.Order) internal _orders;
    bytes32[] internal _bidIds;
    bytes32[] internal _offerIds;

    event OrderPlaced(
        bytes32 indexed id,
        address indexed prosumer,
        MarketTypes.Side side,
        uint32 indexed slot,
        uint64 quantity,
        uint64 price,
        uint256 tokenId
    );
    event OrderCancelled(bytes32 indexed id);
    event TradeRegistered(
        bytes32 indexed bidId,
        bytes32 indexed offerId,
        uint32 indexed slot,
        uint64 quantity,
        uint64 price,
        address buyer,
        address seller
    );
    event SessionFinalised();
    event OrderExpired(bytes32 indexed id, uint64 unmatched);

    error MarketSession_NotRegistered(address caller);
    error MarketSession_Closed(uint40 closesAt);
    error MarketSession_NotClosed(uint40 closesAt);
    error MarketSession_AlreadyFinalised();
    error MarketSession_NotFinalised();
    error MarketSession_BadSlot(uint16 slot, uint16 slotCount);
    error MarketSession_ZeroQuantity();
    error MarketSession_ZeroPrice();
    error MarketSession_BadToken(MarketTypes.Side side, uint256 tokenId);
    error MarketSession_TooManyOrders();
    error MarketSession_NotYourOrder(bytes32 id, address caller);
    error MarketSession_NotOpen(bytes32 id);
    error MarketSession_OnlyMatcher(address caller);
    error MarketSession_BadTrade(bytes32 bidId, bytes32 offerId, string reason);
    error MarketSession_NothingToExpire(bytes32 id);

    constructor(MarketTypes.SessionConfig memory config_) {
        manager = MarketManager(msg.sender);
        _config = config_;
    }

    // ------------------------------------------------------------------
    // Trading: registered prosumer contracts
    // ------------------------------------------------------------------

    /// @notice Place one order. Called by the prosumer contract once per order
    ///         of a batch, after it has locked the collateral and, for an
    ///         offer, minted the energy token.
    /// @return id Unique across sessions: the session's address is part of it.
    function place(MarketTypes.Side side, MarketTypes.OrderRequest calldata request, uint256 tokenId)
        external
        nonReentrant
        returns (bytes32 id)
    {
        if (!manager.isRegistered(msg.sender)) revert MarketSession_NotRegistered(msg.sender);
        if (block.timestamp >= _config.closesAt) revert MarketSession_Closed(_config.closesAt);
        if (request.slot >= _config.slotCount) revert MarketSession_BadSlot(request.slot, _config.slotCount);
        if (request.quantity == 0) revert MarketSession_ZeroQuantity();
        if (request.price == 0) revert MarketSession_ZeroPrice();
        if ((side == MarketTypes.Side.OFFER) != (tokenId != 0)) revert MarketSession_BadToken(side, tokenId);
        if (orderCount >= MAX_ORDERS) revert MarketSession_TooManyOrders();

        id = keccak256(abi.encode(address(this), ++orderCount));
        uint32 slot = _config.firstSlot + request.slot;
        _orders[id] = MarketTypes.Order({
            id: id,
            side: side,
            status: MarketTypes.OrderStatus.OPEN,
            prosumer: msg.sender,
            account: manager.accountOf(msg.sender),
            slot: slot,
            quantity: request.quantity,
            price: request.price,
            matched: 0,
            tokenId: tokenId
        });
        if (side == MarketTypes.Side.BID) {
            _bidIds.push(id);
        } else {
            _offerIds.push(id);
        }
        emit OrderPlaced(id, msg.sender, side, slot, request.quantity, request.price, tokenId);
    }

    /// @notice Withdraw an order before the session closes (decision log
    ///         2.25). The prosumer contract releases its collateral.
    function cancel(bytes32 id) external nonReentrant {
        MarketTypes.Order storage order = _orders[id];
        if (order.prosumer != msg.sender) revert MarketSession_NotYourOrder(id, msg.sender);
        if (order.status != MarketTypes.OrderStatus.OPEN) revert MarketSession_NotOpen(id);
        if (block.timestamp >= _config.closesAt) revert MarketSession_Closed(_config.closesAt);

        order.status = MarketTypes.OrderStatus.CANCELLED;
        emit OrderCancelled(id);
    }

    // ------------------------------------------------------------------
    // Matching: the matcher
    // ------------------------------------------------------------------

    /// @notice Register trades matched off chain (thesis, step 8).
    function registerTrades(MarketTypes.Trade[] calldata trades) external nonReentrant {
        if (msg.sender != manager.matcher()) revert MarketSession_OnlyMatcher(msg.sender);
        if (block.timestamp < _config.closesAt) revert MarketSession_NotClosed(_config.closesAt);
        if (finalised) revert MarketSession_AlreadyFinalised();

        for (uint256 i = 0; i < trades.length; ++i) {
            _registerTrade(trades[i]);
        }
    }

    /// @notice Declare matching done. Every unmatched remainder has expired.
    ///         The matcher, or the operator if the matcher never does.
    function finalise() external {
        if (msg.sender != manager.matcher() && msg.sender != manager.operator()) {
            revert MarketSession_OnlyMatcher(msg.sender);
        }
        if (block.timestamp < _config.closesAt) revert MarketSession_NotClosed(_config.closesAt);
        if (finalised) revert MarketSession_AlreadyFinalised();

        finalised = true;
        emit SessionFinalised();
    }

    /// @notice Release one expired order: its collateral comes back, an
    ///         offer's unmatched energy tokens are burned. Anyone may call it.
    ///
    /// One order per call, rather than the source's loop over every order at
    /// the end of the session: the cost of a call does not grow with the book
    /// (decision log 2.44).
    function expire(bytes32 id) external nonReentrant {
        if (!finalised) revert MarketSession_NotFinalised();
        MarketTypes.Order storage order = _orders[id];
        if (order.status != MarketTypes.OrderStatus.OPEN || order.matched == order.quantity) {
            revert MarketSession_NothingToExpire(id);
        }

        uint64 unmatched = order.quantity - order.matched;
        order.status = MarketTypes.OrderStatus.EXPIRED;
        Prosumer(order.prosumer).onExpired(id, unmatched);
        emit OrderExpired(id, unmatched);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function config() external view returns (MarketTypes.SessionConfig memory) {
        return _config;
    }

    function orderOf(bytes32 id) external view returns (MarketTypes.Order memory) {
        return _orders[id];
    }

    /// @notice The bids, for the matcher.
    function bidIds() external view returns (bytes32[] memory) {
        return _bidIds;
    }

    /// @notice The offers, for the matcher.
    function offerIds() external view returns (bytes32[] memory) {
        return _offerIds;
    }

    function isTrading() external view returns (bool) {
        return block.timestamp < _config.closesAt;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _registerTrade(MarketTypes.Trade calldata trade) private {
        MarketTypes.Order storage bid = _orders[trade.bidId];
        MarketTypes.Order storage offer = _orders[trade.offerId];

        if (bid.side != MarketTypes.Side.BID || bid.status != MarketTypes.OrderStatus.OPEN) {
            revert MarketSession_BadTrade(trade.bidId, trade.offerId, "bid not open");
        }
        if (offer.side != MarketTypes.Side.OFFER || offer.status != MarketTypes.OrderStatus.OPEN) {
            revert MarketSession_BadTrade(trade.bidId, trade.offerId, "offer not open");
        }
        if (bid.slot != offer.slot) revert MarketSession_BadTrade(trade.bidId, trade.offerId, "different slots");
        if (trade.quantity == 0) revert MarketSession_BadTrade(trade.bidId, trade.offerId, "zero quantity");
        if (bid.matched + trade.quantity > bid.quantity) {
            revert MarketSession_BadTrade(trade.bidId, trade.offerId, "bid over-matched");
        }
        if (offer.matched + trade.quantity > offer.quantity) {
            revert MarketSession_BadTrade(trade.bidId, trade.offerId, "offer over-matched");
        }
        if (trade.price > bid.price || trade.price < offer.price) {
            revert MarketSession_BadTrade(trade.bidId, trade.offerId, "price outside limits");
        }
        if (bid.account == offer.account) revert MarketSession_BadTrade(trade.bidId, trade.offerId, "self-trade");

        bid.matched += trade.quantity;
        offer.matched += trade.quantity;

        // The seller's energy token moves to the buyer, then the buyer pays.
        Prosumer(offer.prosumer).onOfferMatched(trade.offerId, trade.quantity, trade.price, bid.account);
        Prosumer(bid.prosumer).onBidMatched(trade.bidId, trade.quantity, trade.price, offer.account);

        emit TradeRegistered(
            trade.bidId, trade.offerId, bid.slot, trade.quantity, trade.price, bid.account, offer.account
        );
    }
}
