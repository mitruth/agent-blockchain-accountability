// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// Stand-ins for the off-chain verifiers of G1 and of the price policies (spec
/// v0.2 section 5), with ProbeMarket, ProbeDecoder and ScriptedPolicy: a script
/// can make the gate reject, flag or execute any submission it likes, place any
/// order and fill any part of it, and check the policies from the event log
/// alone. Not for deployment.
/// @notice `order` is any order, of 1 Wh; `place` an order as the script
///         names it. Each gets a fresh id. Anyone may set how much of an order
///         has filled.
contract ProbeMarket {
    uint256 public orderCount;

    mapping(bytes32 orderId => uint64) public filledOf;

    function order() external returns (bytes32) {
        return bytes32(++orderCount);
    }

    /// @dev The decoder reads the arguments; the market only gives an id.
    ///      side 0 BUY, 1 SELL.
    function place(uint8, uint32, uint64, uint64) external returns (bytes32) {
        return bytes32(++orderCount);
    }

    function setFilled(bytes32 orderId, uint64 filledWh) external {
        filledOf[orderId] = filledWh;
    }
}
