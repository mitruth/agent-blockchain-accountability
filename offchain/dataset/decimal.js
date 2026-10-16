// Decimal strings from the dataset's CSVs to integers, without floating point.
// 0.1945 kWh is 194.4999... Wh as a float; read as a string it is exactly
// 194.5 Wh and rounds once, to 195.

const DIGITS = 9;
const NANO = 10n ** BigInt(DIGITS);

/**
 * "0.194018" → 194018000n, "4.88e-06" → 4880n: the value × 10^9, exact.
 * Throws on anything else, and on a value with more than 9 decimals.
 */
export function parseNano(text) {
  const m = /^(-)?(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(String(text).trim());
  if (!m) throw new Error(`not a decimal: "${text}"`);
  const frac = m[3] ?? "";
  const shift = DIGITS + Number(m[4] ?? 0) - frac.length;
  let n = BigInt(m[2] + frac);
  if (shift >= 0) n *= 10n ** BigInt(shift);
  else {
    const d = 10n ** BigInt(-shift);
    if (n % d) throw new Error(`more than ${DIGITS} decimals: "${text}"`);
    n /= d;
  }
  return m[1] ? -n : n;
}

/** n / d, rounded half away from zero. */
export function roundDiv(n, d) {
  const sign = n < 0n !== d < 0n ? -1n : 1n;
  const a = n < 0n ? -n : n;
  const b = d < 0n ? -d : d;
  const q = a / b;
  return sign * (2n * (a % b) >= b ? q + 1n : q);
}

/** A decimal in some unit, times `factor`, as a rounded integer: ("0.194018", 1000) → 194n. */
export function scaled(text, factor) {
  return roundDiv(parseNano(text) * BigInt(factor), NANO);
}
