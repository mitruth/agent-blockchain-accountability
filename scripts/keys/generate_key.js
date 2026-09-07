import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const privateKey = generatePrivateKey();
const account = privateKeyToAccount(privateKey);

console.log("=== CHEIE NOUA GENERATA ===");
console.log("PRIVATE_KEY=" + privateKey);
console.log("Adresa publica:", account.address);
console.log("\nCopiaza PRIVATE_KEY in .env");
console.log("Trimite ETH de test la:", account.address);
