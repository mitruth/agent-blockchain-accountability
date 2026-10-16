# The honest controller arms, slot by slot

What each honest home-energy controller did for `home_01` through 2022, every
30 minutes. Step 6 replays these to measure how often a policy refuses an honest
agent, scoring against B2 (spec, step 6).

**Source.** The simulation's outputs, in the sibling project
`Demo_PlanApplyEvaluate`, folder `data/`. They are copied here by
`npm run data:extract` (`offchain/dataset/arms.js`). The simulation itself, and
the scripts that ran it, stay in that project.

- **The home's own data** (load, PV, prices) is the same as
  [`data/homes/`](../homes/README.md)'s `home_01`. The extraction checks this
  slot by slot.
- **The daily records** in [`data/hems/`](../hems/README.md) were built from these
  same step logs. The year's import and export here match theirs within
  rounding: they rounded each day, these figures round the year.

## Units

The same as in `data/homes/`. Every number is an integer, rounded half away from
zero, once per value, after every digit of the source is read: the logs print
floats in full, such as `1.4999999952631584` or `2.42e-09`.

| Suffix | Unit |
|---|---|
| `Wh` | watt-hours in the 30-minute slot |
| `W` | watts |
| `Bps` | basis points: 10000 = 1 |
| `MicroUsd` | millionths of a USD, the payment token's 6 decimals |
| `MicroUsdPerKwh` | millionths of a USD per kWh |
| `Milli` | thousandths |

**Slots count from 0,** as in `data/homes/`; the source counts the steps of a day
from 1. `time` is when the slot starts, local time, on the same plain grid.

## The arms

| File | Arm | What it does |
|---|---|---|
| `B_null-no-battery-30min.csv` | B_null | No battery and no scheduling: appliances run when requested. The floor every other arm should beat |
| `B0-rules-30min.csv` | B0 | If-then rules on the current moment: charge when power is cheap or solar is left over, discharge when it is expensive |
| `B0star-tuned-rules-30min.csv` | B0star | B0's rules, with the price and charge thresholds chosen each day from 64 candidates |
| `B1-perfect-foresight-30min.csv` | B1 | The day planned as an optimisation, knowing the day's sun, load and prices. Not realistic: the best case |
| `B2-forecast-plan-30min.csv` | B2 | The same plan, but guessing sun and load, by an exponentially weighted average of the past. Knows prices. **The arm step 6 scores against** |
| `B2r-tuned-forecast-plan-30min.csv` | B2r | B2, with its reserve, cycle budget and other settings chosen each day from 60 candidates |
| `B2nn-mlp-forecast-plan-30min.csv` | B2nn | B2, guessing sun and load with a small neural network instead |

**The A arms are left out.** A0, A1 and A2 are the LLM-driven arms. Their current
runs are mock echoes: their logs say "mock: echo A1 defaults", and their
results equal B0's and B2's. The spec wants A0 and A1 once they have really run;
`node offchain/dataset/cli.js --only arms --arms A0,A1` adds them then.

**How B0star and B2r pick their settings is not in the data.** Their daily
choice logs list the candidates and the day's cost. Whether the choice saw the
day in advance would be in the simulation's scripts, which this extraction does
not read.

## Files

| File | One row is | Columns |
|---|---|---|
| `settings.csv` | the settings every arm ran with | `batteryCapacityWh`, `batteryPowerW`, `etaChargeBps`, `etaDischargeBps`, `socMinBps`, `socMaxBps`, `socInitialBps`, `gridLimitW` (the connection), `exportPriceShareBps` (export price as a share of the import price), `wearMicroUsdPerCycle` (battery wear per full cycle), `forecastWeightBps` (B2's averaging weight), `slotMinutes` |
| `appliance-tasks.csv` | a washing machine or dishwasher job | `date`, `taskId`, `earliestSlot`, `lastSlot` (both included), `durationSlots`, `energyWh`, `slotEnergyWh` |
| `<arm>-<name>-30min.csv` | one slot | `date`, `slot`, `time`, `socBps` (after the slot), `chargeWh`, `dischargeWh` (on the house side of the battery), `taskWh` (appliances the arm ran), `pvWh`, `fixedLoadWh` (base load and HVAC), `netWh`, `importWh`, `exportWh`, `curtailedWh`, `importPriceMicroUsdPerKwh`, `exportPriceMicroUsdPerKwh`, `costMicroUsd` (energy bought minus sold, plus battery wear; negative when the house earned), `runningTasks` (task ids, separated by `\|`) |
| `daily-results.csv` | one day of one arm, as the simulation computed it | `arm`, `date`, `costMicroUsd`, `importWh`, `exportWh`, `curtailedWh`, `selfConsumptionBps`, `selfSufficiencyBps`, `peakImportW`, `cyclesMilli`, `tasksMissed` |
| `annual-results.csv` | one arm's year | the same, without `date` |

**The year at a glance:**

| Arm | Cost | Import | Export | Cycles |
|---|---:|---:|---:|---:|
| B_null | 877.63 USD | 8,154 kWh | 5,773 kWh | 0 |
| B0 | 772.35 USD | 7,364 kWh | 4,808 kWh | 343 |
| B0star | 729.62 USD | 6,870 kWh | 4,314 kWh | 343 |
| B1 | 702.30 USD | 6,887 kWh | 4,275 kWh | 446 |
| B2 | 750.40 USD | 7,547 kWh | 4,934 kWh | 452 |
| B2r | 748.32 USD | 7,515 kWh | 4,910 kWh | 433 |
| B2nn | 758.56 USD | 7,689 kWh | 5,072 kWh | 458 |

No arm missed a task.

## Worth knowing

- **These are imports and exports, not market orders.** Step 6 has to decide
  how an honest agent turns a plan into bids and offers.
- **The battery settings differ from the dataset's.** The arms ran with 10 % to
  100 % state of charge, starting at 50 %; `data/homes/homes.csv` gives 20 % to
  90 %. For anything that replays the arms, use `settings.csv`.
- **Selling earns 30 % of the buying price,** a setting of the simulation.
  The P2P market has its own prices.
- **Only home_01 has arms.** The other five homes have data but were not
  simulated.
- **The simulation's own check reports one failure:** B1 improves on B0 by
  9.07 %, outside the 10 % to 30 % its authors expected. Its nine other
  checks pass (energy balance, state-of-charge bounds, tasks, and so on). The
  report is in the source, `outputs/eval/home_01/sanity_report.txt`.

## Rebuild

```bash
npm run data:extract
```

Two runs give the same files. Before writing, the extraction checks that:

- every arm shares the same dates and prices;
- each export price is 30 % of the import price;
- the state of charge stays in bounds;
- each day's import and export, summed from the slots, matches the
  simulation's daily figures within rounding;
- PV, the fixed load and the prices match `data/homes/` slot by slot.
