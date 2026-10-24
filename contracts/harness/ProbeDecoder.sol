// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, OrderKind, Side, FillState, CallKind} from "../gate/GateTypes.sol";
import {ProbeMarket} from "./ProbeMarket.sol";

/// Stand-ins for the off-chain verifiers of G1 and of the price policies (spec
/// v0.2 section 5); see ProbeMarket.
/// @notice Reads `ProbeMarket.order` as one placement of 1 Wh, and
///         `ProbeMarket.place` as the placement it names. Every order is
///         reported closed at once, with what the script set as filled, so a
///         keeper's reconcile releases the rest and the ledger's open-order
///         bound never binds.
contract ProbeDecoder is IOrderDecoder {
    function callKind(address, bytes4 selector) external pure override returns (CallKind) {
        return selector == ProbeMarket.order.selector || selector == ProbeMarket.place.selector
            ? CallKind.ORDER
            : CallKind.UNKNOWN;
    }

    function fundsMove(address, bytes calldata) external pure override returns (address, uint256) {}

    function decode(address, bytes calldata callData) external pure override returns (Order[] memory legs) {
        legs = new Order[](1);
        legs[0].kind = OrderKind.PLACE;
        if (bytes4(callData[:4]) == ProbeMarket.place.selector) {
            (uint8 side, uint32 slot, uint64 qtyWh, uint64 price) =
                abi.decode(callData[4:], (uint8, uint32, uint64, uint64));
            legs[0].side = Side(side);
            legs[0].slot = slot;
            legs[0].qtyWh = qtyWh;
            legs[0].price = price;
            legs[0].value = uint64((uint256(qtyWh) * price + 999) / 1000);
        } else {
            legs[0].side = Side.BUY;
            legs[0].slot = 1;
            legs[0].qtyWh = 1;
        }
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
