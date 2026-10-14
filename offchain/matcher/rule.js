// The matching rule: a pure function of the open orders. It knows nothing of
// the chain, so another rule can replace it without touching the rest.

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
