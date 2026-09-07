import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const privateKey = generatePrivateKey();
const account = privateKeyToAccount(privateKey);

console.log("=== ADRESA DESTINATIE GENERATA ===");
console.log("Adresa:", account.address);
console.log("\nCopiaza in .env:");
console.log(`DESTINATION_ADDRESS=${account.address}`);
console.log("\n(Cheia privata nu e necesara — aceasta adresa doar primeste fonduri)");
