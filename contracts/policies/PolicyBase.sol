// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IPolicy} from "../interfaces/IPolicy.sol";

/// @title PolicyBase
/// @notice What every policy contract shares: the one gate allowed to change
///         its state.
///
/// A policy's state is keyed by account and policy id. Only the gate writes
/// it: on the owner path for configuration, and in a submission's commit
/// phase or on a release for the orders. Anything else a policy needs -- a
/// slot's start or gate time -- it reads through views.
abstract contract PolicyBase is IPolicy {
    address public immutable gate;

    error Policy_OnlyGate(address caller);

    constructor(address gate_) {
        gate = gate_;
    }

    modifier onlyGate() {
        if (msg.sender != gate) revert Policy_OnlyGate(msg.sender);
        _;
    }
}
