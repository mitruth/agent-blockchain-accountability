// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IPolicy} from "../../../contracts/interfaces/IPolicy.sol";
import {OracleVerifier} from "../../../contracts/oracle/OracleVerifier.sol";
import {BmsReading} from "../../../contracts/oracle/OracleTypes.sol";
import {
    Order, ConfigChange, Verdict, CheckContext, CheckResult, Release
} from "../../../contracts/gate/GateTypes.sol";

/// @notice A test double that rejects every submission unless the account's
///         battery reading is fresh in the oracle the gate passes and shows at
///         least the configured energy, and reports the stored energy it saw.
///         Shows that the readings an order brings are in place before the
///         policies check. Not a policy of the system.
contract FreshBatteryPolicy is IPolicy {
    mapping(address account => uint64) public minSocWh;

    function classifyConfig(address, bytes32, bytes calldata) external pure override returns (ConfigChange) {
        return ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32, bytes calldata config) external override {
        minSocWh[account] = abi.decode(config, (uint64));
    }

    function deconfigure(address, bytes32) external override {}

    function check(address account, bytes32, Order[] calldata, CheckContext calldata ctx)
        external
        view
        override
        returns (CheckResult memory result)
    {
        (BmsReading memory reading, bool fresh) = OracleVerifier(ctx.oracle).bmsOf(account);
        result.valueAfter = reading.socWh;
        result.hard = minSocWh[account];
        result.verdict = fresh && reading.socWh >= minSocWh[account] ? Verdict.EXECUTE : Verdict.REJECT;
    }

    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external override {}

    function credit(address, bytes32, Release calldata) external override {}
}
