// The Brussels clock, for market days. The contracts know only UTC slot
// numbers; local time exists only here. Summer and winter time are handled by
// the time-zone database, so a clock-change day has 23 or 25 hours.

export const TZ = "Europe/Brussels";

/** The Brussels wall clock at `seconds` (UTC): { y, m, d, h, min }. */
export function wallClock(seconds) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  }).formatToParts(new Date(seconds * 1000));
  const v = Object.fromEntries(parts.map((p) => [p.type, Number(p.value)]));
  return { y: v.year, m: v.month, d: v.day, h: v.hour, min: v.minute };
}

/** UTC seconds of y-m-d h:00 on the Brussels wall clock (CET or CEST). */
export function brussels(day, hour) {
  const naive = Date.UTC(day.y, day.m - 1, day.d, hour) / 1000;
  let t = naive - 3600;
  for (let i = 0; i < 3; i++) {
    const w = wallClock(t);
    t += naive - Date.UTC(w.y, w.m - 1, w.d, w.h, w.min) / 1000;
  }
  return t;
}

export function addDays(day, n) {
  const x = new Date(Date.UTC(day.y, day.m - 1, day.d + n));
  return { y: x.getUTCFullYear(), m: x.getUTCMonth() + 1, d: x.getUTCDate() };
}

/**
 * The next day-ahead market day after `t`: delivery 00:00 to 24:00 Brussels
 * time, trading closing at `closingHour`:00 the day before. The first
 * delivery day whose trading is still open. Returns UTC seconds.
 */
export function nextDayAhead(t, slotSeconds, closingHour = 12) {
  let day = addDays(wallClock(t), 1);
  let closesAt = brussels(addDays(day, -1), closingHour);
  if (closesAt <= t) {
    day = addDays(day, 1);
    closesAt = brussels(addDays(day, -1), closingHour);
  }
  const start = brussels(day, 0);
  const end = brussels(addDays(day, 1), 0);
  return { start, end, closesAt, firstSlot: start / slotSeconds, slotCount: (end - start) / slotSeconds };
}

/** "16/10, 00:00 CEST" */
export const label = (seconds) =>
  new Intl.DateTimeFormat("en-GB", {
    timeZone: TZ, day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", timeZoneName: "short",
  }).format(new Date(seconds * 1000));

/** "19:00" */
export const hhmm = (seconds) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(
    new Date(seconds * 1000),
  );
