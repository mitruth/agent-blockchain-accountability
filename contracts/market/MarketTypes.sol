// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Types of the P2P energy flexibility market, ported from Dan's BRIGHT
///         and DEDALUS projects (`GridOperableLibrary`). The market keeps its
///         own vocabulary -- bids and offers -- and the decoder translates it
///         for the enforcement layer, whose vocabulary is buy and sell.
///
/// Units, as in the rest of this repository (spec D6, D12): quantities in Wh,
/// prices in payment-token units per kWh, values rounded up.
library MarketTypes {
    enum Side {
        BID,
        OFFER
    }

    enum EnergyType {
        ELECTRICITY,
        HEAT
    }

    /// @notice One market session: a run of delivery slots and the time its
    ///         trading closes. A day-ahead session is 24 hourly slots closing
    ///         before the first; an intraday session might be 6.
    struct SessionConfig {
        EnergyType energyType;
        uint40 firstSlotStart;
        uint32 slotSeconds;
        uint16 slotCount;
        /// @dev No order can be placed, cancelled or modified from this time
        ///      on, and orders still unmatched expire.
        uint40 closesAt;
    }

    /// @notice One order of a batch, as the prosumer submits it.
    /// @param slot     Index of the delivery slot within the session.
    /// @param quantity Wh.
    /// @param price    Limit price per kWh.
    struct OrderRequest {
        uint16 slot;
        uint64 quantity;
        uint64 price;
    }

    enum OrderStatus {
        NONE,
        OPEN,
        CANCELLED,
        CLOSED
    }

    /// @notice An order as the session holds it.
    /// @param prosumer The prosumer contract that placed it.
    /// @param account  The prosumer contract's owner, where payment and energy
    ///                 tokens are held.
    /// @param tokenId  For an offer, the energy token minted for it; zero for a
    ///                 bid.
    /// @param matched  Quantity matched so far, by one or more trades.
    struct Order {
        bytes32 id;
        Side side;
        OrderStatus status;
        address prosumer;
        address account;
        uint16 slot;
        uint64 quantity;
        uint64 price;
        uint64 matched;
        uint256 tokenId;
    }

    /// @notice A trade as the matcher reports it. Everything else -- who the
    ///         buyer and seller are, which slot, which token -- is read from
    ///         the stored orders, never taken from the matcher.
    struct Trade {
        bytes32 bidId;
        bytes32 offerId;
        uint64 quantity;
        uint64 price;
    }

    /// @notice quantityWh at pricePerKWh, rounded up.
    function value(uint64 quantityWh, uint64 pricePerKWh) internal pure returns (uint256) {
        return (uint256(quantityWh) * pricePerKWh + 999) / 1000;
    }
}
