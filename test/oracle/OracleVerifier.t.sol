// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console} from "forge-std/console.sol";
import {OracleFixture} from "./OracleFixture.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, BmsReading, PvForecast, SignedReading} from "../../contracts/oracle/OracleTypes.sol";

/// @notice The oracle verifier on its own (spec 5.4, step 5.1): signatures,
///         the signer registry, staleness and order.
contract OracleVerifierTest is OracleFixture {
    OracleVerifier internal verifier;
    address internal account = makeAddr("account");
    uint64 internal t0;

    event ReadingAccepted(
        address indexed account, ReadingKind indexed kind, address indexed signer, bytes32 digest, bytes data
    );

    function setUp() public {
        vm.warp(1_760_000_400);
        t0 = uint64(block.timestamp) - 400; // a slot start, 400 s ago
        verifier = new OracleVerifier();
        vm.startPrank(account);
        verifier.setDevice(ReadingKind.BMS, bmsSigner, BMS_MAX_AGE);
        verifier.setDevice(ReadingKind.PV_FORECAST, pvSigner, PV_MAX_AGE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Accepted
    // ------------------------------------------------------------------

    function test_aSignedFreshReadingIsAcceptedEmittedAndStored() public {
        BmsReading memory r = _bms(account, t0, 3_000, 120_000);
        SignedReading memory signed = _signBms(verifier, BMS_KEY, r);
        bytes32 digest = verifier.digestOf(verifier.bmsStructHash(r));

        vm.expectEmit(address(verifier));
        emit ReadingAccepted(account, ReadingKind.BMS, bmsSigner, digest, abi.encode(r));
        assertEq(verifier.accept(signed), account);

        (BmsReading memory stored, bool fresh) = verifier.bmsOf(account);
        assertTrue(fresh);
        assertEq(stored.timestamp, t0);
        assertEq(stored.socWh, 3_000);
        assertEq(stored.dischargeOdometerWh, 120_000);
    }

    function test_theContractSignsWhatTheTypeStringsSay() public view {
        BmsReading memory r = _bms(account, t0, 3_000, 120_000);
        assertEq(verifier.digestOf(verifier.bmsStructHash(r)), _bmsDigest(verifier, r));
        PvForecast memory f = _forecast(account, t0, t0, _values(5, 3));
        assertEq(verifier.digestOf(verifier.pvStructHash(f)), _pvDigest(verifier, f));
    }

    function test_anyoneMayHandInASignedReading() public {
        vm.prank(makeAddr("relay"));
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0)));
        (, bool fresh) = verifier.bmsOf(account);
        assertTrue(fresh);
    }

    function test_aReadingExactlyAsOldAsTheMaximumIsAccepted() public {
        uint64 oldest = uint64(block.timestamp) - BMS_MAX_AGE;
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, oldest, 3_000, 0)));
    }

    function test_aNewerReadingReplacesTheLast() public {
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 100)));
        vm.warp(block.timestamp + PV_SLOT);
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0 + PV_SLOT, 2_000, 1_150)));
        (BmsReading memory stored,) = verifier.bmsOf(account);
        assertEq(stored.socWh, 2_000);
        assertEq(stored.dischargeOdometerWh, 1_150);
    }

    // ------------------------------------------------------------------
    // Refused: who signed
    // ------------------------------------------------------------------

    function test_aReadingSignedByAnotherKeyIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_WrongSigner.selector, vm.addr(OTHER_KEY), bmsSigner)
        );
        verifier.accept(_signBms(verifier, OTHER_KEY, _bms(account, t0, 3_000, 0)));
    }

    function test_aPvKeyCannotSignForTheBattery() public {
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_WrongSigner.selector, pvSigner, bmsSigner));
        verifier.accept(_signBms(verifier, PV_KEY, _bms(account, t0, 3_000, 0)));
    }

    function test_aReadingForAnAccountWithNoSignerIsRefused() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_NoSigner.selector, stranger, ReadingKind.BMS));
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(stranger, t0, 3_000, 0)));
    }

    function test_aTamperedReadingIsRefused() public {
        SignedReading memory signed = _signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0));
        signed.data = abi.encode(_bms(account, t0, 4_900, 0));
        vm.expectPartialRevert(OracleVerifier.Oracle_WrongSigner.selector);
        verifier.accept(signed);
    }

    function test_theHighSTwinOfAValidSignatureIsRefused() public {
        BmsReading memory r = _bms(account, t0, 3_000, 0);
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(BMS_KEY, verifier.digestOf(verifier.bmsStructHash(r)));
        // (r, n - s, flipped v) recovers the same address.
        bytes memory twin = abi.encodePacked(rr, bytes32(N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(OracleVerifier.Oracle_BadSignature.selector);
        verifier.accept(SignedReading({kind: ReadingKind.BMS, data: abi.encode(r), signature: twin}));
    }

    function test_aMalformedSignatureIsRefused() public {
        SignedReading memory signed = _signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0));
        bytes memory full = signed.signature;

        signed.signature = new bytes(64);
        vm.expectRevert(OracleVerifier.Oracle_BadSignature.selector);
        verifier.accept(signed);

        full[64] = bytes1(uint8(29));
        signed.signature = full;
        vm.expectRevert(OracleVerifier.Oracle_BadSignature.selector);
        verifier.accept(signed);
    }

    function test_aReadingSignedForAnotherVerifierIsRefused() public {
        OracleVerifier other = new OracleVerifier();
        vm.prank(account);
        other.setDevice(ReadingKind.BMS, bmsSigner, BMS_MAX_AGE);
        SignedReading memory forOther = _signBms(other, BMS_KEY, _bms(account, t0, 3_000, 0));
        vm.expectPartialRevert(OracleVerifier.Oracle_WrongSigner.selector);
        verifier.accept(forOther);
    }

    function test_aReadingSignedOnAnotherChainIsRefused() public {
        SignedReading memory signed = _signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0));
        vm.chainId(block.chainid + 1);
        vm.expectPartialRevert(OracleVerifier.Oracle_WrongSigner.selector);
        verifier.accept(signed);
    }

    // ------------------------------------------------------------------
    // Refused: when
    // ------------------------------------------------------------------

    function test_aStaleReadingIsRefused() public {
        uint64 tooOld = uint64(block.timestamp) - BMS_MAX_AGE - 1;
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_Stale.selector, tooOld, block.timestamp, BMS_MAX_AGE)
        );
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, tooOld, 3_000, 0)));
    }

    function test_aReadingFromTheFutureIsRefused() public {
        uint64 ahead = uint64(block.timestamp) + 1;
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_FromTheFuture.selector, ahead, block.timestamp));
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, ahead, 3_000, 0)));
    }

    /// @dev The favourable-reading attack (spec 9.1): the agent holds two
    ///      genuine readings and tries to use the older one after the newer.
    function test_aReorderedReadingIsRefused() public {
        SignedReading memory older = _signBms(verifier, BMS_KEY, _bms(account, t0 - 60, 4_500, 0));
        SignedReading memory newer = _signBms(verifier, BMS_KEY, _bms(account, t0, 1_200, 0));
        verifier.accept(newer);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, t0 - 60, t0));
        verifier.accept(older);
    }

    function test_theSameReadingAgainChangesNothingAndEmitsNothing() public {
        SignedReading memory signed = _signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0));
        verifier.accept(signed);
        vm.recordLogs();
        assertEq(verifier.accept(signed), account);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_aDifferentReadingWithTheSameTimestampIsRefused() public {
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0)));
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Conflicting.selector, t0));
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 4_000, 0)));
    }

    function test_theOdometerCannotGoDown() public {
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 5_000)));
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_OdometerWentDown.selector, 4_999, 5_000));
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0 + 1, 3_000, 4_999)));
    }

    function test_aStoredReadingGoesStaleWithTime() public {
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0)));
        vm.warp(t0 + BMS_MAX_AGE);
        (, bool fresh) = verifier.bmsOf(account);
        assertTrue(fresh);
        vm.warp(t0 + BMS_MAX_AGE + 1);
        (, fresh) = verifier.bmsOf(account);
        assertFalse(fresh);
    }

    function test_noReadingIsNotFresh() public view {
        (BmsReading memory r, bool fresh) = verifier.bmsOf(account);
        assertFalse(fresh);
        assertEq(r.timestamp, 0);
    }

    /// @dev Whatever the order they are handed in, only readings newer than
    ///      every one accepted before get through.
    function testFuzz_onlyNewerReadingsAreAccepted(uint64[6] memory ages) public {
        uint64 last;
        for (uint256 i = 0; i < ages.length; ++i) {
            uint64 timestamp = uint64(block.timestamp) - uint64(bound(ages[i], 0, BMS_MAX_AGE));
            SignedReading memory signed = _signBms(verifier, BMS_KEY, _bms(account, timestamp, uint64(i), 0));
            if (timestamp < last) {
                vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, timestamp, last));
                verifier.accept(signed);
            } else if (timestamp == last) {
                vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Conflicting.selector, timestamp));
                verifier.accept(signed);
            } else {
                verifier.accept(signed);
                last = timestamp;
            }
            (BmsReading memory stored,) = verifier.bmsOf(account);
            assertEq(stored.timestamp, last);
        }
    }

    // ------------------------------------------------------------------
    // The signer registry
    // ------------------------------------------------------------------

    function test_aNewSignerDropsTheOldDevicesReading() public {
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 9_000)));
        vm.prank(account);
        verifier.setDevice(ReadingKind.BMS, vm.addr(OTHER_KEY), BMS_MAX_AGE);

        (BmsReading memory stored, bool fresh) = verifier.bmsOf(account);
        assertFalse(fresh);
        assertEq(stored.timestamp, 0);

        // The old key is refused; the new device starts its own odometer, but
        // not before the last timestamp.
        vm.expectPartialRevert(OracleVerifier.Oracle_WrongSigner.selector);
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0 + 1, 3_000, 9_000)));
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, t0 - 1, t0));
        verifier.accept(_signBms(verifier, OTHER_KEY, _bms(account, t0 - 1, 3_000, 0)));
        verifier.accept(_signBms(verifier, OTHER_KEY, _bms(account, t0, 2_500, 0)));
        (stored, fresh) = verifier.bmsOf(account);
        assertTrue(fresh);
        assertEq(stored.socWh, 2_500);
    }

    function test_removingTheSignerMakesItsReadingUnusable() public {
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 0)));
        vm.prank(account);
        verifier.setDevice(ReadingKind.BMS, address(0), 0);
        (, bool fresh) = verifier.bmsOf(account);
        assertFalse(fresh);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_NoSigner.selector, account, ReadingKind.BMS));
        verifier.accept(_signBms(verifier, BMS_KEY, _bms(account, t0 + 1, 3_000, 0)));
    }

    function test_theMaximumAgeIsBounded() public {
        vm.startPrank(account);
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_BadMaxAge.selector, 0));
        verifier.setDevice(ReadingKind.BMS, bmsSigner, 0);
        uint32 tooLong = verifier.MAX_AGE_LIMIT() + 1;
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_BadMaxAge.selector, tooLong));
        verifier.setDevice(ReadingKind.BMS, bmsSigner, tooLong);
        vm.stopPrank();
    }

    function test_eachAccountKeepsItsOwnRegistry() public {
        address neighbour = makeAddr("neighbour");
        vm.prank(neighbour);
        verifier.setDevice(ReadingKind.BMS, vm.addr(OTHER_KEY), BMS_MAX_AGE);
        assertEq(verifier.deviceOf(account, ReadingKind.BMS).signer, bmsSigner);
        // The neighbour's key cannot sign for this account.
        vm.expectPartialRevert(OracleVerifier.Oracle_WrongSigner.selector);
        verifier.accept(_signBms(verifier, OTHER_KEY, _bms(account, t0, 3_000, 0)));
    }

    // ------------------------------------------------------------------
    // The PV forecast
    // ------------------------------------------------------------------

    function test_aForecastIsServedSlotBySlot() public {
        uint64 first = t0;
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0, first, _values(16, 100))));

        (uint64 pv, bool usable) = verifier.pvAt(account, first);
        assertTrue(usable);
        assertEq(pv, 100);
        (pv, usable) = verifier.pvAt(account, first + 15 * PV_SLOT);
        assertTrue(usable);
        assertEq(pv, 250);

        // Before, after, and between slots: not covered.
        (pv, usable) = verifier.pvAt(account, first - PV_SLOT);
        assertFalse(usable);
        assertEq(pv, 0);
        (, usable) = verifier.pvAt(account, first + 16 * PV_SLOT);
        assertFalse(usable);
        (, usable) = verifier.pvAt(account, first + 60);
        assertFalse(usable);
    }

    function test_aForecastIsEmittedInFull() public {
        PvForecast memory f = _forecast(account, t0, t0, _values(4, 0));
        vm.expectEmit(address(verifier));
        emit ReadingAccepted(
            account, ReadingKind.PV_FORECAST, pvSigner, verifier.digestOf(verifier.pvStructHash(f)), abi.encode(f)
        );
        verifier.accept(_signPv(verifier, PV_KEY, f));
    }

    function test_aStaleForecastIsNotUsed() public {
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0, t0, _values(8, 100))));
        vm.warp(t0 + PV_MAX_AGE + 1);
        (uint64 pv, bool usable) = verifier.pvAt(account, t0 + 2 * PV_SLOT);
        assertFalse(usable);
        assertEq(pv, 0);
    }

    function test_aNewerForecastReplacesTheOldOneWhole() public {
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0, t0, _values(16, 100))));
        vm.warp(block.timestamp + 600);
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0 + 600, t0 + PV_SLOT, _values(2, 7))));
        (uint64 pv, bool usable) = verifier.pvAt(account, t0 + PV_SLOT);
        assertEq(pv, 7);
        assertTrue(usable);
        // Slots only the old forecast covered are gone with it.
        (, usable) = verifier.pvAt(account, t0);
        assertFalse(usable);
        (, usable) = verifier.pvAt(account, t0 + 5 * PV_SLOT);
        assertFalse(usable);
    }

    function test_anOlderForecastIsRefused() public {
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0, t0, _values(4, 100))));
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, t0 - 1, t0));
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0 - 1, t0, _values(4, 900))));
    }

    function test_aMalformedForecastIsRefused() public {
        PvForecast memory f = _forecast(account, t0, t0, _values(4, 0));
        f.slotSeconds = 0;
        vm.expectRevert(OracleVerifier.Oracle_BadForecast.selector);
        verifier.accept(_signPv(verifier, PV_KEY, f));

        vm.expectRevert(OracleVerifier.Oracle_BadForecast.selector);
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0, t0, new uint64[](0))));

        uint256 tooMany = verifier.MAX_FORECAST_SLOTS() + 1;
        vm.expectRevert(OracleVerifier.Oracle_BadForecast.selector);
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0, t0, _values(tooMany, 0))));
    }

    function test_aFullTwoDayForecastFits() public {
        uint256 most = verifier.MAX_FORECAST_SLOTS();
        verifier.accept(_signPv(verifier, PV_KEY, _forecast(account, t0, t0, _values(most, 0))));
        (uint64 pv, bool usable) = verifier.pvAt(account, t0 + uint64(most - 1) * PV_SLOT);
        assertTrue(usable);
        assertEq(pv, uint64(most - 1) * 10);
    }

    /// @dev Gas of `accept`, execution only (no base fee, no calldata), for
    ///      the log: a BMS reading, and forecasts of one day and two days of
    ///      half-hour slots, each first into empty storage and then over a
    ///      previous one.
    function test_gasOfAccept() public {
        uint256 bmsFirst = _gasOf(_signBms(verifier, BMS_KEY, _bms(account, t0, 3_000, 10)));
        uint256 bmsNext = _gasOf(_signBms(verifier, BMS_KEY, _bms(account, t0 + 1, 2_900, 20)));
        uint256 day = _gasOf(_signPv(verifier, PV_KEY, _forecast(account, t0, t0, _values(48, 1))));
        uint256 dayAgain = _gasOf(_signPv(verifier, PV_KEY, _forecast(account, t0 + 1, t0, _values(48, 2))));
        uint256 twoDays = _gasOf(_signPv(verifier, PV_KEY, _forecast(account, t0 + 2, t0, _values(96, 3))));
        console.log("accept BMS, first / next:", bmsFirst, bmsNext);
        console.log("accept PV 48 slots, first / next:", day, dayAgain);
        console.log("accept PV 96 slots, over 48:", twoDays);
        // Generous ceilings, so a regression shows.
        assertLt(bmsNext, 60_000);
        assertLt(twoDays, 1_500_000);
    }

    function _gasOf(SignedReading memory signed) internal returns (uint256 used) {
        used = gasleft();
        verifier.accept(signed);
        used -= gasleft();
    }

    function test_theBatteryKeyCannotSignTheForecast() public {
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_WrongSigner.selector, bmsSigner, pvSigner));
        verifier.accept(_signPv(verifier, BMS_KEY, _forecast(account, t0, t0, _values(4, 0))));
    }
}
