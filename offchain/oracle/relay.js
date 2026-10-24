// The oracles on the chain: the PV forecast relay, which signs with the
// provider's key and posts to the verifier, and each prosumer's BMS, which
// signs readings for the agent to bring with its orders.
//
// Keys, from the public test mnemonic: the forecast provider signs with one
// key and the relay posts from another, funded, one, so the signer never
// needs gas; each prosumer's BMS has a key of its own. The deploy script
// chooses them and records them in deployments/local.json.

import { send, read, events } from "../chain/index.js";
import { signBms, signForecast, signTariff } from "./typed.js";

/**
 * Sign and post a PV forecast for prosumer `name`: Wh per market slot from
 * `firstSlotStart`. Returns whether it was new (a forecast posted again is a
 * no-op).
 */
export async function postForecast(deployment, name, { firstSlotStart, pvWh, issuedAt }) {
  const p = deployment.prosumers[name];
  const signed = await signForecast(deployment.oracles.pvProvider.keyIndex, deployment.chainId, deployment.contracts.oracle, {
    account: p.account, issuedAt, firstSlotStart, slotSeconds: deployment.slotSeconds, pvWh,
  });
  const receipt = await handIn(deployment, signed);
  return { signed, isNew: events(receipt, "OracleVerifier", "ReadingAccepted").length > 0 };
}

/**
 * Sign and post prosumer `name`'s tariff, retail and feed-in per market slot
 * from `firstSlotStart`, with the retailer's key. A schedule posted again is
 * a no-op.
 */
export async function postTariff(deployment, name, { firstSlotStart, retail, feedIn, issuedAt }) {
  const p = deployment.prosumers[name];
  const signed = await signTariff(deployment.oracles.tariffProvider.keyIndex, deployment.chainId, deployment.contracts.oracle, {
    account: p.account, issuedAt, firstSlotStart, slotSeconds: deployment.slotSeconds, retail, feedIn,
  });
  const receipt = await handIn(deployment, signed);
  return { signed, isNew: events(receipt, "OracleVerifier", "ReadingAccepted").length > 0 };
}

/** A BMS reading of prosumer `name`'s battery at `timestamp`, signed by its BMS: for the agent's next order. */
export function bmsReading(deployment, name, timestamp, { socWh, dischargeOdometerWh }) {
  const p = deployment.prosumers[name];
  return signBms(p.bms.keyIndex, deployment.chainId, deployment.contracts.oracle, {
    account: p.account, timestamp, socWh, dischargeOdometerWh,
  });
}

/** Hand a signed reading to the verifier directly, from the relay. Anyone may. */
export function handIn(deployment, signed, from = deployment.oracles.relay.keyIndex) {
  return send(from, deployment.contracts.oracle, "OracleVerifier", "accept", [signed]);
}

/** What the verifier holds for prosumer `name`: the latest battery reading and whether it is fresh. */
export async function batteryOf(deployment, name) {
  const [reading, fresh] = await read(deployment.contracts.oracle, "OracleVerifier", "bmsOf", [deployment.prosumers[name].account]);
  return { ...reading, fresh };
}

/** The forecast the verifier holds for prosumer `name`'s slot starting at `slotStart`. */
export async function pvOf(deployment, name, slotStart) {
  const [pvWh, usable] = await read(deployment.contracts.oracle, "OracleVerifier", "pvAt", [
    deployment.prosumers[name].account, BigInt(slotStart),
  ]);
  return { pvWh, usable };
}
