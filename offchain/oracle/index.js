// oracle: the trusted devices around the gate, played from the project's data.
//
//   typed.js     what they sign: EIP-712 BMS readings and PV forecasts
//   battery.js   a battery as its BMS sees it: a simple model, or an arm replayed
//   forecast.js  the PV forecast: actual, or yesterday's
//   data.js      data/homes/ and data/arms/, and data slots to market slots
//   relay.js     on the chain: post a forecast, sign a reading, read them back
//   play.js      one house's battery and forecast at a point in market time
//   cli.js       npm run oracle:post

export { KIND, TYPES, domain, signBms, signForecast, signTariff, signMeter } from "./typed.js";
export { Battery, replayArm } from "./battery.js";
export { MODES, pvForecast } from "./forecast.js";
export {
  DATA_SLOT_SECONDS, SLOTS_PER_DAY, homeParams, homeSlots, armSettings, armSlots, indexOfDate, resample,
} from "./data.js";
export { postForecast, postTariff, postMeter, bmsReading, handIn, batteryOf, pvOf } from "./relay.js";
export { dataIndexAt, batteryAt, forecastAt, tariffAt } from "./play.js";
