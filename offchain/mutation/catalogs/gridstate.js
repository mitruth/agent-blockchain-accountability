// v0.2 step 7: A10, GridStatePolicy.

const G = "contracts/policies/GridStatePolicy.sol";
const GT = "test/policies/GridStatePolicy.t.sol";

export default {
  name: "gridstate",
  tests: [GT],
  mutants: [
    // --- the rules ---
    { name: "A10 DEFICIT refuses an unchanged slot", file: G,
      find: "? c.ne < 0", replace: "? c.ne <= 0" },
    { name: "A10 SURPLUS refuses an unchanged slot", file: G,
      find: "? c.ne > 0 :", replace: "? c.ne >= 0 :" },
    { name: "A10 DEFICIT refuses what helps", file: G,
      find: "? c.ne < 0", replace: "? c.ne > 0" },
    { name: "A10 EMERGENCY refuses cancellations", file: G,
      find: "(s.level == GridLevel.EMERGENCY && c.placed)", replace: "(s.level == GridLevel.EMERGENCY)" },
    { name: "A10 ALERT with no direction refuses placements", file: G,
      find: "(s.level == GridLevel.EMERGENCY && c.placed)", replace: "(c.placed)" },
    { name: "A10 never refuses", file: G,
      find: "if (refused) {", replace: "if (false) {" },

    // --- freshness, level, horizon ---
    { name: "A10 a stale state still applies", file: G,
      find: "if (!fresh || uint8(s.level) < inst.minLevel) return r;", replace: "if (uint8(s.level) < inst.minLevel) return r;" },
    { name: "A10 the minimum level exclusive", file: G,
      find: "uint8(s.level) < inst.minLevel) return r;", replace: "uint8(s.level) <= inst.minLevel) return r;" },
    { name: "A10 the horizon's end inclusive", file: G,
      find: "|| start >= horizonEnd) continue;", replace: "|| start > horizonEnd) continue;" },
    { name: "A10 the horizon ignored", file: G,
      find: "|| start >= horizonEnd) continue;", replace: ") continue;" },

    // --- the change per slot ---
    { name: "A10 the legs of one slot not merged", file: G,
      find: "while (k < distinct && all[k].slot != leg.slot) ++k;", replace: "k = distinct;" },
    { name: "A10 CANCEL legs added", file: G,
      find: "int256 qty = leg.kind == OrderKind.PLACE ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));",
      replace: "int256 qty = int256(uint256(leg.qtyWh));" },
    { name: "A10 the sides swapped", file: G,
      find: "all[k].ne += leg.side == Side.SELL ? qty : -qty;", replace: "all[k].ne += leg.side == Side.BUY ? qty : -qty;" },

    // --- configuration ---
    { name: "A10 a higher minimum level is not a widening", file: G,
      find: "return n.minLevel > inst.minLevel ? ConfigChange.WIDEN", replace: "return false ? ConfigChange.WIDEN" },
    { name: "A10 any minimum level is valid", file: G,
      find: "if (n.minLevel != uint8(GridLevel.ALERT) && n.minLevel != uint8(GridLevel.EMERGENCY)) return ConfigChange.INVALID;",
      replace: "" },
  ].map((m) => ({ ...m, tests: [GT] })),
};
