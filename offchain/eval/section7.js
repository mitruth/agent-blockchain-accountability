// node offchain/eval/section7.js [--report docs/reports/section7-<date>.md]
//
// Spec v0.2 section 7, the new attacks: each must be shown blocked by the
// policy that names it, and shown to pass with that policy removed. Every
// attack is a pair of Solidity tests in the policy's own test file; this
// runs all the pairs in one Hardhat run and reports each test's outcome.
// Needs the contracts built (npm run build).

import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { ROOT } from "../chain/paths.js";

/** [attack, policy, file, blocked test, counterpart test, what the counterpart shows]. */
export const ATTACKS = [
  ["Price walk: 12 bids, each 3 % above the last", "A3T", "test/policies/TariffBand.t.sol",
    "test_priceWalk_isBlockedByA3T", "test_priceWalk_passesUnderA3Alone", "passes with A3T removed"],
  ["Collusive transfer: sales inside A3T's band but under feed-in", "S7", "test/policies/DominatedTradePolicy.t.sol",
    "test_collusiveTransfer_isBlockedByS7", "test_collusiveTransfer_passesUnderA3TAlone", "passes with S7 removed"],
  ["Round-trip churn on one slot, split across two markets", "S8", "test/policies/RoundTripPolicy.t.sol",
    "test_churnAcrossTwoMarkets_isStoppedByS8", "test_churnAcrossTwoMarkets_passesWithoutS8", "passes with S8 removed"],
  ["Chronic oversell against an inflated BMS state of charge; S3 passes", "S9", "test/policies/DeliveryReconciliationPolicy.t.sol",
    "test_chronicOversell_isStoppedByS9", "test_chronicOversell_passesWithoutS9", "passes with S9 removed"],
  ["Meter withholding: the keeper stops posting readings", "S9", "test/policies/DeliveryReconciliationPolicy.t.sol",
    "test_meterWithholding_failsClosed", "test_meterWithholding_passesWithoutS9", "passes with S9 removed"],
  ["Envelope breach, split across orders and two markets", "S10", "test/policies/OperatingEnvelopePolicy.t.sol",
    "test_breachAcrossMarkets_isBlockedByS10", "test_breachAcrossMarkets_passesWithoutS10", "passes with S10 removed"],
  ["Probing campaign: binary search for the S1 cap", "G1", "test/gate/SessionBreaker.t.sol",
    "test_probingCampaign_isSuspendedByG1", "test_probingCampaign_findsTheCapWithoutG1", "finds the cap with G1 removed"],
  ["On-off agent: 2-slot bursts, 10-slot rests", "G1", "test/gate/SessionBreaker.t.sol",
    "test_onOffAgent_isSuspendedWithinTheFlagWindow", "test_onOffAgent_spacedBeyondTheWindowIsNeverSuspended",
    "the same bursts spaced beyond the 24 h window are never suspended"],
  ["Counter-grid trading under ALERT, cancelling sales in DEFICIT", "A10", "test/policies/GridStatePolicy.t.sol",
    "test_counterGrid_isBlockedByA10", "test_counterGrid_passesWithoutA10", "passes with A10 removed"],
  ["Signer collusion: the agent's address registered as a signer", "registration", "test/oracle/OracleVerifierV2.t.sol",
    "test_noAgentKeyMayBeARegisteredSigner", "test_noSignerOfAnyKindMayBeADeclaredAgentKey", "the converse: a signer cannot be declared an agent"],
  ["A9: a withdrawal to the agent", "A9", "test/gate/RecipientLock.t.sol",
    "test_aWithdrawalToTheAgentIsRefused", "test_aWithdrawalToTheAccountPasses", "a withdrawal to the account passes"],
  ["A9: an approval for an unregistered spender", "A9", "test/gate/RecipientLock.t.sol",
    "test_anAllowanceForAnyoneElseIsRefused", "test_anAllowanceForARegisteredMarketPasses", "an allowance for a registered market passes"],
  ["A9: a funds-moving selector without a recipient decoder", "A9", "test/gate/RecipientLock.t.sol",
    "test_aFundsMoveWithoutADecodableRecipientCannotBeRegistered", "test_theTokenDecoderExposesEveryRecipient", "the token decoder exposes every recipient"],
];

const arg = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : null;
};

function main() {
  const files = [...new Set(ATTACKS.map((a) => a[2]))];
  const names = ATTACKS.flatMap((a) => [a[3], a[4]]);
  const grep = `^(${names.join("|")})\\(`;
  const p = spawnSync("npx", ["hardhat", "test", "solidity", "--grep", `"${grep}"`, ...files], {
    cwd: ROOT, shell: true, encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
  });
  const out = (p.stdout ?? "") + (p.stderr ?? "");
  const passed = new Set([...out.matchAll(/✔ (\w+)\(/g)].map((m) => m[1]));
  const ran = (n) => passed.has(n) || new RegExp(`\\d+\\) ${n}\\(`).test(out);
  let failures = 0;
  const rows = ATTACKS.map(([attack, policy, file, blocked, counter, shows]) => {
    const ok = passed.has(blocked) && passed.has(counter);
    if (!ok) failures++;
    const state = (n) => (passed.has(n) ? "passes" : ran(n) ? "FAILS" : "not run");
    return `| ${attack} | ${policy} | \`${blocked}\` ${state(blocked)} | \`${counter}\` ${state(counter)}: ${shows} | \`${file}\` |`;
  });
  const lines = [
    `# Spec v0.2 section 7: the attacks, ${new Date().toISOString().slice(0, 10)}`,
    "",
    "Each attack is a pair of Solidity tests: the attack blocked by the policy that",
    "names it, and its counterpart. Run by `node offchain/eval/section7.js`.",
    "",
    "| Attack | Blocked by | Blocked | Counterpart | File |",
    "|---|---|---|---|---|",
    ...rows,
    "",
    `${ATTACKS.length - failures} of ${ATTACKS.length} attacks shown both ways.`,
    "",
  ];
  console.log(lines.join("\n"));
  const report = arg("report");
  if (report) fs.writeFileSync(report, lines.join("\n"));
  process.exit(failures === 0 && p.status === 0 ? 0 : 1);
}

main();
