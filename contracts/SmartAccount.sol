// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IModule} from "./interfaces/IModule.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {PolicyConfig} from "./PolicyConfig.sol";
import {SpendLedger} from "./SpendLedger.sol";

/// @title SmartAccount
/// @notice Owner-controlled account with a sticky policy pair and an
///         upgradeable spend validator hook.
///
/// PolicyConfig and SpendLedger are immutable here: the account cannot be
/// repointed at a fresh ledger to mint window capacity. The spend validator
/// module is swappable (upgrade path) but execute refuses to run without one
/// installed and selected — uninstalling the hook is not a silent bypass.
///
/// Module list membership is compacted on uninstall so execute never walks an
/// unbounded ghost array of revoked modules.
contract SmartAccount {
    address public immutable owner;

    /// @notice Sticky config. Set once at construction; never replaced.
    PolicyConfig public immutable policyConfig;

    /// @notice Sticky ledger. Set once at construction; never replaced.
    SpendLedger public immutable spendLedger;

    /// @notice Active spend validator. Must be installed. Cleared on uninstall
    ///         of that module; execute reverts until the owner selects another.
    address public spendValidator;

    mapping(address => bool) public installedModules;
    address[] private _moduleList;

    event ModuleInstalled(address indexed module);
    event ModuleUninstalled(address indexed module);
    event SpendValidatorUpdated(address indexed previous, address indexed current);
    event TransactionExecuted(address indexed to, uint256 value);
    event TransactionRejected(address indexed to, uint256 value, string reason);

    error SmartAccount_OnlyOwner();
    error SmartAccount_AlreadyInstalled();
    error SmartAccount_NotInstalled();
    error SmartAccount_InsufficientBalance();
    error SmartAccount_TransferFailed();
    error SmartAccount_SpendsPaused();
    error SmartAccount_NoSpendValidator();
    error SmartAccount_NotSpendValidator();
    error SmartAccount_RejectedByModule();

    modifier onlyOwner() {
        if (msg.sender != owner) revert SmartAccount_OnlyOwner();
        _;
    }

    /// @param policyConfig_ Sticky PolicyConfig for this account.
    /// @param spendLedger_  Sticky SpendLedger for this account.
    constructor(PolicyConfig policyConfig_, SpendLedger spendLedger_) {
        owner = msg.sender;
        policyConfig = policyConfig_;
        spendLedger = spendLedger_;
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // Modules
    // ------------------------------------------------------------------

    /// @notice Install a module and register it on the compacted list.
    function installModule(address module) external onlyOwner {
        if (installedModules[module]) revert SmartAccount_AlreadyInstalled();

        installedModules[module] = true;
        _moduleList.push(module);
        IModule(module).onInstall("");
        emit ModuleInstalled(module);
    }

    /// @notice Uninstall a module and remove it from the iteration list.
    ///         If it was the spend validator, the hook is cleared and execute
    ///         will refuse until setSpendValidator selects a replacement.
    function uninstallModule(address module) external onlyOwner {
        if (!installedModules[module]) revert SmartAccount_NotInstalled();

        installedModules[module] = false;
        _removeFromModuleList(module);

        if (spendValidator == module) {
            address previous = spendValidator;
            spendValidator = address(0);
            emit SpendValidatorUpdated(previous, address(0));
        }

        IModule(module).onUninstall("");
        emit ModuleUninstalled(module);
    }

    /// @notice Designate an already-installed module as the spend validator.
    ///         Separated from install so ledger allowlisting can happen in
    ///         between without silently coupling install → write authority.
    function setSpendValidator(address module) external onlyOwner {
        if (!installedModules[module]) revert SmartAccount_NotInstalled();
        if (!IModule(module).isModuleType(1)) revert SmartAccount_NotSpendValidator();

        address previous = spendValidator;
        spendValidator = module;
        emit SpendValidatorUpdated(previous, module);
    }

    /// @notice Currently installed modules only (no uninstalled ghosts).
    function getInstalledModules() external view returns (address[] memory) {
        return _moduleList;
    }

    // ------------------------------------------------------------------
    // Execution
    // ------------------------------------------------------------------

    /// @notice Owner-only transfer gated by pause + every installed validator.
    /// @param to    Recipient.
    /// @param value Prospective spend in ledger minor units (milli-USD), also
    ///              used as the wei amount transferred in this demo account.
    function execute(address to, uint256 value) external onlyOwner {
        if (address(this).balance < value) revert SmartAccount_InsufficientBalance();
        if (policyConfig.spendsCurrentlyPaused()) revert SmartAccount_SpendsPaused();
        if (spendValidator == address(0) || !installedModules[spendValidator]) {
            revert SmartAccount_NoSpendValidator();
        }

        uint256 length = _moduleList.length;
        for (uint256 i = 0; i < length; ) {
            address module = _moduleList[i];
            // List is compacted; every entry is installed. Re-check for safety.
            if (installedModules[module]) {
                bool allowed = IValidator(module).validateTransaction(msg.sender, to, value);
                if (!allowed) {
                    emit TransactionRejected(to, value, "rejected by module");
                    revert SmartAccount_RejectedByModule();
                }
            }
            unchecked {
                ++i;
            }
        }

        (bool success, ) = to.call{value: value}("");
        if (!success) revert SmartAccount_TransferFailed();
        emit TransactionExecuted(to, value);
    }

    function _removeFromModuleList(address module) private {
        uint256 length = _moduleList.length;
        for (uint256 i = 0; i < length; ) {
            if (_moduleList[i] == module) {
                _moduleList[i] = _moduleList[length - 1];
                _moduleList.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }
}
