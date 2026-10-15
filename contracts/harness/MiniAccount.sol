// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC7579Module} from "../interfaces/IERC7579.sol";

/// @notice The smallest account that behaves like an ERC-7579 account where it
///         matters to PolicyGate. For tests and local demonstrations only: it
///         stands in for a real account (Safe7579, Nexus, Kernel) and has no
///         signature validation of its own.
///
/// `owner` stands in for the EntryPoint plus an owner-only root validator: a
/// call from `owner` is a user operation the owner signed.
///
/// Module management is open to the owner and to the account itself, as on the
/// real implementations, where `installModule` accepts the EntryPoint or a
/// self-call. That self-call is the escalation path the gate has to close, so
/// the mock keeps it open on purpose.
///
/// Sessions stand in for Rhinestone Smart Sessions (decision D1, option 3): the
/// owner lets a key make the account call one function of one contract, until a
/// time, and nothing else. On the real accounts the agent's session is a Smart
/// Session scoped the same way (test/accounts/).
contract MiniAccount {
    uint256 internal constant MODULE_TYPE_EXECUTOR = 2;

    address public immutable owner;

    /// @notice A key's session: the one call it may have the account make.
    struct Session {
        address target;
        bytes4 selector;
        uint48 validUntil;
    }

    mapping(uint256 moduleTypeId => mapping(address module => bool)) private _installed;
    mapping(address key => Session) private _sessions;

    event SessionEnabled(address indexed key, address indexed target, bytes4 selector, uint48 validUntil);
    event SessionRemoved(address indexed key);

    error MiniAccount_Unauthorized(address caller);
    error MiniAccount_AlreadyInstalled(address module);
    error MiniAccount_NotInstalled(address module);
    error MiniAccount_UnsupportedMode(bytes32 mode);
    error MiniAccount_OutsideSession(address key, address target, bytes4 selector);

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert MiniAccount_Unauthorized(msg.sender);
        _;
    }

    modifier onlyOwnerOrSelf() {
        if (msg.sender != owner && msg.sender != address(this)) revert MiniAccount_Unauthorized(msg.sender);
        _;
    }

    /// @notice An owner-authorised call from the account.
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        onlyOwner
        returns (bytes memory)
    {
        return _call(target, value, data);
    }

    /// @notice Let `key` have the account call `selector` on `target`, through
    ///         its last second `validUntil`. Replaces the key's session, if any.
    function enableSession(address key, address target, bytes4 selector, uint48 validUntil) external onlyOwnerOrSelf {
        _sessions[key] = Session({target: target, selector: selector, validUntil: validUntil});
        emit SessionEnabled(key, target, selector, validUntil);
    }

    /// @notice End `key`'s session at once.
    function removeSession(address key) external onlyOwnerOrSelf {
        delete _sessions[key];
        emit SessionRemoved(key);
    }

    function sessionOf(address key) external view returns (Session memory) {
        return _sessions[key];
    }

    /// @notice A session key's call from the account: exactly the target and
    ///         function its session names, while the session is valid, with no
    ///         value.
    function executeAsSession(address target, bytes calldata data) external returns (bytes memory) {
        Session memory s = _sessions[msg.sender];
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        if (s.validUntil < block.timestamp || target != s.target || selector != s.selector) {
            revert MiniAccount_OutsideSession(msg.sender, target, selector);
        }
        return _call(target, 0, data);
    }

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external onlyOwnerOrSelf {
        if (_installed[moduleTypeId][module]) revert MiniAccount_AlreadyInstalled(module);
        _installed[moduleTypeId][module] = true;
        IERC7579Module(module).onInstall(initData);
    }

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)
        external
        onlyOwnerOrSelf
    {
        if (!_installed[moduleTypeId][module]) revert MiniAccount_NotInstalled(module);
        _installed[moduleTypeId][module] = false;
        IERC7579Module(module).onUninstall(deInitData);
    }

    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata) external view returns (bool) {
        return _installed[moduleTypeId][module];
    }

    /// @notice Single-call mode only, from an installed executor only.
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData)
    {
        if (!_installed[MODULE_TYPE_EXECUTOR][msg.sender]) revert MiniAccount_Unauthorized(msg.sender);
        if (mode != bytes32(0)) revert MiniAccount_UnsupportedMode(mode);

        address target = address(bytes20(executionCalldata[:20]));
        uint256 value = uint256(bytes32(executionCalldata[20:52]));

        returnData = new bytes[](1);
        returnData[0] = _call(target, value, executionCalldata[52:]);
    }

    receive() external payable {}

    /// @dev Real accounts accept ERC-1155 tokens through a fallback handler;
    ///      the market delivers energy and payment to the account.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function _call(address target, uint256 value, bytes calldata data) private returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
