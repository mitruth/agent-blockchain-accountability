// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {WindowLib} from "./WindowLib.sol";
import {HorizonLib, IGateLedger} from "./HorizonLib.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {BmsReading} from "../oracle/OracleTypes.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// @title CyclePolicy
/// @notice S4, battery cycles per window (spec 6.5): how much the battery is
///         discharged over a sliding window, counting what it has discharged
///         and what the sales already placed will make it discharge.
///
/// Two parts, in Wh drawn from the cells:
///
///   discharged  from the BMS's signed discharge odometer (D5). At every
///               submission the gate accepts, the energy discharged since the
///               last one is added to a WindowLib window at that time. So it is
///               never counted earlier than it happened, and may be counted
///               later: the window can only overstate the discharge it holds.
///               What the odometer shows beyond the last addition is counted
///               on top.
///   pending     the committed sales over the horizon, net of the PV credit
///               alpha, divided by the discharge efficiency: what they will
///               draw if delivered
///
/// The sum, against the window's cap, is N_max times the capacity (spec: the
/// cycles are the sum over C_bat). The cap is the hard bound and `softWh` the
/// soft one. Only a sale adds to S4: a submission with no sale in it is never
/// judged, and one that does not add to the sum is never rejected (D10).
///
/// A sale with no fresh battery reading, or for a slot outside the horizon, is
/// refused: S4 cannot judge it.
///
/// The first reading an instance sees sets where its odometer starts: what was
/// discharged before it is not known to the policy.
contract CyclePolicy is PolicyBase {
    using WindowLib for WindowLib.Window;

    uint16 public constant MAX_HORIZON = 96;
    uint256 private constant BPS = 10_000;
    uint256 private constant CONFIG_LENGTH = 11 * 32;

    /// @param softWh          S, in Wh drawn from the cells.
    /// @param window          The window; its cap is H = N_max x C_bat.
    /// @param horizonSlots    k: the slots whose committed sales are pending.
    /// @param pvCreditBps     alpha.
    /// @param etaDischargeBps eta_dis: Wh to the house per Wh from the cells.
    struct Config {
        uint64 softWh;
        WindowLib.Config window;
        uint16 horizonSlots;
        uint16 pvCreditBps;
        uint16 etaDischargeBps;
    }

    struct Instance {
        bool set;
        bool seen;
        uint16 horizonSlots;
        uint16 pvCreditBps;
        uint16 etaDischargeBps;
        uint64 softWh;
        uint64 lastOdometerWh;
    }

    PositionLedger public immutable ledger;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;
    mapping(address account => mapping(bytes32 policyId => WindowLib.Window)) private _windows;

    /// @notice Discharge added to the window: the odometer moved from `fromWh`
    ///         to `toWh`.
    event Discharged(address indexed account, bytes32 indexed policyId, uint64 fromWh, uint64 toWh);

    constructor(address gate_) PolicyBase(gate_) {
        ledger = IGateLedger(gate_).ledger();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function configOf(address account, bytes32 policyId) external view returns (Config memory c) {
        Instance memory inst = _instances[account][policyId];
        c.softWh = inst.softWh;
        c.window = _windows[account][policyId].config;
        c.horizonSlots = inst.horizonSlots;
        c.pvCreditBps = inst.pvCreditBps;
        c.etaDischargeBps = inst.etaDischargeBps;
    }

    function instanceOf(address account, bytes32 policyId) external view returns (Instance memory) {
        return _instances[account][policyId];
    }

    /// @notice The discharge the window holds now, and its limit.
    function usedOf(address account, bytes32 policyId) external view returns (uint64 used, uint64 limit) {
        WindowLib.Window storage w = _windows[account][policyId];
        return (w.used(block.timestamp), w.limit(block.timestamp));
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, a window WindowLib refuses, S above H, a
    ///         horizon of 0 or above 96, an efficiency of 0 or above 100 %, a
    ///         PV credit above 100 %. WIDEN: a change of the window's shape or
    ///         of the horizon, or a higher cap, soft bound, rate, efficiency
    ///         or PV credit.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (
            !WindowLib.isValid(n.window) || n.softWh > n.window.cap || n.horizonSlots == 0
                || n.horizonSlots > MAX_HORIZON || n.etaDischargeBps == 0 || n.etaDischargeBps > BPS
                || n.pvCreditBps > BPS
        ) return ConfigChange.INVALID;

        Instance memory inst = _instances[account][policyId];
        if (!inst.set) return ConfigChange.TIGHTEN;
        WindowLib.Config memory o = _windows[account][policyId].config;
        bool reshaped = n.window.kind != o.kind || n.window.step != o.step || n.window.buckets != o.buckets
            || n.window.anchor != o.anchor || n.horizonSlots != inst.horizonSlots;
        bool looser = n.softWh > inst.softWh || n.window.cap > o.cap || n.window.rate > o.rate
            || n.window.initial > o.initial || n.etaDischargeBps > inst.etaDischargeBps
            || n.pvCreditBps > inst.pvCreditBps;
        return reshaped || looser ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        Config memory c = abi.decode(config, (Config));
        _windows[account][policyId].configure(c.window);
        Instance storage inst = _instances[account][policyId];
        inst.set = true;
        inst.softWh = c.softWh;
        inst.horizonSlots = c.horizonSlots;
        inst.pvCreditBps = c.pvCreditBps;
        inst.etaDischargeBps = c.etaDischargeBps;
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        _windows[account][policyId].clear();
        delete _instances[account][policyId];
    }

    // ------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------

    /// @notice The value is the discharge the window holds, plus what the
    ///         odometer shows beyond it, plus the pending sales' draw, in Wh.
    ///         A sale that cannot be judged reports `valueAfter` = 2^256 - 1.
    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        view
        override
        returns (CheckResult memory r)
    {
        bool fresh;
        (r, fresh) = _observed(account, policyId, ctx);
        int256 sale = _firstSale(legs);
        if (sale < 0) return r;
        if (!fresh) return _unjudged(r);
        (bool judged, uint256 pendingBefore, uint256 pendingAfter) =
            _pendingFor(account, policyId, legs, uint256(sale), ctx);
        if (!judged) return _unjudged(r);

        r.valueAfter = r.valueBefore + pendingAfter;
        r.valueBefore += pendingBefore;
        bool worse = r.valueAfter > r.valueBefore;
        if (worse && r.valueAfter > r.hard) r.verdict = Verdict.REJECT;
        else if (worse && r.valueAfter > r.soft) r.verdict = Verdict.FLAG;
        else r.verdict = Verdict.EXECUTE;
    }

    /// @dev Adds the discharge since the last accepted submission, from the
    ///      latest fresh reading. A reading below the last one -- a new BMS,
    ///      whose odometer starts again -- only moves the start.
    function commit(address account, bytes32 policyId, Order[] calldata, CheckContext calldata ctx)
        external
        override
        onlyGate
    {
        (BmsReading memory reading, bool fresh) = OracleVerifier(ctx.oracle).bmsOf(account);
        if (!fresh) return;
        Instance storage inst = _instances[account][policyId];
        uint64 odometer = reading.dischargeOdometerWh;
        if (inst.seen && odometer > inst.lastOdometerWh) {
            _windows[account][policyId].add(ctx.time, odometer - inst.lastOdometerWh);
            emit Discharged(account, policyId, inst.lastOdometerWh, odometer);
        }
        inst.seen = true;
        inst.lastOdometerWh = odometer;
    }

    /// @dev A released sale is no longer pending, which the ledger already
    ///      shows; the window holds only what was discharged. Nothing to do.
    function credit(address, bytes32, Release calldata) external view override onlyGate {}

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _unjudged(CheckResult memory r) private pure returns (CheckResult memory) {
        r.valueAfter = type(uint256).max;
        r.verdict = Verdict.REJECT;
        return r;
    }

    /// @dev The bounds, and what has been discharged: the window, plus what the
    ///      latest fresh reading shows beyond its last addition. Both values
    ///      start there; the verdict starts at EXECUTE.
    function _observed(address account, bytes32 policyId, CheckContext calldata ctx)
        private
        view
        returns (CheckResult memory r, bool fresh)
    {
        Instance storage inst = _instances[account][policyId];
        WindowLib.Window storage w = _windows[account][policyId];
        r.soft = inst.softWh;
        r.hard = w.limit(ctx.time);
        BmsReading memory reading;
        (reading, fresh) = OracleVerifier(ctx.oracle).bmsOf(account);
        uint256 observed = w.used(ctx.time);
        if (fresh && inst.seen && reading.dischargeOdometerWh > inst.lastOdometerWh) {
            observed += reading.dischargeOdometerWh - inst.lastOdometerWh;
        }
        r.valueBefore = observed;
        r.valueAfter = observed;
    }

    /// @dev The pending draw without and with the submission, over the horizon
    ///      of the latest reading, found from the sale at `saleIndex`. Not
    ///      judged when a sale falls outside it.
    function _pendingFor(
        address account,
        bytes32 policyId,
        Order[] calldata legs,
        uint256 saleIndex,
        CheckContext calldata ctx
    ) private view returns (bool judged, uint256 before, uint256 after_) {
        Instance memory inst = _instances[account][policyId];
        (BmsReading memory reading,) = OracleVerifier(ctx.oracle).bmsOf(account);
        (HorizonLib.Horizon memory h, bool ok) = HorizonLib.fromReading(ctx, legs[saleIndex].slot, reading);
        if (!ok) return (false, 0, 0);
        (int256[] memory sellDelta, bool inside) = _sellDeltas(legs, h, inst.horizonSlots);
        if (!inside) return (false, 0, 0);
        (before, after_) = _pending(account, inst, h, ctx.oracle, sellDelta);
        judged = true;
    }

    /// @dev Index of the first SELL placement, or -1.
    function _firstSale(Order[] calldata legs) private pure returns (int256) {
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind == OrderKind.PLACE && legs[i].side == Side.SELL) return int256(i);
        }
        return -1;
    }

    /// @dev Per slot of the horizon, what the submission adds to or takes from
    ///      the committed sales. Not inside when a sale is placed outside it.
    function _sellDeltas(Order[] calldata legs, HorizonLib.Horizon memory h, uint16 k)
        private
        pure
        returns (int256[] memory delta, bool inside)
    {
        delta = new int256[](k);
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            if (leg.side != Side.SELL) continue;
            bool placing = leg.kind == OrderKind.PLACE;
            if (!HorizonLib.contains(h, k, leg.slot)) {
                if (placing) return (delta, false);
                continue;
            }
            int256 qty = int256(uint256(leg.qtyWh));
            delta[leg.slot - h.firstSlot] += placing ? qty : -qty;
        }
        inside = true;
    }

    /// @dev What the committed sales over the horizon will draw from the cells,
    ///      without and with the submission: per slot, the sales beyond the PV
    ///      credit, over the efficiency, rounded up.
    function _pending(
        address account,
        Instance memory inst,
        HorizonLib.Horizon memory h,
        address oracle,
        int256[] memory sellDelta
    ) private view returns (uint256 before, uint256 after_) {
        PositionLedger.Position[] memory positions = ledger.positionsOf(account, h.firstSlot, inst.horizonSlots);
        uint64[] memory pv =
            OracleVerifier(oracle).pvSeries(account, h.firstStart, uint32(h.slotSeconds), inst.horizonSlots);
        int256 eta = int256(uint256(inst.etaDischargeBps));
        unchecked {
            for (uint256 i = 0; i < positions.length; ++i) {
                int256 credit_ = int256((uint256(pv[i]) * inst.pvCreditBps) / BPS);
                int256 sold = int256(uint256(positions[i].committedSellWh));
                before += _draw(sold - credit_, eta);
                after_ += _draw(sold + sellDelta[i] - credit_, eta);
            }
        }
    }

    function _draw(int256 houseWh, int256 eta) private pure returns (uint256) {
        if (houseWh <= 0) return 0;
        return uint256((houseWh * int256(BPS) + eta - 1) / eta);
    }
}
