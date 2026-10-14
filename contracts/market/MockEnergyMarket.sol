// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Side} from "../gate/GateTypes.sol";

/// @title MockEnergyMarket
/// @notice A per-slot order book for a peer-to-peer energy market, as far as
///         the enforcement layer needs one. Step 2 of the v0.1 build.
///
/// Time is cut into delivery slots of `slotSeconds`, slot 0 starting at
/// `genesis`. Trading in a slot closes `gateLeadSeconds` before the slot
/// starts: from then on no order for that slot can be placed, cancelled,
/// modified or filled, and whatever is unfilled has expired.
///
/// Fills come from `operator`, which stands in for the market's clearing
/// engine. How orders are matched is a market rule and out of scope (spec
/// section 1); what matters here is that orders fill partly or fully before gate
/// closure, at a price inside their limit. Test code and the simulation drive
/// fills through this one function.
///
/// The order's owner is whoever placed it, which in this system is always the
/// prosumer account.
contract MockEnergyMarket {
    struct MarketOrder {
        address owner;
        Side side;
        uint32 slot;
        bool cancelled;
        uint64 qtyWh;
        uint64 price;
        uint64 filledWh;
    }

    /// @notice Start of slot 0, Unix seconds.
    uint64 public immutable genesis;

    /// @notice Slot length, the spec's Δ. A parameter (spec amendment A2).
    uint32 public immutable slotSeconds;

    /// @notice How long before a slot starts its trading closes.
    uint32 public immutable gateLeadSeconds;

    /// @notice The clearing engine's stand-in. The only address that fills.
    address public immutable operator;

    uint256 public orderCount;

    mapping(bytes32 orderId => MarketOrder) private _orders;

    event OrderPlaced(
        bytes32 indexed orderId, address indexed owner, Side side, uint32 indexed slot, uint64 qtyWh, uint64 price
    );
    event OrderCancelled(bytes32 indexed orderId, uint64 unfilledWh);
    event OrderFilled(bytes32 indexed orderId, uint64 qtyWh, uint64 clearingPrice);

    error MockEnergyMarket_ZeroSlotLength();
    error MockEnergyMarket_GateClosed(uint32 slot, uint64 gateTime);
    error MockEnergyMarket_ZeroQuantity();
    error MockEnergyMarket_ZeroPrice();
    error MockEnergyMarket_UnknownOrder(bytes32 orderId);
    error MockEnergyMarket_NotOwner(bytes32 orderId, address caller);
    error MockEnergyMarket_NotOpen(bytes32 orderId);
    error MockEnergyMarket_NotOperator(address caller);
    error MockEnergyMarket_OverFill(bytes32 orderId, uint64 remainingWh);
    error MockEnergyMarket_PriceOutsideLimit(bytes32 orderId, uint64 clearingPrice, uint64 limit);

    constructor(uint64 genesis_, uint32 slotSeconds_, uint32 gateLeadSeconds_, address operator_) {
        if (slotSeconds_ == 0) revert MockEnergyMarket_ZeroSlotLength();
        genesis = genesis_;
        slotSeconds = slotSeconds_;
        gateLeadSeconds = gateLeadSeconds_;
        operator = operator_;
    }

    // ------------------------------------------------------------------
    // Time
    // ------------------------------------------------------------------

    function slotStart(uint32 slot) public view returns (uint64) {
        return genesis + uint64(slot) * slotSeconds;
    }

    /// @notice When trading in `slot` closes.
    function gateTime(uint32 slot) public view returns (uint64) {
        uint64 start = slotStart(slot);
        return start > gateLeadSeconds ? start - gateLeadSeconds : 0;
    }

    /// @notice The slot being delivered now; slot 0 before genesis.
    function currentSlot() public view returns (uint32) {
        if (block.timestamp < genesis) return 0;
        return uint32((block.timestamp - genesis) / slotSeconds);
    }

    // ------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------

    /// @param price Limit price, settlement-token units per kWh.
    function placeOrder(Side side, uint32 slot, uint64 qtyWh, uint64 price) external returns (bytes32 orderId) {
        return _place(msg.sender, side, slot, qtyWh, price);
    }

    /// @notice Withdraw the unfilled part of an order. What has filled stays
    ///         filled.
    function cancelOrder(bytes32 orderId) external {
        _cancel(msg.sender, orderId);
    }

    /// @notice Replace an order: the unfilled part of the old one is cancelled
    ///         and a new order is placed, in one call. The side does not change.
    /// @return newOrderId The id of the new order.
    function modifyOrder(bytes32 orderId, uint32 slot, uint64 qtyWh, uint64 price)
        external
        returns (bytes32 newOrderId)
    {
        Side side = _orders[orderId].side;
        _cancel(msg.sender, orderId);
        return _place(msg.sender, side, slot, qtyWh, price);
    }

    /// @notice The clearing engine fills part or all of an open order.
    function fill(bytes32 orderId, uint64 qtyWh, uint64 clearingPrice) external {
        if (msg.sender != operator) revert MockEnergyMarket_NotOperator(msg.sender);
        if (qtyWh == 0) revert MockEnergyMarket_ZeroQuantity();

        MarketOrder storage order = _known(orderId);
        if (!isOpen(orderId)) revert MockEnergyMarket_NotOpen(orderId);

        uint64 remaining = order.qtyWh - order.filledWh;
        if (qtyWh > remaining) revert MockEnergyMarket_OverFill(orderId, remaining);

        bool insideLimit = order.side == Side.BUY ? clearingPrice <= order.price : clearingPrice >= order.price;
        if (!insideLimit) revert MockEnergyMarket_PriceOutsideLimit(orderId, clearingPrice, order.price);

        order.filledWh += qtyWh;
        emit OrderFilled(orderId, qtyWh, clearingPrice);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function orderOf(bytes32 orderId) external view returns (MarketOrder memory) {
        return _orders[orderId];
    }

    /// @notice Not cancelled, not fully filled, and its slot's gate still open.
    function isOpen(bytes32 orderId) public view returns (bool) {
        MarketOrder storage order = _orders[orderId];
        return order.owner != address(0) && !order.cancelled && order.filledWh < order.qtyWh
            && block.timestamp < gateTime(order.slot);
    }

    /// @notice What can still fill: zero unless the order is open.
    function remainingOf(bytes32 orderId) external view returns (uint64) {
        if (!isOpen(orderId)) return 0;
        MarketOrder storage order = _orders[orderId];
        return order.qtyWh - order.filledWh;
    }

    function filledOf(bytes32 orderId) external view returns (uint64) {
        return _orders[orderId].filledWh;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _place(address owner, Side side, uint32 slot, uint64 qtyWh, uint64 price)
        private
        returns (bytes32 orderId)
    {
        if (qtyWh == 0) revert MockEnergyMarket_ZeroQuantity();
        if (price == 0) revert MockEnergyMarket_ZeroPrice();
        uint64 closes = gateTime(slot);
        if (block.timestamp >= closes) revert MockEnergyMarket_GateClosed(slot, closes);

        orderId = bytes32(++orderCount);
        _orders[orderId] =
            MarketOrder({owner: owner, side: side, slot: slot, cancelled: false, qtyWh: qtyWh, price: price, filledWh: 0});
        emit OrderPlaced(orderId, owner, side, slot, qtyWh, price);
    }

    function _cancel(address caller, bytes32 orderId) private {
        MarketOrder storage order = _known(orderId);
        if (order.owner != caller) revert MockEnergyMarket_NotOwner(orderId, caller);
        if (!isOpen(orderId)) revert MockEnergyMarket_NotOpen(orderId);

        order.cancelled = true;
        emit OrderCancelled(orderId, order.qtyWh - order.filledWh);
    }

    function _known(bytes32 orderId) private view returns (MarketOrder storage order) {
        order = _orders[orderId];
        if (order.owner == address(0)) revert MockEnergyMarket_UnknownOrder(orderId);
    }
}
