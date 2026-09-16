// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IModule} from "./IModule.sol";

/// @notice Policy validator hooked by SmartAccount.execute.
/// @dev `from` is the caller of execute: the owner or the agent's session key.
///      `value` is the wei being transferred. It is not spend -- spend is what
///      the meter measured -- and a validator must not treat it as such (F6).
interface IValidator is IModule {
    function validateTransaction(
        address from,
        address to,
        uint256 value
    ) external view returns (bool);
}
