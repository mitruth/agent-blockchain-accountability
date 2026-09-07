import "dotenv/config";
import { createWalletClient, createPublicClient, http } from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "fs";

export function loadArtifact(name) {
  return JSON.parse(
    readFileSync(new URL(`../../artifacts/contracts/${name}.sol/${name}.json`, import.meta.url))
  );
}

export function createReadClient() {
  return createPublicClient({
    chain: baseSepolia,
    transport: http(process.env.ALCHEMY_RPC_URL),
  });
}

export function createClients() {
  const account = privateKeyToAccount(process.env.PRIVATE_KEY);
  const transport = http(process.env.ALCHEMY_RPC_URL);
  const walletClient = createWalletClient({
    account,
    chain: baseSepolia,
    transport,
  });
  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport,
  });
  return { account, walletClient, publicClient };
}
