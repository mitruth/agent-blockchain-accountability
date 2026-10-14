// deploy: the whole system on the local node, written to deployments/local.json.
// The market, the gate, and one smart account and prosumer contract per
// prosumer in prosumers.json.
//
// No database: every address is written to deployments/local.json, and every
// link between them is also on chain (MarketManager.prosumerOf(account),
// Prosumer.owner(), PolicyGate.agentValidUntil(account, agent)).

import fs from "node:fs";
import { key, deploy, send, read, selector, calldata as encode, now, saveDeployment, price, EUR, eur } from "../chain/index.js";

export const DEFAULT_CONFIG = new URL("./prosumers.json", import.meta.url);

// Key indexes of the public test mnemonic. Prosumers take three each from 3 on.
const OPERATOR = 0;
const MATCHER = 1;
const KEEPER = 2;
const EXECUTOR_MODULE = 2n;
const MAX_UINT = 2n ** 256n - 1n;

function rolesOf(i) {
  const base = 3 + 3 * i;
  return { owner: base, sensor: base + 1, agent: base + 2 };
}

export function loadConfig(file = DEFAULT_CONFIG) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

/** Deploy everything in `config`, write deployments/local.json, and return what was written. */
export async function deploySystem(config = loadConfig(), { log = console.log } = {}) {
  log("Deploying to the local Hardhat node\n");

  // --- the market --------------------------------------------------------
  const realTimePrice = price(config.realTimePricePerKWh);
  const token = await deploy(OPERATOR, "LockableERC1155", ["ENERGY_MARKET", ""]);
  const rule = await deploy(OPERATOR, "ClassicSettlement");
  const manager = await deploy(OPERATOR, "MarketManager", [token, config.slotSeconds, realTimePrice, rule]);
  await send(OPERATOR, token, "LockableERC1155", "setRegistrar", [manager]);
  await send(OPERATOR, manager, "MarketManager", "setMatcher", [key(MATCHER).address]);
  log(`market      manager ${manager}`);
  log(`            token   ${token}`);
  log(`            slots of ${config.slotSeconds} s, real-time price ${eur(realTimePrice)} per kWh`);

  // --- the enforcement layer -----------------------------------------------
  const ledger = await deploy(OPERATOR, "PositionLedger");
  const gate = await deploy(OPERATOR, "PolicyGate", [ledger, BigInt(config.maxLegs)]);
  const decoder = await deploy(OPERATOR, "ProsumerDecoder");
  log(`gate        ${gate}  (ledger ${ledger}, decoder ${decoder})\n`);

  const orderFunctions = ["placeBids", "placeOffers", "cancelOrder", "modifyOrder"].map((f) =>
    selector("Prosumer", f),
  );
  const validUntil = BigInt((await now()) + config.agentValidityDays * 86400);

  // --- the prosumers -----------------------------------------------------
  const prosumers = {};
  for (const [i, p] of config.prosumers.entries()) {
    const roles = rolesOf(i);
    const owner = key(roles.owner).address;
    const sensor = key(roles.sensor).address;

    // The owner's smart account, and the prosumer contract it owns.
    const account = await deploy(roles.owner, "MiniAccount", [owner]);
    const prosumer = await deploy(roles.owner, "Prosumer", [account, manager]);

    // The operator admits the prosumer with its sensor, and funds the account.
    await send(OPERATOR, manager, "MarketManager", "registerProsumer", [prosumer, sensor]);
    await send(OPERATOR, token, "LockableERC1155", "mintPayment", [account, BigInt(p.fundsEUR) * EUR]);

    // Owner path: the account lets its prosumer contract lock collateral and
    // move its energy tokens.
    const asAccount = (target, contract, fn, args) =>
      send(roles.owner, account, "MiniAccount", "execute", [target, 0n, encode(contract, fn, args)]);
    await asAccount(token, "LockableERC1155", "setPaymentAllowance", [prosumer, MAX_UINT]);
    await asAccount(token, "LockableERC1155", "setApprovalForAll", [prosumer, true]);

    const entry = {
      account,
      prosumer,
      owner: { address: owner, keyIndex: roles.owner },
      sensor: { address: sensor, keyIndex: roles.sensor },
    };

    if (p.agent) {
      // Owner path: install the gate, appoint it ledger writer, register the
      // agent, and approve the four order functions of the prosumer contract.
      const agent = key(roles.agent).address;
      await send(roles.owner, account, "MiniAccount", "installModule", [EXECUTOR_MODULE, gate, "0x"]);
      await asAccount(ledger, "PositionLedger", "setWriter", [gate, true]);
      await asAccount(gate, "PolicyGate", "registerAgent", [agent, validUntil]);
      for (const sel of orderFunctions) {
        await asAccount(gate, "PolicyGate", "setDecoder", [prosumer, sel, decoder]);
      }
      entry.agent = { address: agent, keyIndex: roles.agent, validUntil: Number(validUntil) };
    }

    prosumers[p.name] = entry;
    const linked = await read(manager, "MarketManager", "prosumerOf", [account]);
    log(
      `${p.name.padEnd(11)} account ${account}  prosumer ${prosumer}` +
        (p.agent ? `  agent ${entry.agent.address}` : "  (no agent)"),
    );
    if (linked.toLowerCase() !== prosumer.toLowerCase()) throw new Error(`prosumerOf(${p.name}) does not point at its prosumer contract`);
  }

  const deployment = {
    network: "hardhat-local",
    chainId: 31337,
    deployedAt: new Date().toISOString(),
    slotSeconds: config.slotSeconds,
    realTimePrice: realTimePrice.toString(),
    contracts: { token, rule, manager, ledger, gate, decoder },
    roles: {
      operator: { address: key(OPERATOR).address, keyIndex: OPERATOR },
      matcher: { address: key(MATCHER).address, keyIndex: MATCHER },
      keeper: { address: key(KEEPER).address, keyIndex: KEEPER },
    },
    prosumers,
  };
  saveDeployment(deployment);
  log("\nWritten: deployments/local.json");
  return deployment;
}
