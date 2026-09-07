import { loadArtifact, createClients } from "../common/chain.js";

async function main() {
  const { account, walletClient, publicClient } = createClients();

  console.log("Deployer (owner + agent, pentru test):", account.address);

  const moduleArtifact = loadArtifact("SpendingLimitModule");
  const maxPerTransaction = 300000000000n; // 3e11 wei = 0.0000003 ETH
  const weeklyLimit = 1000000000000n;      // 1e12 wei = 0.000001 ETH

  console.log("\nDeploying SpendingLimitModule...");
  const moduleHash = await walletClient.deployContract({
    abi: moduleArtifact.abi,
    bytecode: moduleArtifact.bytecode,
    args: [account.address, maxPerTransaction, weeklyLimit],
  });
  const moduleReceipt = await publicClient.waitForTransactionReceipt({ hash: moduleHash });
  const moduleAddress = moduleReceipt.contractAddress;
  console.log("SpendingLimitModule:", moduleAddress);

  const accountArtifact = loadArtifact("SmartAccount");
  console.log("\nDeploying SmartAccount...");
  const accountHash = await walletClient.deployContract({
    abi: accountArtifact.abi,
    bytecode: accountArtifact.bytecode,
  });
  const accountReceipt = await publicClient.waitForTransactionReceipt({ hash: accountHash });
  const smartAccountAddress = accountReceipt.contractAddress;
  console.log("SmartAccount:", smartAccountAddress);

  console.log("\n=== Adauga in .env ===");
  console.log(`SMART_ACCOUNT_ADDRESS=${smartAccountAddress}`);
  console.log(`MODULE_ADDRESS=${moduleAddress}`);
  console.log(`\nBaseScan SmartAccount: https://sepolia.basescan.org/address/${smartAccountAddress}`);
  console.log(`BaseScan Module:       https://sepolia.basescan.org/address/${moduleAddress}`);
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
