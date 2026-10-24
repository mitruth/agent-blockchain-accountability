# Gas after v0.2 step 3: what A3T and S7 cost

**Measured on 22 and 23 October 2026** by `test/policies/DominatedTradePolicy.t.sol`
(`test_gas_priceBids`) and `test/policies/Step5Acceptance.t.sol`
(`test_gas_dayAheadBatch*`), under Hardhat 3, Solidity 0.8.25, optimizer 200
runs. Command:

```bash
npx hardhat test solidity test/policies/DominatedTradePolicy.t.sol test/policies/Step5Acceptance.t.sol
```

## One bid, on the mock market

Each figure is the second of two identical bids, each cancelled after it is
measured.

| Policies | Bid | Gas |
|---|---|---:|
| S7 alone | dominated (0.05 above retail) | 239,791 |
| S7 alone | at retail, nothing given away | 207,971 |
| A1–A6, band off | at retail | 197,626 |
| A1–A6, band on | at retail | 197,728 |
| A1–A6 with the band, and S7 | dominated | 258,584 |

**Read with care: warm storage.** A Solidity test runs as one transaction, so
the second call finds the tariff's storage, and the oracle's account, already
warm. A3T's lookup therefore shows as 102 gas here. In a real submission it is
a cold call to the oracle (2,600) and cold reads of the tariff entry (2,100
each), several thousand gas more. The earlier reports measured the same
"steady state" (`gas-step5-2026-10-19.md`).

The dominated bid costs S7 about 32,000 more than a bid at retail: the window
write and the excess stored for the credit.

## The day-ahead case

A batch of 24 offers, one per hour of tomorrow, at k = 48, on the ported
market.

| Policies | Gas |
|---|---:|
| None | 8,789,352 |
| A1–A6, S1, S2 export and import, S3, S4, S5 | 10,788,611 |
| The same with A3T on, and S7 | **11,365,148** (+576,537, +5.3 %) |

- **Corrected on 24 October** (`gas-v0.2-step4-2026-10-24.md`): the last row
  is not the worst case. The test's tariff (retail 20, feed-in 11) left every
  offer above feed-in, so S7 counted nothing. With every leg dominated, the
  batch costs 12,001,954 (+11.2 %). The original claim, kept for the record:
  "every leg is dominated: feed-in is one unit above the offers' price, so S7
  stores an excess for each of the 24 legs. That is the worst case."
- It stays under the per-transaction cap of 16,777,216 (EIP-7825).

## Sizes

| Contract | Runtime bytes |
|---|---:|
| StaticOrderPolicy (with A3T) | 6,528 |
| DominatedTradePolicy | 10,820 |
| PolicyGate | 21,147 (unchanged) |
