// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The part of ERC-7579 that PolicyGate uses, declared locally.
///
/// PolicyGate is trusted code: a bug in it is a policy bypass. It therefore
/// depends on no external library, and these two interfaces are everything it
/// needs from the standard. ModuleKit is used in the tests, to install the gate
/// on real account implementations, and nowhere in the contracts.

/// @dev Every ERC-7579 module implements this.
interface IERC7579Module {
    /// @notice Called by the account when it installs the module.
    function onInstall(bytes calldata data) external;

    /// @notice Called by the account when it uninstalls the module.
    function onUninstall(bytes calldata data) external;

    /// @notice Executor is type 2.
    function isModuleType(uint256 moduleTypeId) external view returns (bool);

    function isInitialized(address smartAccount) external view returns (bool);
}

/// @dev The one account entry point an executor module calls.
interface IERC7579Execution {
    /// @param mode              Packed execution mode; all zero is "one call,
    ///                          revert on failure".
    /// @param executionCalldata For a single call: target (20 bytes), value
    ///                          (32 bytes), then the call data, packed.
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData);
}
