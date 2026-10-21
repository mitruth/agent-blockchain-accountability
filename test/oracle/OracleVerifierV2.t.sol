// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OracleFixture} from "./OracleFixture.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {
    ReadingKind,
    TariffSchedule,
    MeterReading,
    Envelope,
    GridState,
    GridLevel,
    GridDirection,
    SignedReading
} from "../../contracts/oracle/OracleTypes.sol";

/// @notice The four oracle kinds of spec v0.2, section 4 -- tariff, meter,
///         envelope, grid state -- and signer distinctness.
///
/// It is 09:00 UTC on a half-hour grid: `t0` is the start of the current
/// slot. The tariff and envelope signers have a maximum age of 24 h; the meter
/// measures half-hour slots.
contract OracleVerifierV2Test is OracleFixture {
    uint32 internal constant SLOT = 30 minutes;
    uint32 internal constant SCHEDULE_MAX_AGE = 24 hours;

    OracleVerifier internal verifier;
    address internal account = makeAddr("account");
    address internal agentKey = makeAddr("agentKey");
    uint64 internal t0;

    event ReadingAccepted(
        address indexed account, ReadingKind indexed kind, address indexed signer, bytes32 digest, bytes data
    );

    function setUp() public {
        vm.warp(1_760_000_400);
        t0 = uint64(block.timestamp);
        verifier = new OracleVerifier();
        vm.startPrank(account);
        verifier.setDevice(ReadingKind.BMS, bmsSigner, BMS_MAX_AGE);
        verifier.setDevice(ReadingKind.PV_FORECAST, pvSigner, PV_MAX_AGE);
        verifier.setDevice(ReadingKind.TARIFF, tariffSigner, SCHEDULE_MAX_AGE);
        verifier.setDevice(ReadingKind.ENVELOPE, envelopeSigner, SCHEDULE_MAX_AGE);
        verifier.setMeter(meterSigner, SLOT);
        verifier.setDevice(ReadingKind.GRID_STATE, gridSigner, 0);
        vm.stopPrank();
    }

    // --- builders -----------------------------------------------------------

    function _tariff(uint64 issuedAt, uint256 n) internal view returns (TariffSchedule memory) {
        return TariffSchedule({
            account: account,
            issuedAt: issuedAt,
            firstSlotStart: t0,
            slotSeconds: SLOT,
            retail: _values(n, 300_000),
            feedIn: _values(n, 80_000)
        });
    }

    function _envelope(uint64 issuedAt, uint256 n) internal view returns (Envelope memory) {
        return Envelope({
            account: account,
            issuedAt: issuedAt,
            firstSlotStart: t0,
            slotSeconds: SLOT,
            exportLimitWh: _values(n, 2_000),
            importLimitWh: _values(n, 3_000)
        });
    }

    function _meter(uint64 slotStart, uint64 importWh, uint64 exportWh) internal view returns (MeterReading memory) {
        return MeterReading({account: account, slotStart: slotStart, importWh: importWh, exportWh: exportWh});
    }

    function _grid(uint64 issuedAt, uint64 validUntil, GridLevel level, GridDirection direction)
        internal
        pure
        returns (GridState memory)
    {
        return GridState({issuedAt: issuedAt, validUntil: validUntil, level: level, direction: direction, horizonSlots: 8});
    }

    function _acceptMeter(uint64 slotStart, uint64 importWh, uint64 exportWh) internal {
        verifier.accept(_signMeter(verifier, METER_KEY, _meter(slotStart, importWh, exportWh)));
    }

    // ------------------------------------------------------------------
    // Type strings
    // ------------------------------------------------------------------

    function test_theContractSignsWhatTheNewTypeStringsSay() public view {
        TariffSchedule memory t = _tariff(t0, 3);
        assertEq(verifier.digestOf(verifier.tariffStructHash(t)), _tariffDigest(verifier, t));
        Envelope memory e = _envelope(t0, 3);
        assertEq(verifier.digestOf(verifier.envelopeStructHash(e)), _envelopeDigest(verifier, e));
        MeterReading memory m = _meter(t0 - SLOT, 400, 1_200);
        assertEq(verifier.digestOf(verifier.meterStructHash(m)), _meterDigest(verifier, m));
        GridState memory g = _grid(t0, t0 + 1 hours, GridLevel.ALERT, GridDirection.DEFICIT);
        assertEq(verifier.digestOf(verifier.gridStateStructHash(g)), _gridDigest(verifier, g));
    }

    // ------------------------------------------------------------------
    // Tariff
    // ------------------------------------------------------------------

    function test_aTariffIsAcceptedEmittedAndServedPerSlot() public {
        TariffSchedule memory t = _tariff(t0, 4);
        bytes32 digest = verifier.digestOf(verifier.tariffStructHash(t));
        vm.expectEmit(address(verifier));
        emit ReadingAccepted(account, ReadingKind.TARIFF, tariffSigner, digest, abi.encode(t));
        assertEq(verifier.accept(_signTariff(verifier, TARIFF_KEY, t)), account);

        (uint64 retail, uint64 feedIn, bool usable) = verifier.tariffAt(account, t0 + 2 * SLOT);
        assertTrue(usable);
        assertEq(retail, 300_020);
        assertEq(feedIn, 80_020);
    }

    function test_aTariffServesOnlyTheSlotsItCovers() public {
        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0, 4)));
        (,, bool usable) = verifier.tariffAt(account, t0 - SLOT);
        assertFalse(usable, "before it");
        (,, usable) = verifier.tariffAt(account, t0 + 4 * SLOT);
        assertFalse(usable, "after it");
        (,, usable) = verifier.tariffAt(account, t0 + 3 * SLOT);
        assertTrue(usable, "its last slot");
        (,, usable) = verifier.tariffAt(account, t0 + SLOT / 2);
        assertFalse(usable, "between slots");
    }

    function test_aTariffGoesStaleAfterItsMaximumAge() public {
        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0, 96)));
        vm.warp(t0 + SCHEDULE_MAX_AGE);
        (,, bool usable) = verifier.tariffAt(account, t0 + 48 * SLOT);
        assertTrue(usable, "exactly at the maximum age");
        vm.warp(t0 + SCHEDULE_MAX_AGE + 1);
        uint64 retail;
        (retail,, usable) = verifier.tariffAt(account, t0 + 48 * SLOT);
        assertFalse(usable, "one second past it");
        assertEq(retail, 0);
    }

    function test_aMalformedTariffIsRefused() public {
        TariffSchedule memory t = _tariff(t0, 4);
        t.feedIn = _values(3, 1);
        vm.expectRevert(OracleVerifier.Oracle_BadSchedule.selector);
        verifier.accept(_signTariff(verifier, TARIFF_KEY, t));

        t = _tariff(t0, 97);
        vm.expectRevert(OracleVerifier.Oracle_BadSchedule.selector);
        verifier.accept(_signTariff(verifier, TARIFF_KEY, t));

        t = _tariff(t0, 0);
        vm.expectRevert(OracleVerifier.Oracle_BadSchedule.selector);
        verifier.accept(_signTariff(verifier, TARIFF_KEY, t));

        t = _tariff(t0, 4);
        t.slotSeconds = 0;
        vm.expectRevert(OracleVerifier.Oracle_BadSchedule.selector);
        verifier.accept(_signTariff(verifier, TARIFF_KEY, t));

        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0, 96)));
    }

    function test_aTariffFromTheFutureStaleReorderedOrConflictingIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_FromTheFuture.selector, t0 + 1, block.timestamp));
        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0 + 1, 4)));

        uint64 old = t0 - SCHEDULE_MAX_AGE - 1;
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_Stale.selector, old, block.timestamp, SCHEDULE_MAX_AGE)
        );
        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(old, 4)));

        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0, 4)));
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, t0 - 1, t0));
        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0 - 1, 4)));

        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Conflicting.selector, t0));
        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0, 5)));
    }

    function test_aTariffFromAnotherSignerOrHighSIsRefused() public {
        TariffSchedule memory t = _tariff(t0, 4);
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_WrongSigner.selector, vm.addr(OTHER_KEY), tariffSigner)
        );
        verifier.accept(_signTariff(verifier, OTHER_KEY, t));

        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(TARIFF_KEY, verifier.digestOf(verifier.tariffStructHash(t)));
        bytes memory twin = abi.encodePacked(rr, bytes32(N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(OracleVerifier.Oracle_BadSignature.selector);
        verifier.accept(SignedReading({kind: ReadingKind.TARIFF, data: abi.encode(t), signature: twin}));
    }

    function test_theSameTariffAgainIsANoOp() public {
        SignedReading memory signed = _signTariff(verifier, TARIFF_KEY, _tariff(t0, 4));
        verifier.accept(signed);
        vm.recordLogs();
        verifier.accept(signed);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ------------------------------------------------------------------
    // Envelope
    // ------------------------------------------------------------------

    function test_anEnvelopeIsAcceptedAndServedPerSlot() public {
        verifier.accept(_signEnvelope(verifier, ENVELOPE_KEY, _envelope(t0, 4)));
        (uint64 exportLimitWh, uint64 importLimitWh, bool usable) = verifier.envelopeAt(account, t0 + SLOT);
        assertTrue(usable);
        assertEq(exportLimitWh, 2_010);
        assertEq(importLimitWh, 3_010);
    }

    function test_aMalformedOrStaleEnvelopeIsRefused() public {
        Envelope memory e = _envelope(t0, 4);
        e.importLimitWh = _values(5, 1);
        vm.expectRevert(OracleVerifier.Oracle_BadSchedule.selector);
        verifier.accept(_signEnvelope(verifier, ENVELOPE_KEY, e));

        uint64 old = t0 - SCHEDULE_MAX_AGE - 1;
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_Stale.selector, old, block.timestamp, SCHEDULE_MAX_AGE)
        );
        verifier.accept(_signEnvelope(verifier, ENVELOPE_KEY, _envelope(old, 4)));
    }

    function test_aNewSignerDropsTheScheduleHeld() public {
        verifier.accept(_signEnvelope(verifier, ENVELOPE_KEY, _envelope(t0, 4)));
        verifier.accept(_signTariff(verifier, TARIFF_KEY, _tariff(t0, 4)));
        vm.startPrank(account);
        verifier.setDevice(ReadingKind.ENVELOPE, vm.addr(OTHER_KEY), SCHEDULE_MAX_AGE);
        verifier.setDevice(ReadingKind.TARIFF, vm.addr(0x7A2), SCHEDULE_MAX_AGE);
        vm.stopPrank();
        (,, bool usable) = verifier.envelopeAt(account, t0);
        assertFalse(usable, "envelope dropped");
        (,, usable) = verifier.tariffAt(account, t0);
        assertFalse(usable, "tariff dropped");
    }

    // ------------------------------------------------------------------
    // Meter: per-slot rules
    // ------------------------------------------------------------------

    function test_aMeterReadingIsAcceptedOnceItsSlotHasEnded() public {
        MeterReading memory m = _meter(t0 - SLOT, 400, 1_200);
        bytes32 digest = verifier.digestOf(verifier.meterStructHash(m));
        vm.expectEmit(address(verifier));
        emit ReadingAccepted(account, ReadingKind.METER, meterSigner, digest, abi.encode(m));
        assertEq(verifier.accept(_signMeter(verifier, METER_KEY, m)), account);

        (uint64 importWh, uint64 exportWh, bool present) = verifier.meterAt(account, t0 - SLOT);
        assertTrue(present);
        assertEq(importWh, 400);
        assertEq(exportWh, 1_200);
    }

    /// @dev The slot that started at t0 - SLOT ends exactly now: accepted. The
    ///      current slot is not over: refused.
    function test_aMeterReadingForASlotNotYetOverIsRefused() public {
        _acceptMeter(t0 - SLOT, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_FromTheFuture.selector, t0, block.timestamp));
        _acceptMeter(t0, 1, 1);
        vm.warp(t0 + SLOT - 1);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_FromTheFuture.selector, t0, block.timestamp));
        _acceptMeter(t0, 1, 1);
        vm.warp(t0 + SLOT);
        _acceptMeter(t0, 1, 1);
    }

    /// @dev Decision of 21 October 2026: a late reading still arrives.
    function test_meterReadingsAreAcceptedInAnyOrder() public {
        _acceptMeter(t0 - SLOT, 10, 20);
        _acceptMeter(t0 - 3 * SLOT, 30, 40);
        _acceptMeter(t0 - 2 * SLOT, 50, 60);
        (uint64 importWh,, bool present) = verifier.meterAt(account, t0 - 3 * SLOT);
        assertTrue(present);
        assertEq(importWh, 30);
        (importWh,, present) = verifier.meterAt(account, t0 - 2 * SLOT);
        assertTrue(present);
        assertEq(importWh, 50);
    }

    function test_aConflictingMeterReadingIsRefusedAndTheSameIsANoOp() public {
        _acceptMeter(t0 - SLOT, 400, 1_200);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Conflicting.selector, t0 - SLOT));
        _acceptMeter(t0 - SLOT, 400, 1_201);

        vm.recordLogs();
        _acceptMeter(t0 - SLOT, 400, 1_200);
        assertEq(vm.getRecordedLogs().length, 0, "nothing new");
        (, uint64 exportWh,) = verifier.meterAt(account, t0 - SLOT);
        assertEq(exportWh, 1_200, "the first stays");
    }

    /// @dev The ring holds METER_RING slots back from now. The oldest slot
    ///      still inside is accepted; one slot older is stale.
    function test_aMeterReadingOlderThanTheRingIsStale() public {
        uint256 ring = verifier.METER_RING();
        uint64 oldest = uint64(t0 - (ring - 1) * SLOT);
        _acceptMeter(oldest, 1, 1);
        uint64 tooOld = oldest - SLOT;
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_Stale.selector, tooOld, block.timestamp, uint32(ring * SLOT))
        );
        _acceptMeter(tooOld, 1, 1);
    }

    /// @dev A slot's place in the ring is taken over METER_RING slots later.
    function test_theRingEvictsTheSlotOneRingBack() public {
        uint256 ring = verifier.METER_RING();
        _acceptMeter(t0 - SLOT, 7, 7);
        vm.warp(t0 + ring * SLOT);
        _acceptMeter(uint64(t0 - SLOT + ring * SLOT), 9, 9);
        (,, bool present) = verifier.meterAt(account, t0 - SLOT);
        assertFalse(present, "evicted");
        (uint64 importWh,, bool presentNew) = verifier.meterAt(account, uint64(t0 - SLOT + ring * SLOT));
        assertTrue(presentNew);
        assertEq(importWh, 9);
    }

    function test_aMeterReadingOffItsSlotGridIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_BadMeterSlot.selector, t0 - SLOT + 1, SLOT));
        _acceptMeter(t0 - SLOT + 1, 1, 1);
    }

    function test_aMeterReadingFromAnotherSignerIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_WrongSigner.selector, vm.addr(OTHER_KEY), meterSigner)
        );
        verifier.accept(_signMeter(verifier, OTHER_KEY, _meter(t0 - SLOT, 1, 1)));

        address other = makeAddr("noMeter");
        MeterReading memory m = _meter(t0 - SLOT, 1, 1);
        m.account = other;
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_NoSigner.selector, other, ReadingKind.METER));
        verifier.accept(_signMeter(verifier, METER_KEY, m));
    }

    function test_aNewMeterDropsTheReadingsHeld() public {
        _acceptMeter(t0 - SLOT, 7, 7);
        vm.prank(account);
        verifier.setMeter(meterSigner, SLOT); // the same meter: kept
        (,, bool present) = verifier.meterAt(account, t0 - SLOT);
        assertTrue(present);

        vm.prank(account);
        verifier.setMeter(vm.addr(OTHER_KEY), SLOT);
        (,, present) = verifier.meterAt(account, t0 - SLOT);
        assertFalse(present, "a new signer");

        vm.prank(account);
        verifier.setMeter(meterSigner, SLOT);
        (,, present) = verifier.meterAt(account, t0 - SLOT);
        assertFalse(present, "back to the first signer: still dropped");
    }

    function test_theMeterIsRegisteredWithItsOwnFunction() public {
        vm.prank(account);
        vm.expectRevert(OracleVerifier.Oracle_UseSetMeter.selector);
        verifier.setDevice(ReadingKind.METER, meterSigner, 1 hours);

        vm.startPrank(account);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_BadMeterSlotLength.selector, 0));
        verifier.setMeter(meterSigner, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_BadMeterSlotLength.selector, 1 days + 1));
        verifier.setMeter(meterSigner, 1 days + 1);
        verifier.setMeter(address(0), 0);
        vm.stopPrank();
        assertEq(verifier.meterSlotSecondsOf(account), 0);
    }

    // ------------------------------------------------------------------
    // Grid state
    // ------------------------------------------------------------------

    function test_aGridStateFromTheRegisteredOperatorHoldsUntilValidUntil() public {
        GridState memory g = _grid(t0, t0 + 1 hours, GridLevel.ALERT, GridDirection.DEFICIT);
        bytes32 digest = verifier.digestOf(verifier.gridStateStructHash(g));
        vm.expectEmit(address(verifier));
        emit ReadingAccepted(address(0), ReadingKind.GRID_STATE, gridSigner, digest, abi.encode(g));
        assertEq(verifier.accept(_signGrid(verifier, GRID_KEY, g)), address(0));

        (GridState memory held, bool fresh) = verifier.gridStateOf(account);
        assertTrue(fresh);
        assertEq(uint8(held.level), uint8(GridLevel.ALERT));
        assertEq(uint8(held.direction), uint8(GridDirection.DEFICIT));
        assertEq(held.horizonSlots, 8);

        vm.warp(t0 + 1 hours);
        (, fresh) = verifier.gridStateOf(account);
        assertTrue(fresh, "at validUntil");
        vm.warp(t0 + 1 hours + 1);
        (, fresh) = verifier.gridStateOf(account);
        assertFalse(fresh, "past it");
    }

    function test_aGridStateFromAnotherOperatorIsInert() public {
        verifier.accept(_signGrid(verifier, OTHER_KEY, _grid(t0, t0 + 1 hours, GridLevel.EMERGENCY, GridDirection.NONE)));
        (, bool fresh) = verifier.gridStateOf(account);
        assertFalse(fresh);
    }

    function test_withoutAnOperatorThereIsNoGridState() public {
        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0, t0 + 1 hours, GridLevel.ALERT, GridDirection.DEFICIT)));
        (, bool fresh) = verifier.gridStateOf(makeAddr("nobody"));
        assertFalse(fresh);
    }

    function test_aBadFutureExpiredReorderedOrConflictingGridStateIsRefused() public {
        vm.expectRevert(OracleVerifier.Oracle_BadGridState.selector);
        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0, t0 - 1, GridLevel.ALERT, GridDirection.DEFICIT)));

        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_FromTheFuture.selector, t0 + 1, block.timestamp));
        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0 + 1, t0 + 2, GridLevel.ALERT, GridDirection.DEFICIT)));

        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Stale.selector, t0 - 10, block.timestamp, 0));
        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0 - 10, t0 - 1, GridLevel.ALERT, GridDirection.DEFICIT)));

        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0, t0 + 1 hours, GridLevel.ALERT, GridDirection.DEFICIT)));
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, t0 - 1, t0));
        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0 - 1, t0 + 1 hours, GridLevel.NORMAL, GridDirection.NONE)));

        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Conflicting.selector, t0));
        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0, t0 + 1 hours, GridLevel.NORMAL, GridDirection.NONE)));
    }

    function test_aGridStateValidUntilNowIsAccepted() public {
        verifier.accept(_signGrid(verifier, GRID_KEY, _grid(t0, t0, GridLevel.ALERT, GridDirection.SURPLUS)));
        (, bool fresh) = verifier.gridStateOf(account);
        assertTrue(fresh);
    }

    function test_theGridStateTakesNoMaximumAge() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_BadMaxAge.selector, 1 hours));
        verifier.setDevice(ReadingKind.GRID_STATE, gridSigner, 1 hours);
    }

    // ------------------------------------------------------------------
    // Signer distinctness (spec v0.2, section 4)
    // ------------------------------------------------------------------

    function test_aMeterSignerMayBeNeitherTheBmsNorThePvSigner() public {
        vm.startPrank(account);
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.METER, ReadingKind.BMS)
        );
        verifier.setMeter(bmsSigner, SLOT);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.METER, ReadingKind.PV_FORECAST
            )
        );
        verifier.setMeter(pvSigner, SLOT);
        vm.stopPrank();
    }

    function test_anEnvelopeSignerMayBeNeitherTheBmsNorThePvSigner() public {
        vm.startPrank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.ENVELOPE, ReadingKind.BMS
            )
        );
        verifier.setDevice(ReadingKind.ENVELOPE, bmsSigner, SCHEDULE_MAX_AGE);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.ENVELOPE, ReadingKind.PV_FORECAST
            )
        );
        verifier.setDevice(ReadingKind.ENVELOPE, pvSigner, SCHEDULE_MAX_AGE);
        vm.stopPrank();
    }

    /// @dev The other registration order: the meter and envelope first.
    function test_aBmsOrPvSignerMayBeNeitherTheMeterNorTheEnvelopeSigner() public {
        vm.startPrank(account);
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.BMS, ReadingKind.METER)
        );
        verifier.setDevice(ReadingKind.BMS, meterSigner, BMS_MAX_AGE);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.BMS, ReadingKind.ENVELOPE
            )
        );
        verifier.setDevice(ReadingKind.BMS, envelopeSigner, BMS_MAX_AGE);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.PV_FORECAST, ReadingKind.METER
            )
        );
        verifier.setDevice(ReadingKind.PV_FORECAST, meterSigner, PV_MAX_AGE);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleVerifier.Oracle_SignerNotDistinct.selector, ReadingKind.PV_FORECAST, ReadingKind.ENVELOPE
            )
        );
        verifier.setDevice(ReadingKind.PV_FORECAST, envelopeSigner, PV_MAX_AGE);
        vm.stopPrank();
    }

    /// @dev Spec section 7: signer collusion. The owner's configuration names
    ///      the agent's key as a signer; registration is refused, for every
    ///      kind.
    function test_noSignerOfAnyKindMayBeADeclaredAgentKey() public {
        vm.startPrank(account);
        verifier.setAgentKey(agentKey, true);
        for (uint8 k = 0; k <= uint8(type(ReadingKind).max); ++k) {
            ReadingKind kind = ReadingKind(k);
            vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_SignerIsAgentKey.selector, agentKey));
            if (kind == ReadingKind.METER) verifier.setMeter(agentKey, SLOT);
            else verifier.setDevice(kind, agentKey, kind == ReadingKind.GRID_STATE ? 0 : 1 hours);
        }
        vm.stopPrank();
    }

    /// @dev The other order: an agent key cannot be declared that is already
    ///      a signer.
    function test_noAgentKeyMayBeARegisteredSigner() public {
        address[6] memory signers = [bmsSigner, pvSigner, tariffSigner, meterSigner, envelopeSigner, gridSigner];
        vm.startPrank(account);
        for (uint8 k = 0; k < 6; ++k) {
            vm.expectRevert(
                abi.encodeWithSelector(OracleVerifier.Oracle_AgentKeyIsSigner.selector, signers[k], ReadingKind(k))
            );
            verifier.setAgentKey(signers[k], true);
        }
        vm.stopPrank();
    }

    function test_agentKeysAreBoundedAndCanBeWithdrawn() public {
        uint256 max = verifier.MAX_AGENT_KEYS();
        vm.startPrank(account);
        for (uint256 i = 0; i < max; ++i) {
            verifier.setAgentKey(address(uint160(0xA000 + i)), true);
        }
        vm.expectRevert(OracleVerifier.Oracle_TooManyAgentKeys.selector);
        verifier.setAgentKey(address(0xB000), true);

        verifier.setAgentKey(address(uint160(0xA000)), true); // already declared: no-op
        assertEq(verifier.agentKeyCount(account), max);

        verifier.setAgentKey(address(uint160(0xA000)), false);
        assertEq(verifier.agentKeyCount(account), max - 1);
        assertFalse(verifier.isAgentKey(account, address(uint160(0xA000))));
        verifier.setAgentKey(address(0xB000), true);

        // A withdrawn key may be a signer again.
        verifier.setDevice(ReadingKind.TARIFF, address(uint160(0xA000)), 1 hours);

        vm.expectRevert(OracleVerifier.Oracle_ZeroAgentKey.selector);
        verifier.setAgentKey(address(0), true);
        vm.stopPrank();
    }

    /// @dev Removing a signer is always allowed, whatever is declared.
    function test_removingASignerIsAlwaysAllowed() public {
        vm.startPrank(account);
        verifier.setDevice(ReadingKind.BMS, address(0), 0);
        verifier.setMeter(address(0), 0);
        vm.stopPrank();
        assertEq(verifier.deviceOf(account, ReadingKind.BMS).signer, address(0));
        assertEq(verifier.deviceOf(account, ReadingKind.METER).signer, address(0));
    }

    /// @dev The tariff and grid operator are not anchors that must stay apart
    ///      from the battery's devices (spec section 4 names METER and
    ///      ENVELOPE only).
    function test_otherKindsMayShareASigner() public {
        vm.prank(account);
        verifier.setDevice(ReadingKind.TARIFF, bmsSigner, 1 hours);
        assertEq(verifier.deviceOf(account, ReadingKind.TARIFF).signer, bmsSigner);
    }
}
