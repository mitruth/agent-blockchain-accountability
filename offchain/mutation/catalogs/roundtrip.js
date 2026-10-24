// v0.2 step 4: S8, the same-slot round-trip quota, RoundTripPolicy.

const R = "contracts/policies/RoundTripPolicy.sol";
const RT = "test/policies/RoundTripPolicy.t.sol";

export default {
  name: "roundtrip",
  tests: [RT],
  mutants: [
    // --- what a submission adds ---
    { name: "S8 max for min, before", file: R,
      find: "int256 before = b < s ? b : s;", replace: "int256 before = b > s ? b : s;" },
    { name: "S8 max for min, after", file: R,
      find: "int256 after_ = b2 < s2 ? b2 : s2;", replace: "int256 after_ = b2 > s2 ? b2 : s2;" },
    { name: "S8 before and after swapped", file: R,
      find: "if (after_ > before) added += uint256(after_ - before);", replace: "if (before > after_) added += uint256(before - after_);" },
    { name: "S8 a decrease counted too", file: R,
      find: "if (after_ > before) added += uint256(after_ - before);",
      replace: "added += uint256(after_ > before ? after_ - before : before - after_);" },
    { name: "S8 the whole position counted, not the change", file: R,
      find: "if (after_ > before) added += uint256(after_ - before);", replace: "if (after_ > 0) added += uint256(after_);" },
    { name: "S8 CANCEL legs not subtracted", file: R,
      find: ": -int256(uint256(leg.qtyWh));", replace: ": int256(0);" },
    { name: "S8 CANCEL legs added", file: R,
      find: "int256 qty = leg.kind == OrderKind.PLACE ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));",
      replace: "int256 qty = int256(uint256(leg.qtyWh));" },
    { name: "S8 every leg on the buy side", file: R,
      find: "if (leg.side == Side.BUY) buy[k] += qty;", replace: "if (true) buy[k] += qty;" },
    { name: "S8 the legs on one slot not merged", file: R,
      find: "while (k < distinct && slots[k] != leg.slot) ++k;", replace: "k = distinct;" },
    { name: "S8 the first slot skipped", file: R,
      find: "for (uint256 k = 0; k < distinct; ++k) {", replace: "for (uint256 k = 1; k < distinct; ++k) {" },

    // --- bounds ---
    { name: "S8 flags at the soft bound", file: R,
      find: "else if (r.valueAfter > r.soft) r.verdict = Verdict.FLAG;", replace: "else if (r.valueAfter >= r.soft) r.verdict = Verdict.FLAG;" },
    { name: "S8 never flags", file: R,
      find: "else if (r.valueAfter > r.soft) r.verdict = Verdict.FLAG;", replace: "else if (false) r.verdict = Verdict.FLAG;" },
    { name: "S8 never rejects", file: R,
      find: "else if (amount > type(uint64).max || !w.fits(ctx.time, uint64(amount))) r.verdict = Verdict.REJECT;",
      replace: "else if (amount > type(uint64).max) r.verdict = Verdict.REJECT;" },
    { name: "S8 a reduction judged too", file: R,
      find: "if (amount == 0) r.verdict = Verdict.EXECUTE;\n        else if (amount", replace: "if (false) r.verdict = Verdict.EXECUTE;\n        else if (amount" },

    // --- counting ---
    { name: "S8 nothing added to the window", file: R,
      find: "if (amount != 0) _windows[account][policyId].add(ctx.time, uint64(amount));", replace: "" },
    { name: "S8 a credit given back", file: R,
      find: "function credit(address, bytes32, Release calldata) external override onlyGate {}",
      replace: "function credit(address account, bytes32 policyId, Release calldata release) external override onlyGate {\n        _windows[account][policyId].credit(block.timestamp, release.placedAt, release.releasedWh);\n    }" },

    // --- configuration ---
    { name: "S8 a higher cap is not a widening", file: R,
      find: "|| n.cap > w.cap ||", replace: "||" },
    { name: "S8 a higher soft bound is not a widening", file: R,
      find: "bool looser = next.soft > inst.soft ||", replace: "bool looser =" },
    { name: "S8 another shape is not a widening", file: R,
      find: "return restarts || looser ?", replace: "return looser ?" },
    { name: "S8 a soft bound above the cap is valid", file: R,
      find: " || next.soft > next.window.cap) return ConfigChange.INVALID;", replace: ") return ConfigChange.INVALID;" },
  ].map((m) => ({ ...m, tests: [RT] })),
};
