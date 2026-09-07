import { loadArtifact, createClients } from "../common/chain.js";

async function main() {
  const { account, walletClient, publicClient } = createClients();
  const moduleArtifact = loadArtifact("SpendingLimitModule");

  console.log("Deployer (owner + agent):", account.address);
  console.log("Modulul V2 ramane la:", process.env.MODULE_ADDRESS, "(neatins, ca istoric)\n");

  const maxPerTransaction = 300000000000n; // 3e11 wei
  const weeklyLimit = 1000000000000n;      // 1e12 wei

  console.log("Deploying SpendingLimitModule v3 (accumulare corecta pe zi)...");
  const hash = await walletClient.deployContract({
    abi: moduleArtifact.abi,
    bytecode: moduleArtifact.bytecode,
    args: [account.address, maxPerTransaction, weeklyLimit],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  const moduleV3Address = receipt.contractAddress;

  console.log("\nSpendingLimitModule v3:", moduleV3Address);
  console.log("BaseScan:", `https://sepolia.basescan.org/address/${moduleV3Address}`);
  console.log("\nAdauga in .env:");
  console.log(`MODULE_ADDRESS_V3=${moduleV3Address}`);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
