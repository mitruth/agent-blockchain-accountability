// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GateBase} from "./GateBase.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";

/// @title DecoderRegistry
/// @notice The allowlist of calls an agent may make, and the decoder that reads
///         each one (policy A7, session scope).
///
/// A call is allowed only when the owner has registered a decoder for exactly
/// that target and that function selector. There is no wildcard: an
/// unregistered function on an approved market is as unreachable as an unknown
/// contract.
abstract contract DecoderRegistry is GateBase {
    mapping(
        address account
            => mapping(uint64 generation => mapping(address target => mapping(bytes4 selector => IOrderDecoder)))
    ) private _decoders;

    event DecoderSet(address indexed account, address indexed target, bytes4 indexed selector, address decoder);
    event DecoderRemoved(address indexed account, address indexed target, bytes4 indexed selector);

    error DecoderRegistry_ForbiddenTarget(address target);
    error DecoderRegistry_ZeroDecoder();

    /// @notice Approve one function of one market contract. Owner path.
    ///
    /// The account itself and the gate can never be targets, whoever asks. A
    /// call to the account would run with the account's own authority, which is
    /// how modules are installed and removed; a call to the gate would arrive
    /// on the owner path. `submit` refuses both as well, so this is the second
    /// lock on the same door.
    function setDecoder(address target, bytes4 selector, IOrderDecoder decoder) external onlyAccount nonReentrant {
        if (_isForbiddenTarget(msg.sender, target)) revert DecoderRegistry_ForbiddenTarget(target);
        if (address(decoder) == address(0)) revert DecoderRegistry_ZeroDecoder();

        _decoders[msg.sender][generationOf(msg.sender)][target][selector] = decoder;
        emit DecoderSet(msg.sender, target, selector, address(decoder));
    }

    /// @notice Withdraw an approval at once. Owner path.
    function removeDecoder(address target, bytes4 selector) external onlyAccount nonReentrant {
        delete _decoders[msg.sender][generationOf(msg.sender)][target][selector];
        emit DecoderRemoved(msg.sender, target, selector);
    }

    /// @notice The decoder for a call, or the zero address when the call is
    ///         not allowed.
    function decoderOf(address account, address target, bytes4 selector) public view returns (IOrderDecoder) {
        return _decoders[account][generationOf(account)][target][selector];
    }

    function _isForbiddenTarget(address account, address target) internal view virtual returns (bool) {
        return target == address(0) || target == account || target == address(this);
    }
}
