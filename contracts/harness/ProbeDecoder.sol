// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, OrderKind, Side, FillState, CallKind} from "../gate/GateTypes.sol";
import {ProbeMarket} from "./ProbeMarket.sol";

/// Stand-ins for the off-chain verifier of G1 (spec v0.2 section 5), with
/// ProbeMarket, ProbeDecoder and ScriptedPolicy: a script can make the gate
/// reject, flag or execute any submission it likes, and check the breaker's
/// reaction from the event log alone. Not for deployment.
/// @notice Reads `ProbeMarket.order` as one placement of 1 Wh. The order is
///         reported closed at once, so a keeper's reconcile releases it and
///         the ledger's open-order bound never binds.
contract ProbeDecoder is IOrderDecoder {
    function callKind(address, bytes4 selector) external pure override returns (CallKind) {
        return selector == ProbeMarket.order.selector ? CallKind.ORDER : CallKind.UNKNOWN;
    }

    function fundsMove(address, bytes calldata) external pure override returns (address, uint256) {}

    function decode(address, bytes calldata) external pure override returns (Order[] memory legs) {
        legs = new Order[](1);
        legs[0].kind = OrderKind.PLACE;
        legs[0].side = Side.BUY;
        legs[0].slot = 1;
        legs[0].qtyWh = 1;
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

    function fillState(address, bytes32) external pure override returns (FillState memory) {}

    function gateTime(address, uint32) external pure override returns (uint64) {
        return type(uint64).max;
    }

    function slotStart(address, uint32 slot) external pure override returns (uint64) {
        return uint64(slot) * 1800;
    }
}
