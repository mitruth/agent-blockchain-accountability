// Random histories for S10, run on a chain: one account on two ProbeMarkets on
// one slot grid, placements on both sides of a few slots near now,
// cancellations and modifications through the gate, partial fills and keeper
// releases, and DSO envelopes posted at random (full or short schedules, some
// left to go stale), with waits of seconds to two days. Seeded, so a
// disagreement can be replayed.
//
// Each receipt becomes events of the verifier's history (envelope.js), from
// the gate's, the ledger's and the oracle's events alone.

import { decodeAbiParameters, encodeAbiParameters } from "viem";
import { publicClient, deploy, events, calldata, selector, key, wallet, abi } from "../chain/index.js";
import { signEnvelope, TYPES } from "../oracle/typed.js";

const OWNER = 0;
const AGENT = 1;
const KEEPER = 2;
const DSO = 22;
const EXECUTOR = 2n;
const SLOT = 1800;
const ENVELOPE_KIND = 4;
const ENVELOPE_KIND_ENUM = 4;

export const ENVELOPE_CONFIG = { connectionW: 4_000, softBps: 9_000, slotSeconds: SLOT, origin: 0, maxAge: 6 * 3600 };

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

const CONFIG = { type: "tuple", components: [{ name: "connectionW", type: "uint32" }, { name: "softBps", type: "uint16" }] };

function ledgerEvents(receipt, ledger) {
  const out = [];
  for (const log of events(receipt, "PositionLedger")) {
    if (log.address.toLowerCase() !== ledger.toLowerCase()) continue;
    const a = log.args;
    const base = { block: log.blockNumber, account: a.account, market: a.market, orderId: a.orderId };
    if (log.eventName === "OrderOpened") out.push({ ...base, type: "opened", side: Number(a.side), slot: Number(a.slot), qtyWh: a.qtyWh });
    else if (log.eventName === "FillBooked") out.push({ ...base, type: "fill", filledWh: a.filledWh, totalFilledWh: a.totalFilledWh });
    else if (log.eventName === "OrderClosed") out.push({ ...base, type: "closed", releasedWh: a.releasedWh });
  }
  return out;
}

/** Run `seeds` x `steps`; returns the history, in the verifier's form. */
export async function runEnvelopeScenarios({ seeds = 3, steps = 200, firstSeed = 1 } = {}) {
  const chainId = await publicClient.getChainId();
  const ledger = await deploy(OWNER, "PositionLedger");
  const oracle = await deploy(OWNER, "OracleVerifier");
  const gate = await deploy(OWNER, "PolicyGate", [ledger, oracle, 48n]);
  const markets = [await deploy(OWNER, "ProbeMarket"), await deploy(OWNER, "ProbeMarket")];
  const decoder = await deploy(OWNER, "ProbeDecoder");
  const s10 = await deploy(OWNER, "OperatingEnvelopePolicy", [gate]);
  const account = await deploy(OWNER, "MiniAccount", [key(OWNER).address]);

  const asAccount = (target, contract, fn, args) =>
    send(OWNER, account, "MiniAccount", "execute", [target, 0n, calldata(contract, fn, args)]);
  await send(OWNER, account, "MiniAccount", "installModule", [EXECUTOR, gate, "0x"]);
  await asAccount(ledger, "PositionLedger", "setWriter", [gate, true]);
  await send(OWNER, account, "MiniAccount", "enableSession", [key(AGENT).address, gate, selector("PolicyGate", "submit"), 2n ** 47n]);
  for (const market of markets) {
    for (const fn of ["place", "cancel", "replace"]) {
      await asAccount(gate, "PolicyGate", "setDecoder", [market, selector("ProbeMarket", fn), decoder]);
    }
  }
  await asAccount(oracle, "OracleVerifier", "setDevice", [ENVELOPE_KIND_ENUM, key(DSO).address, ENVELOPE_CONFIG.maxAge]);
  await asAccount(gate, "PolicyGate", "addPolicy", [s10, `0x${"10".repeat(32)}`, encodeAbiParameters([CONFIG], [{
    connectionW: ENVELOPE_CONFIG.connectionW, softBps: ENVELOPE_CONFIG.softBps,
  }])]);

  const history = [];
  const open = []; // { market, orderId, qtyWh, side, slot }
  let t = Number((await publicClient.getBlock()).timestamp) + 10;
  const STEP = 2;

  const submit = async (market, call) => {
    const sub = calldata("PolicyGate", "submit", [market, call, []]);
    const receipt = await at(t, () => send(AGENT, account, "MiniAccount", "executeAsSession", [gate, sub]));
    const submitted = events(receipt, "PolicyGate", "OrderSubmitted")[0];
    const r = events(receipt, "PolicyGate", "PolicyResult").find((x) => x.args.policy.toLowerCase() === s10.toLowerCase()).args.result;
    history.push({
      type: "submission", at: t, account,
      legs: submitted.args.legs.map((l) => ({ kind: Number(l.kind), side: Number(l.side), slot: Number(l.slot), qtyWh: l.qtyWh })),
      s10: { verdict: Number(r.verdict), valueBefore: r.valueBefore, valueAfter: r.valueAfter, soft: r.soft, hard: r.hard },
      executed: events(receipt, "PolicyGate", "Executed").length > 0,
    });
    const ledgerLogs = ledgerEvents(receipt, ledger);
    history.push(...ledgerLogs);
    return ledgerLogs.filter((e) => e.type === "opened");
  };

  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    const rand = generator(seed);
    const int = (n) => Math.floor(rand() * n);

    for (let i = 0; i < steps; i++) {
      const wait = int(20);
      t += STEP + (wait < 12 ? int(600) : wait < 19 ? int(4 * 3600) : int(2 * 86_400));
      const base = Math.floor(t / SLOT) + 2;
      const op = open.length >= 40 ? 7 : int(12);

      if (op <= 1) {
        // An envelope from the current slot: mostly full, sometimes short.
        const first = Math.floor(t / SLOT) * SLOT;
        const n = int(3) === 0 ? 1 + int(8) : 12;
        const exportLimitWh = [];
        const importLimitWh = [];
        for (let k = 0; k < n; k++) {
          exportLimitWh.push(BigInt(int(4) === 0 ? 0 : int(2500)));
          importLimitWh.push(BigInt(int(2500)));
        }
        const signed = await signEnvelope(DSO, chainId, oracle, { account, issuedAt: t, firstSlotStart: first, slotSeconds: SLOT, exportLimitWh, importLimitWh });
        const receipt = await at(t, () => send(KEEPER, oracle, "OracleVerifier", "accept", [signed]));
        for (const e of events(receipt, "OracleVerifier", "ReadingAccepted")) {
          if (Number(e.args.kind) !== ENVELOPE_KIND) continue;
          const [s] = decodeAbiParameters([{ type: "tuple", components: TYPES.Envelope }], e.args.data);
          history.push({
            type: "envelope", issuedAt: Number(s.issuedAt), firstSlotStart: Number(s.firstSlotStart), slotSeconds: Number(s.slotSeconds),
            exportLimitWh: [...s.exportLimitWh], importLimitWh: [...s.importLimitWh],
          });
        }
        continue;
      }
      if (op <= 3 && open.length) {
        const [o] = open.splice(int(open.length), 1);
        await submit(o.market, calldata("ProbeMarket", "cancel", [o.orderId]));
        continue;
      }
      if (op <= 4 && open.length) {
        const k = int(open.length);
        const o = open[k];
        const qtyWh = BigInt(1 + int(2000));
        const opened = await submit(o.market, calldata("ProbeMarket", "replace", [o.orderId, o.side, o.slot, qtyWh, 100_000n]));
        if (opened.length) {
          open.splice(k, 1);
          open.push({ ...o, orderId: opened[0].orderId, qtyWh });
        }
        continue;
      }
      if (op <= 7 && open.length) {
        const [o] = open.splice(int(open.length), 1);
        const filled = BigInt(int(Number(o.qtyWh) + 1));
        await at(t, () => send(OWNER, o.market, "ProbeMarket", "setFilled", [o.orderId, filled]));
        t += STEP;
        const receipt = await at(t, () => send(KEEPER, gate, "PolicyGate", "reconcile", [account, o.market, o.orderId]));
        history.push(...ledgerEvents(receipt, ledger));
        continue;
      }
      const side = int(2);
      const slot = base + int(4);
      const qtyWh = BigInt(1 + int(2000));
      const market = markets[int(2)];
      const opened = await submit(market, calldata("ProbeMarket", "place", [side, slot, qtyWh, 100_000n]));
      if (opened.length) open.push({ market, orderId: opened[0].orderId, qtyWh, side, slot });
    }
  }
  return history;
}
