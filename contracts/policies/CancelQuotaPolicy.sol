// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {WindowLib} from "./WindowLib.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {Order, OrderKind, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// @title CancelQuotaPolicy
/// @notice S6, the cancellation and message quota (spec 6.7): against
///         spoofing and headroom reservation, placing orders only to cancel
///         them, above all just before the gate closes.
///
/// Three windows per instance, of one shape (spec default: an hour of
/// five-minute buckets):
///
///   cancelled Wh  every CANCEL leg, weighted: w_g times its quantity if the
///                 cancellation comes within δ_g of the slot's gate closure,
///                 once otherwise. cancelled <= C_max
///   placed Wh     every PLACE leg. cancelled <= ρ x placed + c0: the free
///                 allowance c0 lets a first cancellation through, and the
///                 multiplication avoids a division
///   messages      every submission. messages <= M_max
///
/// Expiries never count: an order the market expires is never checked, and
/// this policy's credit does nothing. A cancellation adds to this policy's
/// own quantity, so for S6 it is not exposure-reducing (D10 does not exempt
/// it).
///
/// The result reports the cancelled-Wh window. Which of the three rules a
/// rejected submission broke is given by `reasons`.
contract CancelQuotaPolicy is PolicyBase {
    using WindowLib for WindowLib.Window;

    uint256 public constant CANCELLED_CAP = 1;
    uint256 public constant RATIO = 2;
    uint256 public constant MESSAGES = 4;

    /// @param window             The shape of the three windows. Its cap,
    ///                           rate and initial are not used.
    /// @param maxCancelledWh     C_max, weighted Wh.
    /// @param maxMessages        M_max, submissions.
    /// @param gateWeightPercent  w_g, in percent: 300 counts a cancellation
    ///                           near the gate three times. At least 100.
    /// @param gateWindowSeconds  δ_g, how long before the gate closes a
    ///                           cancellation is weighted.
    /// @param ratioPercent       ρ_max, in percent of the placed Wh.
    /// @param freeCancelWh       c0.
    struct Config {
        WindowLib.Config window;
        uint64 maxCancelledWh;
        uint64 maxMessages;
        uint32 gateWeightPercent;
        uint32 gateWindowSeconds;
        uint32 ratioPercent;
        uint64 freeCancelWh;
    }

    struct Instance {
        bool set;
        uint64 maxCancelledWh;
        uint64 maxMessages;
        uint32 gateWeightPercent;
        uint32 gateWindowSeconds;
        uint32 ratioPercent;
        uint64 freeCancelWh;
    }

    struct Windows {
        WindowLib.Window cancelled;
        WindowLib.Window placed;
        WindowLib.Window messages;
    }

    uint256 private constant CONFIG_LENGTH = 13 * 32;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;
    mapping(address account => mapping(bytes32 policyId => Windows)) private _windows;

    constructor(address gate_) PolicyBase(gate_) {}

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function isConfigured(address account, bytes32 policyId) external view returns (bool) {
        return _instances[account][policyId].set;
    }

    /// @notice What the three windows count now.
    function usedOf(address account, bytes32 policyId)
        external
        view
        returns (uint64 cancelledWh, uint64 placedWh, uint64 messages)
    {
        Windows storage w = _windows[account][policyId];
        return (w.cancelled.used(block.timestamp), w.placed.used(block.timestamp), w.messages.used(block.timestamp));
    }

    /// @notice Which rules a submission of `legs` would break, as a bitmask of
    ///         CANCELLED_CAP, RATIO and MESSAGES. Zero when none.
    function reasons(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        public
        view
        returns (uint256 broken)
    {
        Instance memory inst = _instances[account][policyId];
        Windows storage w = _windows[account][policyId];
        (uint256 cancelling, uint256 placing) = _amounts(inst, legs, ctx);
        uint256 t = ctx.time;

        uint256 cancelled = uint256(w.cancelled.used(t)) + cancelling;
        if (cancelled > inst.maxCancelledWh) broken |= CANCELLED_CAP;

        if (cancelling != 0) {
            uint256 placed = uint256(w.placed.used(t)) + placing;
            if (cancelled * 100 > uint256(inst.ratioPercent) * placed + uint256(inst.freeCancelWh) * 100) {
                broken |= RATIO;
            }
        }

        if (uint256(w.messages.used(t)) + 1 > inst.maxMessages) broken |= MESSAGES;
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, a window WindowLib refuses, or a gate
    ///         weight below 100%. WIDEN: a higher C_max, M_max, ρ or c0, a
    ///         lower w_g, a shorter δ_g, or a change of window shape, which
    ///         starts the windows afresh.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (!WindowLib.isValid(n.window) || n.gateWeightPercent < 100) return ConfigChange.INVALID;

        Instance memory c = _instances[account][policyId];
        if (!c.set) return ConfigChange.TIGHTEN;

        WindowLib.Config memory w = _windows[account][policyId].cancelled.config;
        bool restarts = n.window.kind != w.kind || n.window.step != w.step || n.window.buckets != w.buckets
            || n.window.anchor != w.anchor;
        bool looser = n.maxCancelledWh > c.maxCancelledWh || n.maxMessages > c.maxMessages
            || n.gateWeightPercent < c.gateWeightPercent || n.gateWindowSeconds < c.gateWindowSeconds
            || n.ratioPercent > c.ratioPercent || n.freeCancelWh > c.freeCancelWh;
        return restarts || looser ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        Config memory c = abi.decode(config, (Config));
        Windows storage w = _windows[account][policyId];
        // The bounds are the instance's; the windows count, with no cap of their own.
        WindowLib.Config memory shape = c.window;
        shape.cap = type(uint64).max;
        shape.rate = 0;
        shape.initial = 0;
        w.cancelled.configure(shape);
        w.placed.configure(shape);
        w.messages.configure(shape);
        _instances[account][policyId] = Instance({
            set: true,
            maxCancelledWh: c.maxCancelledWh,
            maxMessages: c.maxMessages,
            gateWeightPercent: c.gateWeightPercent,
            gateWindowSeconds: c.gateWindowSeconds,
            ratioPercent: c.ratioPercent,
            freeCancelWh: c.freeCancelWh
        });
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        Windows storage w = _windows[account][policyId];
        w.cancelled.clear();
        w.placed.clear();
        w.messages.clear();
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
        Instance memory inst = _instances[account][policyId];
        (uint256 cancelling,) = _amounts(inst, legs, ctx);
        r.valueBefore = _windows[account][policyId].cancelled.used(ctx.time);
        r.valueAfter = r.valueBefore + cancelling;
        r.soft = inst.maxCancelledWh;
        r.hard = inst.maxCancelledWh;
        r.verdict = reasons(account, policyId, legs, ctx) == 0 ? Verdict.EXECUTE : Verdict.REJECT;
    }

    function commit(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        override
        onlyGate
    {
        (uint256 cancelling, uint256 placing) = _amounts(_instances[account][policyId], legs, ctx);
        Windows storage w = _windows[account][policyId];
        w.messages.add(ctx.time, 1);
        if (cancelling != 0) w.cancelled.add(ctx.time, uint64(cancelling));
        if (placing != 0) w.placed.add(ctx.time, uint64(placing));
    }

    /// @dev Expiries are not cancellations (spec 6.7): nothing to give back.
    function credit(address, bytes32, Release calldata) external override onlyGate {}

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev The weighted Wh cancelled and the Wh placed by `legs`. A weighted
    ///      quantity rounds up (D12).
    function _amounts(Instance memory inst, Order[] calldata legs, CheckContext calldata ctx)
        private
        view
        returns (uint256 cancelling, uint256 placing)
    {
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            if (leg.kind == OrderKind.PLACE) {
                placing += leg.qtyWh;
            } else if (leg.kind == OrderKind.CANCEL) {
                uint64 gateTime = IOrderDecoder(ctx.decoder).gateTime(ctx.market, leg.slot);
                bool nearGate = uint256(ctx.time) + inst.gateWindowSeconds >= gateTime;
                uint256 weight = nearGate ? inst.gateWeightPercent : 100;
                cancelling += (uint256(leg.qtyWh) * weight + 99) / 100;
            }
        }
    }
}
