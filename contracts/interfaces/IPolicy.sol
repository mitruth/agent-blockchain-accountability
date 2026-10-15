// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ConfigChange, Order, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// @title IPolicy
/// @notice A policy contract: its configuration, and its check of the orders
///         an agent submits (spec 4.2).
///
/// A policy contract is stateful, keyed by account, and may host several
/// instances for one account, each with its own `policyId`. Only PolicyGate may
/// change its state.
///
/// The direction table lives in the policy, because only the policy knows which
/// way each of its parameters tightens. The timing lives in the gate: the
/// policy says TIGHTEN or WIDEN, and the gate applies the first at once and the
/// second after the timelock.
///
/// For every submission the gate calls `check` on every instance of the
/// account, with all the legs of the call at once, so that a batch cannot be
/// cut in pieces to pass a cap. If no instance rejects, it calls `commit` on
/// every instance, then has the account make the call. When volume is
/// released later -- a cancellation through the gate, an expiry, an order the
/// market closed -- it calls `credit`.
///
/// A policy never rejects an action that only reduces its own exposure (spec
/// D10): a cancellation, for every policy that charged the placement.
interface IPolicy {
    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice Compare `config` with what is in force for (account, policyId).
    ///
    ///   INVALID  malformed, or breaks a cross-parameter constraint
    ///   TIGHTEN  no parameter is looser than before; also any valid
    ///            configuration of an instance that has none yet
    ///   WIDEN    at least one parameter is looser, whatever the others do
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        returns (ConfigChange);

    /// @notice Put `config` in force. Only PolicyGate may call this.
    function configure(address account, bytes32 policyId, bytes calldata config) external;

    /// @notice Drop the instance. Only PolicyGate may call this.
    function deconfigure(address account, bytes32 policyId) external;

    // ------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------

    /// @notice What this instance says about a submission of `legs`, without
    ///         changing anything.
    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        view
        returns (CheckResult memory);

    /// @notice Record a submission every instance accepted. Called before the
    ///         account makes the call, in the same transaction: if the call
    ///         reverts, so does this. Only PolicyGate may call this.
    function commit(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx) external;

    /// @notice Give back what was charged for released volume. Only PolicyGate
    ///         may call this. A credit that fails leaves the charge in place.
    function credit(address account, bytes32 policyId, Release calldata release) external;
}
