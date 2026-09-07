// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IModule} from "./IModule.sol";

/// @notice Spend / policy validator hooked by SmartAccount.execute.
/// @dev `value` is the prospective spend in ledger minor units (milli-USD),
///      encoded as uint256. It is not an ETH denomination. Callers must ensure
///      it fits in int256 before the validator casts it.
interface IValidator is IModule {
    function validateTransaction(
        address from,
        address to,
        uint256 value
    ) external view returns (bool);
}
