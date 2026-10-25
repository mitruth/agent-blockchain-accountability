// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console} from "forge-std/console.sol";
import {PolicyFixture} from "./PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {OperatingEnvelopePolicy} from "../../contracts/policies/OperatingEnvelopePolicy.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, Envelope, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {Side, ConfigChange, Verdict, CheckResult} from "../../contracts/gate/GateTypes.sol";

/// @notice S10, operating-envelope compliance (spec v0.2 section 5), through
///         the gate on two mock markets on one slot grid. The connection is
///         9 kW: 4,500 Wh a half-hour both ways when no envelope applies.
///         Flagged above 90 % of a limit. The DSO's envelopes hold a day.
abstract contract EnvelopeFixture is PolicyFixture, OracleFixture {
    bytes32 internal constant S10 = keccak256("S10");
    uint32 internal constant P_CONN = 9_000;
    uint16 internal constant SIGMA = 9_000;
    uint64 internal constant STATIC = 4_500;

    OperatingEnvelopePolicy internal s10;
    OracleVerifier internal oracle;
    MockEnergyMarket internal marketB;

    function setUp() public virtual override {
        super.setUp();
        oracle = gate.oracle();
        s10 = new OperatingEnvelopePolicy(address(gate));
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.ENVELOPE, envelopeSigner, 1 days)));
        if (_installS10()) _addPolicy(s10, S10, abi.encode(_config(P_CONN, SIGMA)));

        marketB = new MockEnergyMarket(GENESIS, SLOT_SECONDS, GATE_LEAD, operator);
        bytes4[3] memory selectors = [
            MockEnergyMarket.placeOrder.selector,
            MockEnergyMarket.cancelOrder.selector,
            MockEnergyMarket.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            _asAccount(abi.encodeCall(gate.setDecoder, (address(marketB), selectors[i], decoder)));
        }
    }

    function _installS10() internal pure virtual returns (bool) {
        return true;
    }

    function _config(uint32 connectionW, uint16 softBps) internal pure returns (OperatingEnvelopePolicy.Config memory) {
        return OperatingEnvelopePolicy.Config({connectionW: connectionW, softBps: softBps});
    }

    /// @dev The DSO's envelope from the current slot on, the same limits in
    ///      each of 96 slots.
    function _envelope(uint64 exportWh, uint64 importWh) internal {
        uint64[] memory e = new uint64[](96);
        uint64[] memory i = new uint64[](96);
        for (uint256 k = 0; k < 96; ++k) {
            e[k] = exportWh;
            i[k] = importWh;
        }
        oracle.accept(
            _signEnvelope(
                oracle,
                ENVELOPE_KEY,
                Envelope({
                    account: address(account),
                    issuedAt: uint64(block.timestamp),
                    firstSlotStart: market.slotStart(market.currentSlot()),
                    slotSeconds: SLOT_SECONDS,
                    exportLimitWh: e,
                    importLimitWh: i
                })
            )
        );
    }

    function _onB(Side side, uint32 slot, uint64 qtyWh) internal returns (bytes32) {
        uint256 before = marketB.orderCount();
        vm.prank(agent);
        account.executeAsSession(
            address(gate),
            abi.encodeCall(gate.submit, (address(marketB), _placeCall(side, slot, qtyWh, PRICE), new SignedReading[](0)))
        );
        return marketB.orderCount() > before ? bytes32(marketB.orderCount()) : bytes32(0);
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(s10));
        return all[all.length - 1];
    }
}

contract OperatingEnvelopePolicyTest is EnvelopeFixture {
    // ------------------------------------------------------------------
    // The static fallback
    // ------------------------------------------------------------------

    /// @dev No envelope: P_conn times the slot, 4,500 Wh. At it, placed (and
    ///      flagged, above 90 %); 1 Wh more, refused.
    function test_withoutAnEnvelopeTheConnectionLimitApplies() public {
        vm.recordLogs();
        assertTrue(_place(Side.SELL, SLOT, STATIC, PRICE) != bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(uint8(r.verdict), uint8(Verdict.FLAG));
        assertEq(r.valueAfter, 10_000, "at the limit");
        vm.recordLogs();
        assertEq(_place(Side.SELL, SLOT, 1, PRICE), bytes32(0));
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.REJECT));
        (uint64 e, uint64 i, bool fromEnvelope) = s10.limitsAt(address(account), S10, SLOT);
        assertEq(e, STATIC);
        assertEq(i, STATIC);
        assertFalse(fromEnvelope);
    }

    /// @dev Both ways: 4,500 bought, inclusive; 1 Wh more refused.
    function test_theStaticLimitHoldsForImportToo() public {
        assertTrue(_place(Side.BUY, SLOT, STATIC, PRICE) != bytes32(0));
        assertEq(_place(Side.BUY, SLOT, 1, PRICE), bytes32(0));
    }

    // ------------------------------------------------------------------
    // The envelope
    // ------------------------------------------------------------------

    /// @dev Export 2,000, import 3,000: each inclusive, each its own way.
    function test_theEnvelopesLimitsApplyEachWay() public {
        _envelope(2_000, 3_000);
        assertTrue(_place(Side.SELL, SLOT, 2_000, PRICE) != bytes32(0));
        assertEq(_place(Side.SELL, SLOT, 1, PRICE), bytes32(0), "export limit");
        assertTrue(_place(Side.BUY, SLOT + 1, 3_000, PRICE) != bytes32(0));
        assertEq(_place(Side.BUY, SLOT + 1, 1, PRICE), bytes32(0), "import limit");
        (,, bool fromEnvelope) = s10.limitsAt(address(account), S10, SLOT);
        assertTrue(fromEnvelope);
    }

    /// @dev σ: 1,800 of 2,000 is 90 %, not above; 1 Wh more is.
    function test_aboveSigmaIsFlagged() public {
        _envelope(2_000, 3_000);
        vm.recordLogs();
        _place(Side.SELL, SLOT, 1_800, PRICE);
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.EXECUTE));
        vm.recordLogs();
        _place(Side.SELL, SLOT, 1, PRICE);
        CheckResult memory r = _lastResult();
        assertEq(uint8(r.verdict), uint8(Verdict.FLAG));
        assertEq(r.soft, SIGMA);
        assertEq(r.hard, 10_000);
    }

    /// @dev The position is net: 1,500 bought, then 3,500 sold is 2,000 net
    ///      export, inside the envelope.
    function test_thePositionIsNet() public {
        _envelope(2_000, 3_000);
        _place(Side.BUY, SLOT, 1_500, PRICE);
        assertTrue(_place(Side.SELL, SLOT, 3_500, PRICE) != bytes32(0));
    }

    /// @dev A stale envelope, or one that does not cover the slot: the static
    ///      limit, never a refusal for want of an envelope.
    function test_aStaleEnvelopeFallsBackToStatic() public {
        _envelope(1_000, 1_000);
        assertEq(_place(Side.SELL, SLOT, 1_001, PRICE), bytes32(0), "the envelope binds");
        vm.warp(block.timestamp + 1 days + 1);
        assertTrue(_place(Side.SELL, market.currentSlot() + 4, 1_001, PRICE) != bytes32(0), "stale: static");
    }

    function test_aSlotBeyondTheEnvelopeFallsBackToStatic() public {
        _envelope(1_000, 1_000);
        assertTrue(_place(Side.SELL, market.currentSlot() + 100, 1_001, PRICE) != bytes32(0));
    }

    // ------------------------------------------------------------------
    // A tightening update, and D10
    // ------------------------------------------------------------------

    /// @dev 2,000 sold under an export limit of 2,000; the DSO then cuts it to
    ///      1,000. The excess is 1,000: a further sale is refused; a buy that
    ///      reduces it and a cancellation pass, unflagged.
    function test_aTighteningUpdate() public {
        _envelope(2_000, 3_000);
        bytes32 sold = _place(Side.SELL, SLOT, 1_200, PRICE);
        _place(Side.SELL, SLOT, 800, PRICE);
        vm.warp(block.timestamp + 60);
        _envelope(1_000, 3_000);
        assertEq(_place(Side.SELL, SLOT, 1, PRICE), bytes32(0), "worsens the excess");
        vm.recordLogs();
        assertTrue(_place(Side.BUY, SLOT, 300, PRICE) != bytes32(0), "reduces it");
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.EXECUTE));
        vm.recordLogs();
        _cancel(sold);
        assertFalse(market.isOpen(sold), "a cancellation passes");
        assertEq(uint8(_lastResult().verdict), uint8(Verdict.EXECUTE));
    }

    /// @dev A modification is one change to the slot: a sale of 2,500 under
    ///      a limit of 3,000, the limit then cut to 2,000, the sale reduced to
    ///      1,900. Cancelling 2,500 and placing 1,900 brings the excess from
    ///      500 to none: placed. Judged leg by leg, the 1,900 alone would add.
    function test_aModificationIsJudgedAsOne() public {
        _envelope(3_000, 3_000);
        bytes32 id = _place(Side.SELL, SLOT, 2_500, PRICE);
        vm.warp(block.timestamp + 60);
        _envelope(2_000, 3_000);
        uint256 before = market.orderCount();
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (id, SLOT, 1_900, PRICE)));
        assertEq(market.orderCount(), before + 1, "the reduced sale placed");
    }

    /// @dev Use is rounded up: 1,001 of 3,000 is 3,336.7 bps, reported 3,337.
    ///      Against a zero limit, any position is unbounded, and refused.
    function test_useRoundsUpAndAZeroLimitIsUnbounded() public {
        _envelope(3_000, 0);
        vm.recordLogs();
        _place(Side.SELL, SLOT, 1_001, PRICE);
        assertEq(_lastResult().valueAfter, 3_337);
        vm.recordLogs();
        assertEq(_place(Side.BUY, SLOT + 1, 1, PRICE), bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(r.valueAfter, type(uint256).max);
        assertEq(uint8(r.verdict), uint8(Verdict.REJECT));
    }

    /// @dev A buy that crosses from export to import beyond the import limit
    ///      makes the excess larger: refused, though it reduces the export.
    function test_crossingToTheOtherLimitCounts() public {
        _envelope(2_000, 1_000);
        _place(Side.SELL, SLOT, 500, PRICE);
        assertEq(_place(Side.BUY, SLOT, 1_501, PRICE), bytes32(0), "1,001 net import");
        assertTrue(_place(Side.BUY, SLOT, 1_500, PRICE) != bytes32(0), "1,000 net import");
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_configurationDirections() public view {
        assertEq(uint8(_classify(_config(P_CONN, SIGMA))), uint8(ConfigChange.TIGHTEN), "the same");
        assertEq(uint8(_classify(_config(P_CONN - 1, SIGMA - 1))), uint8(ConfigChange.TIGHTEN), "lower");
        assertEq(uint8(_classify(_config(P_CONN + 1, SIGMA))), uint8(ConfigChange.WIDEN), "a higher P_conn");
        assertEq(uint8(_classify(_config(P_CONN, SIGMA + 1))), uint8(ConfigChange.WIDEN), "a higher sigma");
        assertEq(uint8(_classify(_config(P_CONN, 10_001))), uint8(ConfigChange.INVALID), "sigma above 100 %");
        assertEq(uint8(s10.classifyConfig(address(account), S10, hex"00")), uint8(ConfigChange.INVALID));
    }

    function _classify(OperatingEnvelopePolicy.Config memory c) internal view returns (ConfigChange) {
        return s10.classifyConfig(address(account), S10, abi.encode(c));
    }

    function test_onlyTheGateWritesThePolicy() public {
        vm.expectRevert();
        s10.configure(address(account), S10, abi.encode(_config(P_CONN, SIGMA)));
    }

    // ------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------

    function _gasOfBid(uint32 slot) internal returns (uint256 used) {
        bytes memory sub =
            abi.encodeCall(gate.submit, (address(market), _placeCall(Side.BUY, slot, 100, PRICE), new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        account.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }

    /// @dev One bid, the second of two, with an envelope and without.
    function test_gas_oneBid() public {
        _gasOfBid(SLOT);
        console.log("S10, a bid on the static limit:", _gasOfBid(SLOT));
        _envelope(2_000, 3_000);
        _gasOfBid(SLOT);
        console.log("S10, a bid on the envelope:", _gasOfBid(SLOT));
    }

    // ------------------------------------------------------------------
    // Spec section 7: an envelope breach split across orders and two markets
    // ------------------------------------------------------------------

    /// @dev Export limit 2,000. 1,000 sold on market A, 1,000 on B: each
    ///      venue alone is half the limit, the account at it; a third sale of
    ///      500, on either, is refused.
    function test_breachAcrossMarkets_isBlockedByS10() public {
        _envelope(2_000, 3_000);
        assertTrue(_place(Side.SELL, SLOT, 1_000, PRICE) != bytes32(0));
        assertTrue(_onB(Side.SELL, SLOT, 1_000) != bytes32(0));
        assertEq(_place(Side.SELL, SLOT, 500, PRICE), bytes32(0));
        assertEq(_onB(Side.SELL, SLOT, 500), bytes32(0));
    }
}

contract OperatingEnvelopeWithoutS10Test is EnvelopeFixture {
    function _installS10() internal pure override returns (bool) {
        return false;
    }

    function test_breachAcrossMarkets_passesWithoutS10() public {
        _envelope(2_000, 3_000);
        assertTrue(_place(Side.SELL, SLOT, 1_000, PRICE) != bytes32(0));
        assertTrue(_onB(Side.SELL, SLOT, 1_000) != bytes32(0));
        assertTrue(_place(Side.SELL, SLOT, 500, PRICE) != bytes32(0));
        assertTrue(_onB(Side.SELL, SLOT, 500) != bytes32(0), "3,000 Wh exported against 2,000");
    }
}
