// v0.2 step 3: the price policies -- A3T, the tariff band in
// StaticOrderPolicy, and S7, DominatedTradePolicy.

const A = "contracts/policies/StaticOrderPolicy.sol";
const D = "contracts/policies/DominatedTradePolicy.sol";

const TB = "test/policies/TariffBand.t.sol";
const DT = "test/policies/DominatedTradePolicy.t.sol";
const T = {
  [A]: [TB, DT, "test/policies/StaticOrderPolicy.t.sol"],
  [D]: [DT],
};

export default {
  name: "price",
  tests: [TB, DT, "test/policies/StaticOrderPolicy.t.sol"],
  mutants: withTests([
    // --- A3T ---
    { name: "A3T BUY bound exclusive", file: A,
      find: "return leg.price > uint256(retail) * (BPS + c.buyMarkupBps) / BPS;", replace: "return leg.price >= uint256(retail) * (BPS + c.buyMarkupBps) / BPS;" },
    { name: "A3T SELL bound exclusive", file: A,
      find: "return leg.price < (uint256(feedIn) * (BPS - c.sellDiscountBps) + BPS - 1) / BPS;",
      replace: "return leg.price <= (uint256(feedIn) * (BPS - c.sellDiscountBps) + BPS - 1) / BPS;" },
    { name: "A3T BUY bound rounded up", file: A,
      find: "uint256(retail) * (BPS + c.buyMarkupBps) / BPS;", replace: "(uint256(retail) * (BPS + c.buyMarkupBps) + BPS - 1) / BPS;" },
    { name: "A3T SELL bound rounded down", file: A,
      find: "(uint256(feedIn) * (BPS - c.sellDiscountBps) + BPS - 1) / BPS;", replace: "uint256(feedIn) * (BPS - c.sellDiscountBps) / BPS;" },
    { name: "A3T the BUY side takes the SELL beta", file: A,
      find: "(BPS + c.buyMarkupBps)", replace: "(BPS + c.sellDiscountBps)" },
    { name: "A3T the SELL discount ignored", file: A,
      find: "(BPS - c.sellDiscountBps)", replace: "(BPS)" },
    { name: "A3T a SELL measured against retail", file: A,
      find: "return leg.price < (uint256(feedIn)", replace: "return leg.price < (uint256(retail)" },
    { name: "A3T judges without a tariff", file: A,
      find: "        if (!usable) return true;\n", replace: "        if (!usable) return false;\n" },
    { name: "A3T applies when off", file: A,
      find: "if (c.tariffBand && _outsideBand(", replace: "if (_outsideBand(" },
    { name: "A3T never applies", file: A,
      find: "if (c.tariffBand && _outsideBand(", replace: "if (false && _outsideBand(" },
    { name: "A3T the band off is not a widening", file: A,
      find: " || (current.tariffBand && !next.tariffBand)", replace: "" },
    { name: "A3T a higher markup is not a widening", file: A,
      find: "\n            || next.buyMarkupBps > current.buyMarkupBps ||", replace: "\n            ||" },
    { name: "A3T a higher discount is not a widening", file: A,
      find: " || next.sellDiscountBps > current.sellDiscountBps;", replace: ";" },
    { name: "A3T a 100 % discount is invalid", file: A,
      find: "next.sellDiscountBps > BPS) {", replace: "next.sellDiscountBps >= BPS) {" },

    // --- S7 ---
    { name: "S7 a BUY counted below retail", file: D,
      find: "excess = leg.price > retail ? leg.price - retail : 0;", replace: "excess = retail > leg.price ? retail - leg.price : 0;" },
    { name: "S7 a SELL counted above feed-in", file: D,
      find: "excess = feedIn > leg.price ? feedIn - leg.price : 0;", replace: "excess = leg.price > feedIn ? leg.price - feedIn : 0;" },
    { name: "S7 a SELL measured against retail", file: D,
      find: "else excess = feedIn > leg.price ? feedIn - leg.price : 0;", replace: "else excess = retail > leg.price ? retail - leg.price : 0;" },
    { name: "S7 the amount rounded down", file: D,
      find: "return uint64((uint256(perKWh) * qtyWh + 999) / 1000);", replace: "return uint64((uint256(perKWh) * qtyWh) / 1000);" },
    { name: "S7 judges without a tariff", file: D,
      find: "            if (!usable) return (0, false);\n", replace: "            if (!usable) continue;\n" },
    { name: "S7 flags at the soft bound", file: D,
      find: "else if (r.valueAfter > r.soft) r.verdict = Verdict.FLAG;", replace: "else if (r.valueAfter >= r.soft) r.verdict = Verdict.FLAG;" },
    { name: "S7 never flags", file: D,
      find: "else if (r.valueAfter > r.soft) r.verdict = Verdict.FLAG;", replace: "else if (r.valueAfter > r.soft) r.verdict = Verdict.EXECUTE;" },
    { name: "S7 never rejects", file: D,
      find: "!w.fits(ctx.time, uint64(amount))) r.verdict = Verdict.REJECT;", replace: "!w.fits(ctx.time, uint64(amount))) r.verdict = Verdict.FLAG;" },
    { name: "S7 nothing added to the window", file: D,
      find: "        if (total != 0) _windows[account][policyId].add(ctx.time, uint64(total));\n", replace: "" },
    { name: "S7 the excess not kept", file: D,
      find: "            _excess[account][policyId][key] = excess;\n", replace: "            _excess[account][policyId][key] = 1;\n" },
    { name: "S7 the credit looks under the wrong key", file: D,
      find: "release.price, release.placedAt);", replace: "release.price, block.timestamp);" },
    { name: "S7 the filled part given back too", file: D,
      find: " - _valueUp(excess, release.filledWh);", replace: ";" },
    { name: "S7 the credit to the current bucket", file: D,
      find: ".credit(block.timestamp, release.placedAt, amount);", replace: ".credit(block.timestamp, block.timestamp, amount);" },
    { name: "S7 the key ignores the price", file: D,
      find: "return keccak256(abi.encode(market, slot, side, price, placedAt));", replace: "return keccak256(abi.encode(market, slot, side, placedAt));" },
    { name: "S7 a higher cap is not a widening", file: D,
      find: " || n.cap > w.cap", replace: "" },
    { name: "S7 a soft bound above the cap is valid", file: D,
      find: " || next.soft > next.window.cap) return ConfigChange.INVALID;", replace: ") return ConfigChange.INVALID;" },
  ]),
};

function withTests(mutants) {
  return mutants.map((m) => ({ ...m, tests: T[m.file] }));
}
