// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GateBase} from "./GateBase.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {CallKind} from "./GateTypes.sol";

/// @title DecoderRegistry
/// @notice The allowlist of calls an agent may make, the decoder that reads
///         each one, and what kind of call it is (policies A7 and A9).
///
/// A call is allowed only when the owner has registered a decoder for exactly
/// that target and that function selector. There is no wildcard: an
/// unregistered function on an approved market is as unreachable as an unknown
/// contract.
///
/// The decoder classifies the call when it is registered, and the kind is
/// kept with it (spec v0.2 section 11.2, A9):
///
///   ORDER, CANCEL      decoded into legs and judged by the policies
///   FUNDS_MOVE         its recipient must be the account
///   APPROVAL           its spender must be a market of the account: a target
///                      with at least one ORDER or CANCEL call registered
///   UNKNOWN            refused: the decoder does not vouch for it
///   OPAQUE_FUNDS_MOVE  refused: it can move funds and no one can say to whom
abstract contract DecoderRegistry is GateBase {
    struct Entry {
        IOrderDecoder decoder;
        CallKind kind;
    }

    mapping(
        address account => mapping(uint64 generation => mapping(address target => mapping(bytes4 selector => Entry)))
    ) private _entries;

    /// @dev ORDER and CANCEL calls registered per target: a target with any is
    ///      a market of the account.
    mapping(address account => mapping(uint64 generation => mapping(address target => uint256))) private _orderCalls;

    event DecoderSet(
        address indexed account, address indexed target, bytes4 indexed selector, address decoder, CallKind kind
    );
    event DecoderRemoved(address indexed account, address indexed target, bytes4 indexed selector);

    error DecoderRegistry_ForbiddenTarget(address target);
    error DecoderRegistry_ZeroDecoder();
    error DecoderRegistry_NoSlotGrid(address target);
    error DecoderRegistry_UnregistrableCall(address target, bytes4 selector, CallKind kind);

    /// @notice Approve one function of one contract. Owner path.
    ///
    /// The account itself and the gate can never be targets, whoever asks. A
    /// call to the account would run with the account's own authority, which is
    /// how modules are installed and removed; a call to the gate would arrive
    /// on the owner path. `submit` refuses both as well, so this is the second
    /// lock on the same door.
    ///
    /// A call the decoder cannot classify, or one that can move funds without
    /// the decoder exposing the recipient, is refused (A9).
    ///
    /// The target of an ORDER or CANCEL call is a market, and must be on the
    /// account's slot grid (spec v0.2, C4 and D15): the same origin and the
    /// same slot length as every market registered before it, or positions
    /// summed per slot number would mix delivery intervals. The grid is read
    /// from the decoder's `slotStart` of slots 0 and 1, which assumes a linear
    /// grid; the decoder is trusted code. A token has no slot grid, so a funds
    /// move or an approval is not checked against it.
    function setDecoder(address target, bytes4 selector, IOrderDecoder decoder) external onlyAccount nonReentrant {
        if (_isForbiddenTarget(msg.sender, target)) revert DecoderRegistry_ForbiddenTarget(target);
        if (address(decoder) == address(0)) revert DecoderRegistry_ZeroDecoder();

        CallKind kind = decoder.callKind(target, selector);
        if (kind == CallKind.UNKNOWN || kind == CallKind.OPAQUE_FUNDS_MOVE) {
            revert DecoderRegistry_UnregistrableCall(target, selector, kind);
        }
        bool orderCall = _isOrderCall(kind);
        if (orderCall) {
            uint64 origin = decoder.slotStart(target, 0);
            uint64 next = decoder.slotStart(target, 1);
            if (next <= origin || next - origin > type(uint32).max) revert DecoderRegistry_NoSlotGrid(target);
            _fixGrid(msg.sender, origin, uint32(next - origin));
        }

        uint64 generation = generationOf(msg.sender);
        Entry storage entry = _entries[msg.sender][generation][target][selector];
        bool wasOrderCall = address(entry.decoder) != address(0) && _isOrderCall(entry.kind);
        if (orderCall && !wasOrderCall) _orderCalls[msg.sender][generation][target] += 1;
        else if (!orderCall && wasOrderCall) _orderCalls[msg.sender][generation][target] -= 1;

        entry.decoder = decoder;
        entry.kind = kind;
        emit DecoderSet(msg.sender, target, selector, address(decoder), kind);
    }

    /// @notice Withdraw an approval at once. Owner path.
    function removeDecoder(address target, bytes4 selector) external onlyAccount nonReentrant {
        uint64 generation = generationOf(msg.sender);
        Entry storage entry = _entries[msg.sender][generation][target][selector];
        if (address(entry.decoder) != address(0) && _isOrderCall(entry.kind)) {
            _orderCalls[msg.sender][generation][target] -= 1;
        }
        delete _entries[msg.sender][generation][target][selector];
        emit DecoderRemoved(msg.sender, target, selector);
    }

    /// @notice The decoder for a call, or the zero address when the call is
    ///         not allowed.
    function decoderOf(address account, address target, bytes4 selector) public view returns (IOrderDecoder) {
        return _entries[account][generationOf(account)][target][selector].decoder;
    }

    /// @notice The registered kind of a call; UNKNOWN when it is not allowed.
    function kindOf(address account, address target, bytes4 selector) public view returns (CallKind) {
        return _entries[account][generationOf(account)][target][selector].kind;
    }

    /// @notice Whether `target` is a market of the account: it has at least one
    ///         ORDER or CANCEL call registered.
    function isMarket(address account, address target) public view returns (bool) {
        return _orderCalls[account][generationOf(account)][target] != 0;
    }

    /// @dev Fix the account's slot grid, or revert if this one differs.
    function _fixGrid(address account, uint64 origin, uint32 slotSeconds) internal virtual;

    function _isForbiddenTarget(address account, address target) internal view virtual returns (bool) {
        return target == address(0) || target == account || target == address(this);
    }

    function _isOrderCall(CallKind kind) internal pure returns (bool) {
        return kind == CallKind.ORDER || kind == CallKind.CANCEL;
    }
}
