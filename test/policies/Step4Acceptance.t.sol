// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MarketFixture} from "../market/MarketFixture.sol";
import {MiniAccount} from "../../contracts/harness/MiniAccount.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {ProsumerDecoder} from "../../contracts/market/ProsumerDecoder.sol";
import {Prosumer} from "../../contracts/market/Prosumer.sol";
import {MarketTypes} from "../../contracts/market/MarketTypes.sol";
import {StaticOrderPolicy} from "../../contracts/policies/StaticOrderPolicy.sol";
import {WindowPolicy} from "../../contracts/policies/WindowPolicy.sol";
import {CancelQuotaPolicy} from "../../contracts/policies/CancelQuotaPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";

/// Step 4's acceptance criteria (spec Section 9), on the ported P2P market
/// through the gate: an agent trading for Alice attacks her policies.
///
///   attack                          blocked under SLIDING by   passes under (spec 9.1)
///   split-leg drain                 S1                         per-action bounds only
///   boundary burst                  S1                         S1 on TUMBLING
///   idle-then-burst                 S1                         S1 on REFILL, on STREAM
///   place-and-cancel near the gate  S6                         S6 without the gate weight
///
/// Each attack runs against the baseline the attack matrix names for it: a
/// boundary burst is a weakness of tumbling windows, not of token buckets.
/// The last group measures gas per order, per policy and combined.
///
/// Prices are 0.25 per kWh: 1000 Wh is worth 250,000 units. Time starts at
/// 09:00 UTC; the day-ahead session's trading closes the next morning at 08:00.
contract Step4AcceptanceTest is MarketFixture {
    uint256 internal constant EXECUTOR = 2;
    uint64 internal constant PRICE = 250_000;
    uint64 internal constant DAY = 86_400;

    address internal aliceOwner = makeAddr("aliceOwner");
    address internal agent = makeAddr("agent");

    MiniAccount internal aliceAccount;
    PositionLedger internal ledger;
    PolicyGate internal gate;
    ProsumerDecoder internal decoder;

    StaticOrderPolicy internal statics;
    WindowPolicy internal windows;
    CancelQuotaPolicy internal quota;

    function _owners() internal override returns (address, address) {
        aliceAccount = new MiniAccount(aliceOwner);
        return (address(aliceAccount), makeAddr("bob"));
    }

    function _approveProsumer(address owner_, address prosumer) internal override {
        if (owner_ != address(aliceAccount)) return super._approveProsumer(owner_, prosumer);
        vm.startPrank(aliceOwner);
        aliceAccount.execute(
            address(token), 0, abi.encodeCall(token.setPaymentAllowance, (prosumer, type(uint256).max))
        );
        aliceAccount.execute(address(token), 0, abi.encodeCall(token.setApprovalForAll, (prosumer, true)));
        vm.stopPrank();
    }

    function setUp() public override {
        super.setUp();
        ledger = new PositionLedger();
        gate = new PolicyGate(ledger, new OracleVerifier(), 48);
        decoder = new ProsumerDecoder();
        statics = new StaticOrderPolicy(address(gate));
        windows = new WindowPolicy(address(gate));
        quota = new CancelQuotaPolicy(address(gate));

        vm.startPrank(aliceOwner);
        aliceAccount.installModule(EXECUTOR, address(gate), "");
        aliceAccount.execute(address(ledger), 0, abi.encodeCall(ledger.setWriter, (address(gate), true)));
        aliceAccount.enableSession(agent, address(gate), PolicyGate.submit.selector, type(uint48).max);
        bytes4[4] memory selectors = [
            Prosumer.placeBids.selector,
            Prosumer.placeOffers.selector,
            Prosumer.cancelOrder.selector,
            Prosumer.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            aliceAccount.execute(address(gate), 0, abi.encodeCall(gate.setDecoder, (address(aliceP), selectors[i], decoder)));
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Split-leg drain
    // ------------------------------------------------------------------

    /// Each order is within the per-action bound of 1000 Wh. Alone, the
    /// per-action bounds let the agent spend whatever it likes by splitting:
    /// 24 kWh in one call. S1, a 5 kWh budget over a sliding day, refuses the
    /// batch, and refuses the sixth order when the drain is spread over calls.
    function test_splitLegDrain_passesUnderPerActionBoundsOnly() public {
        _addStatic();
        assertEq(_bidBatch(24, 1000), 24, "24 legs of 1000 Wh, all within A1, all placed");
        assertEq(_spent(), 24 * 250_000);
    }

    function test_splitLegDrain_isBlockedByS1() public {
        _addStatic();
        _addS1(_sliding(1_250_000));
        assertEq(_bidBatch(24, 1000), 0, "the batch is checked as a whole: refused");

        uint256 placed;
        for (uint16 i = 0; i < 24; ++i) placed += _bidBatch(1, 1000);
        assertEq(placed, 5, "spread over calls: the sixth is refused");
        assertEq(_spent(), 1_250_000, "at most the budget");
    }

    // ------------------------------------------------------------------
    // Boundary burst
    // ------------------------------------------------------------------

    /// The budget spent in the last second before midnight UTC, and again in
    /// the first second after.
    function test_boundaryBurst_passesUnderTumbling() public {
        WindowLib.Config memory tumbling;
        tumbling.kind = WindowLib.Kind.TUMBLING;
        tumbling.step = uint32(DAY);
        tumbling.anchor = 0; // UTC days
        tumbling.cap = 1_250_000;
        _addS1(tumbling);
        assertEq(_burstAroundMidnight(), 2 * 1_250_000, "twice the budget within two seconds");
    }

    function test_boundaryBurst_isBlockedBySliding() public {
        _addS1(_sliding(1_250_000));
        assertEq(_burstAroundMidnight(), 1_250_000, "the budget once");
    }

    // ------------------------------------------------------------------
    // Idle-then-burst
    // ------------------------------------------------------------------
    //
    // Every class at the same long-run rate, H a day, H = 1,200,000 units
    // (4.8 kWh). REFILL gives back H/24 an hour up to a week's allowance;
    // STREAM unlocks H/24 an hour up to a month's. After a week idle the agent
    // spends what it can within an hour.

    uint64 internal constant H = 1_200_000;

    function test_idleThenBurst_passesUnderRefill() public {
        WindowLib.Config memory refill;
        refill.kind = WindowLib.Kind.REFILL;
        refill.step = 3600;
        refill.rate = H / 24;
        refill.cap = 7 * H;
        _addS1(refill);
        assertEq(_burstAfterAWeek(), 7 * H, "a week's budget in an hour");
    }

    function test_idleThenBurst_passesUnderStream() public {
        WindowLib.Config memory stream;
        stream.kind = WindowLib.Kind.STREAM;
        stream.step = 3600;
        stream.anchor = uint40(block.timestamp);
        stream.rate = H / 24;
        stream.cap = 30 * H;
        _addS1(stream);
        assertEq(_burstAfterAWeek(), 7 * H, "a week's unlocked allowance in an hour");
    }

    function test_idleThenBurst_isBlockedBySliding() public {
        _addS1(_sliding(H));
        assertEq(_burstAfterAWeek(), H, "one day's budget, whatever came before");
    }

    // ------------------------------------------------------------------
    // Place-and-cancel near the gate
    // ------------------------------------------------------------------
    //
    // The agent reserves headroom with four orders of 1500 Wh, then cancels
    // them 20 minutes before trading closes. S6 allows 6000 cancelled Wh an
    // hour; within 30 minutes of the gate a cancellation weighs three times.

    function test_placeAndCancelNearTheGate_passesWithoutTheGateWeight() public {
        _addS6(100);
        assertEq(_placeAndCancelNearTheGate(), 4, "every reservation withdrawn at the last minute");
    }

    function test_placeAndCancelNearTheGate_isBlockedByS6() public {
        _addS6(300);
        assertEq(_placeAndCancelNearTheGate(), 1, "one withdrawn; the rest must stand");
    }

    // ------------------------------------------------------------------
    // Gas: per order, per policy and combined (step 4)
    // ------------------------------------------------------------------
    //
    // The gas of the agent's whole submission, its session call included,
    // for a one-leg bid, a 24-leg batch and a cancellation, in steady state:
    // each is measured after a first submission of the same kind.

    function test_gas_noPolicy() public {
        _reportGas("no policy");
    }

    function test_gas_staticOrderPolicy() public {
        _addStatic();
        _reportGas("A1-A6");
    }

    function test_gas_S1() public {
        _addS1(_sliding(type(uint64).max));
        _reportGas("S1");
    }

    function test_gas_S2ExportAndImport() public {
        _addS2();
        _reportGas("S2 export + import");
    }

    function test_gas_S6() public {
        _addS6(300);
        _reportGas("S6");
    }

    function test_gas_allCombined() public {
        _addStatic();
        _addS1(_sliding(type(uint64).max));
        _addS2();
        _addS6(300);
        _reportGas("all: A1-A6, S1, S2 x2, S6");
    }

    // ------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------

    function _burstAroundMidnight() internal returns (uint256) {
        uint256 midnight = (block.timestamp / DAY + 1) * DAY;
        vm.warp(midnight - 1);
        _bidBatch(1, 5000);
        vm.warp(midnight + 1);
        _bidBatch(1, 5000);
        return _spent();
    }

    function _burstAfterAWeek() internal returns (uint256) {
        vm.warp(block.timestamp + 7 * DAY);
        session = _openDayAhead();
        for (uint16 i = 0; i < 24; ++i) {
            if (_bidBatch(1, 4800) == 0) break;
        }
        return _spent();
    }

    /// @dev Returns how many of the four reservations the agent withdrew.
    function _placeAndCancelNearTheGate() internal returns (uint256 withdrawn) {
        uint256 closes = session.config().closesAt;
        vm.warp(closes - 1 hours);
        bytes32[] memory ids = new bytes32[](4);
        for (uint16 i = 0; i < 4; ++i) {
            _bidBatch(1, 1500);
            bytes32[] memory all = session.bidIds();
            ids[i] = all[all.length - 1];
        }
        vm.warp(closes - 20 minutes);
        for (uint256 i = 0; i < 4; ++i) {
            _submit(abi.encodeCall(Prosumer.cancelOrder, (ids[i])));
            if (session.orderOf(ids[i]).status == MarketTypes.OrderStatus.CANCELLED) withdrawn++;
        }
    }

    function _reportGas(string memory label) internal {
        // A first submission of each kind, so that what follows is steady state.
        bytes32 first = _firstBid();
        _bidBatch(24, 100);
        _submit(abi.encodeCall(Prosumer.cancelOrder, (first)));

        uint256 one = _gasOf(_bidsCall(1, 100));
        uint256 batch = _gasOf(_bidsCall(24, 100));
        bytes32 target = _firstBid();
        uint256 cancel = _gasOf(abi.encodeCall(Prosumer.cancelOrder, (target)));

        emit log_named_string("policies", label);
        emit log_named_uint("  gas, one bid", one);
        emit log_named_uint("  gas, 24-leg batch", batch);
        emit log_named_uint("  gas, cancel", cancel);
    }

    // ------------------------------------------------------------------
    // Policies
    // ------------------------------------------------------------------

    function _add(IPolicy policy, bytes32 id, bytes memory config) internal {
        vm.prank(aliceOwner);
        aliceAccount.execute(address(gate), 0, abi.encodeCall(gate.addPolicy, (policy, id, config)));
        assertTrue(gate.hasPolicy(address(aliceAccount), policy, id), "policy added");
    }

    function _addStatic() internal {
        StaticOrderPolicy.Config memory c;
        c.maxQtyWh = 1000;
        c.maxValue = 1_000_000;
        c.sellFloor = 0;
        c.buyCeiling = 1_000_000;
        c.horizonSeconds = uint32(3 * DAY);
        c.ratedPowerW = type(uint32).max;
        _add(statics, keccak256("A"), abi.encode(c));
    }

    function _sliding(uint64 cap) internal pure returns (WindowLib.Config memory w) {
        w.kind = WindowLib.Kind.SLIDING;
        w.step = 3600;
        w.buckets = 24;
        w.cap = cap;
    }

    function _addS1(WindowLib.Config memory w) internal {
        _add(windows, keccak256("S1"), abi.encode(WindowPolicy.Config({quantity: WindowPolicy.Quantity.BUY_VALUE, soft: w.cap, window: w})));
    }

    function _addS2() internal {
        WindowLib.Config memory w = _sliding(type(uint64).max);
        _add(windows, keccak256("S2 export"), abi.encode(WindowPolicy.Config({quantity: WindowPolicy.Quantity.SELL_WH, soft: w.cap, window: w})));
        _add(windows, keccak256("S2 import"), abi.encode(WindowPolicy.Config({quantity: WindowPolicy.Quantity.BUY_WH, soft: w.cap, window: w})));
    }

    function _addS6(uint32 gateWeightPercent) internal {
        CancelQuotaPolicy.Config memory c;
        c.window.kind = WindowLib.Kind.SLIDING;
        c.window.step = 300;
        c.window.buckets = 12;
        c.maxCancelledWh = 6000;
        c.maxMessages = 1000;
        c.gateWeightPercent = gateWeightPercent;
        c.gateWindowSeconds = 30 minutes;
        c.ratioPercent = 100;
        c.freeCancelWh = 0;
        _add(quota, keccak256("S6"), abi.encode(c));
    }

    // ------------------------------------------------------------------
    // The agent's calls
    // ------------------------------------------------------------------

    function _submit(bytes memory call) internal {
        vm.prank(agent);
        aliceAccount.executeAsSession(address(gate), abi.encodeCall(gate.submit, (address(aliceP), call, new SignedReading[](0))));
    }

    function _bidsCall(uint16 n, uint64 qtyWh) internal pure returns (bytes memory) {
        MarketTypes.OrderRequest[] memory reqs = new MarketTypes.OrderRequest[](n);
        for (uint16 i = 0; i < n; ++i) reqs[i] = _req(i % 24, qtyWh, PRICE);
        return abi.encodeCall(Prosumer.placeBids, (MarketTypes.EnergyType.ELECTRICITY, reqs));
    }

    /// @dev Submit n bids in one call; returns how many the market received.
    function _bidBatch(uint16 n, uint64 qtyWh) internal returns (uint256) {
        uint256 before = session.bidIds().length;
        _submit(_bidsCall(n, qtyWh));
        return session.bidIds().length - before;
    }

    function _firstBid() internal returns (bytes32) {
        _bidBatch(1, 100);
        bytes32[] memory all = session.bidIds();
        return all[all.length - 1];
    }

    function _gasOf(bytes memory call) internal returns (uint256 used) {
        bytes memory sub = abi.encodeCall(gate.submit, (address(aliceP), call, new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        aliceAccount.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }

    /// @dev The value of every bid the market holds for Alice, at the limit
    ///      price: what the agent managed to commit her to.
    function _spent() internal view returns (uint256 total) {
        bytes32[] memory all = session.bidIds();
        for (uint256 i = 0; i < all.length; ++i) {
            MarketTypes.Order memory o = session.orderOf(all[i]);
            if (o.account == address(aliceAccount)) total += (uint256(o.quantity) * o.price + 999) / 1000;
        }
    }
}
