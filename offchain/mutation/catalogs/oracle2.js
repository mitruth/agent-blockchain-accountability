// v0.2 step 1: the account's slot grid (C4), the four new oracle kinds and
// signer distinctness (spec v0.2, section 4).

const O = "contracts/oracle/OracleVerifier.sol";
const L = "contracts/gate/PositionLedger.sol";
const R = "contracts/gate/DecoderRegistry.sol";

const V2 = "test/oracle/OracleVerifierV2.t.sol";
const MM = "test/gate/MultiMarket.t.sol";
const T = {
  [O]: [V2, "test/oracle/OracleVerifier.t.sol", "test/gate/GateReadings.t.sol"],
  [L]: [MM, "test/gate/PositionLedger.t.sol"],
  [R]: [MM],
};

export default {
  name: "oracle2",
  tests: [V2, MM, "test/oracle/OracleVerifier.t.sol", "test/gate/GateReadings.t.sol", "test/gate/PositionLedger.t.sol"],
  mutants: withTests([
    // --- C4: one slot grid per account ---
    { name: "a market registered without its grid checked", file: R,
      find: "        _fixGrid(msg.sender, origin, uint32(next - origin));\n", replace: "" },
    { name: "a market without a grid registered", file: R,
      find: "        if (next <= origin || next - origin > type(uint32).max) revert DecoderRegistry_NoSlotGrid(target);\n",
      replace: "" },
    { name: "the grid checked on its length only", file: L,
      find: "} else if (grid.origin != origin || grid.slotSeconds != slotSeconds) {",
      replace: "} else if (grid.slotSeconds != slotSeconds) {" },
    { name: "the grid checked on its origin only", file: L,
      find: "} else if (grid.origin != origin || grid.slotSeconds != slotSeconds) {",
      replace: "} else if (grid.origin != origin) {" },
    { name: "a grid of zero length fixed", file: L,
      find: "        if (slotSeconds == 0) revert PositionLedger_ZeroSlotLength();\n", replace: "" },
    { name: "anyone fixes a grid", file: L,
      find: "function fixGrid(address account, uint64 origin, uint32 slotSeconds) external onlyWriter(account) {",
      replace: "function fixGrid(address account, uint64 origin, uint32 slotSeconds) external {" },

    // --- signer distinctness ---
    { name: "a meter or envelope signer may be the BMS signer", file: O,
      find: "        if (_devices[account][a].signer == signer) revert Oracle_SignerNotDistinct(kind, a);\n", replace: "" },
    { name: "a meter or envelope signer may be the PV signer", file: O,
      find: "        if (_devices[account][b].signer == signer) revert Oracle_SignerNotDistinct(kind, b);\n", replace: "" },
    { name: "distinctness in one registration order only", file: O,
      find: "} else if (kind == ReadingKind.BMS || kind == ReadingKind.PV_FORECAST) {", replace: "} else if (false) {" },
    { name: "a signer may be a declared agent key", file: O,
      find: "        if (isAgentKey[account][signer]) revert Oracle_SignerIsAgentKey(signer);\n", replace: "" },
    { name: "an agent key may be a registered signer", file: O,
      find: "if (_devices[msg.sender][ReadingKind(k)].signer == key) revert Oracle_AgentKeyIsSigner(key, ReadingKind(k));",
      replace: "if (false) revert Oracle_AgentKeyIsSigner(key, ReadingKind(k));" },
    { name: "an agent key checked against the BMS signer only", file: O,
      find: "for (uint8 k = 0; k <= uint8(type(ReadingKind).max); ++k) {", replace: "for (uint8 k = 0; k < 1; ++k) {" },
    { name: "one agent key more than the bound", file: O,
      find: "if (agentKeyCount[msg.sender] >= MAX_AGENT_KEYS)", replace: "if (agentKeyCount[msg.sender] > MAX_AGENT_KEYS)" },

    // --- meter: per-slot rules ---
    { name: "a meter reading from any signer accepted", file: O,
      find: "        if (meter != device.signer) revert Oracle_WrongSigner(meter, device.signer);\n", replace: "" },
    { name: "a meter reading for a slot not yet over accepted", file: O,
      find: "        if (uint256(m.slotStart) + length > block.timestamp) revert Oracle_FromTheFuture(m.slotStart, block.timestamp);\n",
      replace: "" },
    { name: "a meter reading refused for the slot that just ended", file: O,
      find: "if (uint256(m.slotStart) + length > block.timestamp)", replace: "if (uint256(m.slotStart) + length >= block.timestamp)" },
    { name: "a meter reading older than the ring accepted", file: O,
      find: "if (block.timestamp - m.slotStart >= ringSeconds) {", replace: "if (block.timestamp - m.slotStart > ringSeconds) {" },
    { name: "a conflicting meter reading accepted", file: O,
      find: "            if (held.digest != digest) revert Oracle_Conflicting(m.slotStart);\n", replace: "" },
    { name: "a meter reading off the slot grid accepted", file: O,
      find: "        if (m.slotStart % length != 0) revert Oracle_BadMeterSlot(m.slotStart, length);\n", replace: "" },
    { name: "the meter ring indexed one slot late", file: O,
      find: "_meters[account][_meterGeneration[account]][(m.slotStart / length) % METER_RING]",
      replace: "_meters[account][_meterGeneration[account]][(m.slotStart / length + 1) % METER_RING]" },
    { name: "the meter view ignores the slot it holds", file: O,
      find: "if (m.digest == bytes32(0) || m.slotStart != slotStart) return (0, 0, false);",
      replace: "if (m.digest == bytes32(0)) return (0, 0, false);" },
    { name: "a new meter keeps the old meter's readings", file: O,
      find: "if (device.signer != signer || _meterSlotSeconds[msg.sender] != length) _meterGeneration[msg.sender] += 1;",
      replace: "if (false) _meterGeneration[msg.sender] += 1;" },

    // --- tariff and envelope ---
    { name: "a schedule with series of different lengths accepted", file: O,
      find: "\n                || s.second.length != s.first.length\n", replace: "\n" },
    { name: "a schedule of any length accepted", file: O,
      find: " || s.first.length > MAX_FORECAST_SLOTS\n", replace: "\n" },
    { name: "a stale schedule served", file: O,
      find: "if (index >= s.first.length || !_isFresh(account, kind, s.issuedAt)) return (0, 0, false);",
      replace: "if (index >= s.first.length) return (0, 0, false);" },
    { name: "a schedule served between its slots", file: O,
      find: "        if (offset % s.slotSeconds != 0) return (0, 0, false);\n", replace: "" },
    { name: "a new tariff signer keeps the old tariff", file: O,
      find: "else if (kind == ReadingKind.TARIFF) delete _tariff[msg.sender];", replace: "else if (kind == ReadingKind.TARIFF) {}" },
    { name: "a new envelope signer keeps the old envelope", file: O,
      find: "else if (kind == ReadingKind.ENVELOPE) delete _envelope[msg.sender];", replace: "else if (kind == ReadingKind.ENVELOPE) {}" },

    // --- grid state ---
    { name: "an expired grid state accepted", file: O,
      find: "        if (g.validUntil < block.timestamp) revert Oracle_Stale(g.issuedAt, block.timestamp, 0);\n", replace: "" },
    { name: "a grid state from the future accepted", file: O,
      find: "        if (g.issuedAt > block.timestamp) revert Oracle_FromTheFuture(g.issuedAt, block.timestamp);\n", replace: "" },
    { name: "a reordered grid state accepted", file: O,
      find: "        if (g.issuedAt < held.state.issuedAt) revert Oracle_Reordered(g.issuedAt, held.state.issuedAt);\n",
      replace: "" },
    { name: "a conflicting grid state accepted", file: O,
      find: "            if (digest != held.digest) revert Oracle_Conflicting(g.issuedAt);\n", replace: "" },
    { name: "a grid state no longer holds at validUntil", file: O,
      find: "&& block.timestamp <= state.validUntil;", replace: "&& block.timestamp < state.validUntil;" },
    { name: "the grid state may take a maximum age", file: O,
      find: "            if (maxAge != 0) revert Oracle_BadMaxAge(maxAge);\n", replace: "" },
  ]),
};

function withTests(mutants) {
  return mutants.map((m) => ({ ...m, tests: T[m.file] }));
}
