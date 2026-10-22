// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IPolicy} from "../interfaces/IPolicy.sol";
import {Order, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// Stand-ins for the off-chain verifier of G1 (spec v0.2 section 5), with
/// ProbeMarket, ProbeDecoder and ScriptedPolicy: a script can make the gate
/// reject, flag or execute any submission it likes, and check the breaker's
/// reaction from the event log alone. Not for deployment.
/// @notice Returns whatever verdict was last set for the account. Anyone may
///         set it.
contract ScriptedPolicy is IPolicy {
    mapping(address account => Verdict) public verdictOf;

    function setVerdict(address account, Verdict verdict) external {
        verdictOf[account] = verdict;
    }

    function classifyConfig(address, bytes32, bytes calldata) external pure override returns (ConfigChange) {
        return ConfigChange.TIGHTEN;
    }

    function configure(address, bytes32, bytes calldata) external override {}

    function deconfigure(address, bytes32) external override {}

    function check(address account, bytes32, Order[] calldata, CheckContext calldata)
        external
        view
        override
        returns (CheckResult memory r)
    {
        r.verdict = verdictOf[account];
        r.soft = 1;
        r.hard = 2;
        r.valueAfter = uint8(r.verdict);
    }

    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external override {}

    function credit(address, bytes32, Release calldata) external override {}
}
