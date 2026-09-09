// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title SpendLedger
/// @notice Per-day signed spend records, held in a fixed-size ring covering the
///         most recent RETENTION_DAYS. Deployed once and never redeployed.
///
/// This contract outlives every validator module. A validator upgrade must not
/// reset or mint spend capacity, which is why the ledger stores raw per-day
/// records rather than a running window total: a module that changes windowDays
/// can only honour the carry-across-upgrades rule by recomputing from raw days,
/// and a stored rolling sum cannot be recomputed.
///
/// Storage is a one-year cache, not the archive. The complete and permanent
/// history is the DayRecorded event log, which is unbounded and is what a third
/// party reconstructs compliance from. Storage only has to hold enough for the
/// contract to enforce the rule on itself, and the rule never looks back
/// further than windowDays -- which PolicyConfig bounds at RETENTION_DAYS.
///
/// The ring is keyed by `dayIndex % RETENTION_DAYS`, so the footprint is fixed
/// forever rather than growing by a slot every day. A slot whose stored
/// dayIndex is not the day being asked about is a wrapped leftover from a
/// previous year and reads as absent.
///
/// Write authorisation is an explicit owner-controlled allowlist. It is
/// deliberately NOT derived from module install status on the account: if it
/// were, permission to install a module would silently become permission to
/// write the ledger, and the upgrade path would become the attack path.
contract SpendLedger {
    /// @notice Days of history held in storage. Must equal
    ///         PolicyConfig.MAX_WINDOW_DAYS; a test asserts the two agree.
    ///         If windowDays could exceed this, a window would reach past the
    ///         wrap and silently sum year-old records as current ones.
    uint64 public constant RETENTION_DAYS = 365;

    /// @notice One calendar day of agent activity, UTC.
    ///
    /// netSpend is signed. A day where export revenue exceeds import cost is a
    /// real negative and reduces the rolling window sum. Clamping it to zero
    /// biases the sum upward, so the cap would bind earlier than it should --
    /// an error in the direction that flatters the mechanism.
    ///
    /// Field order is chosen for packing, not for presentation: dayIndex,
    /// paused and recorded share one slot, so a record costs 3 slots rather
    /// than the 4 the spec's declaration order would have cost.
    ///
    /// `dayIndex` is not redundant with the ring position. It is what
    /// distinguishes a live slot from a wrapped leftover, and `recorded`
    /// distinguishes a genuine record for day 0 from an untouched slot.
    struct DayRecord {
        uint64 dayIndex; // days since Unix epoch, UTC
        bool paused; // true = zero-spend day imposed by pause
        bool recorded; // false = this slot was never written
        uint256 policyVersion; // version checked against
        int256 netSpend; // minor units; positive = net import cost, negative = net export credit
    }

    address public immutable owner;

    /// @notice Addresses permitted to write records. Owner-controlled, and the
    ///         only source of write authority.
    mapping(address => bool) public isWriter;

    /// @dev Ring of the most recent RETENTION_DAYS. Index is dayIndex % RETENTION_DAYS.
    DayRecord[RETENTION_DAYS] private _ring;

    /// @notice Highest day index written so far. Records are non-decreasing in
    ///         day index; a writer may top up the current day but never reach
    ///         back past it.
    uint64 public lastRecordedDay;

    /// @notice First day ever written. May no longer be held in storage once
    ///         more than RETENTION_DAYS have passed -- see oldestRetainedDay.
    uint64 public firstRecordedDay;
    bool private _hasAnyRecord;

    event WriterSet(address indexed writer, bool allowed, address indexed setBy);

    /// @notice Emitted on every submission, including top-ups of a day already
    ///         recorded. Carries the full resulting record so the whole ledger
    ///         is reconstructible from logs alone -- the event log, unlike
    ///         storage, is never evicted.
    event DayRecorded(
        uint64 indexed dayIndex,
        int256 netSpendDelta,
        int256 netSpendTotal,
        uint256 policyVersion,
        bool paused,
        address indexed writer
    );

    /// @notice Emitted when a write evicts a still-live record from the ring.
    ///         The evicted day survives in the log; only its storage slot is gone.
    event DayEvicted(uint64 indexed evictedDay, uint64 indexed byDay);

    error SpendLedger_OnlyOwner();
    error SpendLedger_NotAWriter();
    error SpendLedger_DayWentBackward();
    error SpendLedger_RangeEmpty();
    error SpendLedger_RangeTooWide();

    modifier onlyOwner() {
        if (msg.sender != owner) revert SpendLedger_OnlyOwner();
        _;
    }

    modifier onlyWriter() {
        if (!isWriter[msg.sender]) revert SpendLedger_NotAWriter();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ------------------------------------------------------------------
    // Owner: the allowlist
    // ------------------------------------------------------------------

    function setWriter(address writer, bool allowed) external onlyOwner {
        isWriter[writer] = allowed;
        emit WriterSet(writer, allowed, msg.sender);
    }

    // ------------------------------------------------------------------
    // Writers: records
    // ------------------------------------------------------------------

    /// @notice Record a day, or add to a day already recorded.
    ///
    /// Same-day resubmission accumulates. That is the behaviour of the audited
    /// implementation and it is preserved deliberately: several settlements may
    /// land on one calendar day and each must count.
    ///
    /// A paused day is a zero-spend day, not a missing day. It is written like
    /// any other record so the window still advances across it.
    ///
    /// A day that was never submitted is left absent rather than written as an
    /// explicit zero. It already contributes zero to every window sum, so a
    /// fabricated zero would change no arithmetic while asserting that the
    /// agent reported a day on which it reported nothing. The gap is evidence.
    function recordDay(
        uint64 dayIndex,
        int256 netSpend,
        uint256 policyVersion,
        bool paused
    ) external onlyWriter {
        if (_hasAnyRecord && dayIndex < lastRecordedDay) revert SpendLedger_DayWentBackward();

        DayRecord storage slot = _ring[dayIndex % RETENTION_DAYS];
        bool sameDay = slot.recorded && slot.dayIndex == dayIndex;
        int256 total;

        if (sameDay) {
            // Checked arithmetic: an overflowing top-up reverts, never wraps.
            total = slot.netSpend + netSpend;
            slot.netSpend = total;
            slot.policyVersion = policyVersion;
            slot.paused = paused;
        } else {
            if (slot.recorded) {
                emit DayEvicted(slot.dayIndex, dayIndex);
            }
            total = netSpend;
            slot.dayIndex = dayIndex;
            slot.paused = paused;
            slot.recorded = true;
            slot.policyVersion = policyVersion;
            slot.netSpend = netSpend;

            if (!_hasAnyRecord) {
                _hasAnyRecord = true;
                firstRecordedDay = dayIndex;
            }
        }

        if (dayIndex > lastRecordedDay) {
            lastRecordedDay = dayIndex;
        }

        emit DayRecorded(dayIndex, netSpend, total, policyVersion, paused, msg.sender);
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    function hasAnyRecord() external view returns (bool) {
        return _hasAnyRecord;
    }

    /// @notice Oldest day still held in storage. Days before this are readable
    ///         only from the event log.
    function oldestRetainedDay() public view returns (uint64) {
        if (!_hasAnyRecord) return 0;
        if (lastRecordedDay + 1 < RETENTION_DAYS) return firstRecordedDay;
        uint64 floorDay = lastRecordedDay + 1 - RETENTION_DAYS;
        return floorDay > firstRecordedDay ? floorDay : firstRecordedDay;
    }

    /// @notice True when `dayIndex` is recent enough that storage could still
    ///         hold it. Independent of whether anything was recorded that day.
    function isWithinRetention(uint64 dayIndex) public view returns (bool) {
        if (!_hasAnyRecord) return true;
        if (dayIndex > lastRecordedDay) return true;
        return lastRecordedDay - dayIndex < RETENTION_DAYS;
    }

    /// @notice Whether a live record for this day is held in storage. Returns
    ///         false for a day evicted by the ring, which is not the same as
    ///         the day never having been recorded -- consult the event log to
    ///         tell those apart.
    function isRecorded(uint64 dayIndex) public view returns (bool) {
        DayRecord storage slot = _ring[dayIndex % RETENTION_DAYS];
        return slot.recorded && slot.dayIndex == dayIndex;
    }

    function recordOf(uint64 dayIndex) external view returns (DayRecord memory) {
        DayRecord storage slot = _ring[dayIndex % RETENTION_DAYS];
        if (!slot.recorded || slot.dayIndex != dayIndex) {
            return DayRecord({
                dayIndex: dayIndex,
                paused: false,
                recorded: false,
                policyVersion: 0,
                netSpend: 0
            });
        }
        return slot;
    }

    /// @notice Net spend on a day. An unrecorded day reads as zero, which is
    ///         also what a genuinely idle day records. Callers that must tell
    ///         the two apart read isRecorded.
    ///
    /// A day evicted by the ring also reads as zero. That is why PolicyConfig
    /// bounds windowDays at RETENTION_DAYS: a window that reached past the wrap
    /// would read evicted days as zero and understate the sum.
    function netSpendOf(uint64 dayIndex) external view returns (int256) {
        DayRecord storage slot = _ring[dayIndex % RETENTION_DAYS];
        if (!slot.recorded || slot.dayIndex != dayIndex) return 0;
        return slot.netSpend;
    }

    /// @notice Records over an inclusive day range, for off-chain replay.
    ///         Bounded by an explicit caller-supplied range; nothing here
    ///         iterates a list any participant can grow. Days outside
    ///         retention come back with recorded = false.
    function recordRange(uint64 fromDay, uint64 toDay)
        external
        view
        returns (DayRecord[] memory out)
    {
        if (toDay < fromDay) revert SpendLedger_RangeEmpty();
        uint256 length = uint256(toDay - fromDay) + 1;
        if (length > RETENTION_DAYS) revert SpendLedger_RangeTooWide();

        out = new DayRecord[](length);
        for (uint256 i = 0; i < length; i++) {
            uint64 day = fromDay + uint64(i);
            DayRecord storage slot = _ring[day % RETENTION_DAYS];
            if (slot.recorded && slot.dayIndex == day) {
                out[i] = slot;
            } else {
                out[i] = DayRecord({
                    dayIndex: day,
                    paused: false,
                    recorded: false,
                    policyVersion: 0,
                    netSpend: 0
                });
            }
        }
    }
}
