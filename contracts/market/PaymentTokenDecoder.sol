// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, FillState, CallKind} from "../gate/GateTypes.sol";
import {LockableERC1155} from "./LockableERC1155.sol";

/// @title PaymentTokenDecoder
/// @notice Reads the market token's calls for the recipient lock (spec v0.2
///         section 11.2, A9). The token is no market: no call of it is an
///         order. What it can do is move the account's funds or let someone
///         else move them, and A9 judges exactly that.
///
///   safeTransferFrom, safeBatchTransferFrom   FUNDS_MOVE to `to`
///   unlock                                    FUNDS_MOVE to `recipient`, or
///                                             back to `owner` when zero
///   unlockAll                                 FUNDS_MOVE back to `owner`
///   setPaymentAllowance, setApprovalForAll    APPROVAL of `operator`
///   lock                                      OPAQUE_FUNDS_MOVE: the lock names
///                                             an unlocker, who may later pay it
///                                             to anyone; no recipient here
///   anything else                             UNKNOWN
///
/// The gate refuses to register OPAQUE_FUNDS_MOVE and UNKNOWN calls, so the
/// agent can never lock the account's funds under its own key, burn its
/// energy tokens, or reach the token's roles.
contract PaymentTokenDecoder is IOrderDecoder {
    error PaymentTokenDecoder_NotAnOrder();
    error PaymentTokenDecoder_NotAFundsMove(bytes4 selector);

    /// @inheritdoc IOrderDecoder
    function callKind(address, bytes4 selector) external pure override returns (CallKind) {
        if (
            selector == IERC1155.safeTransferFrom.selector || selector == IERC1155.safeBatchTransferFrom.selector
                || selector == LockableERC1155.unlock.selector || selector == LockableERC1155.unlockAll.selector
        ) return CallKind.FUNDS_MOVE;
        if (selector == LockableERC1155.setPaymentAllowance.selector || selector == IERC1155.setApprovalForAll.selector) {
            return CallKind.APPROVAL;
        }
        if (selector == LockableERC1155.lock.selector) return CallKind.OPAQUE_FUNDS_MOVE;
        return CallKind.UNKNOWN;
    }

    /// @inheritdoc IOrderDecoder
    function fundsMove(address, bytes calldata callData)
        external
        pure
        override
        returns (address counterparty, uint256 amount)
    {
        bytes4 selector = bytes4(callData[:4]);
        if (selector == IERC1155.safeTransferFrom.selector) {
            (, address to,, uint256 value,) = abi.decode(callData[4:], (address, address, uint256, uint256, bytes));
            return (to, value);
        }
        if (selector == IERC1155.safeBatchTransferFrom.selector) {
            (, address to,, uint256[] memory values,) =
                abi.decode(callData[4:], (address, address, uint256[], uint256[], bytes));
            for (uint256 i = 0; i < values.length; ++i) {
                amount += values[i];
            }
            return (to, amount);
        }
        if (selector == LockableERC1155.unlock.selector) {
            (address owner,, uint256 value, address recipient) =
                abi.decode(callData[4:], (address, address, uint256, address));
            return (recipient == address(0) ? owner : recipient, value);
        }
        if (selector == LockableERC1155.unlockAll.selector) {
            (address owner,) = abi.decode(callData[4:], (address, address));
            return (owner, 0);
        }
        if (selector == LockableERC1155.setPaymentAllowance.selector) {
            (address operator, uint256 value) = abi.decode(callData[4:], (address, uint256));
            return (operator, value);
        }
        if (selector == IERC1155.setApprovalForAll.selector) {
            (address operator, bool approved) = abi.decode(callData[4:], (address, bool));
            return (operator, approved ? type(uint256).max : 0);
        }
        revert PaymentTokenDecoder_NotAFundsMove(selector);
    }

    // ------------------------------------------------------------------
    // No call of the token is an order
    // ------------------------------------------------------------------

    function decode(address, bytes calldata) external pure override returns (Order[] memory) {
        revert PaymentTokenDecoder_NotAnOrder();
    }

    function placedOrderIds(address, bytes calldata, bytes calldata) external pure override returns (bytes32[] memory) {
        revert PaymentTokenDecoder_NotAnOrder();
    }

    function fillState(address, bytes32) external pure override returns (FillState memory) {
        revert PaymentTokenDecoder_NotAnOrder();
    }

    function gateTime(address, uint32) external pure override returns (uint64) {
        revert PaymentTokenDecoder_NotAnOrder();
    }

    function slotStart(address, uint32) external pure override returns (uint64) {
        revert PaymentTokenDecoder_NotAnOrder();
    }
}
