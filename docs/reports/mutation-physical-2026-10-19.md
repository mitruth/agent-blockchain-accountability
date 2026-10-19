# Mutation run, 2026-10-19

42 mutants: 42 caught, 0 accepted survivors, 0 not caught, 0 did not build, 0 bad patterns.

| Catalogue | Mutant | Verdict | Caught by, or why accepted |
| --------- | ------ | ------- | -------------------------- |
| physical | reading accepted with a decreasing timestamp (spec 8) | caught | tests |
| physical | a stale reading accepted | caught | tests |
| physical | the maximum age exclusive | caught | tests |
| physical | a reading from the future accepted | caught | tests |
| physical | any signer accepted | caught | tests |
| physical | the high-s twin accepted | caught | tests |
| physical | a conflicting reading with the same timestamp accepted | caught | tests |
| physical | the odometer may go down | caught | tests |
| physical | a new signer keeps the old device's reading | caught | tests |
| physical | a stored reading never goes stale | caught | tests |
| physical | a forecast served between its slots | caught | tests |
| physical | a stale forecast served to the policies | caught | tests |
| physical | a forecast of any length | caught | tests |
| physical | the domain does not bind the chain | caught | tests |
| physical | a reading for another account accepted | caught | tests |
| physical | any number of readings | caught | tests |
| physical | the verifier allowed as target | caught | tests |
| physical | the ledger's batch view off by one slot | caught | tests |
| physical | the horizon starts a slot late | caught | tests |
| physical | placed buys credited in the S3 floor (spec 8) | caught | tests |
| physical | S3 accepts a placement outside its horizon (spec 8: H_slots <= k) | caught | tests |
| physical | S3 without a fresh reading | caught | tests |
| physical | S3 floor losses rounded down | caught | tests |
| physical | S3 shortfall not counted | caught | tests |
| physical | S3 ceiling excess not counted | caught | tests |
| physical | S3 discharge power not checked | caught | tests |
| physical | S3 charge power not checked | caught | tests |
| physical | S3 PV above a full battery stored | caught | tests |
| physical | S3 rejects any shortfall, reduced or not | caught | tests |
| physical | S3 counts a cancellation as a placement | caught | tests |
| physical | S4 discharge never added to the window | caught | tests |
| physical | S4 ignores the odometer beyond the window | caught | tests |
| physical | S4 pending without the efficiency | caught | tests |
| physical | S4 pending without the PV credit | caught | tests |
| physical | S4 judges a sale without a fresh reading | caught | tests |
| physical | S4 judges a bid as a sale | caught | tests |
| physical | S4 cap exclusive | caught | tests |
| physical | S4 rejects what does not add | caught | tests |
| physical | S5 looks only to the left | caught | tests |
| physical | S5 rejects steps it did not make larger | caught | tests |
| physical | S5 rejects above the soft bound | caught | tests |
| physical | S5 treats a cancellation as a placement | caught | tests |
