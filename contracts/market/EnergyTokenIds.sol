// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MarketTypes} from "./MarketTypes.sol";

/// @title EnergyTokenIds
/// @notice Token ids of the energy tokens, after DEDALUS's
///         `ERC1155TokenIdMasks`.
///
///   bit 255        1: an energy token (id 0, all bits clear, is payment)
///   bits 95..254   the minter's address
///   bits 55..94    start time of the delivery slot, Unix seconds
///   bits 51..54    energy type
///   bits 0..50     a counter, unique per token contract
///
/// DEDALUS stored the hour of the day in five bits. Sessions here have any
/// number of slots of any length, so the slot's start time is stored instead.
library EnergyTokenIds {
    uint256 internal constant ENERGY_FLAG = 1 << 255;
    uint256 internal constant COUNTER_BITS = 51;

    error EnergyTokenIds_CounterExhausted();

    function encode(address minter, uint40 slotStart, MarketTypes.EnergyType energyType, uint256 counter)
        internal
        pure
        returns (uint256)
    {
        if (counter >= (1 << COUNTER_BITS)) revert EnergyTokenIds_CounterExhausted();
        return ENERGY_FLAG | (uint256(uint160(minter)) << 95) | (uint256(slotStart) << 55)
            | (uint256(uint8(energyType)) << 51) | counter;
    }

    function isEnergy(uint256 id) internal pure returns (bool) {
        return id & ENERGY_FLAG != 0;
    }

    function minter(uint256 id) internal pure returns (address) {
        return address(uint160(id >> 95));
    }

    function slotStart(uint256 id) internal pure returns (uint40) {
        return uint40(id >> 55);
    }

    function energyType(uint256 id) internal pure returns (MarketTypes.EnergyType) {
        return MarketTypes.EnergyType(uint8((id >> 51) & 0xF));
    }
}
