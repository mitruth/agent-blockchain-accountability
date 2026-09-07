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
  console.log(`  Zi ${dayIndex} raportata: ${amountWei} wei`);
}

async function main() {
  const { account, walletClient, publicClient } = createClients();

  const AMOUNT = 1000n;

  console.log("=== TEST GAP: 6 zile tranzactii, 5 zile pauza, apoi raport dupa gap ===\n");

  let nonce = await publicClient.getTransactionCount({ address: account.address });

  const lastReportedDay = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS, abi: artifact.abi, functionName: "lastReportedDay",
  });
  const startDay = Number(lastReportedDay) + 1;
  const lastOfBlock = startDay + 5;
  const dayAfterGap = startDay + 11;

  console.log(`Continuam de la ziua ${startDay} (ultima raportata a fost ${lastReportedDay})\n`);

  console.log(`Raportare zile ${startDay}-${lastOfBlock} (6 zile consecutive):`);
  for (let d = startDay; d <= lastOfBlock; d++) {
    await reportDay(walletClient, publicClient, d, AMOUNT, nonce++);
  }

  console.log(`\n(zilele ${lastOfBlock + 1}-${dayAfterGap - 1} NU sunt raportate — gap de 5 zile)`);

  console.log(`\nRaportare zi ${dayAfterGap} (dupa gap):`);
  await reportDay(walletClient, publicClient, dayAfterGap, AMOUNT, nonce++);

  const weeklyTotal = await publicClient.readContract({
    address: process.env.MODULE_ADDRESS,
    abi: artifact.abi,
    functionName: "getWeeklyTotal",
    args: [BigInt(dayAfterGap)],
  });

  const expected = 2000n;

  console.log("\n=== REZULTAT ===");
  console.log(`getWeeklyTotal(${dayAfterGap}) =`, weeklyTotal.toString(), "wei");
  console.log(`Asteptat: doar ziua ${lastOfBlock} (1000) + ziua ${dayAfterGap} (1000) = ${expected} wei`);
  console.log("NU 6000 (daca ar fi numarat toate cele 6 zile vechi)");
  console.log(weeklyTotal === expected ? "\n✅ CORECT — gap-ul e tratat corect!" : "\n❌ GRESIT (posibil citire RPC intarziata — reincearca peste cateva secunde)");
}

main().catch((err) => { console.error(err.message); process.exit(1); });
