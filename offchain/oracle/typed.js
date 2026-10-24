// What the oracles sign, as EIP-712 typed data, and how a signed reading
// travels: the same types as contracts/oracle/OracleTypes.sol, the same domain
// as OracleVerifier. A signature made here is what the verifier checks.

import { encodeAbiParameters } from "viem";
import { key } from "../chain/index.js";

/** `ReadingKind` in the contract. */
export const KIND = { BMS: 0, PV_FORECAST: 1, TARIFF: 2 };

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
