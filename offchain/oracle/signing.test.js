// npm run test:offchain
//
// What the off-chain oracles sign is what the contract checks: viem's EIP-712
// signatures, made from offchain/oracle/typed.js, are accepted by
// OracleVerifier on a fresh chain inside this process, and a reading changed
// after signing is not. Needs the contracts built (npm run build).

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { hashTypedData } from "viem";
import { useInProcessChain, deploy, send, read, key, now, explain } from "../chain/index.js";
import { KIND, TYPES, domain, signBms, signForecast } from "./typed.js";

const DEPLOYER = 0;
const ACCOUNT = 5; // plays a prosumer's account: it registers its own devices
const RELAY = 6;
const BMS_KEY = 40;
const PV_KEY = 41;

let connection, verifier, chainId, account;

before(async () => {
  connection = await useInProcessChain();
  verifier = await deploy(DEPLOYER, "OracleVerifier");
  chainId = 31337;
  account = key(ACCOUNT).address;
  await send(ACCOUNT, verifier, "OracleVerifier", "setDevice", [KIND.BMS, key(BMS_KEY).address, 1800]);
  await send(ACCOUNT, verifier, "OracleVerifier", "setDevice", [KIND.PV_FORECAST, key(PV_KEY).address, 3600]);
});

after(async () => {
  await connection.close();
});

test("the contract's digest is viem's EIP-712 hash", async () => {
  const reading = { account, timestamp: 1_000n, socWh: 2_500n, dischargeOdometerWh: 7n };
  const structHash = await read(verifier, "OracleVerifier", "bmsStructHash", [reading]);
  const onChain = await read(verifier, "OracleVerifier", "digestOf", [structHash]);
  const offChain = hashTypedData({
    domain: domain(chainId, verifier), types: { BmsReading: TYPES.BmsReading }, primaryType: "BmsReading", message: reading,
  });
  assert.equal(onChain, offChain);
});

test("a BMS reading signed off-chain is accepted and read back", async () => {
  const t = await now();
  const signed = await signBms(BMS_KEY, chainId, verifier, { account, timestamp: t, socWh: 3_100, dischargeOdometerWh: 42 });
  await send(RELAY, verifier, "OracleVerifier", "accept", [signed]);
  const [reading, fresh] = await read(verifier, "OracleVerifier", "bmsOf", [account]);
  assert.equal(fresh, true);
  assert.equal(reading.socWh, 3_100n);
  assert.equal(reading.dischargeOdometerWh, 42n);
});

test("a forecast signed off-chain is accepted and served slot by slot", async () => {
  const t = await now();
  const first = t - (t % 1800);
  const signed = await signForecast(PV_KEY, chainId, verifier, {
    account, issuedAt: t, firstSlotStart: first, slotSeconds: 1800, pvWh: [0, 120, 340, 610],
  });
  await send(RELAY, verifier, "OracleVerifier", "accept", [signed]);
  const [pvWh, usable] = await read(verifier, "OracleVerifier", "pvAt", [account, BigInt(first + 2 * 1800)]);
  assert.equal(usable, true);
  assert.equal(pvWh, 340n);
});

test("a reading changed after it was signed is refused", async () => {
  const t = await now();
  const signed = await signBms(BMS_KEY, chainId, verifier, { account, timestamp: t, socWh: 1_000, dischargeOdometerWh: 50 });
  const changed = await signBms(BMS_KEY, chainId, verifier, { account, timestamp: t, socWh: 4_900, dischargeOdometerWh: 50 });
  await assert.rejects(
    send(RELAY, verifier, "OracleVerifier", "accept", [{ ...signed, data: changed.data }]),
    (e) => /Oracle_WrongSigner/.test(explain(e)),
  );
});
