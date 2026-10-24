// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// Stand-ins for the off-chain verifiers of G1, of the price policies and of
/// S8 (spec v0.2 section 5), with ProbeMarket, ProbeDecoder and ScriptedPolicy:
/// a script can make the gate reject, flag or execute any submission it likes,
/// place, cancel or replace any order and fill any part of it, and check the
/// policies from the event log alone. Not for deployment.
/// @notice `order` is any order, of 1 Wh; `place` an order as the script
///         names it; `cancel` and `replace` act on one placed earlier. Each
///         placement gets a fresh id. Anyone may set how much of an order has
///         filled.
contract ProbeMarket {
    struct Placed {
        uint8 side;
        uint32 slot;
        uint64 qtyWh;
    }

    uint256 public orderCount;

    mapping(bytes32 orderId => uint64) public filledOf;
    mapping(bytes32 orderId => Placed) private _placed;

    function order() external returns (bytes32) {
        return bytes32(++orderCount);
    }

    /// @dev The decoder reads the arguments; the market keeps them only for a
    ///      later cancellation. side 0 BUY, 1 SELL.
    function place(uint8 side, uint32 slot, uint64 qtyWh, uint64) external returns (bytes32 orderId) {
        orderId = bytes32(++orderCount);
        _placed[orderId] = Placed(side, slot, qtyWh);
    }

    function cancel(bytes32) external {}

    /// @dev A modification: the old order cancelled, a new one placed.
    function replace(bytes32, uint8 side, uint32 slot, uint64 qtyWh, uint64) external returns (bytes32 orderId) {
        orderId = bytes32(++orderCount);
        _placed[orderId] = Placed(side, slot, qtyWh);
    }

    function placedOf(bytes32 orderId) external view returns (Placed memory) {
        return _placed[orderId];
    }

    function setFilled(bytes32 orderId, uint64 filledWh) external {
        filledOf[orderId] = filledWh;
    }
}
