// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice What the oracles sign (docs/spec/policy-spec-v0.1.md, section 5.4).
///         Every quantity is an integer: Wh and seconds.

/// @notice Who signed: the house's battery management system, or the PV
///         forecast provider. The tariff feed of spec 5.4 is not built (log 5.1).
enum ReadingKind {
    BMS,
    PV_FORECAST
}

/// @notice The battery as its BMS measured it. Signed by the BMS key the
///         account registered; delivered with the agent's order.
/// @param account             The house the battery belongs to.
/// @param timestamp           When it was measured: the start of a slot.
/// @param socWh               Energy stored, in Wh.
/// @param dischargeOdometerWh All the energy the battery has ever discharged,
///                            in Wh. Never decreases.
struct BmsReading {
    address account;
    uint64 timestamp;
    uint64 socWh;
    uint64 dischargeOdometerWh;
}

/// @notice PV energy expected per slot, from `firstSlotStart` on. Signed by the
///         forecast provider the account registered; posted by a relay.
/// @param issuedAt       When the provider issued it.
/// @param firstSlotStart Start of the slot `pvWh[0]` is for.
/// @param slotSeconds    Length of every slot.
/// @param pvWh           Expected PV energy per slot, in Wh.
struct PvForecast {
    address account;
    uint64 issuedAt;
    uint64 firstSlotStart;
    uint32 slotSeconds;
    uint64[] pvWh;
}

/// @notice A reading as it travels: `data` is `abi.encode` of a `BmsReading`
///         or a `PvForecast`, by `kind`, and `signature` the signer's 65-byte
///         EIP-712 signature over it.
struct SignedReading {
    ReadingKind kind;
    bytes data;
    bytes signature;
}
