// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ConfigChange} from "../gate/GateTypes.sol";

/// @title IPolicy
/// @notice The configuration side of a policy contract.
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
/// The order-checking half of the interface -- check, commit and credit --
/// arrives with the first policies in step 4 of the build order.
interface IPolicy {
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
}
