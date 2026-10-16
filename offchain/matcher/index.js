// matcher: the off-chain matching service (thesis figure 3.3, steps 6 to 8).
// Read a closed session's bids and offers, match them, register the trades,
// finalise.
//
//   rule.js   the matching rule, a pure function: replace it to change how
//             orders are matched
//   index.js  the service around it: reads the chain, sends the trades
//   cli.js    npm run demo:match

import { read, send, now, usd, kWh } from "../chain/index.js";
import { matchOrders } from "./rule.js";

export { matchOrders };

const OPEN = 1;
const TRADES_PER_TX = 50;

/** Read the session's open orders, match them, register the trades, finalise. */
export async function runMatcher(deployment, session, { log = console.log, rule = matchOrders } = {}) {
  const matcherKey = deployment.roles.matcher.keyIndex;
  const config = await read(session, "MarketSession", "config");
  if (Number(config.closesAt) > (await now())) {
    throw new Error(`Session ${session} is still trading; it closes at ${new Date(Number(config.closesAt) * 1000).toISOString()}`);
  }

  const load = async (ids) => {
    const orders = [];
    for (const [seq, id] of ids.entries()) {
      const o = await read(session, "MarketSession", "orderOf", [id]);
      if (o.status === OPEN && o.matched < o.quantity) {
        orders.push({ id, account: o.account.toLowerCase(), slot: Number(o.slot), price: o.price, remaining: o.quantity - o.matched, seq });
      }
    }
    return orders;
  };
  const bids = await load(await read(session, "MarketSession", "bidIds"));
  const offers = await load(await read(session, "MarketSession", "offerIds"));
  log(`matcher     ${bids.length} open bids, ${offers.length} open offers`);

  const trades = rule(bids, offers);
  for (let i = 0; i < trades.length; i += TRADES_PER_TX) {
    await send(matcherKey, session, "MarketSession", "registerTrades", [trades.slice(i, i + TRADES_PER_TX)]);
  }
  await send(matcherKey, session, "MarketSession", "finalise");

  const total = trades.reduce((sum, t) => sum + t.quantity, 0n);
  log(`matcher     ${trades.length} trades, ${kWh(total)} in total; session finalised`);
  for (const t of trades) {
    log(`              ${t.bidId.slice(0, 10)} ← ${t.offerId.slice(0, 10)}  ${kWh(t.quantity)} at ${usd(t.price)}/kWh`);
  }
  return trades;
}
