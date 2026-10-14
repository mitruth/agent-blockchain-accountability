// The off-chain matching service (thesis figure 3.3, steps 6 to 8): read a
// closed session's bids and offers, match them, register the trades, finalise.
//
//   npm run demo:match                    the current electricity session
//   node scripts/demo/matcher.js 0x...    a given session
//
// The matching rule is `matchOrders`, a pure function of the open orders. It
// knows nothing of the chain, so another rule can replace it without touching
// the rest.

import { pathToFileURL } from "node:url";
import { loadDeployment, read, send, now, eur, kWh } from "./lib.js";

const OPEN = 1;
const TRADES_PER_TX = 50;

/**
 * Double auction, slot by slot. Bids from the highest price, offers from the
 * lowest; earlier orders first at equal price. The best bid trades with the
 * best offer from a different account while the bid's price is at least the
 * offer's, for the smaller of the two remaining quantities, at the midpoint of
 * the two limit prices (rounded down, so it stays inside both).
 *
 * An order is { id, account, slot, price, remaining, seq }; prices and
 * quantities are BigInt. Returns trades { bidId, offerId, quantity, price }.
 * The orders' `remaining` is consumed.
 */
export function matchOrders(bids, offers) {
  const trades = [];
  const slots = [...new Set([...bids, ...offers].map((o) => o.slot))].sort((a, b) => a - b);

  for (const slot of slots) {
    const b = bids.filter((o) => o.slot === slot).sort(byPrice(-1));
    const o = offers.filter((x) => x.slot === slot).sort(byPrice(1));

    for (const bid of b) {
      while (bid.remaining > 0n) {
        // The cheapest offer this bid may take: not its own, not used up.
        const offer = o.find((x) => x.remaining > 0n && x.account !== bid.account);
        if (!offer || offer.price > bid.price) break;

        const quantity = bid.remaining < offer.remaining ? bid.remaining : offer.remaining;
        trades.push({ bidId: bid.id, offerId: offer.id, quantity, price: (bid.price + offer.price) / 2n });
        bid.remaining -= quantity;
        offer.remaining -= quantity;
      }
    }
  }
  return trades;
}

function byPrice(direction) {
  return (x, y) => (x.price === y.price ? x.seq - y.seq : x.price < y.price ? -direction : direction);
}

/** Read the session's open orders, match them, register the trades, finalise. */
export async function runMatcher(deployment, session, { log = console.log } = {}) {
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

  const trades = matchOrders(bids, offers);
  for (let i = 0; i < trades.length; i += TRADES_PER_TX) {
    await send(matcherKey, session, "MarketSession", "registerTrades", [trades.slice(i, i + TRADES_PER_TX)]);
  }
  await send(matcherKey, session, "MarketSession", "finalise");

  const total = trades.reduce((sum, t) => sum + t.quantity, 0n);
  log(`matcher     ${trades.length} trades, ${kWh(total)} in total; session finalised`);
  for (const t of trades) {
    log(`              ${t.bidId.slice(0, 10)} ← ${t.offerId.slice(0, 10)}  ${kWh(t.quantity)} at ${eur(t.price)}/kWh`);
  }
  return trades;
}

// --- command line --------------------------------------------------------------

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const deployment = loadDeployment();
  const session =
    process.argv[2] ?? (await read(deployment.contracts.manager, "MarketManager", "currentSession", [0]));
  runMatcher(deployment, session).catch((error) => {
    console.error(error.shortMessage ?? error.message ?? error);
    process.exit(1);
  });
}
