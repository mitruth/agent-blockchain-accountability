import { loadArtifact, createClients } from "../common/chain.js";

const artifact = loadArtifact("SpendingLimitModule");

async function trySetLimits(walletClient, publicClient, label, newMax, newWeekly, nonce) {
  console.log(`\n--- ${label} ---`);
  console.log(`  Cerere: maxPerTransaction=${newMax}, weeklyLimit=${newWeekly}`);
  try {
    const hash = await walletClient.writeContract({
      address: process.env.MODULE_ADDRESS,
      abi: artifact.abi,
      functionName: "setLimits",
      args: [newMax, newWeekly],
      nonce,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "success") {
      console.log("  -> ACCEPTATA. Tx:", `https://sepolia.basescan.org/tx/${hash}`);
    } else {
      console.log("  -> RESPINSA (revert on-chain). Tx:", `https://sepolia.basescan.org/tx/${hash}`);
    }
  } catch (err) {
    console.log("  -> RESPINSA (exceptie).");
    console.log("  -> Motiv:", err.shortMessage || err.message.slice(0, 150));
  }
}

async function main() {
  const { account, walletClient, publicClient } = createClients();

  let nonce = await publicClient.getTransactionCount({ address: account.address });

  const currentMax = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "maxPerTransaction",
  });
  const currentWeekly = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "weeklyLimit",
  });

  console.log("=== TEST REGULA: max 50% schimbare per apel ===");
  console.log("Valori curente: maxPerTransaction =", currentMax.toString(), ", weeklyLimit =", currentWeekly.toString());

  const smallIncrease = (currentMax * 117n) / 100n;
  await trySetLimits(walletClient, publicClient, "TEST A: crestere ~17% (sub 50%, asteptat: ACCEPTATA)", smallIncrease, currentWeekly, nonce++);

  const hugeIncrease = currentMax * 1000n;
  await trySetLimits(walletClient, publicClient, "TEST B: crestere de 1000x (asteptat: RESPINSA)", hugeIncrease, currentWeekly, nonce++);

  console.log("\n=== VALORI FINALE (ar trebui sa reflecte doar Test A) ===");
  const finalMax = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "maxPerTransaction",
  });
  console.log("maxPerTransaction =", finalMax.toString());
}

main().catch((err) => { console.error(err.message); process.exit(1); });
