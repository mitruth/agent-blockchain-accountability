// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {WindowLib} from "./WindowLib.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// @title DominatedTradePolicy
/// @notice S7, the dominated-trade budget (spec v0.2 section 5): the value an
///         agent gives away by trading worse than the grid, over a sliding
///         window.
///
/// Within a slot, a BUY above the retail tariff r is dominated, because import
/// at r was there to be had; a SELL below the feed-in tariff f is dominated,
/// because export at f was. Each PLACE leg counts what it gives away at its
/// limit price, the worst case for both sides, rounded up (D12):
///
///   BUY   max(0, price - r) x qtyWh / 1000
///   SELL  max(0, f - price) x qtyWh / 1000
///
/// in settlement-token units, against the signed tariff of the order's slot.
/// The budget is not zero, because the outside option is not always open: the
/// DSO's envelope may cap export, say.
///
/// What it closes: many trades each just inside A3T's tolerance; a transfer to
/// a colluding counterparty outside the [f, r] corridor; an LLM seller under-
/// or over-bidding. What it cannot: a transfer at prices inside the corridor,
/// which looks like any bargain without a market reference. S7 bounds the
/// transfer outside it (stated limitation).
///
/// Counting follows WindowPolicy: at placement, in the bucket of the
/// submission's time (D9); FLAG above the soft bound S; REJECT when the
/// submission does not fit the window's cap L; a submission that adds nothing,
/// such as a cancellation, always passes (D10). With no usable tariff for a
/// placement's slot the submission cannot be judged and is rejected (fail
/// closed).
///
/// Credits (D2). When part of an order is released unfilled, S7 gives back
/// what it charged for that part, to the bucket it was counted in. The tariff
/// may have changed since the placement, so S7 keeps the excess per kWh it
/// charged, keyed by the placement's market, slot, side, price and time, all of
/// which the release carries. Two orders with the same key were judged against
/// the same tariff, so one entry serves both; an entry is never deleted.
contract DominatedTradePolicy is PolicyBase {
    using WindowLib for WindowLib.Window;

    /// @param soft   S: above it, a submission is flagged. At most the cap.
    /// @param window The window; its cap is L. SLIDING in production; the
    ///               other classes are the evaluation's baselines.
    struct Config {
        uint64 soft;
        WindowLib.Config window;
    }

    struct Instance {
        bool set;
        uint64 soft;
    }

    uint256 private constant CONFIG_LENGTH = 8 * 32;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;
    mapping(address account => mapping(bytes32 policyId => WindowLib.Window)) private _windows;
    mapping(address account => mapping(bytes32 policyId => mapping(bytes32 placement => uint64))) private _excess;

    /// @notice The excess per kWh a placement was charged at, kept for its
    ///         credit. Emitted at commit, so the verifier can replay credits.
    event Charged(
        address indexed account, bytes32 indexed policyId, bytes32 indexed placement, uint64 excessPerKWh, uint64 amount
    );

    /// @notice Released volume given back: `amount` asked, `credited` what the
    ///         window still counted of it.
    event Credited(
        address indexed account,
        bytes32 indexed policyId,
        address market,
        bytes32 indexed orderId,
        uint64 amount,
        uint64 credited
    );

    constructor(address gate_) PolicyBase(gate_) {}

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function configOf(address account, bytes32 policyId) external view returns (Config memory c) {
        c.soft = _instances[account][policyId].soft;
        c.window = _windows[account][policyId].config;
    }

    function usedOf(address account, bytes32 policyId) external view returns (uint64 used, uint64 limit) {
        WindowLib.Window storage w = _windows[account][policyId];
        return (w.used(block.timestamp), w.limit(block.timestamp));
    }

    /// @notice The key a placement's excess is kept under.
    function placementKey(address market, uint32 slot, Side side, uint64 price, uint256 placedAt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(market, slot, side, price, placedAt));
    }

    function excessOf(address account, bytes32 policyId, bytes32 placement) external view returns (uint64) {
        return _excess[account][policyId][placement];
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, a window WindowLib refuses, or S above L.
    ///         WIDEN: a higher cap, soft bound, refill or stream rate, or
    ///         stream start; or a change of shape, which starts the window
    ///         afresh and so forgets what was counted.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory next = abi.decode(config, (Config));
        if (!WindowLib.isValid(next.window) || next.soft > next.window.cap) return ConfigChange.INVALID;

        Instance memory inst = _instances[account][policyId];
        if (!inst.set) return ConfigChange.TIGHTEN;

        WindowLib.Config memory w = _windows[account][policyId].config;
        WindowLib.Config memory n = next.window;
        bool restarts = n.kind != w.kind || n.step != w.step || n.buckets != w.buckets || n.anchor != w.anchor;
        bool looser = next.soft > inst.soft || n.cap > w.cap || n.rate > w.rate || n.initial > w.initial;
        return restarts || looser ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        Config memory c = abi.decode(config, (Config));
        _windows[account][policyId].configure(c.window);
        _instances[account][policyId] = Instance({set: true, soft: c.soft});
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        _windows[account][policyId].clear();
        delete _instances[account][policyId];
    }

    // ------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------

    /// @notice The value is what the window counts, before and after; a
    ///         submission that cannot be judged reports `valueAfter` =
    ///         2^256 - 1.
    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        view
        override
        returns (CheckResult memory r)
    {
        WindowLib.Window storage w = _windows[account][policyId];
        r.valueBefore = w.used(ctx.time);
        r.soft = _instances[account][policyId].soft;
        r.hard = w.limit(ctx.time);

        (uint256 amount, bool judged) = _amount(account, legs, ctx);
        if (!judged) {
            r.valueAfter = type(uint256).max;
            r.verdict = Verdict.REJECT;
            return r;
        }
        r.valueAfter = r.valueBefore + amount;
        if (amount == 0) r.verdict = Verdict.EXECUTE;
        else if (amount > type(uint64).max || !w.fits(ctx.time, uint64(amount))) r.verdict = Verdict.REJECT;
        else if (r.valueAfter > r.soft) r.verdict = Verdict.FLAG;
        else r.verdict = Verdict.EXECUTE;
    }

    /// @dev Counts the submission and keeps each placement's excess per kWh.
    ///      Called only after `check` passed, so every placement is judged.
    function commit(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        override
        onlyGate
    {
        uint256 total;
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            if (leg.kind != OrderKind.PLACE) continue;
            (uint64 excess,) = _excessOf(account, leg, ctx);
            if (excess == 0) continue;
            uint64 amount = _valueUp(excess, leg.qtyWh);
            total += amount;
            bytes32 key = placementKey(ctx.market, leg.slot, leg.side, leg.price, ctx.time);
            _excess[account][policyId][key] = excess;
            emit Charged(account, policyId, key, excess, amount);
        }
        if (total != 0) _windows[account][policyId].add(ctx.time, uint64(total));
    }

    /// @dev Gives back what was charged for the order less what its filled
    ///      part was charged, both rounded up as when charged, so never more
    ///      than was charged.
    function credit(address account, bytes32 policyId, Release calldata release) external override onlyGate {
        if (!_instances[account][policyId].set) return;
        bytes32 key = placementKey(release.market, release.slot, release.side, release.price, release.placedAt);
        uint64 excess = _excess[account][policyId][key];
        if (excess == 0) return;
        uint64 amount = _valueUp(excess, release.qtyWh) - _valueUp(excess, release.filledWh);
        if (amount == 0) return;
        uint64 credited = _windows[account][policyId].credit(block.timestamp, release.placedAt, amount);
        emit Credited(account, policyId, release.market, release.orderId, amount, credited);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev What the PLACE legs give away, all together; not judged when a
    ///      placement has no usable tariff.
    function _amount(address account, Order[] calldata legs, CheckContext calldata ctx)
        private
        view
        returns (uint256 amount, bool judged)
    {
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            if (leg.kind != OrderKind.PLACE) continue;
            (uint64 excess, bool usable) = _excessOf(account, leg, ctx);
            if (!usable) return (0, false);
            amount += _valueUp(excess, leg.qtyWh);
        }
        return (amount, true);
    }

    /// @dev How far a placement's price is on the wrong side of the grid's
    ///      price for its slot, per kWh; zero inside the corridor.
    function _excessOf(address account, Order calldata leg, CheckContext calldata ctx)
        private
        view
        returns (uint64 excess, bool usable)
    {
        uint64 start = IOrderDecoder(ctx.decoder).slotStart(ctx.market, leg.slot);
        uint64 retail;
        uint64 feedIn;
        (retail, feedIn, usable) = OracleVerifier(ctx.oracle).tariffAt(account, start);
        if (!usable) return (0, false);
        if (leg.side == Side.BUY) excess = leg.price > retail ? leg.price - retail : 0;
        else excess = feedIn > leg.price ? feedIn - leg.price : 0;
    }

    function _valueUp(uint64 perKWh, uint64 qtyWh) private pure returns (uint64) {
        return uint64((uint256(perKWh) * qtyWh + 999) / 1000);
    }
}
