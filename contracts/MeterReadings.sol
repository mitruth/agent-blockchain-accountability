// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title MeterReadings
/// @notice Authentication and sanity checks for a day of meter readings.
///
/// Grid import and export are the other input daily spend is computed from.
/// They come from the meter, never from the agent (D7.1, D7.3). The dataset
/// holds no meter data, so the HEMS simulator plays the meter and holds its key.
///
/// The meter signs EIP-712 typed data: a day index and two vectors of 48
/// half-hourly readings in milliwatt-hours, 00:00 UTC first. Anyone may relay
/// the signed payload -- authenticity comes from the signature, not from who
/// sends the transaction -- which is what stops an agent from withholding a
/// bad day.
///
/// The domain binds the chain id and the SpendLedger address. The ledger, not
/// the validator: the ledger is never redeployed, so signatures survive a
/// validator upgrade, and a payload signed for one ledger or chain cannot be
/// replayed onto another.
library MeterReadings {
    uint256 internal constant INTERVALS_PER_DAY = 48;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant READINGS_TYPEHASH =
        keccak256("MeterReadings(uint64 dayIndex,uint64[48] importMWh,uint64[48] exportMWh)");

    bytes32 internal constant NAME_HASH = keccak256("HouseholdMeter");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    /// @dev secp256k1n / 2. A signature with s above this has a twin with the
    ///      same signer; accepting both would make one reading submittable
    ///      under two distinct signatures.
    uint256 internal constant HALF_CURVE_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    error MeterReadings_BadSignatureLength();
    error MeterReadings_BadSignature();

    function domainSeparator(uint256 chainId, address ledger) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, ledger));
    }

    /// @notice The EIP-712 digest the meter signs.
    /// @dev EIP-712 encodes a fixed-size array as the keccak of its elements,
    ///      each padded to 32 bytes -- which is what encodePacked does for
    ///      array elements.
    function digest(
        uint256 chainId,
        address ledger,
        uint64 dayIndex,
        uint64[48] memory importMWh,
        uint64[48] memory exportMWh
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                READINGS_TYPEHASH,
                dayIndex,
                keccak256(abi.encodePacked(importMWh)),
                keccak256(abi.encodePacked(exportMWh))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(chainId, ledger), structHash));
    }

    /// @notice Recover the signer of a 65-byte (r, s, v) signature.
    ///         Reverts on anything malformed rather than returning a garbage
    ///         address that a caller might compare against an unset meter.
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address signer) {
        if (signature.length != 65) revert MeterReadings_BadSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (uint256(s) > HALF_CURVE_ORDER) revert MeterReadings_BadSignature();
        if (v != 27 && v != 28) revert MeterReadings_BadSignature();

        signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert MeterReadings_BadSignature();
    }

    /// @notice A half-hour cannot both import and export.
    ///
    /// The meter is trusted, so this is a sanity check on the trusted party and
    /// on the relay rather than a defence against the agent. It is free, and it
    /// catches a reading vector that was scrambled on the way.
    ///
    /// @return ok         true when no half-hour has both.
    /// @return firstBad   index of the first offending half-hour when ok is false.
    function importAndExportAreExclusive(uint64[48] memory importMWh, uint64[48] memory exportMWh)
        internal
        pure
        returns (bool ok, uint256 firstBad)
    {
        for (uint256 i = 0; i < INTERVALS_PER_DAY; i++) {
            if (importMWh[i] != 0 && exportMWh[i] != 0) {
                return (false, i);
            }
        }
        return (true, 0);
    }
}
