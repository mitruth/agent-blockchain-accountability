# Gas after v0.2 step 1: what C1 and C3 cost

**Measured on 21 October 2026** by `test/policies/Step4Acceptance.t.sol` and
`test/policies/Step5Acceptance.t.sol` (the `test_gas_*` tests), under Hardhat 3,
Solidity 0.8.25, optimizer 200 runs. The setup is as in
`gas-step5-2026-10-19.md` and `gas-2026-10-16.md`. Command:

```bash
npx hardhat test solidity test/policies/Step5Acceptance.t.sol test/policies/Step4Acceptance.t.sol
```

## What changed

- **C1 (A1 rated power).** One more `slotStart` read per placement leg, for the
  slot's length.
- **C3 (S3 socMin by hour).** The floor is looked up per slot from a 24-entry
  profile, and the configuration is 33 words instead of 10.

## A1–A6 alone (step 4 harness)

| Submission | v0.1 (16 Oct) | v0.2 step 1 | Change |
|---|---:|---:|---:|
| One bid | 321,287 | 325,308 | +4,021 |
| 24-leg batch | 6,667,321 | 6,762,061 | +94,740 (about 3,950 a leg) |
| Cancel | 87,085 | 87,146 | +61 |

## S3 by horizon k, one offer (step 5 harness)

| k | No policy | + S3, v0.1 | + S3, v0.2 step 1 | Change |
|---:|---:|---:|---:|---:|
| 8 | 379,496 | 442,350 | 465,836 | +23,486 |
| 16 | 379,496 | 474,331 | 502,469 | +28,138 |
| 24 | 379,496 | 506,398 | 539,189 | +32,791 |
| 48 | 379,496 | 603,114 | 649,862 | +46,748 |
| 96 | 379,496 | 798,855 | 873,516 | +74,661 |

Fitted: S3 is now about **49,000 fixed plus 4,630 per slot**, up from 30,500 plus
4,050. The fixed part is the profile: 24 floors computed per check. The per-slot
part is the hour lookup.

With S4 and S5 as well, one offer at k = 96 costs 1,177,070, and at k = 48
831,875.

## The day-ahead case

A batch of 24 offers at k = 48 under A1–A6, S1, S2 export and import, S3, S4
and S5: **10,782,758** (v0.1: 10,640,167; +142,591, +1.3 %). With no policy:
8,786,125. Under the 16,777,216 per-transaction cap (EIP-7825).

## The oracle

Accepting the first BMS reading costs 87,628 (v0.1: 87,468), from the larger
dispatch in `accept`.
