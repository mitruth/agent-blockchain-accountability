// Random order histories for the ledger, across two markets and two accounts,
// run on a chain: placements, partial fills, cancellations, expiries and
// orders closed elsewhere, on a few slots so that the markets share them.
// After every ledger write the chain's position for the slot it touched is
// read, as a checkpoint for the verifier. Seeded, so a disagreement can be
// replayed.

import { deploy, send, read, key } from "../chain/index.js";

const DEPLOYER = 0;
const ACCOUNTS = [1, 2];
const MARKETS = ["0x00000000000000000000000000000000000000a1", "0x00000000000000000000000000000000000000b2"];
const SLOTS = 3;
const MAX_OPEN = 64;

/** mulberry32, as in fuzz.js. */
function generator(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const id = (n) => `0x${n.toString(16).padStart(64, "0")}`;

/**
 * Deploy a ledger and a scripted decoder, then run `steps` random writes for
 * each seed. Returns { ledger, checkpoints }.
 */
export async function runLedgerScenarios({ seeds = 4, steps = 80, firstSeed = 1 } = {}) {
  const ledger = await deploy(DEPLOYER, "PositionLedger");
  const decoder = await deploy(DEPLOYER, "LedgerProbeDecoder");
  const checkpoints = [];
  const open = []; // { who, account, market, orderId, slot, qty, filled }
  let next = 1n;

  for (const who of ACCOUNTS) {
    const account = key(who).address;
    await send(who, ledger, "PositionLedger", "setWriter", [account, true]);
    // Both markets share the half-hour grid: the second call is a check.
    await send(who, ledger, "PositionLedger", "fixGrid", [account, 0n, 1800]);
    await send(who, ledger, "PositionLedger", "fixGrid", [account, 0n, 1800]);
  }

  const checkpoint = async (receipt, account, slot) => {
    const position = await read(ledger, "PositionLedger", "positionOf", [account, slot]);
    checkpoints.push({ block: receipt.blockNumber, account, slot, position });
  };

  for (let seed = firstSeed; seed < firstSeed + seeds; seed++) {
    const rand = generator(seed);
    const int = (n) => Math.floor(rand() * n);

    for (let i = 0; i < steps; i++) {
      const op = int(10);
      if (op < 5 || open.length === 0) {
        const who = ACCOUNTS[int(ACCOUNTS.length)];
        const account = key(who).address;
        if (open.filter((o) => o.who === who).length >= MAX_OPEN) continue;
        const market = MARKETS[int(MARKETS.length)];
        const orderId = id(next++);
        const slot = int(SLOTS);
        const qty = BigInt(1 + int(2000));
        const leg = { kind: 0, side: int(2), slot, qtyWh: qty, price: 1n, value: 0n, orderId: id(0n) };
        const receipt = await send(who, ledger, "PositionLedger", "recordPlace", [account, market, decoder, orderId, leg]);
        open.push({ who, account, market, orderId, slot, qty, filled: 0n });
        await checkpoint(receipt, account, slot);
        continue;
      }

      const index = int(open.length);
      const o = open[index];
      let receipt;
      if (op < 7) {
        // A fill, partial or full.
        const filled = o.filled + BigInt(int(Number(o.qty - o.filled) + 1));
        await send(DEPLOYER, decoder, "LedgerProbeDecoder", "setFill", [o.market, o.orderId, filled, true, false]);
        o.filled = filled;
        receipt = await send(o.who, ledger, "PositionLedger", "reconcile", [o.account, o.market, o.orderId]);
        if (filled === o.qty) open.splice(index, 1);
      } else if (op < 8) {
        receipt = await send(o.who, ledger, "PositionLedger", "recordCancel", [o.account, o.market, o.orderId]);
        open.splice(index, 1);
      } else {
        // Expired, or closed elsewhere: the market no longer holds it open.
        const expired = op === 8;
        await send(DEPLOYER, decoder, "LedgerProbeDecoder", "setFill", [o.market, o.orderId, o.filled, false, expired]);
        receipt = await send(o.who, ledger, "PositionLedger", "reconcile", [o.account, o.market, o.orderId]);
        open.splice(index, 1);
      }
      await checkpoint(receipt, o.account, o.slot);
    }
  }
  return { ledger, checkpoints };
}
