// Shared helpers for the local demo: one Hardhat node, test keys, the
// compiled contracts, and transactions that explain their reverts.
//
// The node is `npx hardhat node`: chain 31337 at http://127.0.0.1:8545, with
// accounts from Hardhat's public test mnemonic. Every role in the demo is one
// of those accounts, by index. Never use these keys anywhere real.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEventLogs,
  toFunctionSelector,
  getAbiItem,
  encodeFunctionData,
  decodeErrorResult,
} from "viem";
import { hardhat } from "viem/chains";
import { mnemonicToAccount } from "viem/accounts";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(HERE, "..", "..");
export const DEPLOYMENT_FILE = path.join(ROOT, "deployments", "local.json");

const MNEMONIC = "test test test test test test test test test test test junk";
const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";

export const publicClient = createPublicClient({ chain: hardhat, transport: http(RPC) });

const wallets = new Map();

/** The test account at `index` of the public mnemonic. */
export function key(index) {
  return mnemonicToAccount(MNEMONIC, { addressIndex: index });
}

function wallet(index) {
  if (!wallets.has(index)) {
    wallets.set(index, createWalletClient({ account: key(index), chain: hardhat, transport: http(RPC) }));
  }
  return wallets.get(index);
}

/** ABI and bytecode of a contract, from `npx hardhat build --no-tests`. */
export function artifact(name) {
  const dirs = ["market", "gate", "demo"];
  for (const dir of dirs) {
    const file = path.join(ROOT, "artifacts", "contracts", dir, `${name}.sol`, `${name}.json`);
    if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, "utf8"));
  }
  throw new Error(`No artifact for ${name}. Run: npx hardhat build --no-tests`);
}

const abiCache = new Map();
export function abi(name) {
  if (!abiCache.has(name)) abiCache.set(name, artifact(name).abi);
  return abiCache.get(name);
}

/** Deploy `name` from the key at `from`; returns the address. */
export async function deploy(from, name, args = []) {
  const { abi: contractAbi, bytecode } = artifact(name);
  const hash = await wallet(from).deployContract({ abi: contractAbi, bytecode, args });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Deploying ${name} reverted`);
  return receipt.contractAddress;
}

/**
 * Send a transaction from the key at `from`. It is simulated first, so a revert
 * throws with the contract's own error rather than a bare failure.
 * Returns the receipt.
 */
export async function send(from, address, contract, functionName, args = []) {
  let request;
  try {
    ({ request } = await publicClient.simulateContract({
      account: key(from),
      address,
      abi: abi(contract),
      functionName,
      args,
    }));
  } catch (error) {
    throw new Error(`${contract}.${functionName} reverted: ${explain(error)}`);
  }
  const hash = await wallet(from).writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${contract}.${functionName} reverted`);
  return receipt;
}

// A revert can come from any contract down the call chain: the gate, the
// account, the prosumer contract, the session, the token. Try every ABI.
const EVERY_CONTRACT = [
  "PolicyGate", "PositionLedger", "MiniAccount", "Prosumer", "MarketSession",
  "MarketManager", "LockableERC1155", "ProsumerDecoder",
];

function revertData(error) {
  for (let e = error; e; e = e.cause) {
    if (typeof e.data === "string" && e.data.startsWith("0x")) return e.data;
    if (e.data && typeof e.data.data === "string") return e.data.data;
    if (typeof e.raw === "string" && e.raw.startsWith("0x")) return e.raw;
  }
  return null;
}

export function explain(error) {
  const data = revertData(error);
  if (data) {
    for (const name of EVERY_CONTRACT) {
      try {
        const decoded = decodeErrorResult({ abi: abi(name), data });
        const args = (decoded.args ?? []).map((a) => (typeof a === "bigint" ? a.toString() : String(a)));
        return `${decoded.errorName}(${args.join(", ")})`;
      } catch {}
    }
  }
  return (error.shortMessage ?? error.message ?? String(error)).split("\n")[0];
}

export function read(address, contract, functionName, args = []) {
  return publicClient.readContract({ address, abi: abi(contract), functionName, args });
}

export function calldata(contract, functionName, args = []) {
  return encodeFunctionData({ abi: abi(contract), functionName, args });
}

export function selector(contract, functionName) {
  return toFunctionSelector(getAbiItem({ abi: abi(contract), name: functionName }));
}

/** Events of `contract` in a receipt. */
export function events(receipt, contract, eventName) {
  return parseEventLogs({ abi: abi(contract), logs: receipt.logs, eventName });
}

// --- time -------------------------------------------------------------------

export async function now() {
  const block = await publicClient.getBlock();
  return Number(block.timestamp);
}

/** Move the chain to `timestamp` (seconds) and mine a block there. */
export async function warpTo(timestamp) {
  const current = await now();
  if (timestamp > current) {
    await publicClient.request({ method: "evm_setNextBlockTimestamp", params: [timestamp] });
  }
  await publicClient.request({ method: "evm_mine", params: [] });
}

// --- deployment file ---------------------------------------------------------

export function saveDeployment(data) {
  fs.mkdirSync(path.dirname(DEPLOYMENT_FILE), { recursive: true });
  fs.writeFileSync(DEPLOYMENT_FILE, JSON.stringify(data, null, 2) + "\n");
}

export function loadDeployment() {
  if (!fs.existsSync(DEPLOYMENT_FILE)) throw new Error("No deployment. Run: npm run demo:deploy");
  return JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf8"));
}

// --- units -------------------------------------------------------------------

/** The payment token has 6 decimals: 1 EUR = 1,000,000 units. */
export const EUR = 1_000_000n;

export function eur(units) {
  const n = BigInt(units);
  const sign = n < 0n ? "-" : "";
  const a = n < 0n ? -n : n;
  return `${sign}${a / EUR}.${(a % EUR).toString().padStart(6, "0")} EUR`;
}

export function kWh(wh) {
  return `${(Number(wh) / 1000).toFixed(3)} kWh`;
}
