// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title GateBase
/// @notice What every part of PolicyGate shares: which accounts have the gate
///         installed, the owner path, and the reentrancy lock.
///
/// The gate is one deployment serving many accounts, so all state is keyed by
/// account. It is also keyed by an installation generation. Uninstalling the
/// gate cannot walk the mappings to clear them, so each new installation gets a
/// fresh generation instead, and everything written under an earlier one reads
/// as absent: an agent registered before an uninstall has no authority after a
/// reinstall.
abstract contract GateBase {
    struct Installation {
        bool installed;
        uint64 generation;
    }

    mapping(address account => Installation) private _installations;

    uint256 private _lock = 1;

    event GateInstalled(address indexed account, uint64 generation);
    event GateUninstalled(address indexed account, uint64 generation);

    error Gate_NotInstalled(address account);
    error Gate_AlreadyInstalled(address account);
    error Gate_Reentrancy();

    /// @notice The caller must be an account with the gate installed, and every
    ///         write lands in that account's own state.
    ///
    /// An account calls the gate when its root validator, the owner, has
    /// authorised the call, or when the agent's session has, and the session
    /// allows `submit` and nothing else (decision D1, option 3). So every other
    /// function guarded here is the owner path. The agent cannot route around
    /// its session either: `submit` refuses the gate as a target.
    ///
    /// Any address may call `onInstall` and so pass this check, but it then
    /// writes state keyed by itself, which no other account ever reads.
    modifier onlyAccount() {
        if (!_installations[msg.sender].installed) revert Gate_NotInstalled(msg.sender);
        _;
    }

    /// @dev One lock for the whole gate, held by `submit` and by every owner
    ///      write. Nothing can register an agent, a decoder or a configuration
    ///      while an order is part-way through.
    modifier nonReentrant() {
        if (_lock != 1) revert Gate_Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    function isInstalled(address account) public view returns (bool) {
        return _installations[account].installed;
    }

    /// @notice The installation generation state is read and written under.
    function generationOf(address account) public view returns (uint64) {
        return _installations[account].generation;
    }

    function _install(address account) internal {
        Installation storage installation = _installations[account];
        if (installation.installed) revert Gate_AlreadyInstalled(account);

        installation.installed = true;
        installation.generation += 1;
        emit GateInstalled(account, installation.generation);
    }

    function _uninstall(address account) internal {
        Installation storage installation = _installations[account];
        if (!installation.installed) revert Gate_NotInstalled(account);

        installation.installed = false;
        emit GateUninstalled(account, installation.generation);
    }
}
