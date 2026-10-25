// v0.2 step 5: S9, DeliveryReconciliationPolicy, and the gate's poke and
// resetPolicy.

const D = "contracts/policies/DeliveryReconciliationPolicy.sol";
const G = "contracts/gate/PolicyGate.sol";
const DT = "test/policies/DeliveryReconciliationPolicy.t.sol";

export default {
  name: "delivery",
  tests: [DT],
  mutants: [
    // --- the arithmetic ---
    { name: "S9 alarm at h, not above", file: D,
      find: "if (cusum > c.h) {", replace: "if (cusum >= c.h) {" },
    { name: "S9 the slack k not taken off", file: D,
      find: "uint64 cusum = sum > c.k ? uint64(sum - c.k) : 0;", replace: "uint64 cusum = uint64(sum);" },
    { name: "S9 a net import counts beyond the sale", file: D,
      find: "if (dn <= 0) s = cn;", replace: "if (dn <= 0) s = cn + uint64(uint256(-dn));" },
    { name: "S9 over-delivery counts as a shortfall", file: D,
      find: "else if (uint256(dn) < cn) s = cn - uint64(uint256(dn));",
      replace: "else s = cn > uint64(uint256(dn)) ? cn - uint64(uint256(dn)) : uint64(uint256(dn)) - cn;" },
    { name: "S9 contracted export not net of buys", file: D,
      find: "uint64 cn = p.clearedSellWh > p.clearedBuyWh ? p.clearedSellWh - p.clearedBuyWh : 0;",
      replace: "uint64 cn = p.clearedSellWh;" },
    { name: "S9 C not reset on an alarm", file: D,
      find: "            run.state.cusum = 0;\n", replace: "            run.state.cusum = cusum;\n" },

    // --- when a slot is taken in ---
    { name: "S9 settles at the slot's end, no lag", file: D,
      find: "uint256 settledAt = start + g.slotSeconds + c.settlementLagSeconds;", replace: "uint256 settledAt = start + g.slotSeconds;" },
    { name: "S9 an unreconciled slot taken in", file: D,
      find: "bool reconciled = p.committedBuyWh == p.clearedBuyWh && p.committedSellWh == p.clearedSellWh;",
      replace: "bool reconciled = true;" },
    { name: "S9 a sale without a reading taken in", file: D,
      find: "if (!reconciled || (cn != 0 && !present)) {", replace: "if (!reconciled) {" },
    { name: "S9 maxProcess off by one", file: D,
      find: "while (run.count < c.maxProcess && _step(", replace: "while (run.count <= c.maxProcess && _step(" },
    { name: "S9 a new instance starts at the slot in progress", file: D,
      find: "return uint32((at - g.origin + g.slotSeconds - 1) / g.slotSeconds);", replace: "return uint32((at - g.origin) / g.slotSeconds);" },

    // --- fail closed (D16) and D10 ---
    { name: "S9 blocks without waiting for grace", file: D,
      find: "run.blocked = p.committedSellWh != 0 && t >= settledAt + c.graceSeconds;", replace: "run.blocked = p.committedSellWh != 0;" },
    { name: "S9 grace exclusive", file: D,
      find: "t >= settledAt + c.graceSeconds;", replace: "t > settledAt + c.graceSeconds;" },
    { name: "S9 never blocks", file: D,
      find: "if (sells != 0 && run.blocked) r.verdict = Verdict.REJECT;", replace: "if (false) r.verdict = Verdict.REJECT;" },
    { name: "S9 blocks buys too", file: D,
      find: "if (sells != 0 && run.blocked) r.verdict", replace: "if (run.blocked) r.verdict" },
    { name: "S9 counts a cancellation as a sale", file: D,
      find: "if (legs[i].kind == OrderKind.PLACE && legs[i].side == Side.SELL)", replace: "if (legs[i].side == Side.SELL)" },

    // --- the penalty ---
    { name: "S9 level 2 never rejects", file: D,
      find: "else if (sells != 0 && penalty && level >= 2) r.verdict = Verdict.REJECT;", replace: "else if (false) r.verdict = Verdict.REJECT;" },
    { name: "S9 level 1 never judged", file: D,
      find: "sells != 0 && penalty && level == 1", replace: "false && penalty && level == 1" },
    { name: "S9 H_pen exclusive", file: D,
      find: "!_windows[account][policyId].fits(ctx.time, uint64(sells))", replace: "!_windows[account][policyId].fits(ctx.time, uint64(sells) + 1)" },
    { name: "S9 the penalty never ends", file: D,
      find: "bool penalty = ctx.time < run.state.penaltyUntil;", replace: "bool penalty = run.state.level != 0;" },
    { name: "S9 the penalty's end inclusive", file: D,
      find: "bool penalty = ctx.time < run.state.penaltyUntil;", replace: "bool penalty = ctx.time <= run.state.penaltyUntil;" },
    { name: "S9 a second alarm stays at level 1", file: D,
      find: "uint8 level = _effectiveLevel(run.state, c, t) >= 1 ? 2 : 1;", replace: "uint8 level = 1;" },
    { name: "S9 the first alarm is level 2", file: D,
      find: "uint8 level = _effectiveLevel(run.state, c, t) >= 1 ? 2 : 1;", replace: "uint8 level = _effectiveLevel(run.state, c, t) >= 0 ? 2 : 1;" },
    { name: "S9 the level never decays", file: D,
      find: "uint256 steps = t > st.lastAlarmAt ? (t - st.lastAlarmAt) / c.escalationSeconds : 0;", replace: "uint256 steps = 0;" },
    { name: "S9 commit does not count sells", file: D,
      find: "if (sells != 0) _windows[account][policyId].add(ctx.time, uint64(sells));", replace: "" },
    { name: "S9 no credit for a released sale", file: D,
      find: "        _windows[account][policyId].credit(block.timestamp, release.placedAt, release.releasedWh);\n", replace: "" },

    // --- persistence, poke, reset ---
    { name: "S9 commit persists nothing", file: D,
      find: "_persist(account, policyId, _process(account, policyId, ctx.time));", replace: "" },
    { name: "S9 poke persists nothing", file: D,
      find: "        _persist(account, policyId, run);\n        return run.count;", replace: "        return run.count;" },
    { name: "S9 reset keeps the level", file: D,
      find: "State({next: next, cusum: 0, level: 0, penaltyUntil: 0, lastAlarmAt: 0})",
      replace: "State({next: next, cusum: 0, level: st.level, penaltyUntil: st.penaltyUntil, lastAlarmAt: st.lastAlarmAt})" },
    { name: "S9 reset keeps the pointer", file: D,
      find: "            if (firstUnsettled > next) next = uint32(firstUnsettled);\n", replace: "" },
    { name: "gate poke without an installed instance", file: G,
      find: "        if (!hasPolicy(account, policy, policyId)) revert PolicyGate_NoSuchPolicy(account, address(policy), policyId);\n",
      replace: "" },
    { name: "gate resetPolicy by anyone", file: G,
      find: "function resetPolicy(IPolicy policy, bytes32 policyId) external onlyAccount nonReentrant {",
      replace: "function resetPolicy(IPolicy policy, bytes32 policyId) external nonReentrant {" },

    // --- configuration ---
    { name: "S9 a higher k is not a widening", file: D,
      find: "bool looser = n.k > o.k ||", replace: "bool looser =" },
    { name: "S9 a shorter penalty is not a widening", file: D,
      find: "|| n.penaltySeconds < o.penaltySeconds", replace: "" },
    { name: "S9 a longer grace is not a widening", file: D,
      find: "|| n.graceSeconds > o.graceSeconds", replace: "" },
    { name: "S9 a higher H_pen is not a widening", file: D,
      find: "|| b.cap > a.cap", replace: "" },
    { name: "S9 no processing is valid", file: D,
      find: "|| n.maxProcess == 0 ||", replace: "||" },
  ].map((m) => ({ ...m, tests: [DT] })),
};
