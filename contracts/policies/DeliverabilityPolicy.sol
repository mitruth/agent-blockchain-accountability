// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {BmsReading} from "../oracle/OracleTypes.sol";
import {HorizonLib, IGateLedger} from "./HorizonLib.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// @title DeliverabilityPolicy
/// @notice S3, cross-slot deliverability (spec 6.4): the battery must be able
///         to deliver what the agent has sold, over the next k slots, without
///         counting on energy that is not certain.
///
/// From the battery's signed state at the start of the current slot, the
/// policy projects it slot by slot over the horizon, in two ways:
///
///   floor     inflow   PV forecast times the credit alpha, and cleared buys
///             outflow  committed sells, and the owner's reserve load
///             The battery may not fall below its minimum. Only cleared buys
///             count (D3): an unfilled bid cannot justify a sale, or the agent
///             could bid at a price that never fills and sell against it.
///   ceiling   inflow   committed (placed) buys; PV is left out, as it can be
///                      curtailed, so PV alone never causes a rejection
///             outflow  the reserve load
///             The battery may not rise above its maximum.
///
/// Per slot, sells may not exceed the discharge power plus the PV credit, and
/// buys beyond the reserve load may not exceed the charge power.
///
/// What the projection cannot deliver is summed, in Wh: the energy short of
/// the floor, and the excess over the ceiling and over each power limit. That
/// sum is the policy's value, before and after the submission. A submission is
/// rejected when it leaves a shortfall and makes it larger. One that keeps it
/// or reduces it -- a cancellation, a smaller modification -- always passes
/// (D10). There is no soft bound.
///
/// A placement is also rejected when the policy cannot judge it: with no fresh
/// battery reading, or for a slot outside the horizon. The horizon starts at
/// the slot of the battery reading. So every slot the agent can reach is one
/// S3 covers: the spec's H_slots <= k (5.6) holds by construction, here, rather
/// than as a check across two policies' configurations.
///
/// The policy keeps no order state. Positions come from the ledger, the battery
/// and the forecast from the oracle verifier. Rounding always errs towards less
/// energy in the floor projection and more in the ceiling one.
contract DeliverabilityPolicy is PolicyBase {
    /// @notice Longest horizon: two days of half-hour slots, the longest
    ///         forecast the verifier holds.
    uint16 public constant MAX_HORIZON = 96;

    uint256 private constant BPS = 10_000;
    uint256 private constant CONFIG_LENGTH = 10 * 32;

    /// @param horizonSlots     k: how many slots the projection covers, from
    ///                         the slot of the battery reading.
    /// @param capacityWh       C_bat.
    /// @param socMinBps        The floor, a share of the capacity.
    /// @param socMaxBps        The ceiling.
    /// @param chargePowerW     P_ch.
    /// @param dischargePowerW  P_dis.
    /// @param etaChargeBps     eta_ch.
    /// @param etaDischargeBps  eta_dis.
    /// @param pvCreditBps      alpha: how much of the PV forecast counts.
    /// @param reserveLoadWh    The load the owner keeps covered, per slot (D4).
    struct Config {
        uint16 horizonSlots;
        uint64 capacityWh;
        uint16 socMinBps;
        uint16 socMaxBps;
        uint32 chargePowerW;
        uint32 dischargePowerW;
        uint16 etaChargeBps;
        uint16 etaDischargeBps;
        uint16 pvCreditBps;
        uint64 reserveLoadWh;
    }

    /// @notice What a projection cannot deliver, in Wh.
    struct Assessment {
        uint256 floorShortfallWh;
        uint256 dischargeExcessWh;
        uint256 ceilingExcessWh;
        uint256 chargeExcessWh;
    }

    /// @notice Why a placement cannot be judged.
    enum Unjudged {
        NONE,
        NO_FRESH_READING,
        OUTSIDE_HORIZON
    }

    PositionLedger public immutable ledger;

    mapping(address account => mapping(bytes32 policyId => Config)) private _configs;

    constructor(address gate_) PolicyBase(gate_) {
        ledger = IGateLedger(gate_).ledger();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function configOf(address account, bytes32 policyId) external view returns (Config memory) {
        return _configs[account][policyId];
    }

    /// @notice The projection before and after a submission of `legs`, or
    ///         why a placement in it cannot be judged.
    function assess(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        view
        returns (Assessment memory before, Assessment memory after_, Unjudged why)
    {
        return _assess(account, policyId, legs, ctx, true);
    }

    /// @dev With `full` false, the projection without the submission is
    ///      skipped when the one with it is clean: the verdict is then EXECUTE
    ///      whatever it holds, and `before` reads zero.
    function _assess(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx, bool full)
        private
        view
        returns (Assessment memory before, Assessment memory after_, Unjudged why)
    {
        Config memory c = _configs[account][policyId];
        HorizonLib.Horizon memory h;
        {
            int256 first = HorizonLib.firstPlacement(legs);
            if (first < 0) return (before, after_, Unjudged.NONE);
            (BmsReading memory reading, bool fresh) = OracleVerifier(ctx.oracle).bmsOf(account);
            if (!fresh) return (before, after_, Unjudged.NO_FRESH_READING);
            bool ok;
            (h, ok) = HorizonLib.fromReading(ctx, legs[uint256(first)].slot, reading);
            if (!ok) return (before, after_, Unjudged.OUTSIDE_HORIZON);
        }
        (Inputs memory inputs, bool inside) = _deltas(legs, h.firstSlot, c.horizonSlots);
        if (!inside) return (before, after_, Unjudged.OUTSIDE_HORIZON);
        (before, after_) = _compare(account, c, h, ctx.oracle, inputs, full);
    }

    /// @dev The positions and the forecast over the horizon, projected without
    ///      and with the submission.
    function _compare(
        address account,
        Config memory c,
        HorizonLib.Horizon memory h,
        address oracle,
        Inputs memory inputs,
        bool full
    ) private view returns (Assessment memory before, Assessment memory after_) {
        inputs.positions = ledger.positionsOf(account, h.firstSlot, c.horizonSlots);
        inputs.pv = OracleVerifier(oracle).pvSeries(account, h.firstStart, uint32(h.slotSeconds), c.horizonSlots);
        Limits memory l = _limits(c, h);
        after_ = _project(l, h.socWh, inputs, true);
        if (full || total(after_) != 0) before = _project(l, h.socWh, inputs, false);
    }

    function total(Assessment memory a) public pure returns (uint256) {
        return a.floorShortfallWh + a.dischargeExcessWh + a.ceilingExcessWh + a.chargeExcessWh;
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed; a horizon of 0 or above 96 slots; no
    ///         capacity; a floor above the ceiling or a ceiling above 100 %;
    ///         an efficiency of 0 or above 100 %; a PV credit above 100 %.
    ///         WIDEN: another horizon (a change of shape, spec 5.6), or any
    ///         parameter looser: more capacity, a lower floor, a higher
    ///         ceiling, more power, higher efficiencies, more PV credit, less
    ///         reserve load.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (
            n.horizonSlots == 0 || n.horizonSlots > MAX_HORIZON || n.capacityWh == 0 || n.socMinBps > n.socMaxBps
                || n.socMaxBps > BPS || n.etaChargeBps == 0 || n.etaChargeBps > BPS || n.etaDischargeBps == 0
                || n.etaDischargeBps > BPS || n.pvCreditBps > BPS
        ) return ConfigChange.INVALID;

        Config memory o = _configs[account][policyId];
        if (o.horizonSlots == 0) return ConfigChange.TIGHTEN;
        bool wider = n.horizonSlots != o.horizonSlots || n.capacityWh > o.capacityWh || n.socMinBps < o.socMinBps
            || n.socMaxBps > o.socMaxBps || n.chargePowerW > o.chargePowerW || n.dischargePowerW > o.dischargePowerW
            || n.etaChargeBps > o.etaChargeBps || n.etaDischargeBps > o.etaDischargeBps
            || n.pvCreditBps > o.pvCreditBps || n.reserveLoadWh < o.reserveLoadWh;
        return wider ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        _configs[account][policyId] = abi.decode(config, (Config));
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        delete _configs[account][policyId];
    }

    // ------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------

    /// @notice EXECUTE or REJECT; no soft bound. The value is the projection's
    ///         undeliverable energy (`total`). A placement that cannot be judged
    ///         reports `valueAfter` = 2^256 - 1. When the projection with the
    ///         submission is clean, the one without it is not computed, as the
    ///         verdict does not depend on it, and `valueBefore` reads zero.
    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        view
        override
        returns (CheckResult memory r)
    {
        (Assessment memory before, Assessment memory after_, Unjudged why) = _assess(account, policyId, legs, ctx, false);
        if (why != Unjudged.NONE) {
            r.valueAfter = type(uint256).max;
            r.verdict = Verdict.REJECT;
            return r;
        }
        r.valueBefore = total(before);
        r.valueAfter = total(after_);
        r.verdict = r.valueAfter != 0 && r.valueAfter > r.valueBefore ? Verdict.REJECT : Verdict.EXECUTE;
    }

    /// @dev Nothing to record: the ledger books the order after the market
    ///      call, and that is all S3 reads.
    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external view override onlyGate {}

    /// @dev Nothing to give back, for the same reason.
    function credit(address, bytes32, Release calldata) external view override onlyGate {}

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev What the PLACE legs add to, and the CANCEL legs take from, each
    ///      slot of the horizon. Not inside when a placement falls outside it;
    ///      a cancellation outside it changes nothing here.
    function _deltas(Order[] calldata legs, uint32 firstSlot, uint16 k)
        private
        pure
        returns (Inputs memory inputs, bool inside)
    {
        int256[] memory sellDelta = new int256[](k);
        int256[] memory buyDelta = new int256[](k);
        inputs.sellDelta = sellDelta;
        inputs.buyDelta = buyDelta;
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            bool placing = leg.kind == OrderKind.PLACE;
            if (leg.slot < firstSlot || leg.slot >= uint256(firstSlot) + k) {
                if (placing) return (inputs, false);
                continue;
            }
            int256 qty = placing ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));
            if (leg.side == Side.SELL) sellDelta[leg.slot - firstSlot] += qty;
            else buyDelta[leg.slot - firstSlot] += qty;
        }
        inside = true;
    }

    /// @dev What a projection reads: the positions and the forecast over the
    ///      horizon, and what the submission changes in each slot.
    struct Inputs {
        PositionLedger.Position[] positions;
        uint64[] pv;
        int256[] sellDelta;
        int256[] buyDelta;
    }

    /// @dev The configuration in Wh per slot. The floor rounds up, the
    ///      ceiling and the power limits down.
    struct Limits {
        int256 minWh;
        int256 maxWh;
        int256 dischargeWh;
        int256 chargeWh;
        int256 reserveWh;
        int256 etaCharge;
        int256 etaDischarge;
        uint256 pvCredit;
    }

    function _limits(Config memory c, HorizonLib.Horizon memory h) private pure returns (Limits memory l) {
        l.minWh = int256((uint256(c.capacityWh) * c.socMinBps + BPS - 1) / BPS);
        l.maxWh = int256((uint256(c.capacityWh) * c.socMaxBps) / BPS);
        l.dischargeWh = int256((uint256(c.dischargePowerW) * h.slotSeconds) / 3600);
        l.chargeWh = int256((uint256(c.chargePowerW) * h.slotSeconds) / 3600);
        l.reserveWh = int256(uint256(c.reserveLoadWh));
        l.etaCharge = int256(uint256(c.etaChargeBps));
        l.etaDischarge = int256(uint256(c.etaDischargeBps));
        l.pvCredit = c.pvCreditBps;
    }

    /// @dev Both projections over the horizon, from `socWh`, with the
    ///      submission's `sellDelta` and `buyDelta` added to the committed
    ///      positions or, without `withDeltas`, as they stand.
    function _project(Limits memory l, uint64 socWh, Inputs memory inputs, bool withDeltas)
        private
        pure
        returns (Assessment memory a)
    {
        int256[2] memory level = [int256(uint256(socWh)), int256(uint256(socWh))]; // floor, ceiling
        unchecked {
            for (uint256 i = 0; i < inputs.positions.length; ++i) {
                PositionLedger.Position memory p = inputs.positions[i];
                int256 sold = int256(uint256(p.committedSellWh));
                int256 bought = int256(uint256(p.committedBuyWh));
                if (withDeltas) {
                    sold += inputs.sellDelta[i];
                    bought += inputs.buyDelta[i];
                }
                int256 pvCredit = int256((uint256(inputs.pv[i]) * l.pvCredit) / BPS);
                int256 charge = bought - l.reserveWh;

                if (sold > l.dischargeWh + pvCredit) a.dischargeExcessWh += uint256(sold - l.dischargeWh - pvCredit);
                if (charge > l.chargeWh) a.chargeExcessWh += uint256(charge - l.chargeWh);

                a.floorShortfallWh +=
                    _floorStep(l, level, pvCredit + int256(uint256(p.clearedBuyWh)) - sold - l.reserveWh);
                a.ceilingExcessWh += _ceilingStep(l, level, charge);
            }
        }
    }

    /// @dev Floor: certain inflows only, gains rounded down and losses up.
    ///      What falls short of the minimum is counted, and the battery stops
    ///      there; what rises above the maximum is spilled.
    function _floorStep(Limits memory l, int256[2] memory level, int256 flow) private pure returns (uint256 short) {
        if (flow >= 0) {
            level[0] += (flow * l.etaCharge) / int256(BPS);
            if (level[0] > l.maxWh) level[0] = l.maxWh;
        } else {
            level[0] -= (-flow * int256(BPS) + l.etaDischarge - 1) / l.etaDischarge;
        }
        if (level[0] < l.minWh) {
            short = uint256(l.minWh - level[0]);
            level[0] = l.minWh;
        }
    }

    /// @dev Ceiling: every placed buy, gains rounded up and losses down. What
    ///      rises above the maximum is counted, and the battery stops there; it
    ///      never goes below the minimum.
    function _ceilingStep(Limits memory l, int256[2] memory level, int256 flow) private pure returns (uint256 excess) {
        if (flow >= 0) {
            level[1] += (flow * l.etaCharge + int256(BPS) - 1) / int256(BPS);
        } else {
            level[1] -= (-flow * int256(BPS)) / l.etaDischarge;
        }
        if (level[1] < l.minWh) level[1] = l.minWh;
        if (level[1] > l.maxWh) {
            excess = uint256(level[1] - l.maxWh);
            level[1] = l.maxWh;
        }
    }
}
