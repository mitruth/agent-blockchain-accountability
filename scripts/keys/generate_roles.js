// Generate the three keys the enforcement layer needs.
//
// The audited deployment used one EOA as both owner and agent, so the agent's
// own wallet could call setLimits. A policy an agent can raise is not delegated
// authority. These are three separate keys and they stay separate.
//
//   OWNER     policy authority. Writes PolicyConfig, sets the ledger writer
//             allowlist, installs and uninstalls modules, revokes the session
//             key, unpauses after the delay. Should be the only funded key that
//             matters; keep it off the agent's machine.
//   AGENT     the session key. Submits daily records through the validator and
//             nothing else. This is the key assumed to be reachable by an
//             attacker or by a prompt injection.
//   GUARDIAN  pauses spends and the agent. Changes no config value, cannot
//             unpause, cannot write the ledger.
//
// Usage: node scripts/keys/generate_roles.js

import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const ROLES = [
  ["OWNER", "policy authority: config, allowlist, modules, key revocation"],
  ["AGENT", "session key: submits daily records, nothing else"],
  ["GUARDIAN", "pause only: spends and agent"],
];

console.log("=== THREE KEYS GENERATED ===\n");

const lines = [];
for (const [role, description] of ROLES) {
  const privateKey = generatePrivateKey();
  const account = privateKeyToAccount(privateKey);
  console.log(`${role}  (${description})`);
  console.log(`  address: ${account.address}`);
  lines.push(`${role}_PRIVATE_KEY=${privateKey}`);
  lines.push(`${role}_ADDRESS=${account.address}`);
  lines.push("");
}

console.log("\n=== Copy into .env (NEVER commit it) ===\n");
console.log(lines.join("\n"));

console.log("Fund OWNER and AGENT with Base Sepolia ETH for gas.");
console.log("GUARDIAN needs gas only to pause.");
console.log("");
console.log("Do not reuse one key for two roles. The key separation is the");
console.log("property under test; collapsing it invalidates every enforcement");
console.log("result measured on the deployment.");
