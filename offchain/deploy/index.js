// deploy: the whole system on the local node, written to deployments/local.json.
// The market, the gate, and one smart account and prosumer contract per
// prosumer in prosumers.json.
//
// No database: every address is written to deployments/local.json, and every
// link between them is also on chain (MarketManager.prosumerOf(account),
// Prosumer.owner(), MiniAccount.sessionOf(agent)).

import fs from "node:fs";
import path from "node:path";
import {
  ROOT, DEPLOYMENT_FILE, key, deploy, send, read, selector, calldata as encode, now, saveDeployment, price, USD, usd,
} from "../chain/index.js";
import { agentPolicyInstances } from "./policies.js";
import { breakerConfigOf, encodeBreakerConfig } from "./breaker.js";

export const DEFAULT_CONFIG = new URL("./prosumers.json", import.meta.url);

// Key indexes of the public test mnemonic. Prosumers take three each from 3 on.
const OPERATOR = 0;
const MATCHER = 1;
const KEEPER = 2;
// The oracles (step 5): the relay posts, funded; the forecast provider and
// each prosumer's BMS only sign, so their keys are past the funded twenty.
const RELAY = 18;
const PV_PROVIDER = 19;
// The retailer that signs the tariff (v0.2 step 3); it only signs.
const TARIFF_PROVIDER = 21;
// The DSO that signs the operating envelope (v0.2 step 6); it only signs.
const DSO = 22;
const bmsKeyOf = (i) => 40 + i;
// Each agent house's meter (v0.2 step 5, for S9): a signer of its own,
// distinct from the BMS, the forecast and the agent (spec v0.2 section 4).
const meterKeyOf = (i) => 50 + i;
// `ReadingKind` in OracleVerifier.
const BMS = 0;
const PV_FORECAST = 1;
const TARIFF = 2;
const ENVELOPE = 4;
// How old a reading may be when accepted: the BMS one slot (spec 5.4,
// tau_soc), the forecast one hour (tau_pv).
const PV_MAX_AGE = 3600;
// A day-ahead tariff holds for a day (spec v0.2 section 4); so does the DSO's
// envelope.
const TARIFF_MAX_AGE = 86_400;
const ENVELOPE_MAX_AGE = 86_400;
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
  log(`            slots of ${config.slotSeconds} s, real-time price ${usd(realTimePrice)} per kWh`);

  // --- the enforcement layer -----------------------------------------------
  const ledger = await deploy(OPERATOR, "PositionLedger");
  const oracle = await deploy(OPERATOR, "OracleVerifier");
  const gate = await deploy(OPERATOR, "PolicyGate", [ledger, oracle, BigInt(config.maxLegs)]);
  const decoder = await deploy(OPERATOR, "ProsumerDecoder");
  const policyContracts = {
    statics: await deploy(OPERATOR, "StaticOrderPolicy", [gate]),
    windows: await deploy(OPERATOR, "WindowPolicy", [gate]),
    quota: await deploy(OPERATOR, "CancelQuotaPolicy", [gate]),
    deliverability: await deploy(OPERATOR, "DeliverabilityPolicy", [gate]),
    cycles: await deploy(OPERATOR, "CyclePolicy", [gate]),
    ramp: await deploy(OPERATOR, "RampPolicy", [gate]),
    dominated: await deploy(OPERATOR, "DominatedTradePolicy", [gate]),
    roundTrip: await deploy(OPERATOR, "RoundTripPolicy", [gate]),
    delivery: await deploy(OPERATOR, "DeliveryReconciliationPolicy", [gate]),
    envelope: await deploy(OPERATOR, "OperatingEnvelopePolicy", [gate]),
  };
  log(`gate        ${gate}  (ledger ${ledger}, oracle ${oracle}, decoder ${decoder})`);
  log(`policies    per-action ${policyContracts.statics}, windows ${policyContracts.windows}, quota ${policyContracts.quota}`);
  log(`            deliverability ${policyContracts.deliverability}, cycles ${policyContracts.cycles}, ramp ${policyContracts.ramp}\n`);

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
    await send(OPERATOR, token, "LockableERC1155", "mintPayment", [account, BigInt(p.fundsUSD) * USD]);

    // Owner path: the account lets its prosumer contract lock collateral and
    // move its energy tokens.
    const asAccount = (target, contract, fn, args) =>
      send(roles.owner, account, "MiniAccount", "execute", [target, 0n, encode(contract, fn, args)]);
    await asAccount(token, "LockableERC1155", "setPaymentAllowance", [prosumer, MAX_UINT]);
    await asAccount(token, "LockableERC1155", "setApprovalForAll", [prosumer, true]);

    const entry = {
      account,
      prosumer,
      // Whose data plays this house (data/homes/), its battery, and whether
      // that battery replays an honest arm (data/arms/) or follows the simple
      // model from the home's initial charge.
      home: p.home,
      battery: p.battery ?? null,
      replay: p.replay ?? null,
      owner: { address: owner, keyIndex: roles.owner },
      sensor: { address: sensor, keyIndex: roles.sensor },
    };

    if (p.agent) {
      // Owner path: install the gate, appoint it ledger writer, give the agent
      // a session that may have the account call the gate's submit and nothing
      // else (decision D1), and approve the four order functions of the
      // prosumer contract.
      const agent = key(roles.agent).address;
      await send(roles.owner, account, "MiniAccount", "installModule", [EXECUTOR_MODULE, gate, "0x"]);
      await asAccount(ledger, "PositionLedger", "setWriter", [gate, true]);
      await send(roles.owner, account, "MiniAccount", "enableSession", [agent, gate, selector("PolicyGate", "submit"), validUntil]);
      for (const sel of orderFunctions) {
        await asAccount(gate, "PolicyGate", "setDecoder", [prosumer, sel, decoder]);
      }
      entry.agent = { address: agent, keyIndex: roles.agent, validUntil: Number(validUntil) };

      // Owner path: the devices whose signed readings the policies trust
      // (step 5): the house's BMS, and the PV forecast provider.
      const bms = key(bmsKeyOf(i)).address;
      await asAccount(oracle, "OracleVerifier", "setDevice", [BMS, bms, config.slotSeconds]);
      await asAccount(oracle, "OracleVerifier", "setDevice", [PV_FORECAST, key(PV_PROVIDER).address, PV_MAX_AGE]);
      await asAccount(oracle, "OracleVerifier", "setDevice", [TARIFF, key(TARIFF_PROVIDER).address, TARIFF_MAX_AGE]);
      await asAccount(oracle, "OracleVerifier", "setDevice", [ENVELOPE, key(DSO).address, ENVELOPE_MAX_AGE]);
      entry.bms = { address: bms, keyIndex: bmsKeyOf(i) };
      // The house's meter, on the market's slot grid, for S9 (v0.2 step 5).
      const meter = key(meterKeyOf(i)).address;
      await asAccount(oracle, "OracleVerifier", "setMeter", [meter, config.slotSeconds]);
      entry.meter = { address: meter, keyIndex: meterKeyOf(i) };

      // Owner path: the session circuit breaker G1 (v0.2 step 2), when the
      // configuration names one. It is opt-in, like every policy.
      if (config.agentPolicies.breaker) {
        const breaker = encodeBreakerConfig(breakerConfigOf(config.agentPolicies.breaker));
        await asAccount(gate, "PolicyGate", "setBreakerConfig", [breaker]);
      }

      // Owner path: the policies the agent trades under (step 4).
      entry.policies = [];
      // "omit" names instances left out, for runs that study the others.
      const omit = new Set(config.agentPolicies.omit ?? []);
      for (const instance of agentPolicyInstances(config.agentPolicies, { battery: p.battery, slotSeconds: config.slotSeconds })) {
        if (omit.has(instance.name)) continue;
        const policy = policyContracts[instance.contract];
        await asAccount(gate, "PolicyGate", "addPolicy", [policy, instance.id, instance.config]);
        entry.policies.push({ name: instance.name, policy, id: instance.id });
      }
    }

    prosumers[p.name] = entry;
    const linked = await read(manager, "MarketManager", "prosumerOf", [account]);
    log(
      `${p.name.padEnd(11)} account ${account}  prosumer ${prosumer}` +
        (p.agent ? `  agent ${entry.agent.address}, ${entry.policies.length} policies` : "  (no agent)"),
    );
    if (linked.toLowerCase() !== prosumer.toLowerCase()) throw new Error(`prosumerOf(${p.name}) does not point at its prosumer contract`);
  }

  const deployment = {
    network: "hardhat-local",
    chainId: 31337,
    deployedAt: new Date().toISOString(),
    slotSeconds: config.slotSeconds,
    dataDate: config.dataDate,
    realTimePrice: realTimePrice.toString(),
    contracts: { token, rule, manager, ledger, oracle, gate, decoder, ...policyContracts },
    roles: {
      operator: { address: key(OPERATOR).address, keyIndex: OPERATOR },
      matcher: { address: key(MATCHER).address, keyIndex: MATCHER },
      keeper: { address: key(KEEPER).address, keyIndex: KEEPER },
    },
    oracles: {
      relay: { address: key(RELAY).address, keyIndex: RELAY },
      pvProvider: { address: key(PV_PROVIDER).address, keyIndex: PV_PROVIDER },
      tariffProvider: { address: key(TARIFF_PROVIDER).address, keyIndex: TARIFF_PROVIDER },
      tariffMaxAge: TARIFF_MAX_AGE,
      dso: { address: key(DSO).address, keyIndex: DSO },
      envelopeMaxAge: ENVELOPE_MAX_AGE,
      bmsMaxAge: config.slotSeconds,
      pvMaxAge: PV_MAX_AGE,
      // The forecast covers the physical policies' horizon.
      horizonSlots: config.agentPolicies.physical?.horizonSlots ?? 0,
    },
    prosumers,
  };
  saveDeployment(deployment);
  log(`\nWritten: ${path.relative(ROOT, DEPLOYMENT_FILE)}`);
  return deployment;
}
