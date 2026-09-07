import { formatEther } from "viem";
import { loadArtifact, createReadClient } from "../common/chain.js";

async function main() {
  const publicClient = createReadClient();
  const artifact = loadArtifact("SpendingLimitModule");

  const maxPerTx = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "maxPerTransaction",
  });

  const weeklyLimit = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "weeklyLimit",
  });

  const agent = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "agent",
  });

  const owner = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "owner",
  });

  console.log("=== VALORI CITITE DIRECT DE PE BLOCKCHAIN ===");
  console.log("Contract:       ", process.env.MODULE_ADDRESS);
  console.log("maxPerTransaction:", maxPerTx.toString(), "wei", `(${formatEther(maxPerTx)} ETH)`);
  console.log("weeklyLimit:      ", weeklyLimit.toString(), "wei", `(${formatEther(weeklyLimit)} ETH)`);
  console.log("agent:            ", agent);
  console.log("owner:            ", owner);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
