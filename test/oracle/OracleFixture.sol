// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {
    ReadingKind,
    BmsReading,
    PvForecast,
    TariffSchedule,
    MeterReading,
    Envelope,
    GridState,
    SignedReading
} from "../../contracts/oracle/OracleTypes.sol";

/// @notice Signing helpers: a key per oracle kind, and readings signed with
///         them for a given verifier.
abstract contract OracleFixture is Test {
    uint256 internal constant BMS_KEY = 0xB0B5;
    uint256 internal constant PV_KEY = 0x50_1A2;
    uint256 internal constant OTHER_KEY = 0xBAD;

    /// @dev One half-hour slot: the BMS reading must be from the current slot.
    uint32 internal constant BMS_MAX_AGE = 30 minutes;
    /// @dev Spec 5.4: tau_pv = 1 h.
    uint32 internal constant PV_MAX_AGE = 1 hours;
    uint32 internal constant PV_SLOT = 30 minutes;

    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address internal bmsSigner = vm.addr(BMS_KEY);
    address internal pvSigner = vm.addr(PV_KEY);

    uint256 internal constant TARIFF_KEY = 0x7A21FF;
    uint256 internal constant METER_KEY = 0x3E7E2;
    uint256 internal constant ENVELOPE_KEY = 0xE7E1;
    uint256 internal constant GRID_KEY = 0x6121D;
    address internal tariffSigner = vm.addr(TARIFF_KEY);
    address internal meterSigner = vm.addr(METER_KEY);
    address internal envelopeSigner = vm.addr(ENVELOPE_KEY);
    address internal gridSigner = vm.addr(GRID_KEY);

    function _bms(address account, uint64 timestamp, uint64 socWh, uint64 odometerWh)
        internal
        pure
        returns (BmsReading memory)
    {
        return BmsReading({account: account, timestamp: timestamp, socWh: socWh, dischargeOdometerWh: odometerWh});
    }

    /// @dev The digests are computed here, from the type strings, and not by
    ///      asking the verifier: a wrong type hash in the contract shows up as a
    ///      refused signature.
    function _domain(OracleVerifier verifier) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PolicyOracle"),
                keccak256("1"),
                block.chainid,
                address(verifier)
            )
        );
    }

    function _bmsDigest(OracleVerifier verifier, BmsReading memory r) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("BmsReading(address account,uint64 timestamp,uint64 socWh,uint64 dischargeOdometerWh)"),
                r.account,
                r.timestamp,
                r.socWh,
                r.dischargeOdometerWh
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(verifier), structHash));
    }

    function _pvDigest(OracleVerifier verifier, PvForecast memory f) internal view returns (bytes32) {
        bytes32[] memory padded = new bytes32[](f.pvWh.length);
        for (uint256 i = 0; i < padded.length; ++i) {
            padded[i] = bytes32(uint256(f.pvWh[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PvForecast(address account,uint64 issuedAt,uint64 firstSlotStart,uint32 slotSeconds,uint64[] pvWh)"
                ),
                f.account,
                f.issuedAt,
                f.firstSlotStart,
                f.slotSeconds,
                keccak256(abi.encodePacked(padded))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(verifier), structHash));
    }

    function _signBms(OracleVerifier verifier, uint256 key, BmsReading memory r)
        internal
        view
        returns (SignedReading memory)
    {
        return SignedReading({kind: ReadingKind.BMS, data: abi.encode(r), signature: _sign(key, _bmsDigest(verifier, r))});
    }

    function _forecast(address account, uint64 issuedAt, uint64 firstSlotStart, uint64[] memory pvWh)
        internal
        pure
        returns (PvForecast memory)
    {
        return PvForecast({
            account: account, issuedAt: issuedAt, firstSlotStart: firstSlotStart, slotSeconds: PV_SLOT, pvWh: pvWh
        });
    }

    function _signPv(OracleVerifier verifier, uint256 key, PvForecast memory f)
        internal
        view
        returns (SignedReading memory)
    {
        return SignedReading({
            kind: ReadingKind.PV_FORECAST, data: abi.encode(f), signature: _sign(key, _pvDigest(verifier, f))
        });
    }

    // --- v0.2 kinds: digests from the type strings, as for the BMS ------------

    function _packed(uint64[] memory values) internal pure returns (bytes32) {
        bytes32[] memory padded = new bytes32[](values.length);
        for (uint256 i = 0; i < padded.length; ++i) {
            padded[i] = bytes32(uint256(values[i]));
        }
        return keccak256(abi.encodePacked(padded));
    }

    function _tariffDigest(OracleVerifier verifier, TariffSchedule memory t) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "TariffSchedule(address account,uint64 issuedAt,uint64 firstSlotStart,uint32 slotSeconds,uint64[] retail,uint64[] feedIn)"
                ),
                t.account,
                t.issuedAt,
                t.firstSlotStart,
                t.slotSeconds,
                _packed(t.retail),
                _packed(t.feedIn)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(verifier), structHash));
    }

    function _envelopeDigest(OracleVerifier verifier, Envelope memory e) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Envelope(address account,uint64 issuedAt,uint64 firstSlotStart,uint32 slotSeconds,uint64[] exportLimitWh,uint64[] importLimitWh)"
                ),
                e.account,
                e.issuedAt,
                e.firstSlotStart,
                e.slotSeconds,
                _packed(e.exportLimitWh),
                _packed(e.importLimitWh)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(verifier), structHash));
    }

    function _meterDigest(OracleVerifier verifier, MeterReading memory m) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("MeterReading(address account,uint64 slotStart,uint64 importWh,uint64 exportWh)"),
                m.account,
                m.slotStart,
                m.importWh,
                m.exportWh
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(verifier), structHash));
    }

    function _gridDigest(OracleVerifier verifier, GridState memory g) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("GridState(uint64 issuedAt,uint64 validUntil,uint8 level,uint8 direction,uint16 horizonSlots)"),
                g.issuedAt,
                g.validUntil,
                uint256(uint8(g.level)),
                uint256(uint8(g.direction)),
                g.horizonSlots
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(verifier), structHash));
    }

    function _signTariff(OracleVerifier verifier, uint256 key, TariffSchedule memory t)
        internal
        view
        returns (SignedReading memory)
    {
        return SignedReading({kind: ReadingKind.TARIFF, data: abi.encode(t), signature: _sign(key, _tariffDigest(verifier, t))});
    }

    function _signEnvelope(OracleVerifier verifier, uint256 key, Envelope memory e)
        internal
        view
        returns (SignedReading memory)
    {
        return SignedReading({
            kind: ReadingKind.ENVELOPE, data: abi.encode(e), signature: _sign(key, _envelopeDigest(verifier, e))
        });
    }

    function _signMeter(OracleVerifier verifier, uint256 key, MeterReading memory m)
        internal
        view
        returns (SignedReading memory)
    {
        return SignedReading({kind: ReadingKind.METER, data: abi.encode(m), signature: _sign(key, _meterDigest(verifier, m))});
    }

    function _signGrid(OracleVerifier verifier, uint256 key, GridState memory g)
        internal
        view
        returns (SignedReading memory)
    {
        return SignedReading({
            kind: ReadingKind.GRID_STATE, data: abi.encode(g), signature: _sign(key, _gridDigest(verifier, g))
        });
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _values(uint256 n, uint64 first) internal pure returns (uint64[] memory values) {
        values = new uint64[](n);
        for (uint256 i = 0; i < n; ++i) {
            values[i] = first + uint64(i) * 10;
        }
    }
}
