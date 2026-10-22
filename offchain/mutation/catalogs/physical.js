// Step 5: the oracle verifier, readings through the gate, and the physical
// policies -- DeliverabilityPolicy (S3), CyclePolicy (S4), RampPolicy (S5) and
// the horizon they share. Spec 8's three step 5 mutants are marked (spec 8).

const O = "contracts/oracle/OracleVerifier.sol";
const G = "contracts/gate/PolicyGate.sol";
const L = "contracts/gate/PositionLedger.sol";
const H = "contracts/policies/HorizonLib.sol";
const D = "contracts/policies/DeliverabilityPolicy.sol";
const C = "contracts/policies/CyclePolicy.sol";
const R = "contracts/policies/RampPolicy.sol";

const A5 = "test/policies/Step5Acceptance.t.sol";
const T = {
  [O]: ["test/oracle/OracleVerifier.t.sol", "test/gate/GateReadings.t.sol", "test/policies/DeliverabilityPolicy.t.sol"],
  [G]: ["test/gate/GateReadings.t.sol"],
  [L]: ["test/policies/DeliverabilityPolicy.t.sol", "test/policies/RampPolicy.t.sol"],
  [H]: ["test/policies/DeliverabilityPolicy.t.sol", "test/policies/CyclePolicy.t.sol"],
  [D]: ["test/policies/DeliverabilityPolicy.t.sol", A5],
  [C]: ["test/policies/CyclePolicy.t.sol", A5],
  [R]: ["test/policies/RampPolicy.t.sol", A5],
};

export default {
  name: "physical",
  tests: [
    "test/oracle/OracleVerifier.t.sol",
    "test/gate/GateReadings.t.sol",
    "test/policies/DeliverabilityPolicy.t.sol",
    "test/policies/CyclePolicy.t.sol",
    "test/policies/RampPolicy.t.sol",
    A5,
  ],
  mutants: withTests([
    // --- the oracle verifier ---
    { name: "reading accepted with a decreasing timestamp (spec 8)", file: O,
      find: "        if (timestamp < device.lastTimestamp) revert Oracle_Reordered(timestamp, device.lastTimestamp);\n",
      replace: "" },
    { name: "a stale reading accepted", file: O,
      find: "        if (block.timestamp - timestamp > device.maxAge) revert Oracle_Stale(timestamp, block.timestamp, device.maxAge);\n",
      replace: "" },
    { name: "the maximum age exclusive", file: O,
      find: "if (block.timestamp - timestamp > device.maxAge) revert",
      replace: "if (block.timestamp - timestamp >= device.maxAge) revert" },
    { name: "a reading from the future accepted", file: O,
      find: "        if (timestamp > block.timestamp) revert Oracle_FromTheFuture(timestamp, block.timestamp);\n",
      replace: "" },
    { name: "any signer accepted", file: O,
      find: "        if (recovered != device.signer) revert Oracle_WrongSigner(recovered, device.signer);\n",
      replace: "" },
    { name: "the high-s twin accepted", file: O,
      find: "if (uint256(s) > HALF_CURVE_ORDER || (v != 27 && v != 28))", replace: "if (v != 27 && v != 28)" },
    { name: "a conflicting reading with the same timestamp accepted", file: O,
      find: "            if (digest != device.lastDigest) revert Oracle_Conflicting(timestamp);\n", replace: "" },
    { name: "the odometer may go down", file: O,
      find: "                revert Oracle_OdometerWentDown(r.dischargeOdometerWh, last.dischargeOdometerWh);\n",
      replace: "" },
    { name: "a new signer keeps the old device's reading", file: O,
      find: "            if (kind == ReadingKind.BMS) delete _bms[msg.sender];",
      replace: "            if (kind == ReadingKind.BMS) {}" },
    { name: "a stored reading never goes stale", file: O,
      find: "        return device.signer != address(0) && timestamp <= block.timestamp\n            && block.timestamp - timestamp <= device.maxAge;",
      replace: "        return device.signer != address(0) && timestamp <= block.timestamp;" },
    { name: "a forecast served between its slots", file: O,
      find: "        if (offset % f.slotSeconds != 0) return (0, false);\n", replace: "" },
    { name: "a stale forecast served to the policies", file: O,
      find: "\n                || !_isFresh(account, ReadingKind.PV_FORECAST, f.issuedAt)\n", replace: "\n" },
    { name: "a forecast of any length", file: O,
      find: " || f.pvWh.length > MAX_FORECAST_SLOTS) {", replace: ") {" },
    { name: "the domain does not bind the chain", file: O,
      find: "VERSION_HASH, block.chainid, address(this)", replace: "VERSION_HASH, uint256(1), address(this)" },

    // --- readings through the gate ---
    { name: "a reading for another account accepted", file: G,
      find: "            if (forAccount != account) revert PolicyGate_ReadingForAnotherAccount(forAccount);\n", replace: "" },
    { name: "any number of readings", file: G,
      find: "        if (readings.length > MAX_READINGS) revert PolicyGate_TooManyReadings(readings.length);\n", replace: "" },
    { name: "the verifier allowed as target", file: G,
      find: "|| target == address(ledger) || target == address(oracle)\n", replace: "|| target == address(ledger)\n" },
    { name: "the ledger's batch view off by one slot", file: L,
      find: "_positions[account][uint32(firstSlot + i)]", replace: "_positions[account][uint32(firstSlot + i + 1)]" },

    // --- the horizon ---
    { name: "the horizon starts a slot late", file: H,
      find: "        h.firstSlot = uint32(slot - back);", replace: "        h.firstSlot = uint32(slot - back + 1);" },

    // --- S3 ---
    { name: "placed buys credited in the S3 floor (spec 8)", file: D,
      find: "pvCredit + int256(uint256(p.clearedBuyWh)) - sold - l.reserveWh", replace: "pvCredit + bought - sold - l.reserveWh" },
    { name: "S3 accepts a placement outside its horizon (spec 8: H_slots <= k)", file: D,
      find: "                if (placing) return (inputs, false);\n", replace: "" },
    { name: "S3 without a fresh reading", file: D,
      find: "            if (!fresh) return (before, after_, Unjudged.NO_FRESH_READING);\n", replace: "" },
    { name: "S3 floor losses rounded down", file: D,
      find: "level[0] -= (-flow * int256(BPS) + l.etaDischarge - 1) / l.etaDischarge;",
      replace: "level[0] -= (-flow * int256(BPS)) / l.etaDischarge;" },
    { name: "S3 shortfall not counted", file: D,
      find: "            short = uint256(minWh - level[0]);", replace: "            short = 0;" },
    // --- S3 socMin profile (v0.2 C3) ---
    { name: "S3 floor hour off by one", file: D,
      find: "l.minWh[((l.firstStart + i * l.slotSeconds) / 3600) % 24]", replace: "l.minWh[((l.firstStart + i * l.slotSeconds) / 3600 + 1) % 24]" },
    { name: "S3 floor of the first slot's hour throughout", file: D,
      find: "l.minWh[((l.firstStart + i * l.slotSeconds) / 3600) % 24]", replace: "l.minWh[(l.firstStart / 3600) % 24]" },
    { name: "S3 a floor lowered in one hour is not a widening", file: D,
      find: "            if (next[i] < current[i]) return true;\n", replace: "" },
    { name: "S3 a floor above the ceiling in one hour is valid", file: D,
      find: "            if (profile[i] > m) m = profile[i];\n", replace: "" },
    { name: "S3 profile floor rounded down", file: D,
      find: "l.minWh[hour] = int256((uint256(c.capacityWh) * c.socMinProfileBps[hour] + BPS - 1) / BPS);",
      replace: "l.minWh[hour] = int256((uint256(c.capacityWh) * c.socMinProfileBps[hour]) / BPS);" },
    { name: "S3 ceiling excess not counted", file: D,
      find: "            excess = uint256(level[1] - l.maxWh);", replace: "            excess = 0;" },
    { name: "S3 discharge power not checked", file: D,
      find: "                if (sold > l.dischargeWh + pvCredit) a.dischargeExcessWh += uint256(sold - l.dischargeWh - pvCredit);\n",
      replace: "" },
    { name: "S3 charge power not checked", file: D,
      find: "                if (charge > l.chargeWh) a.chargeExcessWh += uint256(charge - l.chargeWh);\n", replace: "" },
    { name: "S3 PV above a full battery stored", file: D,
      find: "            if (level[0] > l.maxWh) level[0] = l.maxWh;\n", replace: "" },
    { name: "S3 rejects any shortfall, reduced or not", file: D,
      find: "r.verdict = r.valueAfter != 0 && r.valueAfter > r.valueBefore ? Verdict.REJECT",
      replace: "r.verdict = r.valueAfter != 0 ? Verdict.REJECT" },
    { name: "S3 counts a cancellation as a placement", file: D,
      find: "int256 qty = placing ? int256(uint256(leg.qtyWh)) : -int256(uint256(leg.qtyWh));",
      replace: "int256 qty = int256(uint256(leg.qtyWh));" },

    // --- S4 ---
    { name: "S4 discharge never added to the window", file: C,
      find: "            _windows[account][policyId].add(ctx.time, odometer - inst.lastOdometerWh);\n", replace: "" },
    { name: "S4 ignores the odometer beyond the window", file: C,
      find: "            observed += reading.dischargeOdometerWh - inst.lastOdometerWh;\n", replace: "" },
    { name: "S4 pending without the efficiency", file: C,
      find: "        return uint256((houseWh * int256(BPS) + eta - 1) / eta);", replace: "        return uint256(houseWh);" },
    { name: "S4 pending without the PV credit", file: C,
      find: "int256 credit_ = int256((uint256(pv[i]) * inst.pvCreditBps) / BPS);", replace: "int256 credit_ = 0;" },
    { name: "S4 judges a sale without a fresh reading", file: C,
      find: "        if (!fresh) return _unjudged(r);\n", replace: "" },
    { name: "S4 judges a bid as a sale", file: C,
      find: "if (legs[i].kind == OrderKind.PLACE && legs[i].side == Side.SELL) return int256(i);",
      replace: "if (legs[i].kind == OrderKind.PLACE) return int256(i);" },
    { name: "S4 cap exclusive", file: C,
      find: "if (worse && r.valueAfter > r.hard)", replace: "if (worse && r.valueAfter >= r.hard)" },
    { name: "S4 rejects what does not add", file: C,
      find: "        bool worse = r.valueAfter > r.valueBefore;", replace: "        bool worse = true;" },

    // --- S5 ---
    { name: "S5 looks only to the left", file: R,
      find: "ledger.positionsOf(account, from, t == 0 ? 2 : 3)", replace: "ledger.positionsOf(account, from, 2)" },
    { name: "S5 rejects steps it did not make larger", file: R,
      find: "            if (after_ > before) {", replace: "            if (true) {" },
    { name: "S5 rejects above the soft bound", file: R,
      find: "                if (after_ > c.maxStepWh) s_.reject = true;", replace: "                if (after_ > c.softStepWh) s_.reject = true;" },
    { name: "S5 treats a cancellation as a placement", file: R,
      find: "bool adds = (legs[i].side == Side.BUY) == (legs[i].kind == OrderKind.PLACE);",
      replace: "bool adds = legs[i].side == Side.BUY;" },
  ]),
};

function withTests(mutants) {
  return mutants.map((m) => ({ ...m, tests: T[m.file] }));
}
