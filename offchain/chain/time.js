// The node's clock. On a local node time only moves when a block is mined, and
// it can be moved forward at will.

import { publicClient } from "./client.js";

/** The latest block's timestamp, in seconds. */
export async function now() {
  const block = await publicClient.getBlock();
  return Number(block.timestamp);
}

/** Move the chain to `timestamp` (seconds) and mine a block there. */
export async function warpTo(timestamp) {
  const current = await now();
  if (timestamp > current) {
    await publicClient.request({ method: "evm_setNextBlockTimestamp", params: [timestamp] });
  }
  await publicClient.request({ method: "evm_mine", params: [] });
}
