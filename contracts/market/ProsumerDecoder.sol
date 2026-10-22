// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, OrderKind, Side, FillState, CallKind} from "../gate/GateTypes.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {MarketManager} from "./MarketManager.sol";
import {MarketSession} from "./MarketSession.sol";
import {Prosumer} from "./Prosumer.sol";

/// @title ProsumerDecoder
/// @notice Reads calls to a `Prosumer` contract of the ported P2P market as
///         order legs, and the market's sessions as fill state (decision log
///         2.31).
///
///   placeBids, placeOffers   one PLACE leg per order of the batch; bid is BUY,
///                            offer is SELL
///   cancelOrder              one CANCEL leg, for what the session says is
///                            still unmatched
///   modifyOrder              a CANCEL leg, then a PLACE leg on the same side
///
/// Slots are the market's grid: the session's first slot plus the slot within
/// the session. Value is quantity at the limit price, rounded up (spec D12).
///
/// An order stays open after trading closes and until the session is
/// finalised: that is when matching happens. Once the session is finalised, an
/// order with an unmatched remainder has expired (decision log 2.40).
contract ProsumerDecoder is IOrderDecoder {
    error ProsumerDecoder_UnknownSelector(bytes4 selector);
    error ProsumerDecoder_NoSession(MarketTypes.EnergyType energyType);
    error ProsumerDecoder_UnknownOrder(bytes32 id);
    error ProsumerDecoder_ValueOverflow(uint64 quantity, uint64 price);
    error ProsumerDecoder_NoFundsMove();

    /// @inheritdoc IOrderDecoder
    /// @dev A prosumer contract moves funds only as collateral and payment for
    ///      orders, through the token; it has no withdrawal. So its four order
    ///      functions are its only registrable calls (A9).
    function callKind(address, bytes4 selector) external pure override returns (CallKind) {
        if (
            selector == Prosumer.placeBids.selector || selector == Prosumer.placeOffers.selector
                || selector == Prosumer.modifyOrder.selector
        ) return CallKind.ORDER;
        if (selector == Prosumer.cancelOrder.selector) return CallKind.CANCEL;
        return CallKind.UNKNOWN;
    }

    /// @inheritdoc IOrderDecoder
    function fundsMove(address, bytes calldata) external pure override returns (address, uint256) {
        revert ProsumerDecoder_NoFundsMove();
    }

    /// @inheritdoc IOrderDecoder
    function decode(address market, bytes calldata callData) external view override returns (Order[] memory legs) {
        bytes4 selector = bytes4(callData[:4]);
        Prosumer prosumer = Prosumer(market);

        if (selector == Prosumer.placeBids.selector || selector == Prosumer.placeOffers.selector) {
            (MarketTypes.EnergyType energyType, MarketTypes.OrderRequest[] memory requests) =
                abi.decode(callData[4:], (MarketTypes.EnergyType, MarketTypes.OrderRequest[]));
            MarketSession session = prosumer.manager().currentSession(energyType);
            if (address(session) == address(0)) revert ProsumerDecoder_NoSession(energyType);
            uint32 firstSlot = session.config().firstSlot;
            Side side = selector == Prosumer.placeBids.selector ? Side.BUY : Side.SELL;

            legs = new Order[](requests.length);
            for (uint256 i = 0; i < requests.length; ++i) {
                legs[i] = _placeLeg(side, firstSlot, requests[i]);
            }
        } else if (selector == Prosumer.cancelOrder.selector) {
            bytes32 id = abi.decode(callData[4:], (bytes32));
            legs = new Order[](1);
            legs[0] = _cancelLeg(prosumer, id);
        } else if (selector == Prosumer.modifyOrder.selector) {
            (bytes32 id, MarketTypes.OrderRequest memory request) =
                abi.decode(callData[4:], (bytes32, MarketTypes.OrderRequest));
            legs = new Order[](2);
            legs[0] = _cancelLeg(prosumer, id);
            MarketSession session = prosumer.orderInfo(id).session;
            legs[1] = _placeLeg(legs[0].side, session.config().firstSlot, request);
        } else {
            revert ProsumerDecoder_UnknownSelector(selector);
        }
    }

    /// @inheritdoc IOrderDecoder
    /// @dev placeBids and placeOffers return the batch's ids; modifyOrder
    ///      returns the new order's id.
    function placedOrderIds(address, bytes calldata callData, bytes calldata result)
        external
        pure
        override
        returns (bytes32[] memory ids)
    {
        if (bytes4(callData[:4]) == Prosumer.modifyOrder.selector) {
            ids = new bytes32[](1);
            ids[0] = abi.decode(result, (bytes32));
        } else {
            ids = abi.decode(result, (bytes32[]));
        }
    }

    /// @inheritdoc IOrderDecoder
    function fillState(address market, bytes32 orderId) external view override returns (FillState memory state) {
        MarketSession session = Prosumer(market).orderInfo(orderId).session;
        if (address(session) == address(0)) revert ProsumerDecoder_UnknownOrder(orderId);
        MarketTypes.Order memory order = session.orderOf(orderId);
        bool finalised = session.finalised();
        bool unmatched = order.matched < order.quantity;

        state.filledWh = order.matched;
        state.open = order.status == MarketTypes.OrderStatus.OPEN && !finalised && unmatched;
        state.remainingWh = state.open ? order.quantity - order.matched : 0;
        state.expired = order.status == MarketTypes.OrderStatus.EXPIRED
            || (order.status == MarketTypes.OrderStatus.OPEN && finalised && unmatched);
    }

    /// @inheritdoc IOrderDecoder
    /// @dev The closing time of the current session, of either energy type,
    ///      that covers `slot`; zero if none does.
    function gateTime(address market, uint32 slot) external view override returns (uint64) {
        MarketManager manager = Prosumer(market).manager();
        for (uint8 t = 0; t <= uint8(type(MarketTypes.EnergyType).max); ++t) {
            MarketSession session = manager.currentSession(MarketTypes.EnergyType(t));
            if (address(session) == address(0)) continue;
            MarketTypes.SessionConfig memory c = session.config();
            if (slot >= c.firstSlot && slot < uint32(c.firstSlot) + c.slotCount) return c.closesAt;
        }
        return 0;
    }

    /// @inheritdoc IOrderDecoder
    /// @dev The market's grid: slot number times the slot length.
    function slotStart(address market, uint32 slot) external view override returns (uint64) {
        return uint64(Prosumer(market).manager().slotStart(slot));
    }

    function _placeLeg(Side side, uint32 firstSlot, MarketTypes.OrderRequest memory request)
        private
        pure
        returns (Order memory leg)
    {
        leg.kind = OrderKind.PLACE;
        leg.side = side;
        leg.slot = firstSlot + request.slot;
        leg.qtyWh = request.quantity;
        leg.price = request.price;
        leg.value = _value(request.quantity, request.price);
    }

    function _cancelLeg(Prosumer prosumer, bytes32 id) private view returns (Order memory leg) {
        MarketSession session = prosumer.orderInfo(id).session;
        if (address(session) == address(0)) revert ProsumerDecoder_UnknownOrder(id);
        MarketTypes.Order memory order = session.orderOf(id);
        uint64 unmatched = order.quantity - order.matched;

        leg.kind = OrderKind.CANCEL;
        leg.side = order.side == MarketTypes.Side.BID ? Side.BUY : Side.SELL;
        leg.slot = order.slot;
        leg.qtyWh = unmatched;
        leg.price = order.price;
        leg.value = _value(unmatched, order.price);
        leg.orderId = id;
    }

    function _value(uint64 quantity, uint64 price) private pure returns (uint64) {
        uint256 v = MarketTypes.value(quantity, price);
        if (v > type(uint64).max) revert ProsumerDecoder_ValueOverflow(quantity, price);
        return uint64(v);
    }
}
