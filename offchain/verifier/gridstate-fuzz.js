// Random histories for A10, run on a chain: one account on a ProbeMarket,
// placements on both sides of slots from just ended to a day ahead,
// cancellations and modifications through the gate, and grid states posted
// at random, by the account's operator and by another signer: every level
// and direction, horizons of 0 to 30 slots, validity of seconds to hours,
// with waits of seconds to half a day. Seeded, so a disagreement can be
// replayed.

import { decodeAbiParameters, encodeAbiParameters } from "viem";
import { publicClient, deploy, events, calldata, selector, key, wallet, abi } from "../chain/index.js";
import { signGridState, TYPES } from "../oracle/typed.js";

const OWNER = 0;
const AGENT = 1;
const KEEPER = 2;
const OPERATOR = 23;
const OTHER = 24;
const EXECUTOR = 2n;
const SLOT = 1800;
const GRID_KIND = 5;

export const GRID_CONFIG = { operator: key(OPERATOR).address, minLevel: 1, origin: 0, slotSeconds: SLOT };

function generator(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

async function at(t, call) {
  await publicClient.request({ method: "evm_setNextBlockTimestamp", params: [t] });
  return call();
}

/** Sent with a fixed gas limit, without simulation: see breaker-fuzz.js. */
async function send(from, address, contract, functionName, args = []) {
  const hash = await wallet(from).writeContract({ address, abi: abi(contract), functionName, args, gas: 15_000_000n });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${contract}.${functionName} reverted`);
  return receipt;
}

/** Run `seeds` x `steps`; returns the history, in the verifier's form. */
export async function runGridStateScenarios({ seeds = 3, steps = 200, firstSeed = 1 } = {}) {
  const chainId = await publicClient.getChainId();
  const ledger = await deploy(OWNER, "PositionLedger");
  const oracle = await deploy(OWNER, "OracleVerifier");
  const gate = await deploy(OWNER, "PolicyGate", [ledger, oracle, 48n]);
  const market = await deploy(OWNER, "ProbeMarket");
  const decoder = await deploy(OWNER, "ProbeDecoder");
  const a10 = await deploy(OWNER, "GridStatePolicy", [gate]);
  const account = await deploy(OWNER, "MiniAccount", [key(OWNER).address]);

  const asAccount = (target, contract, fn, args) =>
    send(OWNER, account, "MiniAccount", "execute", [target, 0n, calldata(contract, fn, args)]);
  await send(OWNER, account, "MiniAccount", "installModule", [EXECUTOR, gate, "0x"]);
  await asAccount(ledger, "PositionLedger", "setWriter", [gate, true]);
  await send(OWNER, account, "MiniAccount", "enableSession", [key(AGENT).address, gate, selector("PolicyGate", "submit"), 2n ** 47n]);
  for (const fn of ["place", "cancel", "replace"]) {
    await asAccount(gate, "PolicyGate", "setDecoder", [market, selector("ProbeMarket", fn), decoder]);
  }
  await asAccount(oracle, "OracleVerifier", "setDevice", [GRID_KIND, key(OPERATOR).address, 0]);
  await asAccount(gate, "PolicyGate", "addPolicy", [a10, `0x${"a1".repeat(32)}`, encodeAbiParameters(
    [{ type: "tuple", components: [{ name: "minLevel", type: "uint8" }] }], [{ minLevel: GRID_CONFIG.minLevel }],
  )]);

  const history = [];
  const open = []; // { orderId, side, slot, qtyWh }
  let t = Number((await publicClient.getBlock()).timestamp) + 10;
  const STEP = 2;

  const submit = async (call) => {
    const sub = calldata("PolicyGate", "submit", [market, call, []]);
    const receipt = await at(t, () => send(AGENT, account, "MiniAccount", "executeAsSession", [gate, sub]));
    const submitted = events(receipt, "PolicyGate", "OrderSubmitted")[0];
    const r = events(receipt, "PolicyGate", "PolicyResult").find((x) => x.args.policy.toLowerCase() === a10.toLowerCase()).args.result;
    history.push({
      type: "submission", at: t,
      legs: submitted.args.legs.map((l) => ({ kind: Number(l.kind), side: Number(l.side), slot: Number(l.slot), qtyWh: l.qtyWh })),
      a10: { verdict: Number(r.verdict), valueBefore: r.valueBefore, valueAfter: r.valueAfter, soft: r.soft, hard: r.hard },
      executed: events(receipt, "PolicyGate", "Executed").length > 0,
    });
    return events(receipt, "PositionLedger", "OrderOpened");
  };

  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    const rand = generator(seed);
    const int = (n) => Math.floor(rand() * n);

    for (let i = 0; i < steps; i++) {
      const wait = int(20);
      t += STEP + (wait < 14 ? int(900) : wait < 19 ? int(3 * 3600) : int(12 * 3600));
      const cur = Math.floor(t / SLOT);
      // With many orders open, post a state or cancel (a refused cancellation
      // stays open, so the states must keep coming for it to go).
      const op = open.length >= 40 ? int(5) : int(12);

      if (op <= 2) {
        const signer = int(5) === 0 ? OTHER : OPERATOR;
        const state = { issuedAt: t, validUntil: t + int(4 * 3600), level: int(3), direction: int(3), horizonSlots: int(31) };
        const signed = await signGridState(signer, chainId, oracle, state);
        const receipt = await at(t, () => send(KEEPER, oracle, "OracleVerifier", "accept", [signed]));
        for (const e of events(receipt, "OracleVerifier", "ReadingAccepted")) {
          if (Number(e.args.kind) !== GRID_KIND) continue;
          const [g] = decodeAbiParameters([{ type: "tuple", components: TYPES.GridState }], e.args.data);
          history.push({
            type: "grid", signer: e.args.signer, issuedAt: Number(g.issuedAt), validUntil: Number(g.validUntil),
            level: Number(g.level), direction: Number(g.direction), horizonSlots: Number(g.horizonSlots),
          });
        }
        continue;
      }
      if (op <= 4 && open.length) {
        const [o] = open.splice(int(open.length), 1);
        const opened = await submit(calldata("ProbeMarket", "cancel", [o.orderId]));
        if (!history[history.length - 1].executed) open.push(o);
        void opened;
        continue;
      }
      if (op <= 5 && open.length) {
        const k = int(open.length);
        const o = open[k];
        const qtyWh = BigInt(1 + int(2000));
        const opened = await submit(calldata("ProbeMarket", "replace", [o.orderId, o.side, o.slot, qtyWh, 100_000n]));
        if (opened.length) {
          open.splice(k, 1);
          open.push({ ...o, orderId: opened[0].args.orderId, qtyWh });
        }
        continue;
      }
      const side = int(2);
      const slot = cur - 1 + int(25);
      const qtyWh = BigInt(1 + int(2000));
      const opened = await submit(calldata("ProbeMarket", "place", [side, slot, qtyWh, 100_000n]));
      if (opened.length) open.push({ orderId: opened[0].args.orderId, side, slot, qtyWh });
    }
  }
  return history;
}
