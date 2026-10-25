// v0.2 step 6: S10, OperatingEnvelopePolicy.

const E = "contracts/policies/OperatingEnvelopePolicy.sol";
const ET = "test/policies/OperatingEnvelopePolicy.t.sol";

export default {
  name: "envelope",
  tests: [ET],
  mutants: [
    // --- the verdicts ---
    { name: "S10 an equal excess is a worsening", file: E,
      find: "if (excessAfter > excessBefore) worse = true;", replace: "if (excessAfter >= excessBefore) worse = true;" },
    { name: "S10 never rejects", file: E,
      find: "if (worse) r.verdict = Verdict.REJECT;", replace: "if (false) r.verdict = Verdict.REJECT;" },
    { name: "S10 flags at sigma", file: E,
      find: "if (useAfter > soft && useAfter > useBefore) flag = true;", replace: "if (useAfter >= soft && useAfter > useBefore) flag = true;" },
    { name: "S10 flags a reduction", file: E,
      find: "if (useAfter > soft && useAfter > useBefore) flag = true;", replace: "if (useAfter > soft) flag = true;" },
    { name: "S10 never flags", file: E,
      find: "else if (flag) r.verdict = Verdict.FLAG;", replace: "else if (false) r.verdict = Verdict.FLAG;" },

    // --- the limits ---
    { name: "S10 the envelope ignored", file: E,
      find: "if (usable) return (e, i, true);", replace: "if (false) return (e, i, true);" },
    { name: "S10 the static limit not per slot", file: E,
      find: "uint64((uint256(_instances[account][policyId].config.connectionW) * g.slotSeconds) / 3600)",
      replace: "uint64(uint256(_instances[account][policyId].config.connectionW))" },
    { name: "S10 use against the other limit", file: E,
      find: "uint256 limit = ne > 0 ? exportWh : importWh;", replace: "uint256 limit = ne > 0 ? importWh : exportWh;" },
    { name: "S10 export excess against the import limit", file: E,
      find: "if (ne > 0) return uint256(ne) > exportWh ? uint256(ne) - exportWh : 0;",
      replace: "if (ne > 0) return uint256(ne) > importWh ? uint256(ne) - importWh : 0;" },
    { name: "S10 use rounded down", file: E,
      find: "return (magnitude * BPS + limit - 1) / limit;", replace: "return (magnitude * BPS) / limit;" },
    { name: "S10 a zero limit is no use", file: E,
      find: "if (limit == 0) return UNBOUNDED;", replace: "if (limit == 0) return 0;" },

    // --- the position ---
    { name: "S10 the position gross, not net", file: E,
      find: "int256 before = int256(uint256(p.committedSellWh)) - int256(uint256(p.committedBuyWh));",
      replace: "int256 before = int256(uint256(p.committedSellWh));" },
    { name: "S10 CANCEL legs added", file: E,
      find: "int256 qty = leg.kind == OrderKind.PLACE ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));",
      replace: "int256 qty = int256(uint256(leg.qtyWh));" },
    { name: "S10 the legs of one slot not merged", file: E,
      find: "while (k < distinct && all[k].slot != leg.slot) ++k;", replace: "k = distinct;" },
    { name: "S10 the first slot not judged", file: E,
      find: "for (uint256 k = 0; k < slots.length; ++k) {", replace: "for (uint256 k = 1; k < slots.length; ++k) {" },

    // --- configuration ---
    { name: "S10 a higher P_conn is not a widening", file: E,
      find: "return n.connectionW > o.connectionW ||", replace: "return" },
    { name: "S10 a higher sigma is not a widening", file: E,
      find: "|| n.softBps > o.softBps ?", replace: "?" },
    { name: "S10 sigma above 100 % is valid", file: E,
      find: "if (n.softBps > BPS) return ConfigChange.INVALID;", replace: "" },
  ].map((m) => ({ ...m, tests: [ET] })),
};
