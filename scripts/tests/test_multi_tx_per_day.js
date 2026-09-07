import { loadArtifact, createClients } from "../common/chain.js";

const artifact = loadArtifact("SpendingLimitModule");

async function reportDay(walletClient, publicClient, dayIndex, amountWei, nonce) {
  const hash = await walletClient.writeContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "reportDay",
    args: [BigInt(dayIndex), amountWei],
    nonce,
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

async function main() {
  const { account, walletClient, publicClient } = createClients();

  let nonce = await publicClient.getTransactionCount({ address: account.address });

  const lastReportedDay = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS, abi: artifact.abi, functionName: "lastReportedDay",
  });
  const startDay = Number(lastReportedDay) + 1;

  const TX_AMOUNT = 1000n;

  console.log("=== TEST: 2 tranzactii/zi timp de 5 zile (10 tranzactii total) ===\n");
  console.log(`Pornim de la ziua ${startDay}\n`);

  for (let i = 0; i < 5; i++) {
    const day = startDay + i;
    console.log(`Zi ${day}: raportam 2 tranzactii de ${TX_AMOUNT} wei fiecare`);
    await reportDay(walletClient, publicClient, day, TX_AMOUNT, nonce++);
    await reportDay(walletClient, publicClient, day, TX_AMOUNT, nonce++);

    const daySum = await publicClient.readContract({
      address: process.env.MODULE_ADDRESS, abi: artifact.abi, functionName: "dailySpend", args: [BigInt(day)],
    });
    console.log(`  -> dailySpend[${day}] = ${daySum} (asteptat: ${TX_AMOUNT * 2n})`);
  }

  const lastDay = startDay + 4;
  const expected = TX_AMOUNT * 2n * 5n;

  let weekTotal;
  for (let attempt = 1; attempt <= 4; attempt++) {
    weekTotal = await publicClient.readContract({
      address: process.env.MODULE_ADDRESS, abi: artifact.abi, functionName: "getWeeklyTotal", args: [BigInt(lastDay)],
    });
    if (weekTotal === expected) break;
    if (attempt < 4) {
      console.log(`(citire ${attempt}: ${weekTotal} wei, RPC nu a sincronizat inca — reincerc in 3s...)`);
      await new Promise((r) => setTimeout(r, 3000));
    }
  }

  console.log(`\n=== REZULTAT ===`);
  console.log(`getWeeklyTotal(${lastDay}) = ${weekTotal} wei`);
  console.log(`Asteptat (10 tranzactii x 1000 wei) = ${expected} wei`);
  console.log(weekTotal === expected ? "\n CORECT — toate cele 10 tranzactii sunt acumulate corect!" : "\n GRESIT — verifica manual cu scripts/limits/check_limits.js");
}

main().catch((err) => { console.error(err.message); process.exit(1); });
