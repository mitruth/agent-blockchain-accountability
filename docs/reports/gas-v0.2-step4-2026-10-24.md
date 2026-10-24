# Gas after v0.2 step 4: what S8 costs

**Measured on 24 October 2026** by `test/policies/RoundTripPolicy.t.sol`
(`test_gas_oneBid`) and `test/policies/Step5Acceptance.t.sol`
(`test_gas_dayAheadBatch*`), under Hardhat 3, Solidity 0.8.25, optimizer 200
runs. Command:

```bash
npx hardhat test solidity test/policies/RoundTripPolicy.t.sol test/policies/Step5Acceptance.t.sol --grep gas
```

As in the earlier reports, a Solidity test is one transaction: the figures are
"steady state", with storage already warm.

## One bid, on the mock market, S8 alone

Each figure is the second of two bids into the same slot.

| Bid | Gas |
|---|---:|
| Into a slot with no sell: no round trip | 160,952 |
| Into a slot with a sell: adds a round trip | 167,986 |

A bid that adds a round trip costs about 7,000 more: the window write. Either
way S8 reads the slot's position from the ledger.

## The day-ahead case

A batch of 24 offers, one per hour of tomorrow, at k = 48, on the ported
market.

| Policies | Before the batch | Gas |
|---|---|---:|
| None | | 8,789,352 |
| A1–A6, S1, S2 export and import, S3, S4, S5 | | 10,788,611 |
| The same with A3T on, and S7 (corrected, below) | | 12,001,954 (+1,213,343, +11.2 %) |
| The same | a bid in each of the 24 slots | 11,542,278 |
| The same, and S8 | a bid in each of the 24 slots | **11,979,956** (+437,678, +3.8 %) |

- **S8's worst case.** With a bid already in every slot, each of the 24 offers
  adds a round trip, so S8 reads 24 positions and counts every leg: about
  18,000 gas a leg. The bids warm the ledger's slots first, so this pair is
  compared with each other, not with the rows above.
- Every row stays under the per-transaction cap of 16,777,216 (EIP-7825).

## A correction to step 3

`gas-v0.2-step3-2026-10-23.md` gave the day-ahead batch with A3T and S7 as
11,365,148 (+5.3 %), "every leg dominated". It was not: the test's tariff
(retail 20, feed-in 11) sat far below the offers' price of 200,000, so no
offer was under feed-in and S7 counted nothing. The tariff is now feed-in =
price + 1 and retail 300,000, and the test asserts that S7 counted all 25
offers. The worst case is **12,001,954**, +11.2 % over the batch without A3T
and S7.

## Sizes

| Contract | Runtime bytes | Initcode bytes |
|---|---:|---:|
| RoundTripPolicy | 9,322 | 9,619 |
| DominatedTradePolicy | 10,820 (unchanged) | 10,974 |
| PolicyGate | 21,147 (unchanged) | 31,805 |
