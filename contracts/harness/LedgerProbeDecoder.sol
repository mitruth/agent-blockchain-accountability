// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, FillState} from "../gate/GateTypes.sol";

/// @title LedgerProbeDecoder
/// @notice A decoder whose fills a script sets, so the off-chain verifier can
///         drive the PositionLedger directly across several markets and check
///         its per-slot totals from the event log (spec v0.2, C4). Not for
///         deployment: anyone may set any fill.
///
/// Markets are only keys here: any address will do. Slots are half-hours from
/// 1970 on every market, so all of them share one grid.
contract LedgerProbeDecoder is IOrderDecoder {
    mapping(address market => mapping(bytes32 orderId => FillState)) private _states;

    error LedgerProbeDecoder_NotAnOrderDecoder();

    function setFill(address market, bytes32 orderId, uint64 filledWh, bool open, bool expired) external {
        _states[market][orderId] = FillState({filledWh: filledWh, remainingWh: 0, open: open, expired: expired});
    }

    function decode(address, bytes calldata) external pure override returns (Order[] memory) {
        revert LedgerProbeDecoder_NotAnOrderDecoder();
    }

    function placedOrderIds(address, bytes calldata, bytes calldata) external pure override returns (bytes32[] memory) {
        revert LedgerProbeDecoder_NotAnOrderDecoder();
    }

    function fillState(address market, bytes32 orderId) external view override returns (FillState memory) {
        return _states[market][orderId];
    }

    function gateTime(address, uint32) external pure override returns (uint64) {
        return 0;
    }

    function slotStart(address, uint32 slot) external pure override returns (uint64) {
        return uint64(slot) * 1800;
    }
}
