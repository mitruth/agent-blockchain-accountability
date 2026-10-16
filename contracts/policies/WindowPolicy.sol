// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {WindowLib} from "./WindowLib.sol";
import {
    Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release, valueUp
} from "../gate/GateTypes.sol";

/// @title WindowPolicy
/// @notice Sequence bounds over a window of orders (spec 6.2, 6.3), one
///         quantity per instance:
///
///   BUY_VALUE  S1, the owner's budget: the value of BUY orders at their
///              limit price, gross. A sale never refills it, or
///              sell-and-rebuy would (audit finding F3)
///   SELL_WH    S2, the export cap: Wh offered
///   BUY_WH     S2, the import cap: Wh bid
///
/// Each instance counts on a WindowLib window. Its cap is the hard bound H;
/// `soft` is the soft bound S. SLIDING is what the owner uses; the other four
/// classes are the evaluation's baselines, under the same policy and the same
/// decoder (spec 5.3).
///
/// An order is counted when it is placed (spec D9): in the bucket of the
/// submission's time, whatever its delivery slot. When part of it is released
/// unfilled -- cancelled, expired, or closed by the market -- that part is
/// credited back to the bucket it was counted in, if the window still counts
/// that bucket (D2). A submission that adds nothing to the quantity, such as a
/// cancellation, is never rejected (D10).
contract WindowPolicy is PolicyBase {
    using WindowLib for WindowLib.Window;

    enum Quantity {
        BUY_VALUE,
        SELL_WH,
        BUY_WH
    }

    /// @param quantity What the instance counts.
    /// @param soft     S: above it, a submission is flagged. At most the cap.
    /// @param window   The window; its cap is H.
    struct Config {
        Quantity quantity;
        uint64 soft;
        WindowLib.Config window;
    }

    struct Instance {
        bool set;
        Quantity quantity;
        uint64 soft;
    }

    uint256 private constant CONFIG_LENGTH = 9 * 32;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;
    mapping(address account => mapping(bytes32 policyId => WindowLib.Window)) private _windows;

    /// @notice Released volume given back to the window: `amount` asked,
    ///         `credited` what the window still counted of it.
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
        Instance memory inst = _instances[account][policyId];
        c.quantity = inst.quantity;
        c.soft = inst.soft;
        c.window = _windows[account][policyId].config;
    }

    function isConfigured(address account, bytes32 policyId) external view returns (bool) {
        return _instances[account][policyId].set;
    }

    /// @notice What the window counts now, and what it allows.
    function usedOf(address account, bytes32 policyId) external view returns (uint64 used, uint64 limit) {
        WindowLib.Window storage w = _windows[account][policyId];
        return (w.used(block.timestamp), w.limit(block.timestamp));
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, a window WindowLib refuses, or S above H.
    ///         WIDEN: a higher cap, soft bound, refill or stream rate, or
    ///         stream start; or a change of shape (class, bucket length,
    ///         bucket count, anchor) or of the quantity counted, which starts
    ///         the window afresh and so forgets what was counted.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory next = abi.decode(config, (Config));
        if (uint8(next.quantity) > uint8(type(Quantity).max)) return ConfigChange.INVALID;
        if (!WindowLib.isValid(next.window) || next.soft > next.window.cap) return ConfigChange.INVALID;

        Instance memory inst = _instances[account][policyId];
        if (!inst.set) return ConfigChange.TIGHTEN;

        WindowLib.Config memory w = _windows[account][policyId].config;
        WindowLib.Config memory n = next.window;
        bool restarts = next.quantity != inst.quantity || n.kind != w.kind || n.step != w.step
            || n.buckets != w.buckets || n.anchor != w.anchor;
        bool looser = next.soft > inst.soft || n.cap > w.cap || n.rate > w.rate || n.initial > w.initial;
        return restarts || looser ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        Config memory c = abi.decode(config, (Config));
        Instance storage inst = _instances[account][policyId];
        WindowLib.Window storage w = _windows[account][policyId];
        bool otherQuantity = inst.set && inst.quantity != c.quantity;
        w.configure(c.window);
        if (otherQuantity) w.clear();
        inst.set = true;
        inst.quantity = c.quantity;
        inst.soft = c.soft;
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
        Instance memory inst = _instances[account][policyId];
        WindowLib.Window storage w = _windows[account][policyId];
        uint256 amount = _amount(inst.quantity, legs);

        r.valueBefore = w.used(ctx.time);
        r.valueAfter = r.valueBefore + amount;
        r.soft = inst.soft;
        r.hard = w.limit(ctx.time);

        if (amount == 0) r.verdict = Verdict.EXECUTE;
        else if (amount > type(uint64).max || !w.fits(ctx.time, uint64(amount))) r.verdict = Verdict.REJECT;
        else if (r.valueAfter > inst.soft) r.verdict = Verdict.FLAG;
        else r.verdict = Verdict.EXECUTE;
    }

    function commit(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        override
        onlyGate
    {
        uint256 amount = _amount(_instances[account][policyId].quantity, legs);
        if (amount != 0) _windows[account][policyId].add(ctx.time, uint64(amount));
    }

    /// @dev S1 gives back the value charged for the order less the value of
    ///      its filled part, both rounded up as when charged, so never more
    ///      than was charged. S2 gives back the released Wh.
    function credit(address account, bytes32 policyId, Release calldata release) external override onlyGate {
        Instance memory inst = _instances[account][policyId];
        if (!inst.set) return;
        uint256 amount;
        if (inst.quantity == Quantity.BUY_VALUE) {
            if (release.side == Side.BUY) {
                amount = valueUp(release.qtyWh, release.price) - valueUp(release.filledWh, release.price);
            }
        } else if (_counts(inst.quantity, release.side)) {
            amount = release.releasedWh;
        }
        if (amount == 0) return;
        uint64 credited =
            _windows[account][policyId].credit(block.timestamp, release.placedAt, uint64(amount));
        emit Credited(account, policyId, release.market, release.orderId, uint64(amount), credited);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _counts(Quantity q, Side side) private pure returns (bool) {
        if (q == Quantity.SELL_WH) return side == Side.SELL;
        return side == Side.BUY;
    }

    /// @dev What the PLACE legs add to the instance's quantity, all together.
    function _amount(Quantity q, Order[] calldata legs) private pure returns (uint256 amount) {
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            if (leg.kind != OrderKind.PLACE || !_counts(q, leg.side)) continue;
            amount += q == Quantity.BUY_VALUE ? leg.value : leg.qtyWh;
        }
    }
}
