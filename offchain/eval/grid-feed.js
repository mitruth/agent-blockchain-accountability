// The scripted grid-state episodes (spec v0.2 section 7): days on which the
// grid operator declares an alert while the honest agent trades.
//
// The day-ahead agent trades in the morning for tomorrow. On an episode day
// the operator's state is posted just before it trades, valid for two hours,
// over the next 48 slots: it covers tomorrow from midnight to 09:00, so the
// agent's orders for those slots meet it.
//
//   every 7th day of the year (day 3, 10, ...)    ALERT, DEFICIT
//   every 11th day (day 5, 16, ...), if not above ALERT, SURPLUS
//   every 61st day (day 30, 91, ...), overriding   EMERGENCY, no direction
//
// Fixed days, not drawn, so every run sees the same episodes. The honest
// agent does not read the state: what it is refused is the cost of an alert
// to an agent that ignores the grid.

import { GRID_LEVEL, GRID_DIRECTION } from "../oracle/typed.js";

export const VALID_SECONDS = 2 * 3600;
export const HORIZON_SLOTS = 48;

const dayOfYear = (date) => {
  const d = new Date(`${date}T00:00:00Z`);
  return Math.round((d - Date.UTC(d.getUTCFullYear(), 0, 1)) / 86_400_000);
};

/** The episode for the trading day of `date` (YYYY-MM-DD), or null. */
export function episodeOf(date) {
  const d = dayOfYear(date);
  if (d % 61 === 30) return { level: GRID_LEVEL.EMERGENCY, direction: GRID_DIRECTION.NONE };
  if (d % 7 === 3) return { level: GRID_LEVEL.ALERT, direction: GRID_DIRECTION.DEFICIT };
  if (d % 11 === 5) return { level: GRID_LEVEL.ALERT, direction: GRID_DIRECTION.SURPLUS };
  return null;
}
