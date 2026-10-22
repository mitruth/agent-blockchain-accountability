// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Order, FillState, CallKind} from "../gate/GateTypes.sol";

/// @title IOrderDecoder
/// @notice The one adapter between this system and an approved market. It
///         reads the market's calls into Orders and the market's views into
///         fill state and gate times.
///
/// One decoder per approved market contract, registered by the owner. A decoder
/// is trusted, audited code: the policies check the Orders it returns and the
/// ledger books the fills it reports, so a decoder that misreads the market is a
/// policy bypass.
///
/// Every function is a view, so a decoder can change no state. Anything an
/// order does not carry itself -- the remaining quantity of an order being
/// cancelled, its fills, its gate time -- is read from the market, never taken
/// from the agent.
///
/// A decoder also classifies every call it is registered for (spec v0.2
/// section 11.2, A9): an order, a cancellation, a funds move with its
/// recipient, or an approval with its spender. A call that can move funds is
/// registered only if the decoder can expose who receives them.
interface IOrderDecoder {
    /// @notice What `selector` of `target` is. UNKNOWN and OPAQUE_FUNDS_MOVE
    ///         calls are never registered.
    function callKind(address target, bytes4 selector) external view returns (CallKind);

    /// @notice For a FUNDS_MOVE, who receives the funds and how much; for an
    ///         APPROVAL, the spender and the amount allowed. Called only for
    ///         calls of those kinds.
    function fundsMove(address target, bytes calldata callData)
        external
        view
        returns (address counterparty, uint256 amount);

    /// @notice What the call does, as legs.
    ///
    ///   place    one PLACE leg per order placed; a batch is several. A
    ///            PLACE leg's orderId is zero until the call has run
    ///   cancel   one CANCEL leg for the quantity still unfilled
    ///   modify   a CANCEL leg for the old order, then a PLACE leg for the new
    ///            one: an atomic cancel plus place (spec 5.1)
    ///
    /// @param market   The market contract the call is addressed to.
    /// @param callData The full calldata, selector included.
    function decode(address market, bytes calldata callData) external view returns (Order[] memory legs);

    /// @notice The ids the market gave the orders this call placed, read from
    ///         the market's return data, in the order of the PLACE legs.
    ///         Called only for calls with at least one PLACE leg.
    function placedOrderIds(address market, bytes calldata callData, bytes calldata result)
        external
        view
        returns (bytes32[] memory orderIds);

    /// @notice How much of an order has filled, whether it can still fill, and
    ///         whether it ended unmatched when its session closed.
    function fillState(address market, bytes32 orderId) external view returns (FillState memory);

    /// @notice When trading in `slot` closes. No order for the slot can be
    ///         placed, changed or filled from this time on.
    function gateTime(address market, uint32 slot) external view returns (uint64);

    /// @notice When delivery in `slot` starts, in seconds. Policies read the
    ///         time of day and the horizon of an order from it.
    function slotStart(address market, uint32 slot) external view returns (uint64);
}
