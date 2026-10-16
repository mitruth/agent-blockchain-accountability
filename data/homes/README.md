# Six homes, 30-minute slots: the extract the project uses

These files are taken from the six-home HEMS dataset by
`npm run data:extract` (`offchain/dataset/`). The dataset itself sits beside
the code, in `A Four-Year 30-Minute Simulated Residential HEMS D/`. It is
git-ignored: 75 MB, four years, and to be published on its own.

**The source.** S. Mozhgan Rahmatinia (2026), *A Four-Year 30-Minute Simulated
Residential HEMS Dataset for Six Heterogeneous Homes with PV, Battery, HVAC, and
Shiftable Appliances (2020-2023)*, Mendeley Data, reserved DOI
10.17632/5rrc4787hv.1.

- The homes are simulated, in Sacramento, California.
- Prices are CAISO's real-time TH_NP15 prices, in USD.
- PV comes from NSRDB.

A paper using this extract cites the dataset and those two sources.

**Why 2022.** It is the dataset's evaluation year, and the year of the honest
arms' daily records in `data/hems/` (home_01, 2022). Another year:
`node offchain/dataset/cli.js --year 2023`.

## Units

Every number is an integer, rounded half away from zero, once per value, from
the dataset's decimal text: the extraction never goes through floating point.

| Suffix | Unit |
|---|---|
| `Wh` | watt-hours in the 30-minute slot |
| `W` | watts |
| `Bps` | basis points: 10000 = 1, 2000 = 20 % |
| `MicroUsdPerKwh` | millionths of a USD per kWh. This is the payment token's 6 decimals, so the value can go to the market as is |

**The rounding loses less than half a Wh per value,** but not always evenly. The
HVAC draws one of two fixed amounts, both a fraction of a Wh above a whole
number, so home_01's 2022 load comes out 668 Wh low out of 9.76 MWh (0.007 %).

**The clock.** Each row is local time in Sacramento, on a plain 30-minute grid:
48 slots every day, with no daylight-saving jumps. `slot` is the position in
the day, 0 to 47; `time` is when the slot starts.

## Files

| File | One row is | Columns |
|---|---|---|
| `homes.csv` | a home: who lives there, its PV and its battery | `homeId`, `name`, `householdType`, `people`, `houseAreaM2`, `pvCapacityW`, `batteryCapacityWh`, `batteryPowerW`, `socInitialBps`, `socMinBps`, `socMaxBps`, `etaChargeBps`, `etaDischargeBps` |
| `2022/home_XX-<household>-30min.csv` | one slot of one home | `date`, `slot`, `time`, `baseLoadWh`, `appliancesWh` (washing machine and dishwasher), `hvacWh`, `loadWh` (the three added), `pvWh`, `netLoadWh` (load minus PV, before any battery: positive means the house needs energy) |
| `2022/prices-30min.csv` | one slot | `date`, `slot`, `time`, `priceMicroUsdPerKwh`. One price signal for all six homes (the extraction checks this) |
| `2022/daily-totals.csv` | one day of one home | `name`, `date`, `loadWh`, `hvacWh`, `pvWh`, `shortfallWh` and `surplusWh` (the day's positive and negative `netLoadWh`, before any battery), `minPriceMicroUsdPerKwh`, `maxPriceMicroUsdPerKwh` |
| `2022/days/index.csv` | a representative day, and why it was picked | `file`, `date`, `label`, `why`, `pvWhHome01`, `hvacWhSixHomes`, `maxPriceMicroUsdPerKwh` |
| `2022/days/<date>_<label>.csv` | one slot of one home on that day, all six homes | `name`, `date`, `slot`, `time`, `loadWh`, `pvWh`, `netLoadWh`, `priceMicroUsdPerKwh` |

**The homes:**

| Home | Household | PV | Battery | Battery power |
|---|---|---:|---:|---:|
| `home_01` | single worker | 4.6 kW | 5 kWh | 3 kW |
| `home_02` | retired | 6.8 kW | 7.5 kWh | 5 kW |
| `home_03` | working couple | 6.0 kW | 7.5 kWh | 5 kW |
| `home_04` | remote worker | 6.5 kW | 10 kWh | 5 kW |
| `home_05` | family with children | 7.5 kW | 10 kWh | 5 kW |
| `home_06` | large family | 8.6 kW | 15 kWh | 7 kW |

For every home, the state of charge stays between 20 % and 90 %, and both
efficiencies are 95 %.

**The representative days of 2022.** PV differs between homes only by a constant
factor, so home_01's PV ranks the days for all six.

| Day | Picked as | Why |
|---|---|---|
| 13 June | `summer-sunny` | most PV of June to August |
| 31 December | `winter-cloudy` | least PV of December to February |
| 8 May | `spring-typical` | median PV of March to May |
| 20 October | `autumn-typical` | median PV of September to November |
| 1 January | `heating-peak` | most HVAC energy of November to March, six homes together |
| 6 September | `cooling-peak-and-price-spike` | most HVAC energy of May to September, and the year's highest price, 1.998 USD/kWh. The day of the 2022 California heat wave |

## What this extract is not

- **Not the controllers' decisions.** It is what the house needs and what the
  sun gives. What a controller then charged, discharged, bought and sold is in
  the honest arms' step logs, in the sibling repository
  `Demo_PlanApplyEvaluate`; `data/hems/` keeps only their daily totals.
  Step 6 needs those step logs.
- **One difference to keep in mind:** the arms' records go down to 10 % state of
  charge (`minSocBps` 1000), while `homes.csv` gives 20 % as the minimum for
  every home. The arms ran with their own battery settings.
