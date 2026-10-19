// The compiled contracts, and transactions that explain their reverts.

import fs from "node:fs";
import path from "node:path";
import {
  parseEventLogs,
  toFunctionSelector,
  getAbiItem,
  encodeFunctionData,
  decodeErrorResult,
} from "viem";
import { publicClient, key, wallet } from "./client.js";
import { ROOT } from "./paths.js";

const ARTIFACTS = path.join(ROOT, "artifacts", "contracts");

// Contract name → artifact file, found once by walking artifacts/contracts.
let artifactIndex = null;

function indexArtifacts() {
  const index = new Map();
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (!entry.isDirectory()) continue;
      if (entry.name.endsWith(".sol")) {
        const name = entry.name.slice(0, -4);
        const file = path.join(full, `${name}.json`);
        if (fs.existsSync(file)) index.set(name, index.has(name) ? null : file); // null: ambiguous
      } else {
        walk(full);
      }
    }
  };
  if (fs.existsSync(ARTIFACTS)) walk(ARTIFACTS);
  return index;
}

/** ABI and bytecode of a contract, from `npx hardhat build --no-tests`. */
export function artifact(name) {
  artifactIndex ??= indexArtifacts();
  const file = artifactIndex.get(name);
  if (file === null) throw new Error(`Two contracts are named ${name}; the artifact is ambiguous`);
  if (!file) throw new Error(`No artifact for ${name}. Run: npx hardhat build --no-tests`);
  return JSON.parse(fs.readFileSync(file, "utf8"));
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
  "MarketManager", "LockableERC1155", "ProsumerDecoder", "WindowProbe", "OracleVerifier",
  "DeliverabilityPolicy", "CyclePolicy", "RampPolicy",
];

function revertData(error) {
  for (let e = error; e; e = e.cause) {
    if (typeof e.data === "string" && e.data.startsWith("0x")) return e.data;
    if (e.data && typeof e.data.data === "string") return e.data.data;
    if (typeof e.raw === "string" && e.raw.startsWith("0x")) return e.raw;
  }
  return null;
}

/** The contract's own error for a failed call, decoded against every ABI of the project. */
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
