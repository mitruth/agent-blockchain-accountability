// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyBase} from "./PolicyBase.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {
    Order, OrderKind, Side, ConfigChange, Verdict, CheckContext, CheckResult, Release
} from "../gate/GateTypes.sol";

/// @title StaticOrderPolicy
/// @notice The per-action bounds (spec 6.1): each order on its own, whatever
///         came before it.
///
///   A1  quantity      qtyWh <= min(maxQtyWh, ratedPowerW x slot length),
///                     the second term in Wh rounded down (spec v0.2, C1); and
///                     qtyWh >= minQtyWh, so dust orders cannot fill the
///                     ledger's open-order bound (C2)
///   A2  value         value <= maxValue, at the limit price, rounded up (D12)
///   A3  price         SELL: price >= sellFloor; BUY: price <= buyCeiling
///   A3T tariff band   when the owner turns it on (spec v0.2, A3T), against
///                     the signed tariff of the order's slot, retail r and
///                     feed-in f: BUY: price <= r x (1 + buyMarkup);
///                     SELL: price >= f x (1 - sellDiscount); each bound
///                     rounded towards the stricter side. With no usable
///                     tariff for the slot the order cannot be judged and is
///                     rejected. A3 still applies alongside
///   A4  time of day   the slot does not start in a blocked UTC hour for that
///                     side
///   A6  horizon       the slot starts after now and no later than
///                     now + horizonSeconds
///
/// A5 is covered by S3 at horizon 1 (step 5); A7 and A8 are the gate's
/// allowlist and the agent's session.
///
/// Every PLACE leg is checked; a CANCEL leg never is, since it only reduces
/// exposure (spec D10). A submission is rejected if any leg breaks any bound.
/// There is no soft bound: a per-action bound holds or it does not.
///
/// The result's `valueAfter` says which bounds were broken, as a bitmask of
/// the constants below, across all the legs; zero when none was.
///
/// Why A3T cannot walk: its anchor is the retailer's signed tariff, not the
/// agent's own last price, so a sequence of bids can climb at most to the
/// band's edge.
///
/// Stateless towards orders: `commit` and `credit` do nothing.
contract StaticOrderPolicy is PolicyBase {
    uint256 public constant A1_QUANTITY = 1;
    uint256 public constant A2_VALUE = 2;
    uint256 public constant A3_PRICE = 4;
    uint256 public constant A4_TIME_OF_DAY = 8;
    uint256 public constant A6_HORIZON = 16;
    uint256 public constant A1_MIN_QUANTITY = 32;
    uint256 public constant A3T_TARIFF_BAND = 64;

    uint256 private constant BPS = 10_000;

    /// @param maxQtyWh         A1, Wh per order.
    /// @param maxValue         A2, token units per order.
    /// @param sellFloor        A3, the lowest SELL price, token units per kWh.
    /// @param buyCeiling       A3, the highest BUY price, token units per kWh.
    /// @param buyBlockedHours  A4, bit h set: no BUY for a slot starting in UTC
    ///                         hour h (0 to 23).
    /// @param sellBlockedHours A4, the same for SELL.
    /// @param horizonSeconds   A6, how far ahead a slot may start.
    /// @param minQtyWh         A1, the smallest order, Wh.
    /// @param ratedPowerW      A1, P_rated: the most the house can deliver or
    ///                         take, W. Never zero.
    /// @param tariffBand       A3T on.
    /// @param buyMarkupBps     A3T, beta_b: how far above retail a BUY may go.
    /// @param sellDiscountBps  A3T, beta_s: how far below feed-in a SELL may go;
    ///                         at most 10,000.
    struct Config {
        uint64 maxQtyWh;
        uint64 maxValue;
        uint64 sellFloor;
        uint64 buyCeiling;
        uint24 buyBlockedHours;
        uint24 sellBlockedHours;
        uint32 horizonSeconds;
        uint64 minQtyWh;
        uint32 ratedPowerW;
        bool tariffBand;
        uint16 buyMarkupBps;
        uint16 sellDiscountBps;
    }

    uint256 private constant CONFIG_LENGTH = 12 * 32;

    mapping(address account => mapping(bytes32 policyId => Config)) private _configs;
    mapping(address account => mapping(bytes32 policyId => bool)) public isConfigured;

    constructor(address gate_) PolicyBase(gate_) {}

    function configOf(address account, bytes32 policyId) external view returns (Config memory) {
        return _configs[account][policyId];
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice Tighter is: a lower maxQtyWh, maxValue, buyCeiling or
    ///         ratedPowerW; a higher sellFloor or minQtyWh; more blocked hours;
    ///         a shorter horizon; turning the tariff band on, or a lower
    ///         markup or discount. A change that loosens any of them is a
    ///         WIDEN. INVALID: a zero ratedPowerW, minQtyWh above maxQtyWh, a
    ///         sell discount above 100 %.
    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != CONFIG_LENGTH) return ConfigChange.INVALID;
        Config memory next = abi.decode(config, (Config));
        if (next.ratedPowerW == 0 || next.minQtyWh > next.maxQtyWh || next.sellDiscountBps > BPS) {
            return ConfigChange.INVALID;
        }
        if (!isConfigured[account][policyId]) return ConfigChange.TIGHTEN;

        Config memory current = _configs[account][policyId];
        bool wider = next.maxQtyWh > current.maxQtyWh || next.maxValue > current.maxValue
            || next.sellFloor < current.sellFloor || next.buyCeiling > current.buyCeiling
            || (current.buyBlockedHours & ~next.buyBlockedHours) != 0
            || (current.sellBlockedHours & ~next.sellBlockedHours) != 0
            || next.horizonSeconds > current.horizonSeconds || next.minQtyWh < current.minQtyWh
            || next.ratedPowerW > current.ratedPowerW || (current.tariffBand && !next.tariffBand)
            || next.buyMarkupBps > current.buyMarkupBps || next.sellDiscountBps > current.sellDiscountBps;
        return wider ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        _configs[account][policyId] = abi.decode(config, (Config));
        isConfigured[account][policyId] = true;
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        delete _configs[account][policyId];
        delete isConfigured[account][policyId];
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
        Config memory c = _configs[account][policyId];
        uint256 broken;
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind != OrderKind.PLACE) continue;
            broken |= _broken(account, c, legs[i], ctx);
        }
        r.valueAfter = broken;
        r.verdict = broken == 0 ? Verdict.EXECUTE : Verdict.REJECT;
    }

    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external override onlyGate {}

    function credit(address, bytes32, Release calldata) external override onlyGate {}

    /// @dev The bounds one placement breaks, as a bitmask.
    function _broken(address account, Config memory c, Order calldata leg, CheckContext calldata ctx)
        private
        view
        returns (uint256 broken)
    {
        uint64 start = IOrderDecoder(ctx.decoder).slotStart(ctx.market, leg.slot);
        uint64 slotSeconds = IOrderDecoder(ctx.decoder).slotStart(ctx.market, leg.slot + 1) - start;
        uint256 ratedWh = uint256(c.ratedPowerW) * slotSeconds / 3600;

        if (leg.qtyWh > c.maxQtyWh || leg.qtyWh > ratedWh) broken |= A1_QUANTITY;
        if (leg.qtyWh < c.minQtyWh) broken |= A1_MIN_QUANTITY;
        if (leg.value > c.maxValue) broken |= A2_VALUE;
        if (leg.side == Side.SELL ? leg.price < c.sellFloor : leg.price > c.buyCeiling) broken |= A3_PRICE;

        uint256 hour = (start / 3600) % 24;
        uint24 blocked = leg.side == Side.SELL ? c.sellBlockedHours : c.buyBlockedHours;
        if ((uint256(blocked) >> hour) & 1 == 1) broken |= A4_TIME_OF_DAY;

        if (start <= ctx.time || start > uint256(ctx.time) + c.horizonSeconds) broken |= A6_HORIZON;
        if (c.tariffBand && _outsideBand(account, c, leg, start, ctx.oracle)) broken |= A3T_TARIFF_BAND;
    }

    /// @dev A3T. Outside the band, or not judgeable: no usable tariff for the
    ///      slot. The BUY bound rounds down and the SELL bound up, so neither
    ///      lets in a unit the exact band would not.
    function _outsideBand(address account, Config memory c, Order calldata leg, uint64 start, address oracle)
        private
        view
        returns (bool)
    {
        (uint64 retail, uint64 feedIn, bool usable) = OracleVerifier(oracle).tariffAt(account, start);
        if (!usable) return true;
        if (leg.side == Side.BUY) return leg.price > uint256(retail) * (BPS + c.buyMarkupBps) / BPS;
        return leg.price < (uint256(feedIn) * (BPS - c.sellDiscountBps) + BPS - 1) / BPS;
    }
}
