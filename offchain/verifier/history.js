// The event log of a WindowProbe, as the verifier's histories: everything the
// verifier knows comes from here (spec 8: enforcement must be recomputable
// from the event log alone).

import { publicClient, abi } from "../chain/index.js";
import { KINDS } from "./windows.js";

export function toConfig(c) {
  return {
    kind: KINDS[Number(c.kind)],
    step: Number(c.step),
    buckets: Number(c.buckets),
    anchor: Number(c.anchor),
    cap: BigInt(c.cap),
    rate: BigInt(c.rate),
    initial: BigInt(c.initial),
  };
}

function toEvent(log) {
  const a = log.args;
  const at = Number(a.at);
  switch (log.eventName) {
    case "Configured":
      return { type: "configured", at, config: toConfig(a.config) };
    case "Admitted":
      return { type: "admitted", at, admission: Number(a.admission), amount: a.amount, usedBefore: a.usedBefore, limit: a.limit };
    case "Refused":
      return { type: "refused", at, amount: a.amount, usedBefore: a.usedBefore, limit: a.limit };
    case "Credited":
      return { type: "credited", at, admission: Number(a.admission), amount: a.amount, credited: a.credited };
    case "Observed":
      return { type: "observed", at, used: a.used, limit: a.limit };
    default:
      return null;
  }
}

/** Every window's history from the probe at `address`, in log order, by window id. */
export async function readHistories(address, { fromBlock = 0n } = {}) {
  const logs = await publicClient.getContractEvents({ address, abi: abi("WindowProbe"), fromBlock });
  const byId = new Map();
  for (const log of logs) {
    const event = toEvent(log);
    if (!event) continue;
    const id = log.args.id;
    if (!byId.has(id)) byId.set(id, { id, events: [] });
    byId.get(id).events.push(event);
  }
  return [...byId.values()];
}
