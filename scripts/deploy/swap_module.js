import { loadArtifact, createClients } from "../common/chain.js";

async function main() {
  const { account, walletClient, publicClient } = createClients();
  const artifact = loadArtifact("SmartAccount");

  let nonce = await publicClient.getTransactionCount({ address: account.address });

  const oldModule = process.env.MODULE_ADDRESS_V2;
  const newModule = process.env.MODULE_ADDRESS;

  console.log("SmartAccount:", process.env.SMART_ACCOUNT_ADDRESS);
  console.log("Modul VECHI (de scos):", oldModule);
  console.log("Modul NOU (de instalat):", newModule, "\n");

  const oldInstalled = await publicClient.readContract({
    address: process.env.SMART_ACCOUNT_ADDRESS,
    abi: artifact.abi,
    functionName: "installedModules",
    args: [oldModule],
  });

  if (oldInstalled) {
    console.log("Scoatere modul vechi...");
    let hash = await walletClient.writeContract({
      address: process.env.SMART_ACCOUNT_ADDRESS,
      abi: artifact.abi,
      functionName: "uninstallModule",
      args: [oldModule],
      nonce: nonce++,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log("  -> OK, Tx:", `https://sepolia.basescan.org/tx/${hash}`);
  } else {
    console.log("Modulul vechi nu era instalat, sarim peste.");
  }

  const newInstalled = await publicClient.readContract({
    address: process.env.SMART_ACCOUNT_ADDRESS,
    abi: artifact.abi,
    functionName: "installedModules",
    args: [newModule],
  });

  if (newInstalled) {
    console.log("\nModulul nou e deja instalat.");
  } else {
    console.log("\nInstalare modul nou...");
    let hash = await walletClient.writeContract({
      address: process.env.SMART_ACCOUNT_ADDRESS,
      abi: artifact.abi,
      functionName: "installModule",
      args: [newModule],
      nonce: nonce++,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log("  -> OK, Tx:", `https://sepolia.basescan.org/tx/${hash}`);
  }

  console.log("\n=== Swap complet ===");
  console.log("SmartAccount foloseste acum modulul cu guard pe setLimits.");
}

main().catch((err) => { console.error(err.message); process.exit(1); });
