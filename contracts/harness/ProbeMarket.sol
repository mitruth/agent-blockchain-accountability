// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// Stand-ins for the off-chain verifier of G1 (spec v0.2 section 5), with
/// ProbeMarket, ProbeDecoder and ScriptedPolicy: a script can make the gate
/// reject, flag or execute any submission it likes, and check the breaker's
/// reaction from the event log alone. Not for deployment.
/// @notice Every `order` is accepted and given a fresh id.
contract ProbeMarket {
    uint256 public orderCount;

    function order() external returns (bytes32) {
        return bytes32(++orderCount);
    }
}
