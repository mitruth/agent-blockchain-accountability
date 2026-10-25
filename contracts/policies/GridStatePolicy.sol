// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {GridState, GridLevel, GridDirection} from "../oracle/OracleTypes.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

interface IGridGate {
    function ledger() external view returns (PositionLedger);
    function oracle() external view returns (OracleVerifier);
}

/// @title GridStatePolicy
/// @notice A10, the grid-state direction gate (spec v0.2 sections 5 S12 and
///         11.3): while the grid operator declares an alert, the agent may
///         not trade against the grid's need.
///
/// Precursors of a blackout are visible minutes ahead, and household agents
/// add to them through correlated behaviour. A signed state from the operator
/// narrows every agent's authority at once. Stateless: each submission is
/// judged only against the current state and the ledger.
///
/// While the account's operator's latest state is fresh and its level is at
/// least `minLevel` (ALERT by default), for every slot that starts within the
/// state's `horizonSlots` from now, with dNe the change the submission makes
/// to that slot's committed net export (PLACE added, CANCEL taken away, across
/// its legs):
///
///   DEFICIT   refused if some slot's dNe < 0: a BUY placement, or a SELL
///             cancelled or reduced
///   SURPLUS   refused if some slot's dNe > 0: the mirror image
///   NONE      at EMERGENCY, any placement in the horizon is refused;
///             cancellations pass. At ALERT, nothing is refused
///
/// **The declared exception to D10.** In DEFICIT, cancelling or reducing a
/// SELL reduces the owner's exposure but takes energy from a grid that needs
/// it: A10 refuses it, and SURPLUS the same for a BUY. Judging the net change
/// per slot, and not each leg, lets a modification that raises a sale in
/// DEFICIT through.
///
/// **Fail open (D18).** A stale or missing state is NORMAL. The policy
/// restricts the owner beyond the owner's own interest, so an oracle outage
/// must not freeze trading.
///
/// `CheckResult`: before, the level in force (0 when not fresh); after, the
/// direction (0 DEFICIT, 1 SURPLUS, 2 NONE); soft `minLevel`; hard the
/// state's horizon in slots.
contract GridStatePolicy is PolicyBase {
    /// @param minLevel The level from which the rules apply: 1 ALERT, or 2
    ///                 EMERGENCY only (looser).
    struct Config {
        uint8 minLevel;
    }

    struct Instance {
        bool set;
        uint8 minLevel;
    }

    struct Change {
        uint32 slot;
        int256 ne;
        bool placed;
    }

    uint256 private constant CONFIG_LENGTH = 32;

    PositionLedger public immutable ledger;
    OracleVerifier public immutable oracle;

    mapping(address account => mapping(bytes32 policyId => Instance)) private _instances;

    constructor(address gate_) PolicyBase(gate_) {
        ledger = IGridGate(gate_).ledger();
        oracle = IGridGate(gate_).oracle();
    }

    function configOf(address account, bytes32 policyId) external view returns (Config memory) {
        return Config({minLevel: _instances[account][policyId].minLevel});
    }

    /// @notice INVALID: malformed, or a level other than ALERT (1) or
    ///         EMERGENCY (2). WIDEN: a higher level. TIGHTEN otherwise.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (n.minLevel != uint8(GridLevel.ALERT) && n.minLevel != uint8(GridLevel.EMERGENCY)) return ConfigChange.INVALID;
        Instance storage inst = _instances[account][policyId];
        if (!inst.set) return ConfigChange.TIGHTEN;
        return n.minLevel > inst.minLevel ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        _instances[account][policyId] = Instance({set: true, minLevel: abi.decode(config, (Config)).minLevel});
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        delete _instances[account][policyId];
    }

    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata ctx)
        external
        view
        override
        returns (CheckResult memory r)
    {
        Instance memory inst = _instances[account][policyId];
        (GridState memory s, bool fresh) = oracle.gridStateOf(account);
        r.soft = inst.minLevel;
        r.verdict = Verdict.EXECUTE;
        if (!fresh || uint8(s.level) < inst.minLevel) return r;
        r.valueBefore = uint8(s.level);
        r.valueAfter = uint8(s.direction);
        r.hard = s.horizonSlots;

        PositionLedger.Grid memory g = ledger.gridOf(account);
        uint256 horizonEnd = uint256(ctx.time) + uint256(s.horizonSlots) * g.slotSeconds;
        Change[] memory changes = _changes(legs);
        for (uint256 k = 0; k < changes.length; ++k) {
            Change memory c = changes[k];
            uint256 start = uint256(g.origin) + uint256(c.slot) * g.slotSeconds;
            // In the horizon: not yet ended, and starting before its end.
            if (start + g.slotSeconds <= ctx.time || start >= horizonEnd) continue;
            bool refused = s.direction == GridDirection.DEFICIT
                ? c.ne < 0
                : s.direction == GridDirection.SURPLUS ? c.ne > 0 : (s.level == GridLevel.EMERGENCY && c.placed);
            if (refused) {
                r.verdict = Verdict.REJECT;
                return r;
            }
        }
    }

    /// @dev Stateless: nothing to record.
    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external override onlyGate {}

    /// @dev Stateless: nothing to give back.
    function credit(address, bytes32, Release calldata) external override onlyGate {}

    /// @dev The legs' change to each distinct slot's net export, and whether
    ///      any of its legs places.
    function _changes(Order[] calldata legs) private pure returns (Change[] memory out) {
        Change[] memory all = new Change[](legs.length);
        uint256 distinct;
        for (uint256 i = 0; i < legs.length; ++i) {
            Order calldata leg = legs[i];
            uint256 k = 0;
            while (k < distinct && all[k].slot != leg.slot) ++k;
            if (k == distinct) all[distinct++].slot = leg.slot;
            int256 qty = leg.kind == OrderKind.PLACE ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));
            all[k].ne += leg.side == Side.SELL ? qty : -qty;
            if (leg.kind == OrderKind.PLACE) all[k].placed = true;
        }
        out = new Change[](distinct);
        for (uint256 k = 0; k < distinct; ++k) out[k] = all[k];
    }
}
