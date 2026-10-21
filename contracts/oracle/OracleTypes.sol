// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice What the oracles sign (docs/spec/policy-spec-v0.1.md, section 5.4,
///         and policy-spec-v0.2-gap-policies.md, section 4). Every quantity
///         is an integer: Wh, seconds, and prices in settlement-token units
///         per kWh, the scale of an order's price.

/// @notice Who signed:
///
///   BMS          the house's battery management system
///   PV_FORECAST  the PV forecast provider
///   TARIFF       the retailer or aggregator: retail and feed-in tariff
///   METER        the DSO's smart meter: energy imported and exported
///   ENVELOPE     the DSO: export and import limits per slot
///   GRID_STATE   the system or microgrid operator: the grid's stress level
enum ReadingKind {
    BMS,
    PV_FORECAST,
    TARIFF,
    METER,
    ENVELOPE,
    GRID_STATE
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

/// @notice The account's tariff per slot, from `firstSlotStart` on: what grid
///         import costs (retail) and what grid export earns (feed-in). Signed
///         by the retailer or aggregator; posted by a relay.
/// @param retail Price per kWh of import, per slot.
/// @param feedIn Price per kWh of export, per slot. Same length as `retail`.
struct TariffSchedule {
    address account;
    uint64 issuedAt;
    uint64 firstSlotStart;
    uint32 slotSeconds;
    uint64[] retail;
    uint64[] feedIn;
}

/// @notice What the account's meter measured over one slot. Signed by the
///         DSO's smart-meter key; posted by a keeper, never by the agent.
/// @param slotStart Start of the slot measured. The slot length is the one
///                  the account registered for its meter.
struct MeterReading {
    address account;
    uint64 slotStart;
    uint64 importWh;
    uint64 exportWh;
}

/// @notice The DSO's operating envelope for the account's connection, per
///         slot, from `firstSlotStart` on. Signed by the DSO; posted by a
///         relay.
/// @param exportLimitWh Most the connection may export in each slot.
/// @param importLimitWh Most it may import. Same length as `exportLimitWh`.
struct Envelope {
    address account;
    uint64 issuedAt;
    uint64 firstSlotStart;
    uint32 slotSeconds;
    uint64[] exportLimitWh;
    uint64[] importLimitWh;
}

enum GridLevel {
    NORMAL,
    ALERT,
    EMERGENCY
}

enum GridDirection {
    DEFICIT,
    SURPLUS,
    NONE
}

/// @notice The grid's state, as its operator declares it, for every account
///         that registered the operator: no account field. Posted by a relay.
/// @param validUntil   After this time the state no longer holds.
/// @param horizonSlots How many slots from now the state applies to.
struct GridState {
    uint64 issuedAt;
    uint64 validUntil;
    GridLevel level;
    GridDirection direction;
    uint16 horizonSlots;
}

/// @notice A reading as it travels: `data` is `abi.encode` of the struct its
///         `kind` names, and `signature` the signer's 65-byte EIP-712
///         signature over it.
struct SignedReading {
    ReadingKind kind;
    bytes data;
    bytes signature;
}
