# Daily records from the HEMS simulation

The records below come from the home energy simulation that supplies the
honest-agent arms. Step 6 of the build uses them to calibrate the policies' caps
and to measure how often a cap refuses an honest agent. They were produced for
the project this repository started from, whose code and documentation were
removed at step 4; the data is kept, unchanged.

They are daily totals. The step logs they were built from, slot by slot, are in
[`data/arms/`](../arms/README.md).

These CSVs are a compressed, integer-only view of one simulated year of home energy
control for `home_01` (2022). Each file is one way of running the same house.

One row is a summary of what that controller did for the house over one calendar day:
how much it spent, how much it bought and sold, how hard it used the battery, how empty
the battery got, and the peak grid draw. It is not the list of individual charge and
discharge steps. Those live in the step log; this file keeps only the day's totals and
extremes. Values are scaled to integers so a chain contract can store and compare them
without floating point. Negative `spendMilliUsd` is real (the house was paid that day)
and is not clipped.

**B0, `records_B0.csv`.** A simple set of if-then rules. Charge when power is cheap or there
is leftover solar. Discharge when power is expensive. It only looks at the current moment,
not the rest of the day.

**B1, `records_B1.csv`.** The cheapest the house can be if it already knew the whole day's
sun, load, and prices. That is not realistic. It is the best-case year we measure the
others against.

**B2, `records_B2.csv`.** Same idea as planning the day in advance, but the house has to
guess sun and load. It already knows prices. The guess is often wrong, so this year costs
more than B1.

365 rows plus a header. `dayIndex` runs from 0 (2022-01-01) to 364. Built from each arm's
step log by `export_records.py`. Caps for a 7-day spend policy are printed by
`calibrate_policy.py`. Both scripts, and the step logs, are in the sibling repository
`Demo_PlanApplyEvaluate`, under its `scripts/` folder, not in this one.

## Columns

Every numeric field is an integer. Rounding is half away from zero, applied once per field
per day.


| Column          | Unit         | Meaning                                                           |
| --------------- | ------------ | ----------------------------------------------------------------- |
| `dayIndex`      | days         | Days since 2022-01-01                                             |
| `agentId`       | hex          | `0x` + keccak256 of the ASCII string `home_01`. Same on every row |
| `spendMilliUsd` | milli-USD    | Daily energy + degradation cost × 1000. Signed                    |
| `exportWh`      | Wh           | Energy exported to the grid that day                              |
| `importWh`      | Wh           | Energy imported from the grid that day                            |
| `cyclesMilli`   | milli-cycles | Battery throughput that day, as thousandths of a full cycle       |
| `minSocBps`     | basis points | Lowest battery state of charge that day. 10000 = full, 1000 = 10% |
| `maxImportW`    | W            | Peak import power that day                                        |
| `tasksMissed`   | count        | Flexible tasks that missed their deadline. 0 in these files       |


Rebuild, from the root of `Demo_PlanApplyEvaluate`:

```powershell
python scripts\export_records.py
python scripts\calibrate_policy.py
```

