// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, OrderKind, Side, FillState} from "./GateTypes.sol";

/// @title PositionLedger
/// @notice Every order placed for an account, and the account's positions per
///         delivery slot (spec 5.2).
///
/// Per slot, four quantities in Wh:
///
///   committed buy / sell   placed and not yet released, filled part included
///   cleared buy / sell     filled
///
/// An order is released -- its unfilled part leaves the committed total -- when
/// it is cancelled, when its slot's gate closes, or when the market reports it
/// closed for any other reason. Policies charge exposure on committed volume and
/// credit only cleared volume (spec D3), so everything placed counts until the
/// market says otherwise.
///
/// The ledger is a separate contract, written only by addresses the account
/// itself has authorised. Today that is PolicyGate. If the agent's entry point
/// changes (decision log 1.20), the new entry point is authorised instead and
/// the positions carry over: they are facts about the market, not configuration,
/// so they survive the gate being uninstalled and reinstalled.
///
/// Fills are read through the order's decoder, never supplied by a caller. A
/// fill the ledger has not yet booked leaves the cleared totals low, which errs
/// on the safe side: unfilled buys are never credited.
contract PositionLedger {
    /// @notice Upper bound on one account's open orders. A placement beyond it
    ///         is refused.
    uint256 public constant MAX_OPEN_ORDERS = 64;

    enum Status {
        NONE,
        OPEN,
        CLOSED
    }

    /// @notice Why an order stopped counting as open.
    ///
    ///   FILLED        fully filled; nothing released
    ///   CANCELLED     cancelled through a writer, normally the agent via the gate
    ///   EXPIRED       its slot's gate closed with part of it unfilled
    ///   CLOSED_ELSEWHERE  the market no longer holds it open, before gate
    ///                 closure and not fully filled: cancelled outside the gate
    ///
    /// Only CANCELLED is a cancellation for the cancel quota (spec S6).
    enum CloseReason {
        FILLED,
        CANCELLED,
        EXPIRED,
        CLOSED_ELSEWHERE
    }

    struct Position {
        uint64 committedBuyWh;
        uint64 committedSellWh;
        uint64 clearedBuyWh;
        uint64 clearedSellWh;
    }

    struct OrderRecord {
        IOrderDecoder decoder;
        Status status;
        Side side;
        uint32 slot;
        uint48 placedAt;
        uint64 qtyWh;
        uint64 price;
        uint64 filledWh;
    }

    mapping(address account => mapping(address writer => bool)) public isWriter;
    mapping(address account => uint256) public openOrderCount;

    mapping(address account => mapping(uint32 slot => Position)) private _positions;
    mapping(address account => mapping(address market => mapping(bytes32 orderId => OrderRecord))) private _records;

    event WriterSet(address indexed account, address indexed writer, bool allowed);
    event OrderOpened(
        address indexed account,
        address indexed market,
        bytes32 indexed orderId,
        Side side,
        uint32 slot,
        uint64 qtyWh,
        uint64 price,
        uint48 placedAt
    );
    event FillBooked(
        address indexed account, address indexed market, bytes32 indexed orderId, uint64 filledWh, uint64 totalFilledWh
    );
    event OrderClosed(
        address indexed account, address indexed market, bytes32 indexed orderId, CloseReason reason, uint64 releasedWh
    );

    error PositionLedger_NotWriter(address account, address caller);
    error PositionLedger_NotAPlacement();
    error PositionLedger_ZeroQuantity();
    error PositionLedger_AlreadyRecorded(address market, bytes32 orderId);
    error PositionLedger_TooManyOpenOrders(address account);
    error PositionLedger_NotOpen(address market, bytes32 orderId);
    error PositionLedger_InconsistentFill(bytes32 orderId, uint64 booked, uint64 reported, uint64 qtyWh);

    modifier onlyWriter(address account) {
        if (!isWriter[account][msg.sender]) revert PositionLedger_NotWriter(account, msg.sender);
        _;
    }

    // ------------------------------------------------------------------
    // The account: who may write its positions
    // ------------------------------------------------------------------

    /// @notice Authorise or withdraw a writer for the calling account. Owner
    ///         path: the caller is the account.
    function setWriter(address writer, bool allowed) external {
        isWriter[msg.sender][writer] = allowed;
        emit WriterSet(msg.sender, writer, allowed);
    }

    // ------------------------------------------------------------------
    // Writers
    // ------------------------------------------------------------------

    /// @notice Book a placement the market has accepted.
    function recordPlace(address account, address market, IOrderDecoder decoder, bytes32 orderId, Order calldata leg)
        external
        onlyWriter(account)
    {
        if (leg.kind != OrderKind.PLACE) revert PositionLedger_NotAPlacement();
        if (leg.qtyWh == 0) revert PositionLedger_ZeroQuantity();

        OrderRecord storage record = _records[account][market][orderId];
        if (record.status != Status.NONE) revert PositionLedger_AlreadyRecorded(market, orderId);
        if (openOrderCount[account] >= MAX_OPEN_ORDERS) revert PositionLedger_TooManyOpenOrders(account);

        uint48 placedAt = uint48(block.timestamp);
        _records[account][market][orderId] = OrderRecord({
            decoder: decoder,
            status: Status.OPEN,
            side: leg.side,
            slot: leg.slot,
            placedAt: placedAt,
            qtyWh: leg.qtyWh,
            price: leg.price,
            filledWh: 0
        });
        openOrderCount[account] += 1;

        Position storage position = _positions[account][leg.slot];
        if (leg.side == Side.BUY) {
            position.committedBuyWh += leg.qtyWh;
        } else {
            position.committedSellWh += leg.qtyWh;
        }

        emit OrderOpened(account, market, orderId, leg.side, leg.slot, leg.qtyWh, leg.price, placedAt);
    }

    /// @notice Book a cancellation the market has carried out: fills since the
    ///         last booking are cleared, the unfilled rest is released.
    /// @return releasedWh The unfilled quantity that left the committed total.
    function recordCancel(address account, address market, bytes32 orderId)
        external
        onlyWriter(account)
        returns (uint64 releasedWh)
    {
        OrderRecord storage record = _openRecord(account, market, orderId);
        _bookFills(account, market, orderId, record);
        releasedWh = _close(account, market, orderId, record, CloseReason.CANCELLED);
    }

    /// @notice Bring one order up to date with the market.
    ///
    /// Books any new fill. Then closes the order if it is fully filled, if its
    /// slot's gate has closed (the unfilled rest expires and is released), or if
    /// the market no longer holds it open. Otherwise it stays open.
    ///
    /// @return filledWh   Newly booked fill.
    /// @return releasedWh Unfilled quantity released, if the order closed.
    function reconcile(address account, address market, bytes32 orderId)
        external
        onlyWriter(account)
        returns (uint64 filledWh, uint64 releasedWh)
    {
        OrderRecord storage record = _openRecord(account, market, orderId);
        FillState memory state;
        (filledWh, state) = _bookFills(account, market, orderId, record);

        if (record.filledWh == record.qtyWh) {
            releasedWh = _close(account, market, orderId, record, CloseReason.FILLED);
        } else if (block.timestamp >= record.decoder.gateTime(market, record.slot)) {
            releasedWh = _close(account, market, orderId, record, CloseReason.EXPIRED);
        } else if (!state.open) {
            releasedWh = _close(account, market, orderId, record, CloseReason.CLOSED_ELSEWHERE);
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function positionOf(address account, uint32 slot) external view returns (Position memory) {
        return _positions[account][slot];
    }

    function recordOf(address account, address market, bytes32 orderId) external view returns (OrderRecord memory) {
        return _records[account][market][orderId];
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _openRecord(address account, address market, bytes32 orderId)
        private
        view
        returns (OrderRecord storage record)
    {
        record = _records[account][market][orderId];
        if (record.status != Status.OPEN) revert PositionLedger_NotOpen(market, orderId);
    }

    /// @dev Reads the market's fill through the decoder and moves anything new
    ///      into the cleared total. A fill that goes backwards, or past the
    ///      order's quantity, means the market or its decoder is broken: stop.
    function _bookFills(address account, address market, bytes32 orderId, OrderRecord storage record)
        private
        returns (uint64 filledWh, FillState memory state)
    {
        state = record.decoder.fillState(market, orderId);
        if (state.filledWh < record.filledWh || state.filledWh > record.qtyWh) {
            revert PositionLedger_InconsistentFill(orderId, record.filledWh, state.filledWh, record.qtyWh);
        }

        filledWh = state.filledWh - record.filledWh;
        if (filledWh == 0) return (0, state);

        record.filledWh = state.filledWh;
        Position storage position = _positions[account][record.slot];
        if (record.side == Side.BUY) {
            position.clearedBuyWh += filledWh;
        } else {
            position.clearedSellWh += filledWh;
        }
        emit FillBooked(account, market, orderId, filledWh, state.filledWh);
    }

    function _close(
        address account,
        address market,
        bytes32 orderId,
        OrderRecord storage record,
        CloseReason reason
    ) private returns (uint64 releasedWh) {
        releasedWh = record.qtyWh - record.filledWh;
        record.status = Status.CLOSED;
        openOrderCount[account] -= 1;

        if (releasedWh != 0) {
            Position storage position = _positions[account][record.slot];
            if (record.side == Side.BUY) {
                position.committedBuyWh -= releasedWh;
            } else {
                position.committedSellWh -= releasedWh;
            }
        }
        emit OrderClosed(account, market, orderId, reason, releasedWh);
    }
}
