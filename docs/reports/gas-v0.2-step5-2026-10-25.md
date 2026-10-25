# Gas after v0.2 step 5: what S9 costs

**Measured on 25 October 2026** by `test/policies/DeliveryReconciliationPolicy.t.sol`
(`test_gas_processing`) and `test/policies/Step5Acceptance.t.sol`
(`test_gas_dayAheadBatch*`), under Hardhat 3, Solidity 0.8.25, optimizer 200
runs. Command:

```bash
npx hardhat test solidity test/policies/DeliveryReconciliationPolicy.t.sol test/policies/Step5Acceptance.t.sol --grep gas
```

As in the earlier reports, a Solidity test is one transaction: the figures are
"steady state", with storage already warm.

## One sell, on the mock market, S9 alone

Sixteen slots with a sale and a meter reading, settled; `maxProcess` 8.

| Call | Gas |
|---|---:|
| A sell that takes in 8 settled slots | 405,115 |
| A poke that takes in the other 8 | 98,620 |
| A sell with nothing to take in (the second of two) | 173,776 |

Taking a slot in costs about 29,000 gas inside a submission: the ledger's
position and the meter's reading, both external reads, and the C, s and event
for the slot. A submission takes in at most `maxProcess` slots, so S9's
processing adds at most about 231,000 gas to any submission. A keeper's poke
does the same work without an order (the 98,620 above excludes the order).

## The day-ahead case

A batch of 24 offers against a bid in each slot, at k = 48, on the ported
market, every policy with A3T on.

| Policies | Gas |
|---|---:|
| A1–A6, S1, S2 ×2, S3, S4, S5, S7 | 11,542,278 |
| The same and S8 | 11,979,956 |
| The same and S9, nothing settled to take in | **12,071,510** (+91,554, +0.8 %) |

- With 8 settled slots to take in, the batch would cost about 231,000 more,
  about 12.3 M: still under the per-transaction cap of 16,777,216
  (EIP-7825).

## Sizes

| Contract | Runtime bytes |
|---|---:|
| DeliveryReconciliationPolicy | 16,431 |
| PolicyGate (with `poke`, `resetPolicy`) | 21,739 (from 21,147) |
