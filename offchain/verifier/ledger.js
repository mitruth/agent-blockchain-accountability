// The position ledger, recomputed from its events alone (spec v0.2, C4).
//
// The contract keeps four running sums per (account, slot) and updates them
// in place. The verifier keeps none: it rebuilds every order an account
// placed, on any market, and sums the totals of a slot afresh over all of
// them whenever it is asked. So a sum the contract updates under the wrong
// key, for the wrong side, or not at all, shows up as a disagreement.
//
// Events, in log order, as `readLedgerEvents` gives them:
//
//   { type: "opened", block, account, market, orderId, side, slot, qtyWh }
//   { type: "fill",   block, account, market, orderId, filledWh, totalFilledWh }
//   { type: "closed", block, account, market, orderId, releasedWh }
//
// side: 0 BUY, 1 SELL. Quantities are BigInt.

import { publicClient, abi } from "../chain/index.js";

export const FIELDS = ["committedBuyWh", "committedSellWh", "clearedBuyWh", "clearedSellWh"];

const orderKey = (e) => `${e.account.toLowerCase()}|${e.market.toLowerCase()}|${e.orderId.toLowerCase()}`;

/**
 * Every order from the events, and anything in them that cannot be: an order
 * placed twice, a fill or close for an order not open, a running fill that
 * does not add up or passes the quantity, a release other than the unfilled
 * rest.
 */
export function replayLedger(events) {
  const orders = new Map();
  const problems = [];
  const problem = (event, what) => problems.push({ event, what });

  for (const e of events) {
    const k = orderKey(e);
    if (e.type === "opened") {
      if (orders.has(k)) problem(e, "placed twice");
      orders.set(k, {
        account: e.account.toLowerCase(),
        market: e.market.toLowerCase(),
        slot: Number(e.slot),
        side: Number(e.side),
        qtyWh: e.qtyWh,
        filledWh: 0n,
        releasedWh: null,
      });
      continue;
    }
    const o = orders.get(k);
    if (!o || o.releasedWh !== null) {
      problem(e, "not an open order");
      continue;
    }
    if (e.type === "fill") {
      if (o.filledWh + e.filledWh !== e.totalFilledWh) problem(e, "fill does not add up");
      if (e.totalFilledWh > o.qtyWh) problem(e, "filled beyond the quantity");
      o.filledWh = e.totalFilledWh;
    } else if (e.type === "closed") {
      if (e.releasedWh !== o.qtyWh - o.filledWh) problem(e, "released other than the unfilled rest");
      o.releasedWh = e.releasedWh;
    }
  }
  return { orders: [...orders.values()], problems };
}

/** An account's four totals for one slot, summed over every order on every market. */
export function positionAt(orders, account, slot) {
  const p = { committedBuyWh: 0n, committedSellWh: 0n, clearedBuyWh: 0n, clearedSellWh: 0n };
  const who = account.toLowerCase();
  for (const o of orders) {
    if (o.account !== who || o.slot !== Number(slot)) continue;
    const committed = o.releasedWh === null ? o.qtyWh : o.qtyWh - o.releasedWh;
    if (o.side === 0) {
      p.committedBuyWh += committed;
      p.clearedBuyWh += o.filledWh;
    } else {
      p.committedSellWh += committed;
      p.clearedSellWh += o.filledWh;
    }
  }
  return p;
}

/**
 * Compare the positions the chain reported at each checkpoint with the replay
 * of the events up to that block. A checkpoint is { block, account, slot,
 * position }. Returns { checked, disagreement }: the first disagreement, or
 * null.
 */
export function verifyLedger(events, checkpoints) {
  let checked = 0;
  let disagreement = null;
  for (const c of checkpoints) {
    const { orders, problems } = replayLedger(events.filter((e) => e.block <= c.block));
    if (problems.length > 0) disagreement ??= { ...problems[0], checkpoint: c };
    const mine = positionAt(orders, c.account, c.slot);
    for (const f of FIELDS) {
      checked++;
      if (mine[f] !== BigInt(c.position[f])) {
        disagreement ??= { what: f, chain: BigInt(c.position[f]), verifier: mine[f], checkpoint: c };
      }
    }
  }
  return { checked, disagreement };
}

/** The ledger's order events, in log order. */
export async function readLedgerEvents(address, { fromBlock = 0n } = {}) {
  const logs = await publicClient.getContractEvents({ address, abi: abi("PositionLedger"), fromBlock });
  const out = [];
  for (const log of logs) {
    const a = log.args;
    const base = { block: log.blockNumber, account: a.account, market: a.market, orderId: a.orderId };
    if (log.eventName === "OrderOpened") {
      out.push({ ...base, type: "opened", side: Number(a.side), slot: Number(a.slot), qtyWh: a.qtyWh });
    } else if (log.eventName === "FillBooked") {
      out.push({ ...base, type: "fill", filledWh: a.filledWh, totalFilledWh: a.totalFilledWh });
    } else if (log.eventName === "OrderClosed") {
      out.push({ ...base, type: "closed", releasedWh: a.releasedWh });
    }
  }
  return out;
}
