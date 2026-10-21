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
///
/// Positions are summed over every market the account trades on (spec v0.2,
/// C4): a slot's totals hold the orders of all venues, so S3 and S5 -- and every
/// policy that reads positions -- judge the account's whole position, not one
/// venue's. That is only sound if a slot number means the same delivery
/// interval on every market. So each account has one slot grid, an origin and a
/// slot length, fixed by the first market registered for it; a market on any
/// other grid is refused at registration (D15, extended to the origin on
/// 21 October 2026). The grid is kept here, not in the gate, because the
/// positions outlive a reinstall of the gate, and so must the grid they are
/// numbered on. It never changes.
contract PositionLedger {
    /// @notice Upper bound on one account's open orders. A placement beyond it
    ///         is refused.
    uint256 public constant MAX_OPEN_ORDERS = 64;

    /// @notice An account's slot grid: slot n starts at origin + n × slotSeconds.
    struct Grid {
        uint64 origin;
        uint32 slotSeconds;
    }

    enum Status {
        NONE,
        OPEN,
        CLOSED
    }

    /// @notice Why an order stopped counting as open.
    ///
    ///   FILLED        fully filled; nothing released
    ///   CANCELLED     cancelled through a writer, normally the agent via the gate
    ///   EXPIRED       its session or slot closed with part of it unfilled,
    ///                 as the market reports
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

    mapping(address account => Grid) private _grids;

    mapping(address account => mapping(uint32 slot => Position)) private _positions;
    mapping(address account => mapping(address market => mapping(bytes32 orderId => OrderRecord))) private _records;

    event WriterSet(address indexed account, address indexed writer, bool allowed);
    event GridFixed(address indexed account, uint64 origin, uint32 slotSeconds);
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
    error PositionLedger_ZeroSlotLength();
    error PositionLedger_OffGrid(uint64 origin, uint32 slotSeconds, uint64 accountOrigin, uint32 accountSlotSeconds);

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

    /// @notice Check a market's grid against the account's, fixing the
    ///         account's grid on the first call. Reverts when the market is on
    ///         another grid: another origin or another slot length.
    function fixGrid(address account, uint64 origin, uint32 slotSeconds) external onlyWriter(account) {
        if (slotSeconds == 0) revert PositionLedger_ZeroSlotLength();
        Grid storage grid = _grids[account];
        if (grid.slotSeconds == 0) {
            grid.origin = origin;
            grid.slotSeconds = slotSeconds;
            emit GridFixed(account, origin, slotSeconds);
        } else if (grid.origin != origin || grid.slotSeconds != slotSeconds) {
            revert PositionLedger_OffGrid(origin, slotSeconds, grid.origin, grid.slotSeconds);
        }
    }

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
    /// Books any new fill. Then closes the order if it is fully filled, if the
    /// market reports it expired (its session or slot closed with part
    /// unmatched: the rest is released), or if the market no longer holds it
    /// open for another reason. Otherwise it stays open.
    ///
    /// Expiry is the market's word, not the clock's: in a market that matches
    /// after trading closes, an order is not over at gate closure but when the
    /// session is finalised.
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
        } else if (state.expired) {
            releasedWh = _close(account, market, orderId, record, CloseReason.EXPIRED);
        } else if (!state.open) {
            releasedWh = _close(account, market, orderId, record, CloseReason.CLOSED_ELSEWHERE);
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The account's slot grid; a zero slot length while none is fixed.
    function gridOf(address account) external view returns (Grid memory) {
        return _grids[account];
    }

    function positionOf(address account, uint32 slot) external view returns (Position memory) {
        return _positions[account][slot];
    }

    /// @notice The positions of `count` consecutive slots from `firstSlot`, in
    ///         one call: what a policy looking over a horizon reads.
    function positionsOf(address account, uint32 firstSlot, uint256 count)
        external
        view
        returns (Position[] memory positions)
    {
        positions = new Position[](count);
        for (uint256 i = 0; i < count; ++i) {
            positions[i] = _positions[account][uint32(firstSlot + i)];
        }
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
