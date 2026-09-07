// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title SpendLedger
/// @notice Per-day signed spend records. Deployed once and never redeployed.
///
/// This contract outlives every validator module. A validator upgrade must not
/// reset or mint spend capacity, which is why the ledger stores raw per-day
/// records rather than a running window total: a module that changes windowDays
/// can only honour the carry-across-upgrades rule by recomputing from raw days,
/// and a stored rolling sum cannot be recomputed.
///
/// Because it is never redeployed, DayRecord is a permanent schema.
///
/// Write authorisation is an explicit owner-controlled allowlist. It is
/// deliberately NOT derived from module install status on the account: if it
/// were, permission to install a module would silently become permission to
/// write the ledger, and the upgrade path would become the attack path.
contract SpendLedger {
    /// @notice One calendar day of agent activity, UTC.
    ///
    /// netSpend is signed. A day where export revenue exceeds import cost is a
    /// real negative and reduces the rolling window sum. Clamping it to zero
    /// biases the sum upward, so the cap would bind earlier than it should --
    /// an error in the direction that flatters the mechanism.
    struct DayRecord {
        uint64 dayIndex; // days since Unix epoch, UTC
        int256 netSpend; // minor units; positive = net import cost, negative = net export credit
        uint256 policyVersion; // version checked against
        bool paused; // true = zero-spend day imposed by pause
    }

    address public immutable owner;

    /// @notice Addresses permitted to write records. Owner-controlled, and the
    ///         only source of write authority.
    mapping(address => bool) public isWriter;

    mapping(uint64 => DayRecord) private _records;
    mapping(uint64 => bool) public isRecorded;

    /// @notice Highest day index written so far. Records are non-decreasing in
    ///         day index; a writer may top up the current day but never reach
    ///         back past it.
    uint64 public lastRecordedDay;
    uint64 public firstRecordedDay;
    bool private _hasAnyRecord;

    event WriterSet(address indexed writer, bool allowed, address indexed setBy);

    /// @notice Emitted on every submission, including top-ups of a day already
    ///         recorded. Carries the full resulting record so the whole ledger
    ///         is reconstructible from logs alone.
    event DayRecorded(
        uint64 indexed dayIndex,
        int256 netSpendDelta,
        int256 netSpendTotal,
        uint256 policyVersion,
        bool paused,
        address indexed writer
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "SpendLedger: only owner");
        _;
    }

    modifier onlyWriter() {
        require(isWriter[msg.sender], "SpendLedger: not an allowlisted writer");
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
    function recordDay(
        uint64 dayIndex,
        int256 netSpend,
        uint256 policyVersion,
        bool paused
    ) external onlyWriter {
        require(
            !_hasAnyRecord || dayIndex >= lastRecordedDay,
            "SpendLedger: day index went backward"
        );

        DayRecord storage record = _records[dayIndex];
        int256 total;

        if (isRecorded[dayIndex]) {
            // Checked arithmetic: an overflowing top-up reverts, never wraps.
            total = record.netSpend + netSpend;
            record.netSpend = total;
            record.policyVersion = policyVersion;
            record.paused = paused;
        } else {
            total = netSpend;
            _records[dayIndex] = DayRecord({
                dayIndex: dayIndex,
                netSpend: netSpend,
                policyVersion: policyVersion,
                paused: paused
            });
            isRecorded[dayIndex] = true;

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

    function recordOf(uint64 dayIndex) external view returns (DayRecord memory) {
        return _records[dayIndex];
    }

    /// @notice Net spend on a day. An unrecorded day reads as zero, which is
    ///         also what a genuinely idle day records. Callers that must tell
    ///         the two apart read isRecorded.
    function netSpendOf(uint64 dayIndex) external view returns (int256) {
        return _records[dayIndex].netSpend;
    }

    /// @notice Records over an inclusive day range, for off-chain replay.
    ///         Bounded by an explicit caller-supplied range; nothing here
    ///         iterates a list any participant can grow.
    function recordRange(uint64 fromDay, uint64 toDay)
        external
        view
        returns (DayRecord[] memory out)
    {
        require(toDay >= fromDay, "SpendLedger: empty range");
        uint256 length = uint256(toDay - fromDay) + 1;
        require(length <= 1024, "SpendLedger: range too wide");

        out = new DayRecord[](length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = _records[fromDay + uint64(i)];
        }
    }
}
