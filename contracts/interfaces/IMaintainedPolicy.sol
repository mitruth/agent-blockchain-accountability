// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title IMaintainedPolicy
/// @notice A policy with state that moves on its own, from signed data, and
///         not only when the agent submits (spec v0.2 section 5, S9).
///
/// The gate offers two calls for it, both on an installed instance only:
///
///   poke    anyone may ask the gate to have the policy process what it can
///           and persist it, without a market call: an alarm then does not
///           wait for the agent's next submission
///   reset   the account's owner path: the policy forgets its penalty state
///
/// Both change state only through the policy's own deterministic processing
/// of signed data, or on the owner's word (spec v0.2 section 10).
interface IMaintainedPolicy {
    /// @notice Process and persist. Only PolicyGate may call this.
    /// @return processed How many units of input (for S9, slots) were taken in.
    function poke(address account, bytes32 policyId) external returns (uint256 processed);

    /// @notice Forget the penalty state. Only PolicyGate may call this, on the
    ///         account's own call.
    function reset(address account, bytes32 policyId) external;
}
