// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IModule {
    function onInstall(bytes calldata data) external view;

    function onUninstall(bytes calldata data) external view;

    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}
