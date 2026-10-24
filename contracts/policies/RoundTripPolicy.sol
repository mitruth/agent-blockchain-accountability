// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {WindowLib} from "./WindowLib.sol";
import {IGateLedger} from "./HorizonLib.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// @title RoundTripPolicy
/// @notice S8, the same-slot round-trip quota (spec v0.2 section 5): buying
///         and selling the same delivery slot, over a sliding window, in Wh.
///
/// An account that has both bought and sold energy for one slot has traded a
/// round trip: the volume it holds on both sides, rt(t) = min(committed buy,
/// committed sell). It is the wash and churn pattern REMIT forbids; it also
/// drains fees and inflates the volume an agent shows. Every order of it can be
/// legal on its own.
///
/// The positions are the ledger's, summed over every market of the account on
/// one slot grid (C4): buying on one venue and selling on another is one
/// round trip.
///
/// A submission counts what it adds to the round trips of the slots it
/// touches: for each, the change of min(buy, sell) when its placements are
/// added and its cancellations taken away, where positive, summed over the
/// slots. A cancellation or a reduction adds nothing and always passes (D10).
///
/// Counting follows WindowPolicy: at placement, in the bucket of the
/// submission's time (D9); FLAG above the soft bound S; REJECT when the
/// submission does not fit the cap H. There are no credits: a round trip
/// counts when it is created, even if it is released later, as for S6. Simple,
/// and conservative.
contract RoundTripPolicy is PolicyBase {
    using WindowLib for WindowLib.Window;

    /// @param soft   S, in Wh. At most the cap.
    /// @param window The window; its cap is H, in Wh. SLIDING with a bucket of
    ///               one slot in production; the other classes are the
    ///               evaluation's baselines.
    struct Config {
        uint64 soft;
        WindowLib.Config window;
    }

    struct Instance {
        bool set;
        uint64 soft;
    }

    uint256 private constant CONFIG_LENGTH = 8 * 32;

    PositionLedger public immutable ledger;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;
    mapping(address account => mapping(bytes32 policyId => WindowLib.Window)) private _windows;

    constructor(address gate_) PolicyBase(gate_) {
        ledger = IGateLedger(gate_).ledger();
    }

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

    /// @notice What a submission of `legs` adds to the account's round trips,
    ///         in Wh, against the ledger as it stands.
    function roundTripAdded(address account, Order[] calldata legs) public view returns (uint256 added) {
        uint256 n = legs.length;
        uint32[] memory slots = new uint32[](n);
        int256[] memory buy = new int256[](n);
        int256[] memory sell = new int256[](n);
        uint256 distinct;
        for (uint256 i = 0; i < n; ++i) {
            Order calldata leg = legs[i];
            uint256 k = 0;
            while (k < distinct && slots[k] != leg.slot) ++k;
            if (k == distinct) slots[distinct++] = leg.slot;
            int256 qty = leg.kind == OrderKind.PLACE ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));
            if (leg.side == Side.BUY) buy[k] += qty;
            else sell[k] += qty;
        }
        for (uint256 k = 0; k < distinct; ++k) {
            PositionLedger.Position memory p = ledger.positionOf(account, slots[k]);
            int256 b = int256(uint256(p.committedBuyWh));
            int256 s = int256(uint256(p.committedSellWh));
            int256 before = b < s ? b : s;
            int256 b2 = b + buy[k];
            int256 s2 = s + sell[k];
            int256 after_ = b2 < s2 ? b2 : s2;
            if (after_ > before) added += uint256(after_ - before);
        }
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, a window WindowLib refuses, or S above H.
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

    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        view
        override
        returns (CheckResult memory r)
    {
        WindowLib.Window storage w = _windows[account][policyId];
        uint256 amount = roundTripAdded(account, legs);
        r.valueBefore = w.used(ctx.time);
        r.valueAfter = r.valueBefore + amount;
        r.soft = _instances[account][policyId].soft;
        r.hard = w.limit(ctx.time);

        if (amount == 0) r.verdict = Verdict.EXECUTE;
        else if (amount > type(uint64).max || !w.fits(ctx.time, uint64(amount))) r.verdict = Verdict.REJECT;
        else if (r.valueAfter > r.soft) r.verdict = Verdict.FLAG;
        else r.verdict = Verdict.EXECUTE;
    }

    /// @dev Called before the ledger books the legs, so the ledger still
    ///      holds what `check` read.
    function commit(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        override
        onlyGate
    {
        uint256 amount = roundTripAdded(account, legs);
        if (amount != 0) _windows[account][policyId].add(ctx.time, uint64(amount));
    }

    /// @dev No credits: a round trip counts when created.
    function credit(address, bytes32, Release calldata) external override onlyGate {}
}
