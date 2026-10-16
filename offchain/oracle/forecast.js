// The PV forecast the provider signs: Wh per data slot, from a start index
// of a home's series, in one of two modes.
//
//   actual     what the sun then gave: a perfect forecast, for the demo
//   yesterday  the same slots one day earlier: a naive forecast with the
//              errors real weather brings, for the tests and the evaluation

import { SLOTS_PER_DAY } from "./data.js";

export const MODES = ["actual", "yesterday"];

/** `count` data slots of PV forecast from `start`, in `mode`. */
export function pvForecast(slots, start, count, mode = "actual") {
  const from = mode === "actual" ? start : mode === "yesterday" ? start - SLOTS_PER_DAY : NaN;
  if (Number.isNaN(from)) throw new Error(`unknown forecast mode "${mode}"; use ${MODES.join(" or ")}`);
  if (from < 0 || from + count > slots.length) throw new Error(`the series has no slots ${from} to ${from + count - 1}`);
  return slots.slice(from, from + count).map((s) => Number(s.pvWh));
}
