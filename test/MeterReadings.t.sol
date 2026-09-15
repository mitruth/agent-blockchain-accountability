// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {MeterReadings} from "../contracts/MeterReadings.sol";
import {PolicyConfig} from "../contracts/PolicyConfig.sol";

/// Stage A2: the meter.
///
/// What must hold:
///   - a genuine signature from the registered meter verifies
///   - changing any reading, the day, the chain or the ledger breaks it
///   - malformed and malleable signatures are refused outright
///   - the digest is real EIP-712, byte for byte what an off-chain signer
///     produces -- otherwise every genuine signature fails in deployment
///   - the owner registers the meter, and the meter is never the agent's key
contract MeterReadingsTest is Test {
    PolicyConfig internal config;

    address internal owner = makeAddr("owner");
    address internal agent;
    uint256 internal agentKey;
    address internal guardian = makeAddr("guardian");
    address internal meter;
    uint256 internal meterKey;
    address internal stranger = makeAddr("stranger");

    address internal constant LEDGER = 0x00000000000000000000000000000000000012AB;
    uint256 internal constant CHAIN_ID = 84532; // Base Sepolia
    uint64 internal constant DAY = 20000;

    uint64[48] internal importMWh;
    uint64[48] internal exportMWh;

    function setUp() public {
        (meter, meterKey) = makeAddrAndKey("meter");
        (agent, agentKey) = makeAddrAndKey("agentSessionKey");

        vm.prank(owner);
        config = new PolicyConfig(guardian, agent, 10000, 7, 72 hours, 6 hours);

        // Same vectors as the viem reference in test_digestMatchesViemTypedData.
        for (uint256 i = 0; i < 48; i++) {
            importMWh[i] = uint64(i * 1000 + 7);
            exportMWh[i] = i % 2 == 0 ? 0 : uint64(i * 333);
        }
    }

    function _digest() internal view returns (bytes32) {
        return MeterReadings.digest(CHAIN_ID, LEDGER, DAY, importMWh, exportMWh);
    }

    function _sign(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    // External wrapper so expectRevert can observe a library revert.
    function recoverExternal(bytes32 hash, bytes memory signature) external pure returns (address) {
        return MeterReadings.recover(hash, signature);
    }

    // ------------------------------------------------------------------
    // The digest is real EIP-712
    // ------------------------------------------------------------------

    /// Reference computed independently with viem's hashTypedData -- the
    /// library the simulated meter will sign with -- for the vectors built in
    /// setUp, chain id 84532 and verifying contract 0x...12ab. A mistake in how
    /// the Solidity side encodes the fixed-size arrays would pass every other
    /// test here, because they all compare the contract against itself.
    function test_digestMatchesViemTypedData() public view {
        assertEq(_digest(), 0x8bc42356698b07da360dedfdeea1c76c7d58513239e0d274d846889a428a3f3c);
    }

    // ------------------------------------------------------------------
    // Genuine readings verify
    // ------------------------------------------------------------------

    function test_meterSignatureRecoversTheMeter() public view {
        bytes memory sig = _sign(meterKey, _digest());
        assertEq(MeterReadings.recover(_digest(), sig), meter);
    }

    /// A payload signed by the agent recovers the agent, which is not the
    /// meter. The comparison against the registered meter is what rejects it.
    function test_agentSignatureDoesNotRecoverTheMeter() public view {
        bytes memory sig = _sign(agentKey, _digest());
        address signer = MeterReadings.recover(_digest(), sig);
        assertEq(signer, agent);
        assertTrue(signer != meter);
    }

    // ------------------------------------------------------------------
    // Any change breaks the signature
    // ------------------------------------------------------------------

    function test_alteringOneImportReadingBreaksTheSignature() public {
        bytes memory sig = _sign(meterKey, _digest());
        importMWh[13] -= 1; // one milliwatt-hour
        assertTrue(MeterReadings.recover(_digest(), sig) != meter);
    }

    /// Export readings are bound as tightly as imports: inflating exports is
    /// the direct route to understating spend.
    function test_alteringOneExportReadingBreaksTheSignature() public {
        bytes memory sig = _sign(meterKey, _digest());
        exportMWh[47] += 1;
        assertTrue(MeterReadings.recover(_digest(), sig) != meter);
    }

    function test_swappingImportAndExportBreaksTheSignature() public view {
        bytes memory sig = _sign(meterKey, _digest());
        bytes32 swapped = MeterReadings.digest(CHAIN_ID, LEDGER, DAY, exportMWh, importMWh);
        assertTrue(MeterReadings.recover(swapped, sig) != meter);
    }

    /// A genuine day cannot be presented as a different day.
    function test_anotherDayBreaksTheSignature() public view {
        bytes memory sig = _sign(meterKey, _digest());
        bytes32 other = MeterReadings.digest(CHAIN_ID, LEDGER, DAY + 1, importMWh, exportMWh);
        assertTrue(MeterReadings.recover(other, sig) != meter);
    }

    function test_anotherChainBreaksTheSignature() public view {
        bytes memory sig = _sign(meterKey, _digest());
        bytes32 other = MeterReadings.digest(1, LEDGER, DAY, importMWh, exportMWh);
        assertTrue(MeterReadings.recover(other, sig) != meter);
    }

    /// Readings signed for one household's ledger are not valid on another.
    function test_anotherLedgerBreaksTheSignature() public view {
        bytes memory sig = _sign(meterKey, _digest());
        bytes32 other = MeterReadings.digest(CHAIN_ID, address(0xBEEF), DAY, importMWh, exportMWh);
        assertTrue(MeterReadings.recover(other, sig) != meter);
    }

    // ------------------------------------------------------------------
    // Malformed signatures are refused, not mis-recovered
    // ------------------------------------------------------------------

    /// For every valid (r, s, v) there is a twin (r, n - s, v') from the same
    /// signer. Accepting both would let one reading be submitted under two
    /// distinct signatures.
    function test_malleableTwinSignatureIsRefused() public {
        bytes32 hash = _digest();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(meterKey, hash);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 twinS = bytes32(n - uint256(s));
        uint8 twinV = v == 27 ? 28 : 27;
        bytes memory twin = abi.encodePacked(r, twinS, twinV);

        vm.expectRevert(MeterReadings.MeterReadings_BadSignature.selector);
        this.recoverExternal(hash, twin);
    }

    function test_invalidVIsRefused() public {
        bytes32 hash = _digest();
        (, bytes32 r, bytes32 s) = vm.sign(meterKey, hash);
        vm.expectRevert(MeterReadings.MeterReadings_BadSignature.selector);
        this.recoverExternal(hash, abi.encodePacked(r, s, uint8(1)));
    }

    function test_wrongLengthIsRefused() public {
        bytes memory sig = _sign(meterKey, _digest());
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) short[i] = sig[i];
        vm.expectRevert(MeterReadings.MeterReadings_BadSignatureLength.selector);
        this.recoverExternal(_digest(), short);
    }

    /// An all-zero signature makes ecrecover return address(0). If that were
    /// passed through, it would match a meter that was never registered.
    function test_zeroSignatureIsRefused() public {
        vm.expectRevert(MeterReadings.MeterReadings_BadSignature.selector);
        this.recoverExternal(_digest(), abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
    }

    // ------------------------------------------------------------------
    // Sanity: a half-hour cannot both import and export
    // ------------------------------------------------------------------

    function test_exclusiveReadingsPass() public view {
        uint64[48] memory imp = importMWh;
        uint64[48] memory exp;
        (bool ok,) = MeterReadings.importAndExportAreExclusive(imp, exp);
        assertTrue(ok);
    }

    function test_simultaneousImportAndExportIsFlagged() public view {
        (bool ok, uint256 firstBad) = MeterReadings.importAndExportAreExclusive(importMWh, exportMWh);
        assertFalse(ok, "setUp puts exports on odd half-hours alongside imports");
        assertEq(firstBad, 1);
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    function test_ownerRegistersTheMeter() public {
        vm.prank(owner);
        config.setMeter(meter);
        assertEq(config.meter(), meter);
    }

    function test_nobodyElseRegistersTheMeter() public {
        vm.prank(agent);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setMeter(agent);

        vm.prank(guardian);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setMeter(guardian);

        vm.prank(stranger);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setMeter(stranger);

        assertEq(config.meter(), address(0));
    }

    /// The F1 lesson applied to the meter: one misconfiguration would put the
    /// agent back in charge of the number it is capped on.
    function test_meterMayNotBeTheSessionKey() public {
        vm.prank(owner);
        vm.expectRevert(bytes("PolicyConfig: meter may not be the session key"));
        config.setMeter(agent);
    }

    function test_sessionKeyMayNotBeTheMeter() public {
        vm.prank(owner);
        config.setMeter(meter);

        vm.prank(owner);
        vm.expectRevert(bytes("PolicyConfig: session key may not be the meter"));
        config.setSessionKey(meter);
    }

    /// The distinctness rule must not get in the way of revocation.
    function test_sessionKeyCanStillBeRevokedWithAMeterSet() public {
        vm.prank(owner);
        config.setMeter(meter);

        vm.prank(owner);
        config.setSessionKey(address(0));
        assertEq(config.sessionKey(), address(0));
    }

    // ------------------------------------------------------------------
    // Gas, for the evaluation
    // ------------------------------------------------------------------

    function test_reportGasVerifyOneDay() public {
        bytes memory sig = _sign(meterKey, _digest());
        uint256 before = gasleft();
        address signer = MeterReadings.recover(
            MeterReadings.digest(CHAIN_ID, LEDGER, DAY, importMWh, exportMWh), sig
        );
        uint256 used = before - gasleft();
        assertEq(signer, meter);
        emit log_named_uint("gas, digest + recover for one day of 96 readings", used);
    }
}
