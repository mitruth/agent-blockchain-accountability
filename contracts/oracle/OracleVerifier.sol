// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {
    ReadingKind,
    BmsReading,
    PvForecast,
    TariffSchedule,
    MeterReading,
    Envelope,
    GridState,
    SignedReading
} from "./OracleTypes.sol";

/// @title OracleVerifier
/// @notice The signed readings the policies rely on (spec v0.1 5.4, v0.2
///         section 4): the battery's state from its BMS, the PV forecast, the
///         tariff, the meter, the DSO's operating envelope and the grid state.
///         The agent never supplies a reference value of its own; it can only
///         pass on what a registered device signed.
///
/// One deployment serves every account; all state is keyed by account. Each
/// account registers one signer per kind. For the BMS, PV forecast, tariff and
/// envelope it also sets the oldest a reading may be when it is accepted. Such
/// a reading is accepted when:
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
/// Meter readings follow per-slot rules instead (decision of 21 October 2026),
/// because a policy processes their history (S9) and a late reading must still
/// be able to arrive. One reading per slot, kept in a ring of METER_RING slots:
/// accepted in any order once the slot has ended; refused while the slot is
/// not over (future), once it has left the ring (stale), and when a different
/// reading for the same slot is already held (conflicting). The account
/// registers the meter's slot length with its signer, as a reading names only
/// its slot's start; slot starts are multiples of that length.
///
/// The grid state names no account: one operator declares it for every
/// account that registered that operator. It is kept per signer, newest first:
/// refused when issued in the future, already expired, older than the last
/// from that signer, or conflicting with it. Its freshness is its own
/// `validUntil`, so it takes no maximum age.
///
/// Signers are distinct trust anchors (spec v0.2, section 4), checked whenever
/// a signer or an agent key is registered:
///
///   - a METER or ENVELOPE signer is neither the BMS nor the PV signer, and
///     the other way round, whichever is registered first;
///   - no signer of any kind is a key the account declared as an agent key,
///     and no agent key is declared that is a registered signer.
///
/// Agent keys are declared by the owner (decision of 21 October 2026): the
/// agent acts through a Smart Session, which this contract cannot read, so
/// the check holds against the declaration, not against who actually holds
/// the session. Withdrawing a declaration applies at once.
///
/// Anyone may hand in a reading: authenticity comes from the signature, not
/// from the sender. The gate hands in what the agent attaches to an order;
/// relays and keepers post the rest. Every accepted reading is emitted in full.
///
/// Registering a signer is on the owner path: the account calls this contract
/// itself. The agent cannot, because the gate refuses this contract as a
/// target. A change of signer applies at once and drops the old device's
/// stored readings.
///
/// The domain binds the chain and this contract, so a reading signed for one
/// cannot be replayed onto another. Readings other than the grid state also
/// name their account.
contract OracleVerifier {
    /// @notice Longest forecast, tariff or envelope accepted: two days of
    ///         half-hour slots. Bounds what one post writes to storage.
    uint256 public constant MAX_FORECAST_SLOTS = 96;

    /// @notice Largest maximum age an account may set.
    uint32 public constant MAX_AGE_LIMIT = 7 days;

    /// @notice Meter readings kept per account, one per slot: at least S9's
    ///         grace plus a 96-slot horizon.
    uint256 public constant METER_RING = 128;

    /// @notice Longest meter slot an account may register.
    uint32 public constant MAX_METER_SLOT = 1 days;

    /// @notice Most agent keys one account may declare. Bounds the check.
    uint256 public constant MAX_AGENT_KEYS = 8;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant BMS_TYPEHASH =
        keccak256("BmsReading(address account,uint64 timestamp,uint64 socWh,uint64 dischargeOdometerWh)");
    bytes32 public constant PV_TYPEHASH = keccak256(
        "PvForecast(address account,uint64 issuedAt,uint64 firstSlotStart,uint32 slotSeconds,uint64[] pvWh)"
    );
    bytes32 public constant TARIFF_TYPEHASH = keccak256(
        "TariffSchedule(address account,uint64 issuedAt,uint64 firstSlotStart,uint32 slotSeconds,uint64[] retail,uint64[] feedIn)"
    );
    bytes32 public constant METER_TYPEHASH =
        keccak256("MeterReading(address account,uint64 slotStart,uint64 importWh,uint64 exportWh)");
    bytes32 public constant ENVELOPE_TYPEHASH = keccak256(
        "Envelope(address account,uint64 issuedAt,uint64 firstSlotStart,uint32 slotSeconds,uint64[] exportLimitWh,uint64[] importLimitWh)"
    );
    bytes32 public constant GRID_STATE_TYPEHASH = keccak256(
        "GridState(uint64 issuedAt,uint64 validUntil,uint8 level,uint8 direction,uint16 horizonSlots)"
    );
    bytes32 private constant NAME_HASH = keccak256("PolicyOracle");
    bytes32 private constant VERSION_HASH = keccak256("1");

    /// @dev secp256k1n / 2. A signature with s above it has a twin with the
    ///      same signer.
    uint256 private constant HALF_CURVE_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice A registered signer, and what was last accepted from it.
    /// @param lastTimestamp When the last accepted reading was measured or
    ///                      issued. Kept across a change of signer, so the
    ///                      account's clock only moves forward. Unused for the
    ///                      meter and the grid state.
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

    /// @notice A tariff (first = retail, second = feed-in) or an envelope
    ///         (first = export limit, second = import limit).
    struct StoredSchedule {
        uint64 issuedAt;
        uint64 firstSlotStart;
        uint32 slotSeconds;
        uint64[] first;
        uint64[] second;
    }

    struct StoredMeter {
        uint64 slotStart;
        uint64 importWh;
        uint64 exportWh;
        bytes32 digest;
    }

    struct StoredGridState {
        GridState state;
        bytes32 digest;
    }

    mapping(address account => mapping(ReadingKind => Device)) private _devices;
    mapping(address account => BmsReading) private _bms;
    mapping(address account => StoredForecast) private _pv;
    mapping(address account => StoredSchedule) private _tariff;
    mapping(address account => StoredSchedule) private _envelope;

    mapping(address account => uint32) private _meterSlotSeconds;
    /// @dev Bumped when the meter's signer or slot length changes, so the
    ///      ring of the old meter reads as empty.
    mapping(address account => uint64) private _meterGeneration;
    mapping(address account => mapping(uint64 generation => mapping(uint256 index => StoredMeter))) private _meters;

    mapping(address signer => StoredGridState) private _gridStates;

    mapping(address account => mapping(address key => bool)) public isAgentKey;
    mapping(address account => uint256) public agentKeyCount;

    event DeviceSet(address indexed account, ReadingKind indexed kind, address signer, uint32 maxAge);
    event MeterSet(address indexed account, address signer, uint32 slotSeconds);
    event AgentKeySet(address indexed account, address indexed key, bool declared);

    /// @notice A reading accepted, in full: `data` is what was signed. The
    ///         account is zero for a grid state, which names none.
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
    error Oracle_BadSchedule();
    error Oracle_UseSetMeter();
    error Oracle_BadMeterSlotLength(uint32 slotSeconds);
    error Oracle_BadMeterSlot(uint64 slotStart, uint32 slotSeconds);
    error Oracle_BadGridState();
    error Oracle_SignerNotDistinct(ReadingKind kind, ReadingKind other);
    error Oracle_SignerIsAgentKey(address signer);
    error Oracle_AgentKeyIsSigner(address key, ReadingKind kind);
    error Oracle_ZeroAgentKey();
    error Oracle_TooManyAgentKeys();

    // ------------------------------------------------------------------
    // Owner path
    // ------------------------------------------------------------------

    /// @notice Register the caller's signer for `kind`, and the oldest a
    ///         reading may be when it is accepted. A zero signer removes it.
    ///         The caller is the account. The meter is registered with
    ///         `setMeter`; the grid state takes no maximum age (0).
    function setDevice(ReadingKind kind, address signer, uint32 maxAge) external {
        if (kind == ReadingKind.METER) revert Oracle_UseSetMeter();
        if (kind == ReadingKind.GRID_STATE) {
            if (maxAge != 0) revert Oracle_BadMaxAge(maxAge);
        } else if (signer != address(0) && (maxAge == 0 || maxAge > MAX_AGE_LIMIT)) {
            revert Oracle_BadMaxAge(maxAge);
        }
        _requireDistinct(msg.sender, kind, signer);

        Device storage device = _devices[msg.sender][kind];
        if (device.signer != signer) {
            // What the old device said no longer counts. The new one may sign
            // for the last timestamp, but not before it.
            if (kind == ReadingKind.BMS) delete _bms[msg.sender];
            else if (kind == ReadingKind.PV_FORECAST) delete _pv[msg.sender];
            else if (kind == ReadingKind.TARIFF) delete _tariff[msg.sender];
            else if (kind == ReadingKind.ENVELOPE) delete _envelope[msg.sender];
            device.lastDigest = bytes32(0);
        }
        device.signer = signer;
        device.maxAge = signer == address(0) ? 0 : maxAge;
        emit DeviceSet(msg.sender, kind, signer, device.maxAge);
    }

    /// @notice Register the caller's meter: its signer and the length of the
    ///         slots it measures. A zero signer removes it. A change of either
    ///         drops the readings held.
    function setMeter(address signer, uint32 slotSeconds) external {
        if (signer != address(0) && (slotSeconds == 0 || slotSeconds > MAX_METER_SLOT)) {
            revert Oracle_BadMeterSlotLength(slotSeconds);
        }
        _requireDistinct(msg.sender, ReadingKind.METER, signer);

        Device storage device = _devices[msg.sender][ReadingKind.METER];
        uint32 length = signer == address(0) ? 0 : slotSeconds;
        if (device.signer != signer || _meterSlotSeconds[msg.sender] != length) _meterGeneration[msg.sender] += 1;
        device.signer = signer;
        _meterSlotSeconds[msg.sender] = length;
        emit MeterSet(msg.sender, signer, length);
    }

    /// @notice Declare, or withdraw, a key the caller's agent signs with. No
    ///         oracle signer may be a declared key.
    function setAgentKey(address key, bool declared) external {
        if (key == address(0)) revert Oracle_ZeroAgentKey();
        if (isAgentKey[msg.sender][key] == declared) return;
        if (declared) {
            if (agentKeyCount[msg.sender] >= MAX_AGENT_KEYS) revert Oracle_TooManyAgentKeys();
            for (uint8 k = 0; k <= uint8(type(ReadingKind).max); ++k) {
                if (_devices[msg.sender][ReadingKind(k)].signer == key) revert Oracle_AgentKeyIsSigner(key, ReadingKind(k));
            }
            agentKeyCount[msg.sender] += 1;
        } else {
            agentKeyCount[msg.sender] -= 1;
        }
        isAgentKey[msg.sender][key] = declared;
        emit AgentKeySet(msg.sender, key, declared);
    }

    // ------------------------------------------------------------------
    // Readings
    // ------------------------------------------------------------------

    /// @notice Verify a signed reading and, if it is new, store it. Reverts on
    ///         anything that fails a check.
    /// @return account The account the reading is for; zero for a grid state.
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
        } else if (reading.kind == ReadingKind.PV_FORECAST) {
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
        } else if (reading.kind == ReadingKind.TARIFF) {
            TariffSchedule memory t = abi.decode(reading.data, (TariffSchedule));
            account = t.account;
            _acceptSchedule(
                account,
                ReadingKind.TARIFF,
                _tariff[account],
                StoredSchedule(t.issuedAt, t.firstSlotStart, t.slotSeconds, t.retail, t.feedIn),
                _digest(tariffStructHash(t)),
                reading
            );
        } else if (reading.kind == ReadingKind.ENVELOPE) {
            Envelope memory e = abi.decode(reading.data, (Envelope));
            account = e.account;
            _acceptSchedule(
                account,
                ReadingKind.ENVELOPE,
                _envelope[account],
                StoredSchedule(e.issuedAt, e.firstSlotStart, e.slotSeconds, e.exportLimitWh, e.importLimitWh),
                _digest(envelopeStructHash(e)),
                reading
            );
        } else if (reading.kind == ReadingKind.METER) {
            account = _acceptMeter(reading);
        } else {
            _acceptGridState(reading);
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

    /// @notice The forecast for `count` consecutive slots of `slotSeconds`
    ///         from `firstSlotStart`, in one call. A slot the forecast cannot
    ///         serve -- not covered exactly, or the forecast stale -- reads
    ///         zero, the conservative value for a policy that credits PV.
    function pvSeries(address account, uint64 firstSlotStart, uint32 slotSeconds, uint256 count)
        external
        view
        returns (uint64[] memory pvWh)
    {
        pvWh = new uint64[](count);
        StoredForecast storage f = _pv[account];
        if (
            f.slotSeconds == 0 || f.slotSeconds != slotSeconds || firstSlotStart < f.firstSlotStart
                || (firstSlotStart - f.firstSlotStart) % slotSeconds != 0
                || !_isFresh(account, ReadingKind.PV_FORECAST, f.issuedAt)
        ) return pvWh;
        uint256 offset = (firstSlotStart - f.firstSlotStart) / slotSeconds;
        uint256 length = f.pvWh.length;
        for (uint256 i = 0; i < count && offset + i < length; ++i) {
            pvWh[i] = f.pvWh[offset + i];
        }
    }

    /// @notice The last PV forecast accepted for `account`, in full.
    function forecastOf(address account) external view returns (StoredForecast memory) {
        return _pv[account];
    }

    /// @notice The tariff for the slot starting at `slotStart`, and whether it
    ///         can be used: the schedule covers that slot exactly, and is
    ///         fresh. When it cannot, both prices read zero.
    function tariffAt(address account, uint64 slotStart)
        external
        view
        returns (uint64 retail, uint64 feedIn, bool usable)
    {
        return _scheduleAt(account, ReadingKind.TARIFF, _tariff[account], slotStart);
    }

    /// @notice The envelope's export and import limits for the slot starting
    ///         at `slotStart`, and whether they can be used, as for the tariff.
    function envelopeAt(address account, uint64 slotStart)
        external
        view
        returns (uint64 exportLimitWh, uint64 importLimitWh, bool usable)
    {
        return _scheduleAt(account, ReadingKind.ENVELOPE, _envelope[account], slotStart);
    }

    function tariffOf(address account) external view returns (StoredSchedule memory) {
        return _tariff[account];
    }

    function envelopeOf(address account) external view returns (StoredSchedule memory) {
        return _envelope[account];
    }

    /// @notice What the account's meter measured over the slot starting at
    ///         `slotStart`, if that reading is held.
    function meterAt(address account, uint64 slotStart)
        external
        view
        returns (uint64 importWh, uint64 exportWh, bool present)
    {
        uint32 length = _meterSlotSeconds[account];
        if (length == 0) return (0, 0, false);
        StoredMeter storage m = _meters[account][_meterGeneration[account]][(slotStart / length) % METER_RING];
        if (m.digest == bytes32(0) || m.slotStart != slotStart) return (0, 0, false);
        return (m.importWh, m.exportWh, true);
    }

    /// @notice The slot length the account registered for its meter; zero
    ///         when it has none.
    function meterSlotSecondsOf(address account) external view returns (uint32) {
        return _meterSlotSeconds[account];
    }

    /// @notice The latest grid state from the operator the account
    ///         registered, and whether it holds now: issued, and not past its
    ///         `validUntil`. With no operator registered, or none posted, it is
    ///         not fresh.
    function gridStateOf(address account) external view returns (GridState memory state, bool fresh) {
        address signer = _devices[account][ReadingKind.GRID_STATE].signer;
        if (signer == address(0)) return (state, false);
        state = _gridStates[signer].state;
        fresh = _gridStates[signer].digest != bytes32(0) && state.issuedAt <= block.timestamp
            && block.timestamp <= state.validUntil;
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

    function tariffStructHash(TariffSchedule memory t) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TARIFF_TYPEHASH,
                t.account,
                t.issuedAt,
                t.firstSlotStart,
                t.slotSeconds,
                keccak256(abi.encodePacked(t.retail)),
                keccak256(abi.encodePacked(t.feedIn))
            )
        );
    }

    function meterStructHash(MeterReading memory m) public pure returns (bytes32) {
        return keccak256(abi.encode(METER_TYPEHASH, m.account, m.slotStart, m.importWh, m.exportWh));
    }

    function envelopeStructHash(Envelope memory e) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ENVELOPE_TYPEHASH,
                e.account,
                e.issuedAt,
                e.firstSlotStart,
                e.slotSeconds,
                keccak256(abi.encodePacked(e.exportLimitWh)),
                keccak256(abi.encodePacked(e.importLimitWh))
            )
        );
    }

    /// @dev EIP-712 encodes an enum as its uint8.
    function gridStateStructHash(GridState memory g) public pure returns (bytes32) {
        return keccak256(
            abi.encode(GRID_STATE_TYPEHASH, g.issuedAt, g.validUntil, uint8(g.level), uint8(g.direction), g.horizonSlots)
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

    /// @dev A tariff or an envelope: two series of the same length, at most
    ///      MAX_FORECAST_SLOTS, under the shared checks.
    function _acceptSchedule(
        address account,
        ReadingKind kind,
        StoredSchedule storage stored,
        StoredSchedule memory s,
        bytes32 digest,
        SignedReading calldata reading
    ) private {
        if (
            s.slotSeconds == 0 || s.first.length == 0 || s.first.length > MAX_FORECAST_SLOTS
                || s.second.length != s.first.length
        ) revert Oracle_BadSchedule();
        if (!_admit(account, kind, s.issuedAt, digest, reading)) return;
        stored.issuedAt = s.issuedAt;
        stored.firstSlotStart = s.firstSlotStart;
        stored.slotSeconds = s.slotSeconds;
        stored.first = s.first;
        stored.second = s.second;
    }

    function _acceptMeter(SignedReading calldata reading) private returns (address account) {
        MeterReading memory m = abi.decode(reading.data, (MeterReading));
        account = m.account;
        Device storage device = _devices[account][ReadingKind.METER];
        if (device.signer == address(0)) revert Oracle_NoSigner(account, ReadingKind.METER);
        bytes32 digest = _digest(meterStructHash(m));
        address meter = _recover(digest, reading.signature);
        if (meter != device.signer) revert Oracle_WrongSigner(meter, device.signer);

        uint32 length = _meterSlotSeconds[account];
        if (m.slotStart % length != 0) revert Oracle_BadMeterSlot(m.slotStart, length);
        if (uint256(m.slotStart) + length > block.timestamp) revert Oracle_FromTheFuture(m.slotStart, block.timestamp);
        uint256 ringSeconds = METER_RING * length;
        if (block.timestamp - m.slotStart >= ringSeconds) {
            revert Oracle_Stale(m.slotStart, block.timestamp, uint32(ringSeconds));
        }

        StoredMeter storage held = _meters[account][_meterGeneration[account]][(m.slotStart / length) % METER_RING];
        if (held.digest != bytes32(0) && held.slotStart == m.slotStart) {
            if (held.digest != digest) revert Oracle_Conflicting(m.slotStart);
            return account;
        }
        held.slotStart = m.slotStart;
        held.importWh = m.importWh;
        held.exportWh = m.exportWh;
        held.digest = digest;
        emit ReadingAccepted(account, ReadingKind.METER, meter, digest, reading.data);
    }

    /// @dev Kept under whoever signed it: an account reads only the state of
    ///      the operator it registered, so a state from anyone else is inert.
    function _acceptGridState(SignedReading calldata reading) private {
        GridState memory g = abi.decode(reading.data, (GridState));
        if (g.validUntil < g.issuedAt) revert Oracle_BadGridState();
        bytes32 digest = _digest(gridStateStructHash(g));
        address signer = _recover(digest, reading.signature);

        if (g.issuedAt > block.timestamp) revert Oracle_FromTheFuture(g.issuedAt, block.timestamp);
        if (g.validUntil < block.timestamp) revert Oracle_Stale(g.issuedAt, block.timestamp, 0);
        StoredGridState storage held = _gridStates[signer];
        if (g.issuedAt < held.state.issuedAt) revert Oracle_Reordered(g.issuedAt, held.state.issuedAt);
        if (g.issuedAt == held.state.issuedAt && held.digest != bytes32(0)) {
            if (digest != held.digest) revert Oracle_Conflicting(g.issuedAt);
            return;
        }
        held.state = g;
        held.digest = digest;
        emit ReadingAccepted(address(0), ReadingKind.GRID_STATE, signer, digest, reading.data);
    }

    function _scheduleAt(address account, ReadingKind kind, StoredSchedule storage s, uint64 slotStart)
        private
        view
        returns (uint64, uint64, bool)
    {
        if (s.slotSeconds == 0 || slotStart < s.firstSlotStart) return (0, 0, false);
        uint256 offset = slotStart - s.firstSlotStart;
        if (offset % s.slotSeconds != 0) return (0, 0, false);
        uint256 index = offset / s.slotSeconds;
        if (index >= s.first.length || !_isFresh(account, kind, s.issuedAt)) return (0, 0, false);
        return (s.first[index], s.second[index], true);
    }

    /// @dev The trust anchors stay apart (spec v0.2, section 4). Removing a
    ///      signer (zero) is always allowed.
    function _requireDistinct(address account, ReadingKind kind, address signer) private view {
        if (signer == address(0)) return;
        if (isAgentKey[account][signer]) revert Oracle_SignerIsAgentKey(signer);

        ReadingKind a;
        ReadingKind b;
        if (kind == ReadingKind.METER || kind == ReadingKind.ENVELOPE) {
            (a, b) = (ReadingKind.BMS, ReadingKind.PV_FORECAST);
        } else if (kind == ReadingKind.BMS || kind == ReadingKind.PV_FORECAST) {
            (a, b) = (ReadingKind.METER, ReadingKind.ENVELOPE);
        } else {
            return;
        }
        if (_devices[account][a].signer == signer) revert Oracle_SignerNotDistinct(kind, a);
        if (_devices[account][b].signer == signer) revert Oracle_SignerNotDistinct(kind, b);
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
