// v0.2 step 2: G1, the session circuit breaker (SessionBreaker and its hooks
// in the gate), and A9, the recipient lock (the gate, the registry's call
// kinds, the decoders' classification).

const S = "contracts/gate/SessionBreaker.sol";
const G = "contracts/gate/PolicyGate.sol";
const R = "contracts/gate/DecoderRegistry.sol";
const P = "contracts/market/PaymentTokenDecoder.sol";
const D = "contracts/market/ProsumerDecoder.sol";

const SB = "test/gate/SessionBreaker.t.sol";
const RL = "test/gate/RecipientLock.t.sol";
const GM = "test/market/GatedMarket.t.sol";
const T = {
  [S]: [SB, RL],
  [G]: [SB, RL, "test/gate/PolicyPhases.t.sol", "test/gate/KeyModel.t.sol"],
  [R]: [RL, "test/gate/MultiMarket.t.sol", "test/gate/KeyModel.t.sol"],
  [P]: [RL, GM],
  [D]: [GM],
};

export default {
  name: "breaker",
  tests: [SB, RL, GM, "test/gate/PolicyPhases.t.sol", "test/gate/KeyModel.t.sol", "test/gate/MultiMarket.t.sol"],
  mutants: withTests([
    // --- G1: counting and suspending ---
    { name: "G1 reject cap exclusive", file: S,
      find: "bool overRejects = rejectsUsed > r.config.cap;", replace: "bool overRejects = rejectsUsed >= r.config.cap;" },
    { name: "G1 flag cap exclusive", file: S,
      find: "bool overFlags = flagsUsed > f.config.cap;", replace: "bool overFlags = flagsUsed >= f.config.cap;" },
    { name: "G1 rejections not counted", file: S,
      find: "        if (rejected) r.add(block.timestamp, 1);\n", replace: "" },
    { name: "G1 flags not counted", file: S,
      find: "        if (flagged) f.add(block.timestamp, 1);\n", replace: "" },
    { name: "G1 counts while suspended", file: S,
      find: "if (!s.on || s.suspended) return;", replace: "if (!s.on) return;" },
    { name: "G1 counts while off", file: S,
      find: "if (!s.on || s.suspended) return;", replace: "if (s.suspended) return;" },
    { name: "G1 a suspended account passes everything", file: S,
      find: "        return onlyCancels;\n", replace: "        return true;\n" },
    { name: "G1 a suspended account passes nothing", file: S,
      find: "        return onlyCancels;\n", replace: "        return false;\n" },
    { name: "G1 cooldown boundary exclusive", file: S,
      find: "block.timestamp >= uint256(s.suspendedAt) + s.cooldownSeconds", replace: "block.timestamp > uint256(s.suspendedAt) + s.cooldownSeconds" },
    { name: "G1 no cooldown reinstates at once", file: S,
      find: "if (s.cooldownSeconds != 0 && block.timestamp", replace: "if (block.timestamp" },
    { name: "G1 owner reinstatement keeps the windows", file: S,
      find: "        _rejects[account][generation].clear();\n        _flags[account][generation].clear();\n        emit AgentReinstated(account, Reinstatement.OWNER",
      replace: "        emit AgentReinstated(account, Reinstatement.OWNER" },
    { name: "G1 only the gate records: check removed", file: S,
      find: "function record(address account, uint64 generation, bool rejected, bool flagged) external onlyGate {",
      replace: "function record(address account, uint64 generation, bool rejected, bool flagged) external {" },

    // --- G1: configuration ---
    { name: "G1 a higher cap is not a widening", file: S,
      find: "next.buckets != current.buckets || next.cap > current.cap;", replace: "next.buckets != current.buckets;" },
    { name: "G1 another window shape is not a widening", file: S,
      find: "return next.step != current.step || next.buckets != current.buckets || next.cap > current.cap;",
      replace: "return next.cap > current.cap;" },
    { name: "G1 a cooldown where there was none is not a widening", file: S,
      find: "(n.cooldownSeconds != 0 && (s.cooldownSeconds == 0 || n.cooldownSeconds < s.cooldownSeconds))",
      replace: "(n.cooldownSeconds != 0 && n.cooldownSeconds < s.cooldownSeconds)" },
    { name: "G1 turning off is not a widening", file: S,
      find: "if (config.length == 0) return s.on ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;",
      replace: "if (config.length == 0) return ConfigChange.TIGHTEN;" },
    { name: "G1 a widening applies at once", file: S,
      find: "        if (change == ConfigChange.TIGHTEN) {\n", replace: "        if (true) {\n" },
    { name: "G1 the timelock not checked", file: S,
      find: "        if (block.timestamp < p.eta) revert Breaker_TimelockActive(p.eta);\n", replace: "" },
    { name: "G1 a later write keeps the queued widening", file: S,
      find: "        _dropProposal(account, generation);\n", replace: "" },
    { name: "G1 a window of any class", file: S,
      find: "return c.kind == WindowLib.Kind.SLIDING && WindowLib.isValid(c)", replace: "return WindowLib.isValid(c)" },
    { name: "G1 any cooldown", file: S,
      find: "|| n.cooldownSeconds > MAX_COOLDOWN)", replace: "|| n.cooldownSeconds > MAX_COOLDOWN + 1 days)" },

    // --- G1: the gate's hooks ---
    { name: "G1 never asked before the policies", file: G,
      find: "if (!breaker.admit(account, generationOf(account), _onlyCancels(kind, legs))) {", replace: "if (false) {" },
    { name: "G1 a suspended refusal goes on to the market", file: G, nth: 1,
      find: "            emit Rejected(account, orderHash);\n            return orderHash;", replace: "            emit Rejected(account, orderHash);" },
    { name: "G1 a modification counts as cancel-only", file: G,
      find: "            if (legs[i].kind != OrderKind.CANCEL) return false;",
      replace: "            if (legs[i].kind == OrderKind.PLACE && legs.length == 1) return false;" },
    { name: "G1 a funds move counts as cancel-only", file: G,
      find: "        if (!_isOrderCall(kind)) return false;\n", replace: "" },
    { name: "G1 rejections not recorded", file: G,
      find: "if (!accepted || flagged) breaker.record(account, generationOf(account), !accepted, flagged);",
      replace: "if (flagged) breaker.record(account, generationOf(account), false, flagged);" },
    { name: "G1 flags not recorded", file: G,
      find: "breaker.record(account, generationOf(account), !accepted, flagged);",
      replace: "breaker.record(account, generationOf(account), !accepted, false);" },
    { name: "G1 the breaker allowed as target", file: G,
      find: "\n            || target == address(breaker);", replace: ";" },

    // --- A9: the gate ---
    { name: "A9 any recipient accepted", file: G,
      find: "kind == CallKind.FUNDS_MOVE ? counterparty == account : isMarket(account, counterparty);",
      replace: "kind == CallKind.FUNDS_MOVE ? true : isMarket(account, counterparty);" },
    { name: "A9 any non-zero recipient accepted", file: G,
      find: "kind == CallKind.FUNDS_MOVE ? counterparty == account :", replace: "kind == CallKind.FUNDS_MOVE ? counterparty != address(0) :" },
    { name: "A9 any spender accepted", file: G,
      find: "? counterparty == account : isMarket(account, counterparty);", replace: "? counterparty == account : true;" },
    { name: "A9 a refused move not counted by G1", file: G,
      find: "            breaker.record(account, generationOf(account), true, false);\n            return;", replace: "            return;" },
    { name: "A9 a refused move made anyway", file: G,
      find: "            breaker.record(account, generationOf(account), true, false);\n            return;\n", replace: "            breaker.record(account, generationOf(account), true, false);\n" },
    { name: "A9 a funds move takes the order path", file: G,
      find: "        if (!_isOrderCall(kind)) {\n            _moveFunds", replace: "        if (false) {\n            _moveFunds" },

    // --- A9: the registry ---
    { name: "A9 an UNKNOWN call registered", file: R,
      find: "if (kind == CallKind.UNKNOWN || kind == CallKind.OPAQUE_FUNDS_MOVE) {", replace: "if (kind == CallKind.OPAQUE_FUNDS_MOVE) {" },
    { name: "A9 an OPAQUE funds move registered", file: R,
      find: "if (kind == CallKind.UNKNOWN || kind == CallKind.OPAQUE_FUNDS_MOVE) {", replace: "if (kind == CallKind.UNKNOWN) {" },
    { name: "A9 a market's order calls not counted", file: R,
      find: "_orderCalls[msg.sender][generation][target] += 1;", replace: "_orderCalls[msg.sender][generation][target] += 0;" },
    { name: "A9 a re-registered order call counted twice", file: R,
      find: "if (orderCall && !wasOrderCall) _orderCalls", replace: "if (orderCall) _orderCalls" },
    { name: "A9 removeDecoder keeps the market", file: R,
      find: "        if (address(entry.decoder) != address(0) && _isOrderCall(entry.kind)) {\n", replace: "        if (false) {\n" },
    { name: "A9 a market needs two order calls", file: R,
      find: "return _orderCalls[account][generationOf(account)][target] != 0;", replace: "return _orderCalls[account][generationOf(account)][target] > 1;" },
    { name: "A9 a token held to a slot grid", file: R,
      find: "        if (orderCall) {\n            uint64 origin", replace: "        if (true) {\n            uint64 origin" },

    // --- A9: the decoders ---
    { name: "A9 lock is a plain funds move", file: P,
      find: "if (selector == LockableERC1155.lock.selector) return CallKind.OPAQUE_FUNDS_MOVE;",
      replace: "if (selector == LockableERC1155.lock.selector) return CallKind.FUNDS_MOVE;" },
    { name: "A9 unlock without a recipient pays no one", file: P,
      find: "return (recipient == address(0) ? owner : recipient, value);", replace: "return (recipient, value);" },
    { name: "A9 the token's other calls are approvals", file: P,
      find: "        return CallKind.UNKNOWN;\n", replace: "        return CallKind.APPROVAL;\n" },
    { name: "A9 the prosumer contract's other calls are orders", file: D,
      find: "        return CallKind.UNKNOWN;\n", replace: "        return CallKind.ORDER;\n" },
  ]),
};

function withTests(mutants) {
  return mutants.map((m) => ({ ...m, tests: T[m.file] }));
}
