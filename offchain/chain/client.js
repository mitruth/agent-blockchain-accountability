// The connection to a chain and the test keys.
//
// By default, the local node: `npx hardhat node`, chain 31337 at
// http://127.0.0.1:8545 (or RPC_URL). A program that needs a chain of its own,
// such as the verifier's fuzz runs, calls `useInProcessChain()` first and gets
// a fresh Hardhat chain inside its own process, touching no node.
//
// Accounts come from Hardhat's public test mnemonic. Every role in the system
// is one of those accounts, by index. Never use these keys anywhere real.

import { createPublicClient, createWalletClient, http, custom } from "viem";
import { hardhat } from "viem/chains";
import { mnemonicToAccount } from "viem/accounts";

const MNEMONIC = "test test test test test test test test test test test junk";
const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const POLLING = { pollingInterval: 50 };

let transport = http(RPC);

/** The client every read goes through. Rebound by `useInProcessChain`. */
export let publicClient = createPublicClient({ chain: hardhat, transport, ...POLLING });

const wallets = new Map();

/** The test account at `index` of the public mnemonic. */
export function key(index) {
  return mnemonicToAccount(MNEMONIC, { addressIndex: index });
}

/** A wallet client signing with the test key at `index`. */
export function wallet(index) {
  if (!wallets.has(index)) {
    wallets.set(index, createWalletClient({ account: key(index), chain: hardhat, transport, ...POLLING }));
  }
  return wallets.get(index);
}

const SENDS = new Set(["eth_sendTransaction", "eth_sendRawTransaction", "evm_mine"]);

/**
 * A provider whose blocks do not follow the wall clock (v0.2 step 8): every
 * block not given a time of its own comes one second after the last. Hardhat
 * otherwise advances block time with the real time elapsed since a warp, so
 * a long run's outcome would depend on how fast the machine ran it.
 */
function fixedTimeProvider(provider) {
  let timeSet = false;
  return {
    async request(args) {
      if (args.method === "evm_setNextBlockTimestamp") {
        timeSet = true;
        return provider.request(args);
      }
      if (SENDS.has(args.method)) {
        if (!timeSet) {
          const latest = await provider.request({ method: "eth_getBlockByNumber", params: ["latest", false] });
          await provider.request({ method: "evm_setNextBlockTimestamp", params: [Number(latest.timestamp) + 1] });
        }
        timeSet = false;
      }
      return provider.request(args);
    },
  };
}

/**
 * Switch every client of this process to a new Hardhat chain running in the
 * process itself. Returns the connection; `close()` it when done. With
 * `fixedTime`, block times no longer follow the wall clock (above).
 */
export async function useInProcessChain({ fixedTime = false } = {}) {
  const { network } = await import("hardhat");
  const connection = await network.connect();
  transport = custom(fixedTime ? fixedTimeProvider(connection.provider) : connection.provider);
  publicClient = createPublicClient({ chain: hardhat, transport, ...POLLING });
  wallets.clear();
  return connection;
}
