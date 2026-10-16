# Mutation run, 2026-10-16

43 mutants: 42 caught, 0 accepted survivors, 1 not caught, 0 did not build, 0 bad patterns.

| Catalogue | Mutant | Verdict | Caught by, or why accepted |
| --------- | ------ | ------- | -------------------------- |
| policies | a rejection does not stop the submission | caught | tests |
| policies | a flag is taken for a rejection | caught | tests |
| policies | the check stops at the first rejection | caught | tests |
| policies | a flag is not emitted | caught | tests |
| policies | the commit phase is skipped | caught | tests |
| policies | a cancellation is not credited | caught | tests |
| policies | a release on reconcile is not credited | caught | tests |
| policies | a failing credit blocks reconciliation | caught | tests |
| policies | the whole order is released, fills included | caught | tests |
| policies | a credit goes to the current bucket, not the placement's | caught | tests |
| policies | A1 exclusive: <= becomes < on a policy's cap comparison (spec 8) | caught | tests |
| policies | A2 exclusive | caught | tests |
| policies | A3 floor and ceiling swapped between sides | caught | tests |
| policies | A4 hour off by one | caught | tests |
| policies | A4 blocked hours of the other side | caught | tests |
| policies | A6 a slot starting now is in horizon | caught | tests |
| policies | A6 horizon exclusive | caught | tests |
| policies | a cancel leg is checked as a placement | caught | tests |
| policies | a longer horizon is not a widening | caught | tests |
| policies | fewer blocked hours is not a widening | caught | tests |
| policies | S1 counts sales: net or gross confused | caught | tests |
| policies | S2 export counts purchases | caught | tests |
| policies | S1 counts Wh instead of value | caught | tests |
| policies | a cancel leg adds to the window | caught | tests |
| policies | no flag above the soft bound | caught | tests |
| policies | the commit adds nothing | caught | tests |
| policies | S1 credits the whole order, fills included | caught | tests |
| policies | a credit goes to the current bucket (spec 8, through the policy) | caught | tests |
| policies | a higher cap is not a widening | caught | tests |
| policies | a new bucket count is not a widening | caught | tests |
| policies | S above H accepted | caught | tests |
| policies | another quantity keeps the old count | NOT CAUGHT |  |
| policies | S6 cap exclusive | caught | tests |
| policies | the gate weight is ignored | caught | tests |
| policies | the gate window starts a second late | caught | tests |
| policies | the ratio is not enforced | caught | tests |
| policies | the free allowance is ignored | caught | tests |
| policies | messages are not counted | caught | tests |
| policies | the message limit is off by one | caught | tests |
| policies | placements are not counted | caught | tests |
| policies | cancellations are not counted | caught | tests |
| policies | expiry counted as cancel in S6 (spec 8) | caught | tests |
| policies | a lower gate weight is not a widening | caught | tests |

## After the run

One mutant survived: **another quantity keeps the old count** (`WindowPolicy`).
Changing an instance from BUY value to BUY Wh must start its window afresh, or
500,000 units of value would be read as 500,000 Wh. No test saw it: with a
24-hour window the old count had always expired by the time the 24-hour
widening applied. `test_countingAnotherQuantityStartsAfresh` uses a 48-hour
window; re-run on its own, the mutant is caught.

Also re-run after step 4.1 and 4.2 changed the gate: `gate / submit open to any
caller` (was "agent check removed") and `ledger / cancel legs not booked`, both
caught.

**Result:** 43 of 43 caught. Each mutant ran the tests of the contract it
breaks (`tests` per mutant in `catalogs/policies.js`).
