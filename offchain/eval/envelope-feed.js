// The synthetic DSO envelope (spec v0.2 section 7): the connection's static
// limit both ways, with a midday export cut on some days, the pattern of a
// feeder that cannot take the neighbourhood's solar at noon.
//
//   every slot        export and import limit = the connection's rating times
//                     the slot (home_01: 9 kW, 4,500 Wh a half-hour)
//   a cut day         every CUT_EVERY-th day of the year (day 0 = 1 January):
//                     from 11:00 to 15:00 local, export is cut to
//                     CUT_SHARE of the rating; import is untouched
//
// The days and hours are fixed, not drawn, so that every run sees the same
// envelope. The honest agent does not read it: what it is refused on a cut day
// is the cost of a DSO cut to an agent that ignores the envelope.

export const CUT_EVERY = 5;
export const CUT_FROM_SLOT = 22; // 11:00, in the data's half-hour slots from local midnight
export const CUT_UNTIL_SLOT = 30; // 15:00, exclusive
export const CUT_SHARE = 0.4;

const dayOfYear = (date) => {
  const d = new Date(`${date}T00:00:00Z`);
  return Math.round((d - Date.UTC(d.getUTCFullYear(), 0, 1)) / 86_400_000);
};

/** Whether `date` (YYYY-MM-DD) is a cut day. */
export const isCutDay = (date) => dayOfYear(date) % CUT_EVERY === 0;

/**
 * The limits for one data slot { date, slot }: { exportLimitWh, importLimitWh }.
 * @param connectionW the connection's rating
 * @param slotSeconds the market slot's length
 */
export function envelopeOf(dataSlot, connectionW, slotSeconds) {
  const full = Math.floor((connectionW * slotSeconds) / 3600);
  const slot = Number(dataSlot.slot);
  const cut = isCutDay(dataSlot.date) && slot >= CUT_FROM_SLOT && slot < CUT_UNTIL_SLOT;
  return { exportLimitWh: cut ? Math.floor(full * CUT_SHARE) : full, importLimitWh: full };
}
