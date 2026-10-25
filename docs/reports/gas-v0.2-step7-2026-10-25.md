# Gas after v0.2 step 7: what A10 costs

**Measured on 25 October 2026** by `test/policies/GridStatePolicy.t.sol`
(`test_gas_oneSell`) and `test/policies/Step5Acceptance.t.sol`
(`test_gas_dayAheadBatch*`), under Hardhat 3, Solidity 0.8.25, optimizer 200
runs. Command:

```bash
npx hardhat test solidity test/policies/GridStatePolicy.t.sol test/policies/Step5Acceptance.t.sol --grep gas
```

As in the earlier reports, a Solidity test is one transaction: the figures are
"steady state", with storage already warm.

## One sell, on the mock market, A10 alone

| Grid state | Gas |
|---|---:|
| None in force | 152,168 |
| ALERT, DEFICIT, covering the slot | 157,412 |

A10 is stateless: it reads the operator's state, and with one in force the
account's slot grid, and writes nothing.

## The day-ahead case

A batch of 24 offers against a bid in each slot, at k = 48, on the ported
market, every policy with A3T on.

| Policies | Gas |
|---|---:|
| A1–A6, S1, S2 ×2, S3, S4, S5, S7, S8, S9, S10 | 12,496,159 |
| The same and A10, under an ALERT DEFICIT covering every slot | **12,694,138** (+197,979, +1.6 %) |

- Under the DEFICIT every offer helps the grid, so all 24 pass and A10
  judges every slot: its worst case for a passing batch, about 8,200 gas a
  leg.
- With S9 taking in 8 settled slots as well (about 231,000 more, step 5),
  about 12.93 M: under the per-transaction cap of 16,777,216 (EIP-7825).
  Every v0.2 policy together, at its worst, leaves about 3.8 M of headroom.

## Sizes

| Contract | Runtime bytes |
|---|---:|
| GridStatePolicy | 4,369 |
| PolicyGate | 21,739 (unchanged) |
