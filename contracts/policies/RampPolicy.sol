// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {IGateLedger} from "./HorizonLib.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";
import {Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release} from "../gate/GateTypes.sol";

/// @title RampPolicy
/// @notice S5, the ramp between consecutive slots (spec 6.6): the account's net
///         position may not jump by more than R_max from one slot to the next.
///
/// netPos(t) = committed buy - committed sell, from the ledger (D8). For every
/// slot t a submission changes, the policy looks at the steps to both
/// neighbours, |netPos(t) - netPos(t - 1)| and |netPos(t + 1) - netPos(t)|,
/// with the submission. A step above R_max that the submission made larger is
/// a rejection; one above the soft bound, a flag. A step the submission leaves
/// as it was, or makes smaller, never counts against it (D10): a cancellation,
/// or an order that smooths the profile, passes even when the profile around
/// it is already too steep.
///
/// The value is the largest of those steps, before and after the submission,
/// in Wh. S5 needs no oracle reading.
contract RampPolicy is PolicyBase {
    uint256 private constant CONFIG_LENGTH = 2 * 32;

    /// @param softStepWh S.
    /// @param maxStepWh  R_max, the hard bound.
    struct Config {
        uint64 softStepWh;
        uint64 maxStepWh;
    }

    PositionLedger public immutable ledger;

    mapping(address account => mapping(bytes32 policyId => Config)) private _configs;

    constructor(address gate_) PolicyBase(gate_) {
        ledger = IGateLedger(gate_).ledger();
    }

    function configOf(address account, bytes32 policyId) external view returns (Config memory) {
        return _configs[account][policyId];
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice INVALID: malformed, no hard bound, or S above it. WIDEN: a
    ///         higher bound, soft or hard.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory n = abi.decode(config, (Config));
        if (n.maxStepWh == 0 || n.softStepWh > n.maxStepWh) return ConfigChange.INVALID;
        Config memory o = _configs[account][policyId];
        if (o.maxStepWh == 0) return ConfigChange.TIGHTEN;
        return n.softStepWh > o.softStepWh || n.maxStepWh > o.maxStepWh ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
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

    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata)
        external
        view
        override
        returns (CheckResult memory r)
    {
        Config memory c = _configs[account][policyId];
        r.soft = c.softStepWh;
        r.hard = c.maxStepWh;
        bool flag;
        bool reject;
        for (uint256 i = 0; i < legs.length; ++i) {
            if (_seenBefore(legs, i, legs[i].slot)) continue;
            Steps memory s_ = _around(account, c, legs, legs[i].slot);
            if (s_.before > r.valueBefore) r.valueBefore = s_.before;
            if (s_.after_ > r.valueAfter) r.valueAfter = s_.after_;
            reject = reject || s_.reject;
            flag = flag || s_.flag;
        }
        r.verdict = reject ? Verdict.REJECT : flag ? Verdict.FLAG : Verdict.EXECUTE;
    }

    /// @dev The steps around one slot: the largest before and after, and
    ///      whether a step the submission made larger crossed a bound.
    struct Steps {
        uint256 before;
        uint256 after_;
        bool reject;
        bool flag;
    }

    /// @dev The steps from slot t - 1 to t and from t to t + 1, as they stand
    ///      and with the submission.
    function _around(address account, Config memory c, Order[] calldata legs, uint32 t)
        private
        view
        returns (Steps memory s_)
    {
        uint32 from = t == 0 ? 0 : t - 1;
        PositionLedger.Position[] memory p = ledger.positionsOf(account, from, t == 0 ? 2 : 3);
        for (uint256 j = 0; j + 1 < p.length; ++j) {
            uint32 slotA = from + uint32(j);
            int256 stepBefore = _net(p[j + 1]) - _net(p[j]);
            uint256 before = _abs(stepBefore);
            uint256 after_ = _abs(stepBefore + _delta(legs, slotA + 1) - _delta(legs, slotA));
            if (before > s_.before) s_.before = before;
            if (after_ > s_.after_) s_.after_ = after_;
            if (after_ > before) {
                if (after_ > c.maxStepWh) s_.reject = true;
                else if (after_ > c.softStepWh) s_.flag = true;
            }
        }
    }

    /// @dev S5 reads the ledger's committed positions; nothing of its own.
    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external view override onlyGate {}

    function credit(address, bytes32, Release calldata) external view override onlyGate {}

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _net(PositionLedger.Position memory p) private pure returns (int256) {
        return int256(uint256(p.committedBuyWh)) - int256(uint256(p.committedSellWh));
    }

    /// @dev What the submission changes in slot `t`'s net position: a placed
    ///      buy adds, a placed sell takes away, a cancellation the reverse.
    function _delta(Order[] calldata legs, uint32 t) private pure returns (int256 d) {
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].slot != t) continue;
            int256 qty = int256(uint256(legs[i].qtyWh));
            bool adds = (legs[i].side == Side.BUY) == (legs[i].kind == OrderKind.PLACE);
            d += adds ? qty : -qty;
        }
    }

    function _seenBefore(Order[] calldata legs, uint256 i, uint32 t) private pure returns (bool) {
        for (uint256 j = 0; j < i; ++j) {
            if (legs[j].slot == t) return true;
        }
        return false;
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
