# Gas after v0.2 step 6: what S10 costs

**Measured on 25 October 2026** by `test/policies/OperatingEnvelopePolicy.t.sol`
(`test_gas_oneBid`) and `test/policies/Step5Acceptance.t.sol`
(`test_gas_dayAheadBatch*`), under Hardhat 3, Solidity 0.8.25, optimizer 200
runs. Command:

```bash
npx hardhat test solidity test/policies/OperatingEnvelopePolicy.t.sol test/policies/Step5Acceptance.t.sol --grep gas
```

As in the earlier reports, a Solidity test is one transaction: the figures are
"steady state", with storage already warm.

## One bid, on the mock market, S10 alone

| Limits | Gas |
|---|---:|
| The static connection limit (no envelope) | 159,430 |
| The DSO's envelope | 161,622 |

S10 is stateless: per slot a submission touches, it reads the ledger's
position and the envelope, and writes nothing.

## The day-ahead case

A batch of 24 offers against a bid in each slot, at k = 48, on the ported
market, every policy with A3T on.

| Policies | Gas |
|---|---:|
| A1–A6, S1, S2 ×2, S3, S4, S5, S7, S8, S9 | 12,071,510 |
| The same and S10, on the envelope | **12,496,159** (+424,649, +3.5 %) |

- About 17,700 gas a leg: S10 reads 24 positions and 24 envelope entries.
- With S9 taking in 8 settled slots as well (about 231,000 more, step 5),
  about 12.73 M: under the per-transaction cap of 16,777,216 (EIP-7825).

## Sizes

| Contract | Runtime bytes |
|---|---:|
| OperatingEnvelopePolicy | 5,109 |
| PolicyGate | 21,739 (unchanged) |
