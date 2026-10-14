// Units of the market: energy in Wh, money in the payment token's 6 decimals.

import { parseUnits } from "viem";

/** The payment token has 6 decimals: 1 EUR = 1,000,000 units. */
export const EUR = 1_000_000n;

/** "0.24" EUR (per kWh) in payment units. */
export const price = (eurAmount) => parseUnits(eurAmount, 6);

export function eur(units) {
  const n = BigInt(units);
  const sign = n < 0n ? "-" : "";
  const a = n < 0n ? -n : n;
  return `${sign}${a / EUR}.${(a % EUR).toString().padStart(6, "0")} EUR`;
}

export function kWh(wh) {
  return `${(Number(wh) / 1000).toFixed(3)} kWh`;
}
