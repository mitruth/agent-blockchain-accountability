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
    error DecoderRegistry_NoSlotGrid(address target);

    /// @notice Approve one function of one market contract. Owner path.
    ///
    /// The account itself and the gate can never be targets, whoever asks. A
    /// call to the account would run with the account's own authority, which is
    /// how modules are installed and removed; a call to the gate would arrive
    /// on the owner path. `submit` refuses both as well, so this is the second
    /// lock on the same door.
    ///
    /// The market must be on the account's slot grid (spec v0.2, C4 and D15):
    /// the same origin and the same slot length as every market registered
    /// before it, or positions summed per slot number would mix delivery
    /// intervals. The grid is read from the decoder's `slotStart` of slots 0
    /// and 1, which assumes a linear grid; the decoder is trusted code.
    function setDecoder(address target, bytes4 selector, IOrderDecoder decoder) external onlyAccount nonReentrant {
        if (_isForbiddenTarget(msg.sender, target)) revert DecoderRegistry_ForbiddenTarget(target);
        if (address(decoder) == address(0)) revert DecoderRegistry_ZeroDecoder();

        uint64 origin = decoder.slotStart(target, 0);
        uint64 next = decoder.slotStart(target, 1);
        if (next <= origin || next - origin > type(uint32).max) revert DecoderRegistry_NoSlotGrid(target);
        _fixGrid(msg.sender, origin, uint32(next - origin));

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

    /// @dev Fix the account's slot grid, or revert if this one differs.
    function _fixGrid(address account, uint64 origin, uint32 slotSeconds) internal virtual;

    function _isForbiddenTarget(address account, address target) internal view virtual returns (bool) {
        return target == address(0) || target == account || target == address(this);
    }
}
