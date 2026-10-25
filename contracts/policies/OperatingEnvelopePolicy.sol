// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

interface IEnvelopeGate {
    function ledger() external view returns (PositionLedger);
    function oracle() external view returns (OracleVerifier);
}

/// @title OperatingEnvelopePolicy
/// @notice S10, operating-envelope compliance (spec v0.2 section 5): the
///         account's committed net position in every slot, across all its
///         markets, within the DSO's operating envelope for its connection.
///
/// Joint feasibility of a network needs its model, and DSOs share envelopes
/// instead: per slot, the most the connection may export and import. A market
/// enforces what is traded on it; S10 enforces the owner's whole position, on
/// every venue (C4).
///
/// Per slot t a submission touches, before and after its legs (PLACE added,
/// CANCEL taken away, as the decoder reports them):
///
///   ne(t) = committedSell(t) - committedBuy(t)     net export, all markets
///   the limits E_exp(t), E_imp(t): the signed envelope's for the slot; with
///   none usable (none posted, stale, or not covering t), the owner's static
///   connection limit, P_conn times the slot length, both ways. A fallback
///   to static rather than a refusal, declared fail-open: the connection's
///   rating is always known.
///   excess(t) = max(0, ne - E_exp) + max(0, -ne - E_imp)
///   use(t)    = ne / E_exp if exporting, -ne / E_imp if importing, in bps
///
/// **Verdicts.** REJECT when the submission makes some slot's excess larger.
/// FLAG when it moves some slot's use above σ and higher than before. A
/// submission that only reduces never does either (D10); and when an
/// envelope update tightens a limit below what is already committed, orders
/// that worsen the excess are refused and cancellations pass.
///
/// **Stated limitation.** The envelope bounds physical flow at the
/// connection, which includes uncontracted PV and load. The committed net
/// position is a proxy for it: S10 does not claim physical compliance.
///
/// `CheckResult`: the largest use over the touched slots before and after, in
/// bps; soft σ; hard 10,000 (the limit).
contract OperatingEnvelopePolicy is PolicyBase {
    /// @param connectionW P_conn, the connection's rating in W: the static
    ///                    limit both ways when no envelope applies.
    /// @param softBps     σ: use above this, in bps of the limit, is flagged.
    struct Config {
        uint32 connectionW;
        uint16 softBps;
    }

    struct Instance {
        bool set;
        Config config;
    }

    /// @dev One slot, before and after.
    struct Slot {
        uint32 slot;
        int256 buy;
        int256 sell;
    }

    uint256 private constant CONFIG_LENGTH = 2 * 32;
    uint256 private constant BPS = 10_000;
    uint256 private constant UNBOUNDED = type(uint256).max;

    PositionLedger public immutable ledger;
    OracleVerifier public immutable oracle;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;

    constructor(address gate_) PolicyBase(gate_) {
        ledger = IEnvelopeGate(gate_).ledger();
        oracle = IEnvelopeGate(gate_).oracle();
    }

    function configOf(address account, bytes32 policyId) external view returns (Config memory) {
        return _instances[account][policyId].config;
    }

    /// @notice The limits in force for `slot` of the account's grid: the
    ///         envelope's if usable, else the static ones, and which.
    function limitsAt(address account, bytes32 policyId, uint32 slot)
        public
        view
        returns (uint64 exportWh, uint64 importWh, bool fromEnvelope)
    {
        PositionLedger.Grid memory g = ledger.gridOf(account);
        uint64 start = uint64(uint256(g.origin) + uint256(slot) * g.slotSeconds);
        (uint64 e, uint64 i, bool usable) = oracle.envelopeAt(account, start);
        if (usable) return (e, i, true);
        uint64 stat = uint64((uint256(_instances[account][policyId].config.connectionW) * g.slotSeconds) / 3600);
        return (stat, stat, false);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, or σ above 10,000. WIDEN: a higher P_conn
    ///         or σ. TIGHTEN otherwise.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (n.softBps > BPS) return ConfigChange.INVALID;
        Instance storage inst = _instances[account][policyId];
        if (!inst.set) return ConfigChange.TIGHTEN;
        Config memory o = inst.config;
        return n.connectionW > o.connectionW || n.softBps > o.softBps ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        _instances[account][policyId] = Instance({set: true, config: abi.decode(config, (Config))});
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        delete _instances[account][policyId];
    }

    // ------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------

    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata)
        external
        view
        override
        returns (CheckResult memory r)
    {
        uint16 soft = _instances[account][policyId].config.softBps;
        r.soft = soft;
        r.hard = BPS;
        bool worse;
        bool flag;
        Slot[] memory slots = _changes(legs);
        for (uint256 k = 0; k < slots.length; ++k) {
            (uint256 useBefore, uint256 useAfter, uint256 excessBefore, uint256 excessAfter) =
                _judge(account, policyId, slots[k]);
            if (useBefore > r.valueBefore) r.valueBefore = useBefore;
            if (useAfter > r.valueAfter) r.valueAfter = useAfter;
            if (excessAfter > excessBefore) worse = true;
            if (useAfter > soft && useAfter > useBefore) flag = true;
        }
        if (worse) r.verdict = Verdict.REJECT;
        else if (flag) r.verdict = Verdict.FLAG;
        else r.verdict = Verdict.EXECUTE;
    }

    /// @dev Stateless: nothing to record.
    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external override onlyGate {}

    /// @dev Stateless: nothing to give back.
    function credit(address, bytes32, Release calldata) external override onlyGate {}

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev The legs' change to each distinct slot: Wh bought and sold.
    function _changes(Order[] calldata legs) private pure returns (Slot[] memory out) {
        Slot[] memory all = new Slot[](legs.length);
        uint256 distinct;
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            uint256 k = 0;
            while (k < distinct && all[k].slot != leg.slot) ++k;
            if (k == distinct) all[distinct++].slot = leg.slot;
            int256 qty = leg.kind == OrderKind.PLACE ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));
            if (leg.side == Side.BUY) all[k].buy += qty;
            else all[k].sell += qty;
        }
        out = new Slot[](distinct);
        for (uint256 k = 0; k < distinct; ++k) out[k] = all[k];
    }

    function _judge(address account, bytes32 policyId, Slot memory s)
        private
        view
        returns (uint256 useBefore, uint256 useAfter, uint256 excessBefore, uint256 excessAfter)
    {
        PositionLedger.Position memory p = ledger.positionOf(account, s.slot);
        int256 before = int256(uint256(p.committedSellWh)) - int256(uint256(p.committedBuyWh));
        int256 after_ = before + s.sell - s.buy;
        (uint64 exportWh, uint64 importWh,) = limitsAt(account, policyId, s.slot);
        useBefore = _use(before, exportWh, importWh);
        useAfter = _use(after_, exportWh, importWh);
        excessBefore = _excess(before, exportWh, importWh);
        excessAfter = _excess(after_, exportWh, importWh);
    }

    function _use(int256 ne, uint64 exportWh, uint64 importWh) private pure returns (uint256) {
        if (ne == 0) return 0;
        uint256 magnitude = ne > 0 ? uint256(ne) : uint256(-ne);
        uint256 limit = ne > 0 ? exportWh : importWh;
        if (limit == 0) return UNBOUNDED;
        return (magnitude * BPS + limit - 1) / limit;
    }

    function _excess(int256 ne, uint64 exportWh, uint64 importWh) private pure returns (uint256) {
        if (ne > 0) return uint256(ne) > exportWh ? uint256(ne) - exportWh : 0;
        uint256 imported = uint256(-ne);
        return imported > importWh ? imported - importWh : 0;
    }
}
