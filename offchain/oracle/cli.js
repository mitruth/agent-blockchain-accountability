// npm run oracle:post                              every agent prosumer: a PV forecast and a BMS reading
// npm run oracle:post -- --date 2022-06-13 --mode yesterday --slots 24
// npm run oracle:post -- --attacks                 also try a reordered and a forged reading
//
// On the local node, after `npm run demo:deploy`. For each prosumer with an
// agent, the relay posts a PV forecast for the coming slots and hands in a BMS
// reading for the current slot, both from the prosumer's home in the data:
//
//   the forecast   the home's PV from `--date` on, `--mode` actual (default)
//                  or yesterday, summed to the market's slot length
//   the battery    an honest arm replayed (data/arms/) where the prosumer's
//                  `battery` names one, as Alice's does; otherwise the home's
//                  battery at its initial charge (data/homes/homes.csv)
//
// The data's day is laid on the market's: the current slot takes the data
// slot of the same UTC time of day on `--date`. Then it prints what the
// verifier holds. Run it again within the slot and the battery reading is
// the same, so nothing new is accepted.

import { loadDeployment, now, explain } from "../chain/index.js";
import {
  Battery, replayArm, pvForecast, homeParams, homeSlots, armSettings, armSlots, indexOfDate, resample,
  DATA_SLOT_SECONDS, postForecast, bmsReading, handIn, batteryOf, pvOf, signBms,
} from "./index.js";

function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const date = option("date", "2022-06-13");
const mode = option("mode", "actual");
const marketSlots = Number(option("slots", 24));
const attacks = process.argv.includes("--attacks");

const kWh = (wh) => `${(Number(wh) / 1000).toFixed(3)} kWh`;

async function main() {
  const d = loadDeployment();
  const slotSeconds = d.slotSeconds;
  const factor = slotSeconds / DATA_SLOT_SECONDS;
  const t = await now();
  const slotStart = Math.floor(t / slotSeconds) * slotSeconds;
  const dayOffset = Math.floor((slotStart % 86400) / DATA_SLOT_SECONDS);
  console.log(`Slot starting ${new Date(slotStart * 1000).toISOString()} (UTC), ${slotSeconds / 60}-minute slots; data from ${date}, forecast ${mode}\n`);

  for (const [name, p] of Object.entries(d.prosumers)) {
    if (!p.bms) continue;
    const slots = homeSlots(p.home);
    const start = indexOfDate(slots, date) + dayOffset;

    // The forecast, from the current slot on.
    const pvWh = resample(pvForecast(slots, start, marketSlots * factor, mode), slotSeconds);
    const posted = await postForecast(d, name, { firstSlotStart: slotStart, pvWh, issuedAt: t });

    // The battery at the start of the current slot.
    const state = p.battery !== "model"
      ? replayArm(armSettings(p.home), armSlots(p.battery, p.home))[start]
      : new Battery(homeParams(p.home), slotSeconds).state();
    const reading = await bmsReading(d, name, slotStart, state);
    const receipt = await handIn(d, reading);
    const fresh = receipt.logs.length > 0;

    const held = await batteryOf(d, name);
    const source = p.battery !== "model" ? `arm ${p.battery} of ${p.home}` : `${p.home}, initial charge`;
    console.log(`${name} (${source})`);
    console.log(`  battery   ${kWh(held.socWh)} stored, odometer ${kWh(held.dischargeOdometerWh)}, fresh: ${held.fresh}${fresh ? "" : " (already held)"}`);
    const next = [];
    for (let k = 0; k < Math.min(marketSlots, 6); k++) {
      const pv = await pvOf(d, name, slotStart + k * slotSeconds);
      next.push(pv.usable ? kWh(pv.pvWh) : "n/a");
    }
    console.log(`  forecast  ${posted.isNew ? "posted" : "already held"}, ${pvWh.length} slots; next: ${next.join(", ")}`);

    if (attacks) {
      const older = await bmsReading(d, name, slotStart - 1, { ...state, socWh: state.socWh + 1000 });
      const forged = await signBms(d.oracles.pvProvider.keyIndex, d.chainId, d.contracts.oracle, {
        account: p.account, timestamp: slotStart + 1, socWh: 99_999, dischargeOdometerWh: state.dischargeOdometerWh,
      });
      for (const [what, signed] of [["an older reading, 1 kWh fuller", older], ["a reading signed by another key", forged]]) {
        try {
          await handIn(d, signed);
          console.log(`  !! ${what} was accepted`);
        } catch (e) {
          console.log(`  ${what}: refused, ${explain(e)}`);
        }
      }
    }
    console.log("");
  }
}

main().catch((e) => {
  console.error(explain(e));
  process.exit(1);
});
