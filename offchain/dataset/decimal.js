// Decimal strings from the datasets' CSVs to integers, without floating point.
// 0.1945 kWh is 194.4999... Wh as a float; read as a string it is exactly
// 194.5 Wh and rounds once, to 195. The controllers' logs print floats in
// full (1.4999999952631584, 2.42e-09, -0.0): every digit is read, then the
// value is rounded once.

/** "4.88e-06" → { digits: 488n, exp: -8 }: the value is digits × 10^exp, exactly. */
export function parseDecimal(text) {
  const m = /^([+-])?(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(String(text).trim());
  if (!m) throw new Error(`not a decimal: "${text}"`);
  const frac = m[3] ?? "";
  const digits = BigInt(m[2] + frac);
  return { digits: m[1] === "-" ? -digits : digits, exp: Number(m[4] ?? 0) - frac.length };
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
  const { digits, exp } = parseDecimal(text);
  const n = digits * BigInt(factor);
  return exp >= 0 ? n * 10n ** BigInt(exp) : roundDiv(n, 10n ** BigInt(-exp));
}
