// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {WindowLib} from "./WindowLib.sol";
import {IMaintainedPolicy} from "../interfaces/IMaintainedPolicy.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

interface IGateReaders {
    function ledger() external view returns (PositionLedger);
    function oracle() external view returns (OracleVerifier);
}

/// @title DeliveryReconciliationPolicy
/// @notice S9, delivery reconciliation with allowance feedback (spec v0.2
///         section 5): what the account sold, against what its meter says it
///         delivered, slot by slot, with a CUSUM that raises an alarm on
///         chronic shortfall and penalties that narrow the agent's selling.
///
/// S3 trusts the BMS and PV readings it is given; S9 checks the outcome
/// against the meter, a separate signer. An agent that oversells against an
/// inflated state of charge passes every per-slot check, and fails here.
///
/// **Processing.** A pointer advances over the account's settled slots, at
/// most `maxProcess` per call. For each slot t, from the ledger and the meter:
///
///   cn(t) = max(0, clearedSell − clearedBuy)        contracted net export
///   dn(t) = exportWh − importWh                     delivered net export
///   s(t)  = min(cn, max(0, cn − dn))                 shortfall
///   C     = max(0, C + s − k)                        upper CUSUM
///   C > h: alarm. C = 0, the level rises, the penalty runs T_pen from now.
///
/// A slot is processed once it has ended `settlementLag` ago and every order
/// of it is reconciled (its committed volume equals its cleared volume on both
/// sides): before that the ledger may not yet hold its fills, and S9 would
/// see less sold than was. This readiness rule is ours; the spec says "cleared
/// positions". Processing stops at the first slot not ready, or with a sale
/// and no meter reading.
///
/// **Fail closed (D16).** If that slot has sales (committed) and ended more
/// than `settlementLag + grace` ago, every SELL placement is rejected until
/// its reading arrives and its orders are reconciled. Anyone can do both.
///
/// **Penalty, on SELL legs only.**
///   level 1  a SELL_WH window (24 h by default) capped at H_pen applies; it
///            counts every placed sell all the time, with credits as S2, and
///            is judged only while the penalty runs
///   level 2  an alarm while the level is at least 1: SELL placement is
///            rejected while the penalty runs
///   decay    the level falls by one per W_esc without an alarm
///   owner    `reset` through the gate
/// A submission whose processing raises an alarm is flagged, unless it is
/// rejected: our reading of the spec's "emit PolicyFlag".
///
/// **D10.** BUY legs and cancellations are never rejected.
///
/// **Keeping it current.** Processing reaches a slot only through a
/// submission or a `poke`, at most `maxProcess` slots each. An alarm or a D16
/// block is seen once processing reaches its slot; a keeper that pokes keeps
/// both current, whatever the agent does (the reason the spec adds `poke`).
///
/// **Persistence.** `check` processes in memory; `commit` and `poke` persist.
/// A rejected submission persists nothing, and the next call computes the
/// same result: the processing depends only on signed data and the ledger.
///
/// `CheckResult`: before and after are C before and after processing; soft
/// and hard are h.
contract DeliveryReconciliationPolicy is PolicyBase, IMaintainedPolicy {
    using WindowLib for WindowLib.Window;

    /// @param k                 Slack per slot, in Wh (D19: the p95 of honest shortfall).
    /// @param h                 Alarm threshold on C, in Wh.
    /// @param penaltySeconds    T_pen: how long a penalty runs after an alarm.
    /// @param escalationSeconds W_esc: the level falls by one per this long without an alarm.
    /// @param settlementLagSeconds A slot is settled this long after it ends.
    /// @param graceSeconds      How long after settlement a reading may be missing before SELLs are refused.
    /// @param maxProcess        Most slots one call processes (1 to MAX_PROCESS).
    /// @param window            Level 1's SELL_WH window; its cap is H_pen.
    struct Config {
        uint64 k;
        uint64 h;
        uint32 penaltySeconds;
        uint32 escalationSeconds;
        uint32 settlementLagSeconds;
        uint32 graceSeconds;
        uint16 maxProcess;
        WindowLib.Config window;
    }

    /// @param next        The next slot to process.
    /// @param cusum       C, in Wh.
    /// @param level       The penalty level at the last alarm (0, 1 or 2), before decay.
    /// @param penaltyUntil The penalty runs while block time is before this.
    /// @param lastAlarmAt When the last alarm was raised; decay counts from it.
    struct State {
        uint32 next;
        uint64 cusum;
        uint8 level;
        uint64 penaltyUntil;
        uint64 lastAlarmAt;
    }

    struct Instance {
        bool set;
        uint64 configuredAt;
        Config config;
    }

    /// @dev One slot taken in, for the events.
    struct Slot {
        uint32 slot;
        uint64 cn;
        int256 dn;
        uint64 s;
        uint64 cusum;
        bool alarm;
        uint8 level;
    }

    /// @dev The result of processing, in memory.
    struct Run {
        State state;
        Slot[] slots;
        uint256 count;
        bool alarm;
        bool blocked;
    }

    uint256 private constant CONFIG_LENGTH = 14 * 32;
    uint16 public constant MAX_PROCESS = 32;

    PositionLedger public immutable ledger;
    OracleVerifier public immutable oracle;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;
    mapping(address account => mapping(bytes32 policyId => State)) private _states;
    mapping(address account => mapping(bytes32 policyId => WindowLib.Window)) private _windows;

    /// @notice A settled slot taken in. `dn` is signed: negative when the
    ///         account imported on net. `cusum` is C with this slot's
    ///         shortfall taken in, before an alarm resets it to 0.
    event SlotReconciled(
        address indexed account, bytes32 indexed policyId, uint32 slot, uint64 cn, int256 dn, uint64 s, uint64 cusum
    );
    /// @notice C crossed h on `slot`: a penalty at `level` runs until
    ///         `penaltyUntil`. `cusum` is C before it was reset.
    event DeliveryAlarm(
        address indexed account, bytes32 indexed policyId, uint32 slot, uint8 level, uint64 cusum, uint64 penaltyUntil
    );
    /// @notice The owner reset the penalty; processing resumes at `next`.
    event PenaltyReset(address indexed account, bytes32 indexed policyId, uint32 next);

    constructor(address gate_) PolicyBase(gate_) {
        ledger = IGateReaders(gate_).ledger();
        oracle = IGateReaders(gate_).oracle();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function configOf(address account, bytes32 policyId) external view returns (Config memory) {
        return _instances[account][policyId].config;
    }

    function stateOf(address account, bytes32 policyId) external view returns (State memory) {
        return _states[account][policyId];
    }

    /// @notice The penalty level now, after decay.
    function levelOf(address account, bytes32 policyId) public view returns (uint8) {
        return _effectiveLevel(_states[account][policyId], _instances[account][policyId].config, block.timestamp);
    }

    /// @notice What processing now would give, without persisting it.
    function pending(address account, bytes32 policyId)
        external
        view
        returns (State memory state, uint256 processed, bool alarm, bool blocked)
    {
        Run memory run = _process(account, policyId, block.timestamp);
        return (run.state, run.count, run.alarm, run.blocked);
    }

    function soldOf(address account, bytes32 policyId) external view returns (uint64 used, uint64 limit) {
        WindowLib.Window storage w = _windows[account][policyId];
        return (w.used(block.timestamp), w.limit(block.timestamp));
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, a window WindowLib refuses, no processing,
    ///         or more than MAX_PROCESS. TIGHTEN: nothing looser. WIDEN:
    ///         a higher k, h or H_pen; a shorter T_pen or W_esc; a longer
    ///         grace; any change of the settlement lag or of maxProcess; a
    ///         window of another shape or a higher rate or initial amount.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (!WindowLib.isValid(n.window) || n.maxProcess == 0 || n.maxProcess > MAX_PROCESS) {
            return ConfigChange.INVALID;
        }

        Instance storage inst = _instances[account][policyId];
        if (!inst.set) return ConfigChange.TIGHTEN;
        Config memory o = inst.config;
        bool looser = n.k > o.k || n.h > o.h || n.penaltySeconds < o.penaltySeconds
            || n.escalationSeconds < o.escalationSeconds || n.graceSeconds > o.graceSeconds
            || n.settlementLagSeconds != o.settlementLagSeconds || n.maxProcess != o.maxProcess;
        WindowLib.Config memory a = o.window;
        WindowLib.Config memory b = n.window;
        bool windowLooser = b.kind != a.kind || b.step != a.step || b.buckets != a.buckets || b.anchor != a.anchor
            || b.cap > a.cap || b.rate > a.rate || b.initial > a.initial;
        return looser || windowLooser ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    /// @dev A new instance starts at the first slot that begins at or after
    ///      now; a reconfiguration keeps the pointer, C and the penalty.
    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        Config memory c = abi.decode(config, (Config));
        Instance storage inst = _instances[account][policyId];
        if (!inst.set) {
            inst.set = true;
            inst.configuredAt = uint64(block.timestamp);
            delete _states[account][policyId];
        }
        inst.config = c;
        _windows[account][policyId].configure(c.window);
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        _windows[account][policyId].clear();
        delete _instances[account][policyId];
        delete _states[account][policyId];
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
        Config memory c = _instances[account][policyId].config;
        Run memory run = _process(account, policyId, ctx.time);
        uint256 sells = _sells(legs);

        r.valueBefore = _states[account][policyId].cusum;
        r.valueAfter = run.state.cusum;
        r.soft = c.h;
        r.hard = c.h;

        bool penalty = ctx.time < run.state.penaltyUntil;
        uint8 level = _effectiveLevel(run.state, c, ctx.time);
        if (sells != 0 && run.blocked) r.verdict = Verdict.REJECT;
        else if (sells != 0 && penalty && level >= 2) r.verdict = Verdict.REJECT;
        else if (
            sells != 0 && penalty && level == 1
                && (sells > type(uint64).max || !_windows[account][policyId].fits(ctx.time, uint64(sells)))
        ) r.verdict = Verdict.REJECT;
        else if (run.alarm) r.verdict = Verdict.FLAG;
        else r.verdict = Verdict.EXECUTE;
    }

    function commit(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        override
        onlyGate
    {
        _persist(account, policyId, _process(account, policyId, ctx.time));
        uint256 sells = _sells(legs);
        if (sells != 0) _windows[account][policyId].add(ctx.time, uint64(sells));
    }

    /// @dev Released sells are given back to level 1's window, to the bucket
    ///      they were placed in (D2), as S2 does.
    function credit(address account, bytes32 policyId, Release calldata release) external override onlyGate {
        if (!_instances[account][policyId].set || release.side != Side.SELL || release.releasedWh == 0) return;
        _windows[account][policyId].credit(block.timestamp, release.placedAt, release.releasedWh);
    }

    // ------------------------------------------------------------------
    // Maintenance
    // ------------------------------------------------------------------

    function poke(address account, bytes32 policyId) external override onlyGate returns (uint256 processed) {
        Run memory run = _process(account, policyId, block.timestamp);
        _persist(account, policyId, run);
        return run.count;
    }

    /// @dev The owner forgives: C, the level and the penalty go, and
    ///      processing resumes at the first slot not yet settled, so that a
    ///      reading too old for the meter's ring can no longer block selling.
    function reset(address account, bytes32 policyId) external override onlyGate {
        Instance storage inst = _instances[account][policyId];
        if (!inst.set) return;
        State storage st = _states[account][policyId];
        PositionLedger.Grid memory g = ledger.gridOf(account);
        uint32 next = st.next;
        if (g.slotSeconds != 0) {
            uint256 settledUntil = block.timestamp > inst.config.settlementLagSeconds
                ? block.timestamp - inst.config.settlementLagSeconds
                : 0;
            // Slots that ended at or before settledUntil are settled.
            uint256 firstUnsettled = settledUntil >= g.origin + g.slotSeconds
                ? (settledUntil - g.origin) / g.slotSeconds
                : 0;
            if (firstUnsettled > next) next = uint32(firstUnsettled);
        }
        _states[account][policyId] = State({next: next, cusum: 0, level: 0, penaltyUntil: 0, lastAlarmAt: 0});
        emit PenaltyReset(account, policyId, next);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Every slot processing can take in at time `t`, in memory.
    function _process(address account, bytes32 policyId, uint256 t) private view returns (Run memory run) {
        Instance storage inst = _instances[account][policyId];
        run.state = _states[account][policyId];
        if (!inst.set) return run;
        Config memory c = inst.config;
        run.slots = new Slot[](c.maxProcess);

        PositionLedger.Grid memory g = ledger.gridOf(account);
        if (g.slotSeconds == 0) return run;
        uint32 first = _firstSlot(g, inst.configuredAt);
        if (run.state.next < first) run.state.next = first;
        bool meterOnGrid = oracle.meterSlotSecondsOf(account) == g.slotSeconds;
        while (run.count < c.maxProcess && _step(account, c, g, meterOnGrid, t, run)) {}
    }

    /// @dev Take in the slot `run.state.next` points at. False when
    ///      processing stops there: not settled, not reconciled, or a sale
    ///      without a reading (then `run.blocked` says whether SELLs stop).
    function _step(
        address account,
        Config memory c,
        PositionLedger.Grid memory g,
        bool meterOnGrid,
        uint256 t,
        Run memory run
    ) private view returns (bool) {
        uint32 slot = run.state.next;
        uint256 start = uint256(g.origin) + uint256(slot) * g.slotSeconds;
        uint256 settledAt = start + g.slotSeconds + c.settlementLagSeconds;
        if (t < settledAt) return false;

        PositionLedger.Position memory p = ledger.positionOf(account, slot);
        uint64 cn = p.clearedSellWh > p.clearedBuyWh ? p.clearedSellWh - p.clearedBuyWh : 0;
        bool reconciled = p.committedBuyWh == p.clearedBuyWh && p.committedSellWh == p.clearedSellWh;
        (bool present, int256 dn) = _delivered(account, uint64(start), meterOnGrid);
        if (!reconciled || (cn != 0 && !present)) {
            run.blocked = p.committedSellWh != 0 && t >= settledAt + c.graceSeconds;
            return false;
        }
        _take(c, t, run, slot, cn, dn);
        return true;
    }

    /// @dev The meter's net export over the slot starting at `start`.
    function _delivered(address account, uint64 start, bool meterOnGrid)
        private
        view
        returns (bool present, int256 dn)
    {
        if (!meterOnGrid) return (false, 0);
        (uint64 importWh, uint64 exportWh, bool held) = oracle.meterAt(account, start);
        return (held, int256(uint256(exportWh)) - int256(uint256(importWh)));
    }

    /// @dev The shortfall into C, and an alarm if C passes h.
    function _take(Config memory c, uint256 t, Run memory run, uint32 slot, uint64 cn, int256 dn) private pure {
        uint64 s;
        if (dn <= 0) s = cn;
        else if (uint256(dn) < cn) s = cn - uint64(uint256(dn));

        uint256 sum = uint256(run.state.cusum) + s;
        uint64 cusum = sum > c.k ? uint64(sum - c.k) : 0;
        Slot memory rec = Slot({slot: slot, cn: cn, dn: dn, s: s, cusum: cusum, alarm: false, level: 0});
        if (cusum > c.h) {
            uint8 level = _effectiveLevel(run.state, c, t) >= 1 ? 2 : 1;
            run.state.level = level;
            run.state.penaltyUntil = uint64(t + c.penaltySeconds);
            run.state.lastAlarmAt = uint64(t);
            run.state.cusum = 0;
            run.alarm = true;
            rec.alarm = true;
            rec.level = level;
        } else {
            run.state.cusum = cusum;
        }
        run.slots[run.count++] = rec;
        run.state.next = slot + 1;
    }

    function _persist(address account, bytes32 policyId, Run memory run) private {
        if (!_instances[account][policyId].set) return;
        _states[account][policyId] = run.state;
        for (uint256 i = 0; i < run.count; ++i) {
            Slot memory s = run.slots[i];
            emit SlotReconciled(account, policyId, s.slot, s.cn, s.dn, s.s, s.cusum);
            if (s.alarm) emit DeliveryAlarm(account, policyId, s.slot, s.level, s.cusum, run.state.penaltyUntil);
        }
    }

    /// @dev The first slot that begins at or after `at`.
    function _firstSlot(PositionLedger.Grid memory g, uint256 at) private pure returns (uint32) {
        if (at <= g.origin) return 0;
        return uint32((at - g.origin + g.slotSeconds - 1) / g.slotSeconds);
    }

    /// @dev The level after decay: one step per W_esc since the last alarm.
    function _effectiveLevel(State memory st, Config memory c, uint256 t) private pure returns (uint8) {
        if (st.level == 0 || c.escalationSeconds == 0) return st.level;
        uint256 steps = t > st.lastAlarmAt ? (t - st.lastAlarmAt) / c.escalationSeconds : 0;
        return steps >= st.level ? 0 : uint8(st.level - steps);
    }

    /// @dev The Wh a submission places on the SELL side.
    function _sells(Order[] calldata legs) private pure returns (uint256 sells) {
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind == OrderKind.PLACE && legs[i].side == Side.SELL) sells += legs[i].qtyWh;
        }
    }
}
