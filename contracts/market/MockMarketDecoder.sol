// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, OrderKind, Side, FillState} from "../gate/GateTypes.sol";
import {MockEnergyMarket} from "./MockEnergyMarket.sol";

/// @title MockMarketDecoder
/// @notice Reads MockEnergyMarket's three order calls into legs, and its views
///         into fill state and gate times.
///
/// Every quantity on a CANCEL leg comes from the market: the agent names the
/// order, the market says how much of it is still unfilled. A MODIFY is a CANCEL
/// leg for the old order followed by a PLACE leg for the new one, so each policy
/// sees a modification as exactly what it does (spec 5.1).
///
/// Value is quantity at the limit price. Prices are per kWh and quantities in
/// Wh, so value = qtyWh * price / 1000, rounded up: a cap quantity rounds up
/// (spec D12).
contract MockMarketDecoder is IOrderDecoder {
    error MockMarketDecoder_UnknownSelector(bytes4 selector);
    error MockMarketDecoder_ValueOverflow(uint64 qtyWh, uint64 price);

    /// @inheritdoc IOrderDecoder
    function decode(address market, bytes calldata callData) external view override returns (Order[] memory legs) {
        bytes4 selector = bytes4(callData[:4]);

        if (selector == MockEnergyMarket.placeOrder.selector) {
            (Side side, uint32 slot, uint64 qtyWh, uint64 price) =
                abi.decode(callData[4:], (Side, uint32, uint64, uint64));
            legs = new Order[](1);
            legs[0] = _placeLeg(side, slot, qtyWh, price);
        } else if (selector == MockEnergyMarket.cancelOrder.selector) {
            bytes32 orderId = abi.decode(callData[4:], (bytes32));
            legs = new Order[](1);
            legs[0] = _cancelLeg(MockEnergyMarket(market), orderId);
        } else if (selector == MockEnergyMarket.modifyOrder.selector) {
            (bytes32 orderId, uint32 slot, uint64 qtyWh, uint64 price) =
                abi.decode(callData[4:], (bytes32, uint32, uint64, uint64));
            legs = new Order[](2);
            legs[0] = _cancelLeg(MockEnergyMarket(market), orderId);
            legs[1] = _placeLeg(legs[0].side, slot, qtyWh, price);
        } else {
            revert MockMarketDecoder_UnknownSelector(selector);
        }
    }

    /// @inheritdoc IOrderDecoder
    /// @dev placeOrder and modifyOrder both return the new order's id.
    function placedOrderId(address, bytes calldata, bytes calldata result)
        external
        pure
        override
        returns (bytes32)
    {
        return abi.decode(result, (bytes32));
    }

    /// @inheritdoc IOrderDecoder
    function fillState(address market, bytes32 orderId) external view override returns (FillState memory state) {
        MockEnergyMarket m = MockEnergyMarket(market);
        state.filledWh = m.filledOf(orderId);
        state.remainingWh = m.remainingOf(orderId);
        state.open = m.isOpen(orderId);
    }

    /// @inheritdoc IOrderDecoder
    function gateTime(address market, uint32 slot) external view override returns (uint64) {
        return MockEnergyMarket(market).gateTime(slot);
    }

    function _placeLeg(Side side, uint32 slot, uint64 qtyWh, uint64 price) private pure returns (Order memory leg) {
        leg.kind = OrderKind.PLACE;
        leg.side = side;
        leg.slot = slot;
        leg.qtyWh = qtyWh;
        leg.price = price;
        leg.value = _value(qtyWh, price);
    }

    function _cancelLeg(MockEnergyMarket market, bytes32 orderId) private view returns (Order memory leg) {
        MockEnergyMarket.MarketOrder memory order = market.orderOf(orderId);
        uint64 unfilled = market.remainingOf(orderId);

        leg.kind = OrderKind.CANCEL;
        leg.side = order.side;
        leg.slot = order.slot;
        leg.qtyWh = unfilled;
        leg.price = order.price;
        leg.value = _value(unfilled, order.price);
        leg.orderId = orderId;
    }

    function _value(uint64 qtyWh, uint64 price) private pure returns (uint64) {
        uint256 value = (uint256(qtyWh) * price + 999) / 1000;
        if (value > type(uint64).max) revert MockMarketDecoder_ValueOverflow(qtyWh, price);
        return uint64(value);
    }
}
