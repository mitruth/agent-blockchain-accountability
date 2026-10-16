// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ReadingKind, BmsReading, PvForecast, SignedReading} from "./OracleTypes.sol";

/// @title OracleVerifier
/// @notice The signed readings the physical policies rely on: the battery's
///         state from its BMS, and the PV forecast (spec 5.4). The agent never
///         supplies a reference value of its own; it can only pass on what a
///         registered device signed.
///
/// One deployment serves every account; all state is keyed by account. Each
/// account registers one signer per kind, with the oldest a reading may be when
/// it is accepted. A reading is accepted when:
///
///   - its EIP-712 signature recovers to the signer the account registered for
///     that kind (low-s only, so one reading has one valid signature);
///   - it is not dated in the future, and not older than the account's maximum
///     age: a stale reading is refused;
///   - it is not older than the last reading accepted from that device: a
///     reordered reading is refused, so the agent cannot pick a favourable old
///     one. The same timestamp is accepted again only for the very same
///     reading, so one signer cannot be made to choose between two;
///   - for the BMS, its discharge odometer has not gone down.
///
/// Anyone may hand in a reading: authenticity comes from the signature, not
/// from the sender. The gate hands in what the agent attaches to an order, a
/// relay posts the PV forecast. Every accepted reading is emitted in full.
///
/// Registering a signer is on the owner path: the account calls this contract
/// itself. The agent cannot, because the gate refuses this contract as a
/// target. A change of signer applies at once and drops the old device's
/// stored reading.
///
/// The domain binds the chain and this contract, so a reading signed for one
/// cannot be replayed onto another. Readings also name their account.
contract OracleVerifier {
    /// @notice Longest forecast accepted: two days of half-hour slots. Bounds
    ///         what one post writes to storage.
    uint256 public constant MAX_FORECAST_SLOTS = 96;

    /// @notice Largest maximum age an account may set.
    uint32 public constant MAX_AGE_LIMIT = 7 days;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant BMS_TYPEHASH =
        keccak256("BmsReading(address account,uint64 timestamp,uint64 socWh,uint64 dischargeOdometerWh)");
    bytes32 public constant PV_TYPEHASH = keccak256(
        "PvForecast(address account,uint64 issuedAt,uint64 firstSlotStart,uint32 slotSeconds,uint64[] pvWh)"
    );
    bytes32 private constant NAME_HASH = keccak256("PolicyOracle");
    bytes32 private constant VERSION_HASH = keccak256("1");

    /// @dev secp256k1n / 2. A signature with s above it has a twin with the
    ///      same signer.
    uint256 private constant HALF_CURVE_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice A registered signer, and what was last accepted from it.
    /// @param lastTimestamp When the last accepted reading was measured or
    ///                      issued. Kept across a change of signer, so the
    ///                      account's clock only moves forward.
    /// @param lastDigest    That reading's EIP-712 digest.
    struct Device {
        address signer;
        uint32 maxAge;
        uint64 lastTimestamp;
        bytes32 lastDigest;
    }

    struct StoredForecast {
        uint64 issuedAt;
        uint64 firstSlotStart;
        uint32 slotSeconds;
        uint64[] pvWh;
    }

    mapping(address account => mapping(ReadingKind => Device)) private _devices;
    mapping(address account => BmsReading) private _bms;
    mapping(address account => StoredForecast) private _pv;

    event DeviceSet(address indexed account, ReadingKind indexed kind, address signer, uint32 maxAge);

    /// @notice A reading accepted, in full: `data` is what was signed.
    event ReadingAccepted(
        address indexed account, ReadingKind indexed kind, address indexed signer, bytes32 digest, bytes data
    );

    error Oracle_BadMaxAge(uint32 maxAge);
    error Oracle_NoSigner(address account, ReadingKind kind);
    error Oracle_BadSignature();
    error Oracle_WrongSigner(address recovered, address registered);
    error Oracle_FromTheFuture(uint64 timestamp, uint256 now_);
    error Oracle_Stale(uint64 timestamp, uint256 now_, uint32 maxAge);
    error Oracle_Reordered(uint64 timestamp, uint64 lastTimestamp);
    error Oracle_Conflicting(uint64 timestamp);
    error Oracle_OdometerWentDown(uint64 odometerWh, uint64 lastOdometerWh);
    error Oracle_BadForecast();

    // ------------------------------------------------------------------
    // Owner path
    // ------------------------------------------------------------------

    /// @notice Register the caller's signer for `kind`, and the oldest a
    ///         reading may be when it is accepted. A zero signer removes it.
    ///         The caller is the account.
    function setDevice(ReadingKind kind, address signer, uint32 maxAge) external {
        if (signer != address(0) && (maxAge == 0 || maxAge > MAX_AGE_LIMIT)) revert Oracle_BadMaxAge(maxAge);
        Device storage device = _devices[msg.sender][kind];
        if (device.signer != signer) {
            // What the old device said no longer counts. The new one may sign
            // for the last timestamp, but not before it.
            if (kind == ReadingKind.BMS) delete _bms[msg.sender];
            else delete _pv[msg.sender];
            device.lastDigest = bytes32(0);
        }
        device.signer = signer;
        device.maxAge = signer == address(0) ? 0 : maxAge;
        emit DeviceSet(msg.sender, kind, signer, device.maxAge);
    }

    // ------------------------------------------------------------------
    // Readings
    // ------------------------------------------------------------------

    /// @notice Verify a signed reading and, if it is new, store it. Reverts on
    ///         anything that fails a check.
    /// @return account The account the reading is for.
    function accept(SignedReading calldata reading) external returns (address account) {
        if (reading.kind == ReadingKind.BMS) {
            BmsReading memory r = abi.decode(reading.data, (BmsReading));
            account = r.account;
            bytes32 digest = _digest(bmsStructHash(r));
            if (!_admit(account, ReadingKind.BMS, r.timestamp, digest, reading)) return account;
            BmsReading storage last = _bms[account];
            if (last.timestamp != 0 && r.dischargeOdometerWh < last.dischargeOdometerWh) {
                revert Oracle_OdometerWentDown(r.dischargeOdometerWh, last.dischargeOdometerWh);
            }
            _bms[account] = r;
        } else {
            PvForecast memory f = abi.decode(reading.data, (PvForecast));
            if (f.slotSeconds == 0 || f.pvWh.length == 0 || f.pvWh.length > MAX_FORECAST_SLOTS) {
                revert Oracle_BadForecast();
            }
            account = f.account;
            bytes32 digest = _digest(pvStructHash(f));
            if (!_admit(account, ReadingKind.PV_FORECAST, f.issuedAt, digest, reading)) return account;
            StoredForecast storage stored = _pv[account];
            stored.issuedAt = f.issuedAt;
            stored.firstSlotStart = f.firstSlotStart;
            stored.slotSeconds = f.slotSeconds;
            stored.pvWh = f.pvWh;
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function deviceOf(address account, ReadingKind kind) external view returns (Device memory) {
        return _devices[account][kind];
    }

    /// @notice The last BMS reading accepted for `account`, and whether it is
    ///         still fresh: its signer still registered and its age within the
    ///         account's maximum.
    function bmsOf(address account) external view returns (BmsReading memory reading, bool fresh) {
        reading = _bms[account];
        fresh = reading.timestamp != 0 && _isFresh(account, ReadingKind.BMS, reading.timestamp);
    }

    /// @notice The PV forecast for the slot starting at `slotStart`, and
    ///         whether it can be used: the forecast covers that slot exactly,
    ///         and is fresh. When it cannot, `pvWh` is zero.
    function pvAt(address account, uint64 slotStart) external view returns (uint64 pvWh, bool usable) {
        StoredForecast storage f = _pv[account];
        if (f.slotSeconds == 0 || slotStart < f.firstSlotStart) return (0, false);
        uint256 offset = slotStart - f.firstSlotStart;
        if (offset % f.slotSeconds != 0) return (0, false);
        uint256 index = offset / f.slotSeconds;
        if (index >= f.pvWh.length || !_isFresh(account, ReadingKind.PV_FORECAST, f.issuedAt)) return (0, false);
        return (f.pvWh[index], true);
    }

    /// @notice The last PV forecast accepted for `account`, in full.
    function forecastOf(address account) external view returns (StoredForecast memory) {
        return _pv[account];
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function bmsStructHash(BmsReading memory r) public pure returns (bytes32) {
        return keccak256(abi.encode(BMS_TYPEHASH, r.account, r.timestamp, r.socWh, r.dischargeOdometerWh));
    }

    /// @dev EIP-712 encodes an array as the keccak of its elements, each padded
    ///      to 32 bytes, which is what encodePacked does with array elements.
    function pvStructHash(PvForecast memory f) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PV_TYPEHASH, f.account, f.issuedAt, f.firstSlotStart, f.slotSeconds, keccak256(abi.encodePacked(f.pvWh))
            )
        );
    }

    /// @notice The digest a signer signs for a struct hash.
    function digestOf(bytes32 structHash) external view returns (bytes32) {
        return _digest(structHash);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev The checks every kind shares. Returns false for the reading
    ///      accepted last, handed in again: nothing to store, nothing to emit.
    function _admit(address account, ReadingKind kind, uint64 timestamp, bytes32 digest, SignedReading calldata reading)
        private
        returns (bool isNew)
    {
        Device storage device = _devices[account][kind];
        if (device.signer == address(0)) revert Oracle_NoSigner(account, kind);
        address recovered = _recover(digest, reading.signature);
        if (recovered != device.signer) revert Oracle_WrongSigner(recovered, device.signer);

        if (timestamp > block.timestamp) revert Oracle_FromTheFuture(timestamp, block.timestamp);
        if (block.timestamp - timestamp > device.maxAge) revert Oracle_Stale(timestamp, block.timestamp, device.maxAge);
        if (timestamp < device.lastTimestamp) revert Oracle_Reordered(timestamp, device.lastTimestamp);
        if (timestamp == device.lastTimestamp && device.lastDigest != bytes32(0)) {
            if (digest != device.lastDigest) revert Oracle_Conflicting(timestamp);
            return false;
        }

        device.lastTimestamp = timestamp;
        device.lastDigest = digest;
        emit ReadingAccepted(account, kind, recovered, digest, reading.data);
        return true;
    }

    function _isFresh(address account, ReadingKind kind, uint64 timestamp) private view returns (bool) {
        Device storage device = _devices[account][kind];
        return device.signer != address(0) && timestamp <= block.timestamp
            && block.timestamp - timestamp <= device.maxAge;
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @dev Reverts on anything malformed rather than return an address that
    ///      might be compared against an unset signer.
    function _recover(bytes32 hash, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) revert Oracle_BadSignature();
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (uint256(s) > HALF_CURVE_ORDER || (v != 27 && v != 28)) revert Oracle_BadSignature();
        signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert Oracle_BadSignature();
    }
}
