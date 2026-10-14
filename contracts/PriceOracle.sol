// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title PriceOracle
/// @notice Publishes electricity prices for one UTC day of 48 half-hours.
///
/// Prices are one of the two inputs daily spend is computed from; the other is
/// the meter's readings. Neither comes from the agent. Before this contract the
/// agent reported its own daily spend, so the cap bounded a number the agent
/// chose (F8, docs/earlier-design/design-decisions.md D7.1).
///
/// The publisher is its own key. It is not the owner, the agent or the
/// guardian. In this project it is simulated by a script that publishes the
/// CAISO TH_NP15 real-time price series from the dataset; the interface is kept
/// narrow so a real feed can take its place (D7.2).
///
/// Storage holds a hash commitment per day, not the prices. The prices are
/// emitted in full, and whoever settles a day passes them back in to be checked
/// against the commitment. One slot a day instead of twenty-four, and the event
/// log is already the archive (D3.7).
///
/// A published day is final. There is no amendment path: a price that could be
/// changed after a day was settled would let history be rewritten.
contract PriceOracle {
    uint256 public constant INTERVALS_PER_DAY = 48;

    /// @notice Price unit: 1e-8 USD per kWh. The dataset's prices carry eight
    ///         decimal places, so this represents them exactly (D7.10).
    int256 public constant PRICE_SCALE = 1e8;

    /// @notice Operates the oracle: chooses the publisher. Deliberately named
    ///         admin, not owner -- in a real deployment this is the feed
    ///         operator, not the household.
    address public immutable admin;

    address public publisher;

    /// @notice keccak256 of the day's prices; zero until published.
    mapping(uint64 => bytes32) public commitmentOf;

    event PublisherUpdated(address indexed previousPublisher, address indexed newPublisher);

    /// @notice The full price vectors, so the chain carries the data and not
    ///         only its hash.
    event PricesPublished(
        uint64 indexed dayIndex,
        bytes32 commitment,
        int64[48] importPrices,
        int64[48] exportPrices,
        address indexed publisher
    );

    error PriceOracle_OnlyAdmin();
    error PriceOracle_OnlyPublisher();
    error PriceOracle_AlreadyPublished(uint64 dayIndex);

    constructor(address publisher_) {
        admin = msg.sender;
        publisher = publisher_;
        emit PublisherUpdated(address(0), publisher_);
    }

    function setPublisher(address newPublisher) external {
        if (msg.sender != admin) revert PriceOracle_OnlyAdmin();
        emit PublisherUpdated(publisher, newPublisher);
        publisher = newPublisher;
    }

    /// @notice Publish one UTC day of prices, in 1e-8 USD/kWh, one entry per
    ///         half-hour starting at 00:00 UTC.
    ///
    /// Prices are signed: real-time prices can go negative, and the contract
    /// must not assume they will not.
    ///
    /// Export prices are published, not derived here. An export-price rule held
    /// in contract configuration would be a spend-lowering knob outside the cap
    /// semantics; export tariffs are the utility's to set (D7.2).
    function publishDay(
        uint64 dayIndex,
        int64[48] calldata importPrices,
        int64[48] calldata exportPrices
    ) external {
        if (msg.sender != publisher) revert PriceOracle_OnlyPublisher();
        if (commitmentOf[dayIndex] != bytes32(0)) revert PriceOracle_AlreadyPublished(dayIndex);

        bytes32 commitment = pricesCommitment(dayIndex, importPrices, exportPrices);
        commitmentOf[dayIndex] = commitment;

        emit PricesPublished(dayIndex, commitment, importPrices, exportPrices, msg.sender);
    }

    /// @notice The commitment for a set of prices. Binds the day, so a valid
    ///         price vector for one day cannot be presented for another.
    function pricesCommitment(
        uint64 dayIndex,
        int64[48] calldata importPrices,
        int64[48] calldata exportPrices
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(dayIndex, importPrices, exportPrices));
    }

    function isPublished(uint64 dayIndex) external view returns (bool) {
        return commitmentOf[dayIndex] != bytes32(0);
    }

    /// @notice True only if these are exactly the prices published for this day.
    function verifyPrices(
        uint64 dayIndex,
        int64[48] calldata importPrices,
        int64[48] calldata exportPrices
    ) external view returns (bool) {
        bytes32 stored = commitmentOf[dayIndex];
        return stored != bytes32(0) && stored == pricesCommitment(dayIndex, importPrices, exportPrices);
    }
}
