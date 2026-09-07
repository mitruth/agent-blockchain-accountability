import { readFileSync } from "fs";
import { loadArtifact, createClients } from "../common/chain.js";

const accountArtifact = loadArtifact("SmartAccount");

function parseCsv(path) {
  const lines = readFileSync(path, "utf8").trim().split("\n");
  const headers = lines[0].split(",").map((h) => h.trim());
  return lines.slice(1).map((line) => {
    const vals = line.split(",").map((v) => v.trim());
    return Object.fromEntries(headers.map((h, i) => [h, vals[i]]));
  });
}

const SCALE = 100000000n; // 1e8 wei per milliUSD

async function tryTransfer(walletClient, publicClient, label, dayIndex, spendMilliUsd) {
  const amountWei = BigInt(spendMilliUsd) * SCALE;
  console.log(`\n--- ${label}: Zi ${dayIndex}, spend=${spendMilliUsd} mUSD -> ${amountWei} wei ---`);

  try {
    const hash = await walletClient.writeContract({
      address: process.env.SMART_ACCOUNT_ADDRESS,
      abi: accountArtifact.abi,
      functionName: "execute",
      args: [process.env.DESTINATION_ADDRESS, amountWei],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log("  -> TRECUT. Tx:", `https://sepolia.basescan.org/tx/${hash}`);
    console.log("  -> Status:", receipt.status);
  } catch (err) {
    console.log("  -> RESPINS de contract.");
    console.log("  -> Motiv:", err.shortMessage || err.message.slice(0, 150));
  }
}

async function main() {
  const { walletClient, publicClient } = createClients();

  const rows = parseCsv(new URL("../../records_B0.csv", import.meta.url));
  const zi0 = rows[0];
  const zi1 = rows[1];

  console.log("=== TEST REGULA PER TRANZACTIE ===");
  console.log("maxPerTransaction = 300000000000 wei (0.0000003 ETH)");

  await tryTransfer(walletClient, publicClient, "SUB LIMITA (asteptat: trece)", zi1.dayIndex, zi1.spendMilliUsd);
  await tryTransfer(walletClient, publicClient, "PESTE LIMITA (asteptat: respins)", zi0.dayIndex, zi0.spendMilliUsd);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
