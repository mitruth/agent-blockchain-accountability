// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {BmsReading} from "../oracle/OracleTypes.sol";
import {Order, OrderKind, CheckContext} from "../gate/GateTypes.sol";
import {PositionLedger} from "../gate/PositionLedger.sol";

/// @dev What a policy reads from the gate it serves: its position ledger.
interface IGateLedger {
    function ledger() external view returns (PositionLedger);
}

/// @title HorizonLib
/// @notice The horizon the physical policies look over (S3, S4): k slots from
///         the one holding the battery reading's timestamp. A slot before it
///         is in the past for the battery; a slot k or more after it is beyond
///         what the policy judges.
library HorizonLib {
    /// @param firstSlot   The slot holding the reading.
    /// @param firstStart  When it starts.
    /// @param slotSeconds The slot length, read from the market.
    /// @param socWh       The battery's energy in the reading.
    struct Horizon {
        uint32 firstSlot;
        uint64 firstStart;
        uint64 slotSeconds;
        uint64 socWh;
    }

    /// @notice Index of the first PLACE leg, or -1 when there is none.
    function firstPlacement(Order[] calldata legs) internal pure returns (int256) {
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind == OrderKind.PLACE) return int256(i);
        }
        return -1;
    }

    /// @notice The horizon of `reading`, found from `slot`, a slot of the
    ///         submission. The slot length is read from the market through the
    ///         decoder; slots are taken to be of equal length. Not ok when
    ///         `slot` starts before the reading's slot.
    function fromReading(CheckContext calldata ctx, uint32 slot, BmsReading memory reading)
        internal
        view
        returns (Horizon memory h, bool ok)
    {
        IOrderDecoder decoder = IOrderDecoder(ctx.decoder);
        uint64 start = decoder.slotStart(ctx.market, slot);
        uint64 next = decoder.slotStart(ctx.market, slot + 1);
        if (next <= start) return (h, false);
        h.slotSeconds = next - start;
        h.socWh = reading.socWh;

        uint256 back;
        if (reading.timestamp >= start) {
            if (reading.timestamp - start >= h.slotSeconds) return (h, false); // slot is in the past
        } else {
            back = (uint256(start - reading.timestamp) + h.slotSeconds - 1) / h.slotSeconds;
            if (back > slot) return (h, false);
        }
        h.firstSlot = uint32(slot - back);
        h.firstStart = uint64(start - back * h.slotSeconds);
        return (h, true);
    }

    function contains(Horizon memory h, uint16 k, uint32 slot) internal pure returns (bool) {
        return slot >= h.firstSlot && slot < uint256(h.firstSlot) + k;
    }
}
