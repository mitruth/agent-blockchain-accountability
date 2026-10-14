// keeper: the housekeeping anyone may do, and nobody is trusted for.
//
// After the matcher has finalised a session, every order with an unmatched
// remainder is expired, which releases its collateral; then every agent order
// still open in the gate's PositionLedger is reconciled, which books its fills
// and closes it. Both calls are permissionless.

import { read, send } from "../chain/index.js";

const OPEN = 1;

/** Every order id of a session, bids first. */
export async function orderIds(session) {
  return [...(await read(session, "MarketSession", "bidIds")), ...(await read(session, "MarketSession", "offerIds"))];
}

/** Expire every order of `session` left with an unmatched remainder. Returns how many. */
export async function expireUnmatched(deployment, session) {
  const keeper = deployment.roles.keeper.keyIndex;
  let expired = 0;
  for (const id of await orderIds(session)) {
    const o = await read(session, "MarketSession", "orderOf", [id]);
    if (o.status === OPEN && o.matched < o.quantity) {
      await send(keeper, session, "MarketSession", "expire", [id]);
      expired++;
    }
  }
  return expired;
}

/** Reconcile, through the gate, every order of `session` the ledger still holds open for prosumer `name`. Returns how many. */
export async function reconcile(deployment, session, name) {
  const keeper = deployment.roles.keeper.keyIndex;
  const { ledger, gate } = deployment.contracts;
  const p = deployment.prosumers[name];
  let reconciled = 0;
  for (const id of await orderIds(session)) {
    const rec = await read(ledger, "PositionLedger", "recordOf", [p.account, p.prosumer, id]);
    if (rec.status === OPEN) {
      await send(keeper, gate, "PolicyGate", "reconcile", [p.account, p.prosumer, id]);
      reconciled++;
    }
  }
  return reconciled;
}
