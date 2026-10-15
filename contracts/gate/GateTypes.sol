// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Shared types for PolicyGate, the decoders and the policy contracts
///         (docs/spec/policy-spec-v0.1.md, sections 5.1 and 5.6).

enum OrderKind {
    PLACE,
    CANCEL,
    MODIFY
}

enum Side {
    BUY,
    SELL
}

/// @notice What an agent's call means, as a decoder reads it from the calldata.
///         Policies see this and never the raw calldata.
/// @param slot    Delivery slot index, as the market numbers it.
/// @param qtyWh   Energy in Wh.
/// @param price   Limit price, settlement-token units per kWh.
/// @param value   qtyWh at the limit price, in settlement-token units.
/// @param orderId The market's id for the order; zero when placing.
struct Order {
    OrderKind kind;
    Side side;
    uint32 slot;
    uint64 qtyWh;
    uint64 price;
    uint64 value;
    bytes32 orderId;
}

/// @notice An order's progress on the market, as the decoder reads it.
/// @param filledWh    Filled so far, in Wh.
/// @param remainingWh Still able to fill: zero once the order is cancelled,
///                    fully filled, or past its slot's gate closure.
/// @param open        Whether the market still holds the order live.
/// @param expired     The order ended because its session or slot closed,
///                    with part of it unmatched. Not set for a cancellation.
struct FillState {
    uint64 filledWh;
    uint64 remainingWh;
    bool open;
    bool expired;
}

/// @notice How a proposed configuration compares with the one in force.
///         A policy classifies; the gate decides when it applies.
enum ConfigChange {
    INVALID,
    TIGHTEN,
    WIDEN
}

/// @notice A policy's verdict on one submission (spec 5.5): within the soft
///         bound, between the soft and the hard bound, or beyond the hard one.
enum Verdict {
    EXECUTE,
    FLAG,
    REJECT
}

/// @notice What a policy reports about a submission: its own quantity before
///         and after the submission, its soft and hard bounds, and its verdict.
///         Units are the policy's: Wh, token units, a count.
struct CheckResult {
    uint256 valueBefore;
    uint256 valueAfter;
    uint256 soft;
    uint256 hard;
    Verdict verdict;
}

/// @notice What a policy may read about a submission besides its legs.
/// @param market  The target of the call.
/// @param decoder The decoder registered for the call (an IOrderDecoder): its
///                views give a slot's start and gate time.
/// @param time    The block time of the submission.
struct CheckContext {
    address market;
    address decoder;
    uint64 time;
}

/// @notice Volume an order no longer exposes: an order closed by a
///         cancellation, an expiry, or the market, with part of it unfilled.
///         Policies give back what they charged for that part.
/// @param releasedWh The unfilled part, released.
struct Release {
    address market;
    bytes32 orderId;
    Side side;
    uint32 slot;
    uint48 placedAt;
    uint64 qtyWh;
    uint64 price;
    uint64 filledWh;
    uint64 releasedWh;
}

/// @notice `qtyWh` at `price` per kWh, in token units, rounded up (spec D12):
///         a cap counts at least the true value.
function valueUp(uint64 qtyWh, uint64 price) pure returns (uint256) {
    return (uint256(qtyWh) * price + 999) / 1000;
}
