// The connection to the local node and the test keys.
//
// The node is `npx hardhat node`: chain 31337 at http://127.0.0.1:8545, with
// accounts from Hardhat's public test mnemonic. Every role in the system is one
// of those accounts, by index. Never use these keys anywhere real.

import { createPublicClient, createWalletClient, http } from "viem";
import { hardhat } from "viem/chains";
import { mnemonicToAccount } from "viem/accounts";

const MNEMONIC = "test test test test test test test test test test test junk";
const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";

export const publicClient = createPublicClient({ chain: hardhat, transport: http(RPC) });

const wallets = new Map();

/** The test account at `index` of the public mnemonic. */
export function key(index) {
  return mnemonicToAccount(MNEMONIC, { addressIndex: index });
}

/** A wallet client signing with the test key at `index`. */
export function wallet(index) {
  if (!wallets.has(index)) {
    wallets.set(index, createWalletClient({ account: key(index), chain: hardhat, transport: http(RPC) }));
  }
  return wallets.get(index);
}
