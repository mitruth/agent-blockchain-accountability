// What the oracles sign, as EIP-712 typed data, and how a signed reading
// travels: the same types as contracts/oracle/OracleTypes.sol, the same domain
// as OracleVerifier. A signature made here is what the verifier checks.

import { encodeAbiParameters } from "viem";
import { key } from "../chain/index.js";

/** `ReadingKind` in the contract. */
export const KIND = { BMS: 0, PV_FORECAST: 1, TARIFF: 2, METER: 3, ENVELOPE: 4, GRID_STATE: 5 };

export const TYPES = {
  BmsReading: [
    { name: "account", type: "address" },
    { name: "timestamp", type: "uint64" },
    { name: "socWh", type: "uint64" },
    { name: "dischargeOdometerWh", type: "uint64" },
  ],
  PvForecast: [
    { name: "account", type: "address" },
    { name: "issuedAt", type: "uint64" },
    { name: "firstSlotStart", type: "uint64" },
    { name: "slotSeconds", type: "uint32" },
    { name: "pvWh", type: "uint64[]" },
  ],
  TariffSchedule: [
    { name: "account", type: "address" },
    { name: "issuedAt", type: "uint64" },
    { name: "firstSlotStart", type: "uint64" },
    { name: "slotSeconds", type: "uint32" },
    { name: "retail", type: "uint64[]" },
    { name: "feedIn", type: "uint64[]" },
  ],
  MeterReading: [
    { name: "account", type: "address" },
    { name: "slotStart", type: "uint64" },
    { name: "importWh", type: "uint64" },
    { name: "exportWh", type: "uint64" },
  ],
  Envelope: [
    { name: "account", type: "address" },
    { name: "issuedAt", type: "uint64" },
    { name: "firstSlotStart", type: "uint64" },
    { name: "slotSeconds", type: "uint32" },
    { name: "exportLimitWh", type: "uint64[]" },
    { name: "importLimitWh", type: "uint64[]" },
  ],
};

const asTuple = (fields) => ({ type: "tuple", components: fields });

/** The verifier's EIP-712 domain. */
export function domain(chainId, verifier) {
  return { name: "PolicyOracle", version: "1", chainId, verifyingContract: verifier };
}

/**
 * A BMS reading signed with the test key at `keyIndex`, ready for
 * `OracleVerifier.accept` or `PolicyGate.submit`'s readings.
 * @param reading { account, timestamp, socWh, dischargeOdometerWh }, integers
 */
export async function signBms(keyIndex, chainId, verifier, reading) {
  const message = {
    account: reading.account,
    timestamp: BigInt(reading.timestamp),
    socWh: BigInt(reading.socWh),
    dischargeOdometerWh: BigInt(reading.dischargeOdometerWh),
  };
  const signature = await key(keyIndex).signTypedData({
    domain: domain(chainId, verifier), types: { BmsReading: TYPES.BmsReading }, primaryType: "BmsReading", message,
  });
  return { kind: KIND.BMS, data: encodeAbiParameters([asTuple(TYPES.BmsReading)], [message]), signature };
}

/**
 * A PV forecast signed with the test key at `keyIndex`.
 * @param forecast { account, issuedAt, firstSlotStart, slotSeconds, pvWh: [] }, integers
 */
export async function signForecast(keyIndex, chainId, verifier, forecast) {
  const message = {
    account: forecast.account,
    issuedAt: BigInt(forecast.issuedAt),
    firstSlotStart: BigInt(forecast.firstSlotStart),
    slotSeconds: Number(forecast.slotSeconds),
    pvWh: forecast.pvWh.map(BigInt),
  };
  const signature = await key(keyIndex).signTypedData({
    domain: domain(chainId, verifier), types: { PvForecast: TYPES.PvForecast }, primaryType: "PvForecast", message,
  });
  return { kind: KIND.PV_FORECAST, data: encodeAbiParameters([asTuple(TYPES.PvForecast)], [message]), signature };
}

/**
 * A tariff schedule signed with the test key at `keyIndex` (spec v0.2
 * section 4): retail and feed-in per slot, token units per kWh.
 * @param schedule { account, issuedAt, firstSlotStart, slotSeconds, retail: [], feedIn: [] }, integers
 */
export async function signTariff(keyIndex, chainId, verifier, schedule) {
  const message = {
    account: schedule.account,
    issuedAt: BigInt(schedule.issuedAt),
    firstSlotStart: BigInt(schedule.firstSlotStart),
    slotSeconds: Number(schedule.slotSeconds),
    retail: schedule.retail.map(BigInt),
    feedIn: schedule.feedIn.map(BigInt),
  };
  const signature = await key(keyIndex).signTypedData({
    domain: domain(chainId, verifier), types: { TariffSchedule: TYPES.TariffSchedule }, primaryType: "TariffSchedule", message,
  });
  return { kind: KIND.TARIFF, data: encodeAbiParameters([asTuple(TYPES.TariffSchedule)], [message]), signature };
}

/**
 * A meter reading signed with the test key at `keyIndex` (spec v0.2 section
 * 4): what the account imported and exported over the slot starting at
 * `slotStart`, in Wh. S9 reads it.
 * @param reading { account, slotStart, importWh, exportWh }, integers
 */
export async function signMeter(keyIndex, chainId, verifier, reading) {
  const message = {
    account: reading.account,
    slotStart: BigInt(reading.slotStart),
    importWh: BigInt(reading.importWh),
    exportWh: BigInt(reading.exportWh),
  };
  const signature = await key(keyIndex).signTypedData({
    domain: domain(chainId, verifier), types: { MeterReading: TYPES.MeterReading }, primaryType: "MeterReading", message,
  });
  return { kind: KIND.METER, data: encodeAbiParameters([asTuple(TYPES.MeterReading)], [message]), signature };
}

/**
 * The DSO's operating envelope for the account's connection, signed with the
 * test key at `keyIndex` (spec v0.2 section 4): the most it may export and
 * import in each slot from `firstSlotStart`, in Wh. S10 reads it.
 * @param envelope { account, issuedAt, firstSlotStart, slotSeconds, exportLimitWh: [], importLimitWh: [] }
 */
export async function signEnvelope(keyIndex, chainId, verifier, envelope) {
  const message = {
    account: envelope.account,
    issuedAt: BigInt(envelope.issuedAt),
    firstSlotStart: BigInt(envelope.firstSlotStart),
    slotSeconds: Number(envelope.slotSeconds),
    exportLimitWh: envelope.exportLimitWh.map(BigInt),
    importLimitWh: envelope.importLimitWh.map(BigInt),
  };
  const signature = await key(keyIndex).signTypedData({
    domain: domain(chainId, verifier), types: { Envelope: TYPES.Envelope }, primaryType: "Envelope", message,
  });
  return { kind: KIND.ENVELOPE, data: encodeAbiParameters([asTuple(TYPES.Envelope)], [message]), signature };
}
