// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, OrderKind, Side, FillState, CallKind} from "../gate/GateTypes.sol";
import {ProbeMarket} from "./ProbeMarket.sol";

/// Stand-ins for the off-chain verifiers of G1, of the price policies and of
/// S8 (spec v0.2 section 5); see ProbeMarket.
/// @notice Reads `ProbeMarket.order` as one placement of 1 Wh,
///         `ProbeMarket.place` as the placement it names, `cancel` as a
///         cancellation of the unfilled rest, and `replace` as a cancellation
///         followed by a placement. Every order is reported closed at once,
///         with what the script set as filled, so a keeper's reconcile
///         releases the rest and the ledger's open-order bound never binds.
contract ProbeDecoder is IOrderDecoder {
    function callKind(address, bytes4 selector) external pure override returns (CallKind) {
        if (selector == ProbeMarket.cancel.selector) return CallKind.CANCEL;
        return selector == ProbeMarket.order.selector || selector == ProbeMarket.place.selector
            || selector == ProbeMarket.replace.selector ? CallKind.ORDER : CallKind.UNKNOWN;
    }

    function fundsMove(address, bytes calldata) external pure override returns (address, uint256) {}

    function decode(address market, bytes calldata callData) external view override returns (Order[] memory legs) {
        bytes4 selector = bytes4(callData[:4]);
        if (selector == ProbeMarket.cancel.selector) {
            legs = new Order[](1);
            legs[0] = _cancelLeg(market, abi.decode(callData[4:], (bytes32)));
        } else if (selector == ProbeMarket.replace.selector) {
            (bytes32 old, uint8 side, uint32 slot, uint64 qtyWh, uint64 price) =
                abi.decode(callData[4:], (bytes32, uint8, uint32, uint64, uint64));
            legs = new Order[](2);
            legs[0] = _cancelLeg(market, old);
            legs[1] = _placeLeg(side, slot, qtyWh, price);
        } else if (selector == ProbeMarket.place.selector) {
            (uint8 side, uint32 slot, uint64 qtyWh, uint64 price) =
                abi.decode(callData[4:], (uint8, uint32, uint64, uint64));
            legs = new Order[](1);
            legs[0] = _placeLeg(side, slot, qtyWh, price);
        } else {
            legs = new Order[](1);
            legs[0].kind = OrderKind.PLACE;
            legs[0].side = Side.BUY;
            legs[0].slot = 1;
            legs[0].qtyWh = 1;
        }
    }

    function _placeLeg(uint8 side, uint32 slot, uint64 qtyWh, uint64 price) private pure returns (Order memory leg) {
        leg.kind = OrderKind.PLACE;
        leg.side = Side(side);
        leg.slot = slot;
        leg.qtyWh = qtyWh;
        leg.price = price;
        leg.value = uint64((uint256(qtyWh) * price + 999) / 1000);
    }

    /// @dev As a real decoder: the quantity is the market's unfilled rest.
    function _cancelLeg(address market, bytes32 orderId) private view returns (Order memory leg) {
        ProbeMarket.Placed memory p = ProbeMarket(market).placedOf(orderId);
        leg.kind = OrderKind.CANCEL;
        leg.side = Side(p.side);
        leg.slot = p.slot;
        leg.qtyWh = p.qtyWh - ProbeMarket(market).filledOf(orderId);
        leg.orderId = orderId;
    }

    function placedOrderIds(address, bytes calldata, bytes calldata result)
        external
        pure
        override
        returns (bytes32[] memory ids)
    {
        ids = new bytes32[](1);
        ids[0] = abi.decode(result, (bytes32));
    }

    function fillState(address market, bytes32 orderId) external view override returns (FillState memory state) {
        state.filledWh = ProbeMarket(market).filledOf(orderId);
    }

    function gateTime(address, uint32) external pure override returns (uint64) {
        return type(uint64).max;
    }

    function slotStart(address, uint32 slot) external pure override returns (uint64) {
        return uint64(slot) * 1800;
    }
}
