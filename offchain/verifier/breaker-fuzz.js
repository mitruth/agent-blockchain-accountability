// Random histories for G1, the session circuit breaker, run on a chain: an
// account whose submissions a scripted policy rejects, flags or lets through
// at random, with waits of seconds to hours, owner reinstatements and
// configuration changes in between. Seeded, so a disagreement can be
// replayed.
//
// Each transaction's receipt becomes one event of the verifier's history
// (breaker.js), from the gate's and the breaker's events alone.

import { decodeAbiParameters } from "viem";
import { publicClient, deploy, read, events, calldata, selector, key, wallet, abi } from "../chain/index.js";
import { BREAKER_CONFIG, encodeBreakerConfig } from "../deploy/breaker.js";

const OWNER = 0;
const AGENT = 1;
const KEEPER = 2;
const EXECUTOR = 2n;
const EXECUTE = 0;
const FLAG = 1;
const REJECT = 2;
const OWNER_REINSTATEMENT = 0;

function generator(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Run `call` in a block with timestamp exactly `t`. */
async function at(t, call) {
  await publicClient.request({ method: "evm_setNextBlockTimestamp", params: [t] });
  return call();
}

/**
 * Send without simulating first. A simulation, and a gas estimate, run at the
 * latest block's time, not at the time set for the next block: a call whose
 * path depends on the time (a timelock, a cooldown) would be judged a step
 * early. So the gas is fixed instead, and a revert is read from the receipt.
 */
async function send(from, address, contract, functionName, args = []) {
  const hash = await wallet(from).writeContract({ address, abi: abi(contract), functionName, args, gas: 15_000_000n });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${contract}.${functionName} reverted at ${await blockTime(receipt)}`);
  return receipt;
}

async function blockTime(receipt) {
  return Number((await publicClient.getBlock({ blockNumber: receipt.blockNumber })).timestamp);
}

const sliding = (step, buckets, cap) => ({ kind: 0, step, buckets, anchor: 0, cap: BigInt(cap), rate: 0n, initial: 0n });

function randomConfig(int) {
  return {
    rejects: sliding([60, 300][int(2)], [6, 12][int(2)], int(6)),
    flags: sliding([600, 3600][int(2)], [6, 24][int(2)], int(8)),
    cooldownSeconds: [0, 0, 300, 1800][int(4)],
  };
}

/** The verifier's form of a SessionBreaker.Config, from the event's bytes. */
export function toBreakerConfig(bytes) {
  if (bytes === "0x") return null;
  const [c] = decodeAbiParameters([BREAKER_CONFIG], bytes);
  const shape = (w) => ({ step: Number(w.step), buckets: Number(w.buckets), cap: Number(w.cap) });
  return { rejects: shape(c.rejects), flags: shape(c.flags), cooldownSeconds: Number(c.cooldownSeconds) };
}

/** Run `seeds` × `steps`; returns the history, in the verifier's form. */
export async function runBreakerScenarios({ seeds = 4, steps = 120, firstSeed = 1 } = {}) {
  const ledger = await deploy(OWNER, "PositionLedger");
  const oracle = await deploy(OWNER, "OracleVerifier");
  const gate = await deploy(OWNER, "PolicyGate", [ledger, oracle, 48n]);
  const breaker = await read(gate, "PolicyGate", "breaker");
  const market = await deploy(OWNER, "ProbeMarket");
  const decoder = await deploy(OWNER, "ProbeDecoder");
  const policy = await deploy(OWNER, "ScriptedPolicy");
  const account = await deploy(OWNER, "MiniAccount", [key(OWNER).address]);

  const asAccount = (target, contract, fn, args) =>
    send(OWNER, account, "MiniAccount", "execute", [target, 0n, calldata(contract, fn, args)]);
  await send(OWNER, account, "MiniAccount", "installModule", [EXECUTOR, gate, "0x"]);
  await asAccount(ledger, "PositionLedger", "setWriter", [gate, true]);
  await send(OWNER, account, "MiniAccount", "enableSession", [key(AGENT).address, gate, selector("PolicyGate", "submit"), 2n ** 47n]);
  await asAccount(gate, "PolicyGate", "setDecoder", [market, selector("ProbeMarket", "order"), decoder]);
  await asAccount(gate, "PolicyGate", "addPolicy", [policy, `0x${"11".repeat(32)}`, "0x"]);

  const history = [];
  const configEvents = (receipt, t) => {
    for (const e of events(receipt, "SessionBreaker", "BreakerConfigApplied")) {
      history.push({ type: "config", at: t, config: toBreakerConfig(e.args.config) });
    }
  };

  const block = await publicClient.getBlock();
  let t = Number(block.timestamp) + 10;
  const STEP = 2;
  const order = calldata("ProbeMarket", "order", []);

  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    const rand = generator(seed);
    const int = (n) => Math.floor(rand() * n);
    t += STEP;
    configEvents(await at(t, () => asAccount(gate, "PolicyGate", "setBreakerConfig", [encodeBreakerConfig(randomConfig(int))])), t);

    for (let i = 0; i < steps; i++) {
      const wait = int(20);
      t += STEP + (wait < 12 ? int(60) : wait < 18 ? int(900) : int(7200));
      const op = int(40);

      if (op === 0) {
        // The owner reinstates, if there is anything to lift.
        const state = await read(breaker, "SessionBreaker", "stateOf", [account, 1n]);
        if (!state.suspended) continue;
        const receipt = await at(t, () => asAccount(gate, "PolicyGate", "reinstate", []));
        for (const e of events(receipt, "SessionBreaker", "AgentReinstated")) {
          if (Number(e.args.how) === OWNER_REINSTATEMENT) history.push({ type: "reinstate", at: t });
        }
        continue;
      }
      if (op === 1) {
        // A new configuration: applied at once if it tightens, else queued and
        // applied a day later.
        const encoded = encodeBreakerConfig(randomConfig(int));
        const receipt = await at(t, () => asAccount(gate, "PolicyGate", "setBreakerConfig", [encoded]));
        configEvents(receipt, t);
        if (events(receipt, "SessionBreaker", "BreakerConfigProposed").length) {
          t += 86_400;
          configEvents(await at(t, () => asAccount(gate, "PolicyGate", "applyBreakerConfig", [encoded])), t);
        }
        continue;
      }

      const r = int(4);
      const verdict = r < 2 ? EXECUTE : r === 2 ? FLAG : REJECT;
      await at(t, () => send(OWNER, policy, "ScriptedPolicy", "setVerdict", [account, verdict]));
      t += STEP;
      const submit = calldata("PolicyGate", "submit", [market, order, []]);
      const receipt = await at(t, () => send(AGENT, account, "MiniAccount", "executeAsSession", [gate, submit]));

      const suspended = events(receipt, "SessionBreaker", "AgentSuspended")[0];
      const reinstated = events(receipt, "SessionBreaker", "AgentReinstated")[0];
      history.push({
        type: "submission",
        at: t,
        rejected: events(receipt, "PolicyGate", "Rejected").length > 0,
        flagged: events(receipt, "PolicyGate", "PolicyFlag").length > 0,
        reinstated: reinstated ? "AUTO" : null,
        suspended: suspended
          ? { reason: Number(suspended.args.reason), rejectsUsed: Number(suspended.args.rejectsUsed), flagsUsed: Number(suspended.args.flagsUsed) }
          : null,
      });

      // An executed order is closed at once, so the open-order bound never binds.
      for (const e of events(receipt, "PositionLedger", "OrderOpened")) {
        t += STEP;
        await at(t, () => send(KEEPER, gate, "PolicyGate", "reconcile", [account, market, e.args.orderId]));
      }
    }
  }
  return history;
}
