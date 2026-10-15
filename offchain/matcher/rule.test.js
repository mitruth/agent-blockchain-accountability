// npm run test:offchain

import { test } from "node:test";
import assert from "node:assert/strict";
import { matchOrders } from "./rule.js";

const order = (id, account, slot, price, remaining, seq = 0) => ({
  id, account, slot, price: BigInt(price), remaining: BigInt(remaining), seq,
});

test("the best bid takes the cheapest offer, at the midpoint", () => {
  const trades = matchOrders(
    [order("b1", "alice", 1, 240, 800)],
    [order("o1", "bob", 1, 180, 2000), order("o2", "carol", 1, 170, 700)],
  );
  assert.deepEqual(trades, [
    { bidId: "b1", offerId: "o2", quantity: 700n, price: 205n },
    { bidId: "b1", offerId: "o1", quantity: 100n, price: 210n },
  ]);
});

test("no trade when the offer asks more than the bid pays", () => {
  assert.deepEqual(matchOrders([order("b", "alice", 1, 200, 1)], [order("o", "bob", 1, 201, 1)]), []);
});

test("an account does not trade with itself", () => {
  assert.deepEqual(matchOrders([order("b", "alice", 1, 300, 1)], [order("o", "alice", 1, 100, 1)]), []);
});

test("slots are matched separately", () => {
  assert.deepEqual(matchOrders([order("b", "alice", 1, 300, 1)], [order("o", "bob", 2, 100, 1)]), []);
});
