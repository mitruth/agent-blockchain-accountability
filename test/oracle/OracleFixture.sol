// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, BmsReading, PvForecast, SignedReading} from "../../contracts/oracle/OracleTypes.sol";

/// @notice Signing helpers: a BMS key and a PV forecast key, and readings
///         signed with them for a given verifier.
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
