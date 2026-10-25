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
import {DeliverabilityPolicy} from "../../contracts/policies/DeliverabilityPolicy.sol";
import {CyclePolicy} from "../../contracts/policies/CyclePolicy.sol";
import {RampPolicy} from "../../contracts/policies/RampPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, BmsReading, SignedReading, TariffSchedule} from "../../contracts/oracle/OracleTypes.sol";
import {DominatedTradePolicy} from "../../contracts/policies/DominatedTradePolicy.sol";
import {RoundTripPolicy} from "../../contracts/policies/RoundTripPolicy.sol";
import {DeliveryReconciliationPolicy} from "../../contracts/policies/DeliveryReconciliationPolicy.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";

/// Step 5's acceptance criteria (spec Section 9), on the ported P2P market
/// through the gate: an agent trading for Alice attacks her battery.
///
///   attack                             blocked by           passes under (spec 9.1)
///   cross-slot over-commitment         S3                   per-action bounds only
///   phantom-buy justification          S3 (D3)              per-action bounds only
///   excess cycling                     S4                   per-action bounds only
///   position spike                     S5                   per-action bounds only
///   stale or favourable reading        the oracle verifier  per-action bounds only
///
/// And: a cancellation always passes under per-action bounds, S1, S2, S3 and
/// S4, for which it only ever reduces exposure. Not for S6, whose quantity is
/// cancellations (log 4.5), nor always for S5: cancelling the middle of a
/// plateau can open a steep step, and S5 then refuses it (spec 6.6, log 5.6).
/// The last group measures gas as a function of the horizon k.
///
/// Alice's battery is home_01's as the honest arms ran it (data/arms/): 5 kWh,
/// 3 kW, 95 % each way, 10 % to 100 %. The market has hourly slots, so 3 kWh
/// a slot at most. It is 09:00; the day-ahead session is tomorrow, slots 24
/// to 47 from now, so the physical policies look 48 slots ahead.
contract Step5AcceptanceTest is MarketFixture, OracleFixture {
    uint256 internal constant EXECUTOR = 2;
    uint64 internal constant PRICE = 200_000;
    uint64 internal constant DAY = 86_400;
    uint16 internal constant K = 48;

    address internal aliceOwner = makeAddr("aliceOwner");
    address internal agent = makeAddr("agent");

    MiniAccount internal aliceAccount;
    PositionLedger internal ledger;
    PolicyGate internal gate;
    OracleVerifier internal oracle;
    ProsumerDecoder internal decoder;

    StaticOrderPolicy internal statics;
    WindowPolicy internal windows;
    DeliverabilityPolicy internal s3;
    CyclePolicy internal s4;
    RampPolicy internal s5;

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
        oracle = new OracleVerifier();
        gate = new PolicyGate(ledger, oracle, 48);
        decoder = new ProsumerDecoder();
        statics = new StaticOrderPolicy(address(gate));
        windows = new WindowPolicy(address(gate));
        s3 = new DeliverabilityPolicy(address(gate));
        s4 = new CyclePolicy(address(gate));
        s5 = new RampPolicy(address(gate));

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
        aliceAccount.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.BMS, bmsSigner, SLOT_SECONDS)));
        aliceAccount.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.PV_FORECAST, pvSigner, 3600)));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Cross-slot over-commitment
    // ------------------------------------------------------------------

    /// Three offers of 1.5 kWh, each within the 3 kWh a slot the battery can
    /// give, together 4.7 kWh from the cells: more than the 3.5 kWh it holds
    /// above its floor.
    function test_crossSlotOverCommitment_passesUnderPerActionBoundsOnly() public {
        _addStatic();
        assertEq(_offersWith(_slots3(0, 1, 2), 1_500, _battery(4_000, 0)), 3, "all three placed");
    }

    function test_crossSlotOverCommitment_isBlockedByS3() public {
        _addStatic();
        _addS3();
        assertEq(_offersWith(_slots3(0, 1, 2), 1_500, _battery(4_000, 0)), 0, "the batch is refused whole");
        uint256 placed;
        for (uint16 i = 0; i < 3; ++i) placed += _offers(_slot1(i), 1_500);
        assertEq(placed, 2, "spread over calls: the third is refused");
    }

    // ------------------------------------------------------------------
    // Phantom-buy justification
    // ------------------------------------------------------------------

    /// A bid of 3 kWh that will never fill, at a price nobody sells at, then
    /// an offer of 2 kWh against it. The battery holds 1 kWh, 500 Wh above its
    /// floor.
    function test_phantomBuy_passesUnderPerActionBoundsOnly() public {
        _addStatic();
        _submitWith(_bidsCall(_slot1(0), 3_000, 1), _battery(1_000, 0));
        assertEq(_offers(_slot1(1), 2_000), 1);
    }

    function test_phantomBuy_isBlockedByS3() public {
        _addStatic();
        _addS3();
        _submitWith(_bidsCall(_slot1(0), 3_000, 1), _battery(1_000, 0));
        assertEq(session.bidIds().length, 1, "the bid itself is fine");
        assertEq(_offers(_slot1(1), 2_000), 0, "an unfilled bid does not justify the offer");
        assertEq(_offers(_slot1(1), 450), 1, "what the battery holds itself does");
    }

    // ------------------------------------------------------------------
    // Excess cycling
    // ------------------------------------------------------------------

    /// One full cycle a day: 5 kWh drawn from the cells over a sliding 24
    /// hours. Four offers of 1.5 kWh draw 6.3 kWh.
    function test_excessCycling_passesUnderPerActionBoundsOnly() public {
        _addStatic();
        _offersWith(_slot1(0), 1_500, _battery(5_000, 0));
        uint256 placed = 1;
        for (uint16 i = 1; i < 4; ++i) placed += _offers(_slot1(i), 1_500);
        assertEq(placed, 4);
    }

    function test_excessCycling_isBlockedByS4() public {
        _addStatic();
        _addS4();
        uint256 placed = _offersWith(_slot1(0), 1_500, _battery(5_000, 0));
        for (uint16 i = 1; i < 4; ++i) placed += _offers(_slot1(i), 1_500);
        assertEq(placed, 3, "the fourth would take the day past one cycle");
    }

    function test_excessCycling_countsWhatTheBatteryAlreadyDischarged() public {
        _addStatic();
        _addS4();
        _submitWith(_bidsCall(_slot1(0), 100, PRICE), _battery(5_000, 20_000));
        vm.warp(block.timestamp + SLOT_SECONDS);
        // The house drew 3.5 kWh from the battery in the last hour.
        uint256 placed = _offersWith(_slot1(1), 1_000, _battery(1_500, 23_500));
        placed += _offers(_slot1(2), 1_000);
        assertEq(placed, 1, "3,500 + 1,053 fits; one more 1,053 does not");
    }

    // ------------------------------------------------------------------
    // Position spike
    // ------------------------------------------------------------------

    function test_positionSpike_passesUnderPerActionBoundsOnly() public {
        _addStatic();
        assertEq(_offersWith(_slot1(5), 3_000, _battery(5_000, 0)), 1);
    }

    function test_positionSpike_isBlockedByS5() public {
        _addStatic();
        _addS5();
        assertEq(_offersWith(_slot1(5), 3_000, _battery(5_000, 0)), 0, "a 3 kWh step is refused");
        assertEq(_offers(_slots3(4, 5, 6), 1_500), 3, "more energy, as a ramp, passes");
    }

    // ------------------------------------------------------------------
    // Stale or favourable reading selection
    // ------------------------------------------------------------------

    /// The agent holds two genuine readings: an older one with a full battery,
    /// and the current one with little left. It tries to sell against the
    /// older.
    function test_favourableReading_passesWithoutTheOracleCheck() public {
        _addStatic();
        // Per-action bounds read no reading at all: the sale goes through
        // whatever the battery holds.
        assertEq(_offersWith(_slot1(0), 2_500, _battery(600, 0)), 1);
    }

    function test_aReorderedReadingIsRejected() public {
        _addStatic();
        _addS3();
        uint64 start = _slotStartNow();
        SignedReading[] memory older = _one(_signBms(oracle, BMS_KEY, _bms(address(aliceAccount), start - 60, 5_000, 0)));
        SignedReading[] memory current = _one(_signBms(oracle, BMS_KEY, _bms(address(aliceAccount), start, 600, 0)));
        assertEq(_offersWith(_slot1(0), 2_500, current), 0, "the current reading refuses the sale");

        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, start - 60, start));
        _submitRaw(_offersCall(_slot1(0), 2_500), older);
        assertEq(session.offerIds().length, 0);
    }

    function test_aStaleReadingIsRejected() public {
        _addStatic();
        _addS3();
        uint64 tooOld = uint64(block.timestamp) - SLOT_SECONDS - 1;
        SignedReading[] memory stale = _one(_signBms(oracle, BMS_KEY, _bms(address(aliceAccount), tooOld, 5_000, 0)));
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_Stale.selector, tooOld, block.timestamp, SLOT_SECONDS)
        );
        _submitRaw(_offersCall(_slot1(0), 2_500), stale);
    }

    function test_aStoredReadingGoneStaleNoLongerServes() public {
        _addStatic();
        _addS3();
        assertEq(_offersWith(_slot1(0), 500, _battery(5_000, 0)), 1);
        vm.warp(block.timestamp + SLOT_SECONDS + 1);
        assertEq(_offers(_slot1(1), 500), 0, "no fresh reading: refused");
    }

    // ------------------------------------------------------------------
    // An exposure-reducing cancellation always passes
    // ------------------------------------------------------------------

    /// Under per-action bounds, S1, S2, S3 and S4, whatever orders the agent
    /// got placed and however badly the battery then turns out, every open
    /// order can be cancelled, with or without a fresh reading.
    function testFuzz_anExposureReducingCancelAlwaysPasses(uint256 seed) public {
        _addStatic();
        _addS1S2();
        _addS3();
        _addS4();
        _offersWith(_slot1(0), 1, _battery(uint64(bound(seed, 500, 5_000)), 0));
        for (uint256 i = 0; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint16 slot = uint16(seed % 24);
            uint64 qty = uint64(1 + ((seed >> 32) % 3_000));
            if ((seed >> 64) % 2 == 0) _offers(_slot1(slot), qty);
            else _submit(_bidsCall(_slot1(slot), qty, PRICE));
        }
        // An hour later: the battery is nearly empty and has cycled hard.
        vm.warp(block.timestamp + SLOT_SECONDS);
        bool withReading = (seed >> 128) % 2 == 0;
        SignedReading[] memory bad = withReading ? _battery(510, 1_000_000) : new SignedReading[](0);

        bytes32[] memory bids = session.bidIds();
        bytes32[] memory offers = session.offerIds();
        for (uint256 i = 0; i < bids.length + offers.length; ++i) {
            bytes32 id = i < bids.length ? bids[i] : offers[i - bids.length];
            _submitWith(abi.encodeCall(Prosumer.cancelOrder, (id)), i == 0 ? bad : new SignedReading[](0));
            assertEq(uint8(session.orderOf(id).status), uint8(MarketTypes.OrderStatus.CANCELLED), "cancelled");
        }
    }

    // ------------------------------------------------------------------
    // Gas as a function of k
    // ------------------------------------------------------------------
    //
    // The agent's whole submission, its session call included: one offer and
    // one bid, in steady state, with the battery reading already held. Time is
    // moved to two hours before the session's first slot, so that an order in
    // it is within even the shortest horizon. Each line adds a policy to the
    // ones before.

    function test_gas_k8() public {
        _reportGasAt(8);
    }

    function test_gas_k16() public {
        _reportGasAt(16);
    }

    function test_gas_k24() public {
        _reportGasAt(24);
    }

    function test_gas_k48() public {
        _reportGasAt(48);
    }

    function test_gas_k96() public {
        _reportGasAt(96);
    }

    /// The day-ahead case: a batch of 24 offers, one per hour of tomorrow,
    /// against every policy of steps 4 and 5 but S6, at k = 48.
    function test_gas_dayAheadBatch() public {
        _addStatic();
        _addS1S2();
        _addS3();
        _addS4();
        _addS5();
        oracle.accept(_battery(2_500, 0)[0]); // half full: room both ways
        _offers(_slot1(0), 10); // a first submission, for steady state
        uint256 batch = _gasOf(_offersCall(_slots24(), 10));
        assertEq(session.offerIds().length, 25, "the batch was placed");
        emit log_named_uint("gas, 24-offer batch, A1-A6 + S1 + S2 x2 + S3 + S4 + S5, k = 48", batch);
    }

    /// @dev v0.2 step 3: the same batch with A3T on and S7 added. Feed-in
    ///      sits one unit above the offers' price, so every leg is dominated
    ///      and S7 keeps an excess for each: the worst case. (Corrected in
    ///      step 4: the step 3 tariff, retail 20 and feed-in 11, left every
    ///      offer above feed-in, and S7 counted nothing.)
    function test_gas_dayAheadBatchWithPrices() public {
        DominatedTradePolicy s7 = _addEveryPolicyWithPrices();
        oracle.accept(_battery(2_500, 0)[0]);
        _offers(_slot1(0), 10);
        uint256 batch = _gasOf(_offersCall(_slots24(), 10));
        assertEq(session.offerIds().length, 25, "the batch was placed");
        assertEq(_s7Used(s7), 25, "S7 counted every offer");
        emit log_named_uint("gas, 24-offer batch, A1-A6 with A3T + S1 + S2 x2 + S3 + S4 + S5 + S7, k = 48", batch);
    }

    /// @dev v0.2 step 4: the same, with S8 added, and a bid already in each
    ///      of the 24 slots, so every offer of the batch adds a round trip and
    ///      S8 reads and counts all 24 slots: its worst case.
    function test_gas_dayAheadBatchWithRoundTrip() public {
        DominatedTradePolicy s7 = _addEveryPolicyWithPrices();
        RoundTripPolicy s8 = new RoundTripPolicy(address(gate));
        RoundTripPolicy.Config memory r;
        r.soft = type(uint64).max;
        r.window = _sliding(type(uint64).max);
        _add(s8, keccak256("S8"), abi.encode(r));
        uint256 batch = _batchAgainstBids();
        (uint64 used,) = s8.usedOf(address(aliceAccount), keccak256("S8"));
        assertEq(used, 25 * 10, "S8 counted every offer");
        assertEq(_s7Used(s7), 25, "S7 counted every offer, and no bid");
        emit log_named_uint("gas, 24-offer batch against 24 bids, every policy with A3T, S7 and S8, k = 48", batch);
    }

    /// @dev v0.2 step 5: the same, with S9 added on the house's meter. Its
    ///      cost here is the window it counts sells into and the slots it
    ///      looks at, none of them settled yet; taking settled slots in costs
    ///      about 29,000 gas each, at most maxProcess a submission
    ///      (DeliveryReconciliationPolicy.t.sol, test_gas_processing).
    function test_gas_dayAheadBatchWithDelivery() public {
        _addEveryPolicyWithPrices();
        RoundTripPolicy s8 = new RoundTripPolicy(address(gate));
        RoundTripPolicy.Config memory r;
        r.soft = type(uint64).max;
        r.window = _sliding(type(uint64).max);
        _add(s8, keccak256("S8"), abi.encode(r));
        uint32 slotSeconds = uint32(manager.slotSeconds());
        vm.prank(aliceOwner);
        aliceAccount.execute(address(oracle), 0, abi.encodeCall(oracle.setMeter, (meterSigner, slotSeconds)));
        DeliveryReconciliationPolicy s9 = new DeliveryReconciliationPolicy(address(gate));
        DeliveryReconciliationPolicy.Config memory d;
        d.k = 436;
        d.h = 2_100;
        d.penaltySeconds = 1 days;
        d.escalationSeconds = 7 days;
        d.settlementLagSeconds = slotSeconds;
        d.graceSeconds = 4 * slotSeconds;
        d.maxProcess = 8;
        d.window = _sliding(15_000);
        _add(s9, keccak256("S9"), abi.encode(d));
        uint256 batch = _batchAgainstBids();
        emit log_named_uint("gas, 24-offer batch against 24 bids, every policy with A3T, S7, S8 and S9, k = 48", batch);
    }

    /// @dev The baseline for S8: the same bids and batch without it.
    function test_gas_dayAheadBatchAgainstBids() public {
        _addEveryPolicyWithPrices();
        uint256 batch = _batchAgainstBids();
        emit log_named_uint("gas, 24-offer batch against 24 bids, every policy with A3T and S7, k = 48", batch);
    }

    /// @dev A bid in each of the 24 slots (20 Wh: room for the steady-state
    ///      offer in slot 0 and the batch's), then the measured 24-offer batch.
    function _batchAgainstBids() internal returns (uint256 batch) {
        oracle.accept(_battery(2_500, 0)[0]);
        _submit(_bidsCall(_slots24(), 20, PRICE));
        assertEq(session.bidIds().length, 24, "a bid in every slot");
        _offers(_slot1(0), 10);
        batch = _gasOf(_offersCall(_slots24(), 10));
        assertEq(session.offerIds().length, 25, "the batch was placed");
    }

    /// @dev A1-A6 with A3T on, S1, S2, S3, S4, S5 and S7, against a tariff
    ///      where feed-in sits one unit above the orders' price (so every
    ///      offer is dominated, inside A3T's band) and retail well above it
    ///      (so a bid is inside the band and not dominated).
    function _addEveryPolicyWithPrices() internal returns (DominatedTradePolicy s7) {
        vm.prank(aliceOwner);
        aliceAccount.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.TARIFF, tariffSigner, 1 days)));
        uint64[] memory retail = new uint64[](96);
        uint64[] memory feedIn = new uint64[](96);
        for (uint256 i = 0; i < 96; ++i) {
            retail[i] = 300_000;
            feedIn[i] = PRICE + 1;
        }
        oracle.accept(
            _signTariff(
                oracle,
                TARIFF_KEY,
                TariffSchedule({
                    account: address(aliceAccount),
                    issuedAt: uint64(block.timestamp),
                    firstSlotStart: uint64(manager.slotStart(firstSlot)),
                    slotSeconds: manager.slotSeconds(),
                    retail: retail,
                    feedIn: feedIn
                })
            )
        );
        StaticOrderPolicy.Config memory c;
        c.maxQtyWh = 3_000;
        c.maxValue = 10_000_000;
        c.sellFloor = 0;
        c.buyCeiling = 10_000_000;
        c.horizonSeconds = uint32(3 * DAY);
        c.ratedPowerW = type(uint32).max;
        c.tariffBand = true;
        c.buyMarkupBps = 1_000;
        c.sellDiscountBps = 1_000;
        _add(statics, keccak256("A"), abi.encode(c));
        _addS1S2();
        _addS3();
        _addS4();
        _addS5();
        s7 = new DominatedTradePolicy(address(gate));
        DominatedTradePolicy.Config memory d;
        d.soft = type(uint64).max;
        d.window = _sliding(type(uint64).max);
        _add(s7, keccak256("S7"), abi.encode(d));
    }

    /// @dev What S7 has counted: 1 unit for each 10 Wh offer one unit under
    ///      feed-in (rounded up, D12).
    function _s7Used(DominatedTradePolicy s7) internal view returns (uint64 used) {
        (used,) = s7.usedOf(address(aliceAccount), keccak256("S7"));
    }

    function test_gas_dayAheadBatchNoPolicy() public {
        oracle.accept(_battery(2_500, 0)[0]); // half full: room both ways
        _offers(_slot1(0), 10);
        uint256 batch = _gasOf(_offersCall(_slots24(), 10));
        emit log_named_uint("gas, 24-offer batch, no policy", batch);
    }

    function _reportGasAt(uint16 k) internal {
        vm.warp(manager.slotStart(firstSlot) - 2 hours);
        oracle.accept(_battery(2_500, 0)[0]); // half full: room both ways
        emit log_named_uint("horizon k", k);
        _gasLine("  none");
        _add(s3, keccak256("S3"), abi.encode(_s3Config(k)));
        _gasLine("  + S3");
        _add(s4, keccak256("S4"), abi.encode(_s4Config(k)));
        _gasLine("  + S4");
        _addS5();
        _gasLine("  + S5");
    }

    function _gasLine(string memory label) internal {
        _offers(_slot1(0), 10); // steady state, both kinds
        _submit(_bidsCall(_slot1(1), 10, PRICE));
        uint256 offers = session.offerIds().length;
        uint256 bids = session.bidIds().length;
        uint256 offer = _gasOf(_offersCall(_slot1(0), 10));
        uint256 bid = _gasOf(_bidsCall(_slot1(1), 10, PRICE));
        assertEq(session.offerIds().length, offers + 1, "the measured offer was placed");
        assertEq(session.bidIds().length, bids + 1, "the measured bid was placed");
        emit log_named_uint(string.concat(label, ", one offer"), offer);
        emit log_named_uint(string.concat(label, ", one bid"), bid);
    }

    // ------------------------------------------------------------------
    // Policies
    // ------------------------------------------------------------------

    function _add(IPolicy policy, bytes32 id, bytes memory config) internal {
        vm.prank(aliceOwner);
        aliceAccount.execute(address(gate), 0, abi.encodeCall(gate.addPolicy, (policy, id, config)));
        assertTrue(gate.hasPolicy(address(aliceAccount), policy, id), "policy added");
    }

    /// @dev Per-action bounds wide enough for every scenario: 3 kWh an order.
    function _addStatic() internal {
        StaticOrderPolicy.Config memory c;
        c.maxQtyWh = 3_000;
        c.maxValue = 10_000_000;
        c.sellFloor = 0;
        c.buyCeiling = 10_000_000;
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

    function _addS1S2() internal {
        WindowLib.Config memory w = _sliding(type(uint64).max);
        _add(windows, keccak256("S1"), abi.encode(WindowPolicy.Config({quantity: WindowPolicy.Quantity.BUY_VALUE, soft: w.cap, window: w})));
        _add(windows, keccak256("S2 export"), abi.encode(WindowPolicy.Config({quantity: WindowPolicy.Quantity.SELL_WH, soft: w.cap, window: w})));
        _add(windows, keccak256("S2 import"), abi.encode(WindowPolicy.Config({quantity: WindowPolicy.Quantity.BUY_WH, soft: w.cap, window: w})));
    }

    function _s3Config(uint16 k) internal pure returns (DeliverabilityPolicy.Config memory) {
        return DeliverabilityPolicy.Config({
            horizonSlots: k,
            capacityWh: 5_000,
            socMinProfileBps: _flat(1_000),
            socMaxBps: 10_000,
            chargePowerW: 3_000,
            dischargePowerW: 3_000,
            etaChargeBps: 9_500,
            etaDischargeBps: 9_500,
            pvCreditBps: 10_000,
            reserveLoadWh: 0
        });
    }

    function _flat(uint16 bps) internal pure returns (uint16[24] memory profile) {
        for (uint256 i = 0; i < 24; ++i) {
            profile[i] = bps;
        }
    }

    function _addS3() internal {
        _add(s3, keccak256("S3"), abi.encode(_s3Config(K)));
    }

    /// @dev One cycle a day: 5,000 Wh from the cells over a sliding 24 hours,
    ///      flagged above 4,000.
    function _s4Config(uint16 k) internal pure returns (CyclePolicy.Config memory) {
        return CyclePolicy.Config({
            softWh: 4_000,
            window: WindowLib.Config({kind: WindowLib.Kind.SLIDING, step: 3600, buckets: 24, anchor: 0, cap: 5_000, rate: 0, initial: 0}),
            horizonSlots: k,
            pvCreditBps: 10_000,
            etaDischargeBps: 9_500
        });
    }

    function _addS4() internal {
        _add(s4, keccak256("S4"), abi.encode(_s4Config(K)));
    }

    /// @dev Steps of at most 2 kWh between hours, flagged above 1.5.
    function _addS5() internal {
        _add(s5, keccak256("S5"), abi.encode(RampPolicy.Config({softStepWh: 1_500, maxStepWh: 2_000})));
    }

    // ------------------------------------------------------------------
    // Readings
    // ------------------------------------------------------------------

    function _slotStartNow() internal view returns (uint64) {
        return uint64(manager.slotStart(uint32(block.timestamp / SLOT_SECONDS)));
    }

    function _battery(uint64 socWh, uint64 odometerWh) internal view returns (SignedReading[] memory) {
        return _one(_signBms(oracle, BMS_KEY, _bms(address(aliceAccount), _slotStartNow(), socWh, odometerWh)));
    }

    function _one(SignedReading memory r) internal pure returns (SignedReading[] memory one) {
        one = new SignedReading[](1);
        one[0] = r;
    }

    // ------------------------------------------------------------------
    // The agent's calls
    // ------------------------------------------------------------------

    function _slot1(uint16 a) internal pure returns (uint16[] memory s) {
        s = new uint16[](1);
        s[0] = a;
    }

    function _slots3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory s) {
        s = new uint16[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }

    function _slots24() internal pure returns (uint16[] memory s) {
        s = new uint16[](24);
        for (uint16 i = 0; i < 24; ++i) s[i] = i;
    }

    function _offersCall(uint16[] memory slots, uint64 qtyWh) internal pure returns (bytes memory) {
        MarketTypes.OrderRequest[] memory reqs = new MarketTypes.OrderRequest[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) reqs[i] = _req(slots[i], qtyWh, PRICE);
        return abi.encodeCall(Prosumer.placeOffers, (MarketTypes.EnergyType.ELECTRICITY, reqs));
    }

    function _bidsCall(uint16[] memory slots, uint64 qtyWh, uint64 price) internal pure returns (bytes memory) {
        MarketTypes.OrderRequest[] memory reqs = new MarketTypes.OrderRequest[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) reqs[i] = _req(slots[i], qtyWh, price);
        return abi.encodeCall(Prosumer.placeBids, (MarketTypes.EnergyType.ELECTRICITY, reqs));
    }

    function _submitRaw(bytes memory call, SignedReading[] memory readings) internal {
        vm.prank(agent);
        aliceAccount.executeAsSession(address(gate), abi.encodeCall(gate.submit, (address(aliceP), call, readings)));
    }

    function _submitWith(bytes memory call, SignedReading[] memory readings) internal {
        _submitRaw(call, readings);
    }

    function _submit(bytes memory call) internal {
        _submitRaw(call, new SignedReading[](0));
    }

    /// @dev Offers in one call; returns how many the market received.
    function _offersWith(uint16[] memory slots, uint64 qtyWh, SignedReading[] memory readings)
        internal
        returns (uint256)
    {
        uint256 before = session.offerIds().length;
        _submitWith(_offersCall(slots, qtyWh), readings);
        return session.offerIds().length - before;
    }

    function _offers(uint16[] memory slots, uint64 qtyWh) internal returns (uint256) {
        return _offersWith(slots, qtyWh, new SignedReading[](0));
    }

    function _gasOf(bytes memory call) internal returns (uint256 used) {
        bytes memory sub = abi.encodeCall(gate.submit, (address(aliceP), call, new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        aliceAccount.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }
}
