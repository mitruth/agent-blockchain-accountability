// Units of the market: energy in Wh, money in the payment token's 6 decimals.

import { parseUnits } from "viem";

/** The payment token has 6 decimals: 1 USD = 1,000,000 units. */
export const USD = 1_000_000n;

/** "0.24" USD (per kWh) in payment units. */
export const price = (eurAmount) => parseUnits(eurAmount, 6);

export function usd(units) {
  const n = BigInt(units);
  const sign = n < 0n ? "-" : "";
  const a = n < 0n ? -n : n;
  return `${sign}${a / USD}.${(a % USD).toString().padStart(6, "0")} USD`;
}

export function kWh(wh) {
  return `${(Number(wh) / 1000).toFixed(3)} kWh`;
}
