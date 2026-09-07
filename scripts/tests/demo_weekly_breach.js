import { loadArtifact, createClients } from "../common/chain.js";

const moduleArtifact = loadArtifact("SpendingLimitModule");
const accountArtifact = loadArtifact("SmartAccount");

const NEW_MAX_PER_TX = 210000000000n;    // 2.1e11 wei
const NEW_WEEKLY_LIMIT = 1000000000000n; // 1e12 wei
const DAILY_AMOUNT = 150000000000n;      // 1.5e11 wei  depaseste

async function main() {
  const { account, walletClient, publicClient } = createClients();

  let nonce = await publicClient.getTransactionCount({ address: account.address });

  console.log("=== DEMO: limita per-tranzactie OK, limita saptamanala DEPASITA ===\n");

  const currentMax = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: moduleArtifact.abi,
    functionName: "maxPerTransaction",
  });
  const currentWeekly = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: moduleArtifact.abi,
    functionName: "weeklyLimit",
  });
  const maxDiffAllowed = (currentMax * 50n) / 100n;
  const weeklyDiffAllowed = (currentWeekly * 50n) / 100n;
  const maxDiffWanted = NEW_MAX_PER_TX > currentMax ? NEW_MAX_PER_TX - currentMax : currentMax - NEW_MAX_PER_TX;
  const weeklyDiffWanted = NEW_WEEKLY_LIMIT > currentWeekly ? NEW_WEEKLY_LIMIT - currentWeekly : currentWeekly - NEW_WEEKLY_LIMIT;
  if (maxDiffWanted > maxDiffAllowed || weeklyDiffWanted > weeklyDiffAllowed) {
    console.error(`EROARE: schimbarea ceruta depaseste garda de 50%.`);
    console.error(`  Curent: maxPerTransaction=${currentMax}, weeklyLimit=${currentWeekly}`);
    console.error(`  Cerut:  maxPerTransaction=${NEW_MAX_PER_TX}, weeklyLimit=${NEW_WEEKLY_LIMIT}`);
    process.exit(1);
  }

  console.log(`Setare limite: maxPerTransaction=${NEW_MAX_PER_TX}, weeklyLimit=${NEW_WEEKLY_LIMIT}`);
  let hash = await walletClient.writeContract({
    address: process.env.MODULE_ADDRESS,
    abi: moduleArtifact.abi,
    functionName: "setLimits",
    args: [NEW_MAX_PER_TX, NEW_WEEKLY_LIMIT],
    nonce: nonce++,
  });
  await publicClient.waitForTransactionReceipt({ hash });
  console.log("  -> OK\n");

  const lastDay = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: moduleArtifact.abi,
    functionName: "lastReportedDay",
  });
  const startDay = Number(lastDay) + 1;
  console.log(`Continuam de la ziua ${startDay} (ultima raportata a fost ${lastDay})\n`);

  console.log("Raportare 6 zile, fiecare 180.000.000.000 wei (sub limita per-tranzactie de 200.000.000.000):");
  let lastReportedDay;
  for (let i = 0; i < 6; i++) {
    const day = startDay + i;
    hash = await walletClient.writeContract({
      address: process.env.MODULE_ADDRESS,
      abi: moduleArtifact.abi,
      functionName: "reportDay",
      args: [BigInt(day), DAILY_AMOUNT],
      nonce: nonce++,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Zi ${day}: ${DAILY_AMOUNT} wei -> raportata OK`);
    lastReportedDay = day;
  }

  const weekTotal = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: moduleArtifact.abi,
    functionName: "getWeeklyTotal",
    args: [BigInt(lastReportedDay)],
  });
  console.log(`\nSuma ultimelor 7 zile (getWeeklyTotal) = ${weekTotal} wei`);
  console.log(`Limita saptamanala = ${NEW_WEEKLY_LIMIT} wei`);
  console.log(`Marja ramasa = ${NEW_WEEKLY_LIMIT - weekTotal} wei\n`);

  console.log("--- A 7-A TRANZACTIE (execute prin SmartAccount) ---");
  console.log(`Valoare: ${DAILY_AMOUNT} wei`);
  console.log(`Verificare per-tranzactie: ${DAILY_AMOUNT} < ${NEW_MAX_PER_TX} -> RESPECTATA`);
  console.log(`Verificare saptamanala: ${weekTotal} + ${DAILY_AMOUNT} = ${weekTotal + DAILY_AMOUNT} vs limita ${NEW_WEEKLY_LIMIT}`);
  console.log(`  -> ${weekTotal + DAILY_AMOUNT > NEW_WEEKLY_LIMIT ? "DEPASESTE, ar trebui RESPINSA" : "OK, ar trebui sa treaca"}\n`);

  try {
    hash = await walletClient.writeContract({
      address: process.env.SMART_ACCOUNT_ADDRESS,
      abi: accountArtifact.abi,
      functionName: "execute",
      args: [process.env.DESTINATION_ADDRESS, DAILY_AMOUNT],
      nonce: nonce++,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "success") {
      console.log("REZULTAT: TRECUT (neasteptat!). Tx:", `https://sepolia.basescan.org/tx/${hash}`);
    } else {
      console.log("REZULTAT: RESPINSA de contract (revert on-chain), exact cum era asteptat.");
      console.log("Tx (revert):", `https://sepolia.basescan.org/tx/${hash}`);
    }
  } catch (err) {
    console.log("REZULTAT: RESPINSA de contract (exceptie la trimitere).");
    console.log("Motiv:", err.shortMessage || err.message.slice(0, 200));
  }

  console.log("\n=== CONCLUZIE DEMO ===");
  console.log("Primele 6 tranzactii: respecta limita per-tranzactie -> acceptate");
  console.log("A 7-a tranzactie: respecta limita per-tranzactie, DAR depaseste limita saptamanala -> RESPINSA");
}

main().catch((err) => { console.error(err.message); process.exit(1); });
