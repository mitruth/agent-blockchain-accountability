import { loadArtifact, createClients } from "../common/chain.js";

async function main() {
  const { walletClient, publicClient } = createClients();
  const artifact = loadArtifact("SmartAccount");

  console.log("SmartAccount:", process.env.SMART_ACCOUNT_ADDRESS);
  console.log("Module:      ", process.env.MODULE_ADDRESS);

  const alreadyInstalled = await publicClient.readContract({
    address: process.env.SMART_ACCOUNT_ADDRESS,
    abi: artifact.abi,
    functionName: "installedModules",
    args: [process.env.MODULE_ADDRESS],
  });

  if (alreadyInstalled) {
    console.log("\nModulul e deja instalat!");
    return;
  }

  console.log("\nInstalare modul...");
  const hash = await walletClient.writeContract({
    address: process.env.SMART_ACCOUNT_ADDRESS,
    abi: artifact.abi,
    functionName: "installModule",
    args: [process.env.MODULE_ADDRESS],
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("SUCCESS! Tx:", `https://sepolia.basescan.org/tx/${hash}`);
  console.log("Status:", receipt.status);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
