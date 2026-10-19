// The oracles of one house, played from the data at a point in market time.
//
// The data's day `dataDate` is laid on a market day starting at `dayStart`
// (UTC seconds): market time t reads data slot indexOfDate(dataDate) +
// (t - dayStart) / 1800, running back into the day before and on into the
// day after as needed.
//
//   batteryAt   the battery at t: an honest arm replayed where the prosumer
//               names one (Alice: "replay": "B2"), otherwise the home's
//               battery from its initial charge
//   forecastAt  the PV forecast from t, summed to the market's slot length

import { Battery, replayArm } from "./battery.js";
import { pvForecast } from "./forecast.js";
import { homeParams, homeSlots, armSettings, armSlots, indexOfDate, resample, DATA_SLOT_SECONDS } from "./data.js";

const cache = new Map();
const once = (key, make) => {
  if (!cache.has(key)) cache.set(key, make());
  return cache.get(key);
};

/** The data slot that market time `t` reads. */
export function dataIndexAt(home, dataDate, dayStart, t) {
  const first = indexOfDate(once(`slots ${home}`, () => homeSlots(home)), dataDate);
  return first + Math.floor((t - dayStart) / DATA_SLOT_SECONDS);
}

/** The battery of prosumer `p` (a deployment entry) at market time `t`: { socWh, dischargeOdometerWh, source }. */
export function batteryAt(p, dataDate, dayStart, t) {
  const i = dataIndexAt(p.home, dataDate, dayStart, t);
  if (p.replay) {
    const states = once(`replay ${p.home} ${p.replay}`, () => replayArm(armSettings(p.home), armSlots(p.replay, p.home)));
    return { ...states[i], source: `arm ${p.replay} of ${p.home}, replayed` };
  }
  return { ...new Battery(homeParams(p.home), DATA_SLOT_SECONDS).state(), source: `${p.home}, initial charge` };
}

/** `count` market slots of PV forecast for prosumer `p` from market time `t`, in `mode`. */
export function forecastAt(p, dataDate, dayStart, t, count, slotSeconds, mode = "actual") {
  const i = dataIndexAt(p.home, dataDate, dayStart, t);
  const perSlot = slotSeconds / DATA_SLOT_SECONDS;
  const slots = once(`slots ${p.home}`, () => homeSlots(p.home));
  return resample(pvForecast(slots, i, count * perSlot, mode), slotSeconds);
}
