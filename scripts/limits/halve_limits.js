import { formatEther } from "viem";
import { loadArtifact, createClients } from "../common/chain.js";

async function main() {
  const { walletClient, publicClient } = createClients();
  const artifact = loadArtifact("SpendingLimitModule");

  const currentMax = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS, abi: artifact.abi, functionName: "maxPerTransaction",
  });
  const currentWeekly = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS, abi: artifact.abi, functionName: "weeklyLimit",
  });

  const newMax = currentMax / 2n;
  const newWeekly = currentWeekly / 2n;

  console.log("Curent: maxPerTransaction =", formatEther(currentMax), "ETH, weeklyLimit =", formatEther(currentWeekly), "ETH");
  console.log("Nou:    maxPerTransaction =", formatEther(newMax), "ETH, weeklyLimit =", formatEther(newWeekly), "ETH\n");

  const hash = await walletClient.writeContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "setLimits",
    args: [newMax, newWeekly],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  if (receipt.status === "success") {
    console.log("SUCCESS! Tx:", `https://sepolia.basescan.org/tx/${hash}`);
  } else {
    console.log("RESPINSA. Tx:", `https://sepolia.basescan.org/tx/${hash}`);
  }
}

main().catch((err) => { console.error(err.message); process.exit(1); });
