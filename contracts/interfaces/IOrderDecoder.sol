// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Order, FillState} from "../gate/GateTypes.sol";

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
interface IOrderDecoder {
    /// @notice What the call does, as one or two legs.
    ///
    ///   place    one PLACE leg; its orderId is zero until the call has run
    ///   cancel   one CANCEL leg for the quantity still unfilled
    ///   modify   a CANCEL leg for the old order, then a PLACE leg for the new
    ///            one: an atomic cancel plus place (spec 5.1)
    ///
    /// @param market   The market contract the call is addressed to.
    /// @param callData The full calldata, selector included.
    function decode(address market, bytes calldata callData) external view returns (Order[] memory legs);

    /// @notice The id the market gave the order this call placed, read from
    ///         the market's return data. Called only for calls with a PLACE leg.
    function placedOrderId(address market, bytes calldata callData, bytes calldata result)
        external
        view
        returns (bytes32 orderId);

    /// @notice How much of an order has filled, and whether it can still fill.
    function fillState(address market, bytes32 orderId) external view returns (FillState memory);

    /// @notice When trading in `slot` closes. No order for the slot can be
    ///         placed, changed or filled from this time on.
    function gateTime(address market, uint32 slot) external view returns (uint64);
}
