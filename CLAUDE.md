# PolicyGate: owner-side policies for delegated energy-trading agents

## Who does what
I'm Dan, and I build and own everything in this repo. A student's earlier work (an ERC-7579
account with a custom validation module, natural-language authorization via Grok) is separate
from mine: don't edit it, and don't build on its validator. PolicyGuard, the old daily-record
contract, stays compiling and untouched until I decide whether to retire it (D13).

## The project
An autonomous trading agent (LLM or RL) trades in a peer-to-peer energy market for a prosumer
with PV and a battery. The agent is untrusted: buggy, prompt-injected or malicious. The owner's
policies are enforced on-chain at the owner's ERC-7579 smart account, before any order reaches
the market. The research contribution is the sequence-level policies (sliding windows in money
and energy units, physically anchored by signed oracles), evaluated against attack sequences that
per-action checks let through. This is the implementation behind a paper, so correctness and
evidence matter more than features.

## Where the detail is
All in `docs/`. Read the relevant section before building. Don't invent behaviour the specs
already define.
- `policy-spec-v0.2-gap-policies.md`: the current work. **Section 11 is binding**: what gets
  built, the build order (11.6) and the framing. Sections 1–10 are the analysis and the full spec
  of each policy. Where they disagree with Section 11, Section 11 wins.
- `implemented-policies-brief.md`: what v0.1 built and verified (commit `1259622`), and its
  known deviations from the spec.
- `policy-spec-v0.1-implementation.md`: architecture, key model, decisions D1–D14, invariants.
  Still holds unless v0.2 says otherwise.
The `delegated-authority-enforcement` skill describes an older PolicyGuard work order. Where it
disagrees with these docs, the docs win.

## Architecture in one paragraph
The owner installs `PolicyGate`, an ERC-7579 executor. The agent's only permitted action is
`PolicyGate.submit(target, callData, readings)`. The gate checks the allowlist, decodes the
call into order legs through a per-market decoder, verifies signed oracle readings, runs every
installed policy's `check`, and only if none rejects calls `commit`, has the account make the
market call and books the legs in the `PositionLedger`. A rejection emits events and returns
normally; it never reverts. Policies are separate contracts behind the `IPolicy` interface,
keyed by `(account, policyId)`.

## Stack
Solidity 0.8.25 (cancun, optimizer 200 runs), Hardhat 3.15.0, Foundry 1.8.5 (through Docker),
ModuleKit 0.5.9, OpenZeppelin 5.6.1, viem 2.x, Node 24.19, Python 3.14, npm.
Accounts tested: ERC-7579 reference, Safe7579, Biconomy Nexus, ZeroDev Kernel (via ModuleKit).
Off-chain: Python for the independent verifier, the HEMS simulation and calibration.
Target network: Base Sepolia; everything runs locally until I say otherwise.
Don't add a dependency without asking me.

## Hard rules
- **The proposer is never trusted.** Every check uses a reference the agent does not produce:
  signed oracle readings, the market's own views, the ledger. Never a value from calldata the
  agent chose, except the order itself.
- **The agent has no path** to module management, the gate's registries, the oracle's signer
  registry or any policy's configuration. The account, gate, ledger and oracle are forbidden
  targets. Every change touching the gate gets a test that tries the bypass.
- **No policy check in `validateUserOp`.** ERC-7562 forbids TIMESTAMP and most storage reads
  there. Time- and oracle-dependent logic runs at execution.
- **Enforcement is recomputable from events alone.** Every new quantity, alarm, penalty and
  suspension emits the inputs that produced it, and the independent verifier recomputes it.
- **The verifier is a different algorithm.** Python, brute force over all intervals, never a
  port of the Solidity. It must be able to disagree.
- **Every new comparison gets mutants** (`<=`/`<`, off-by-one, wrong bucket, wrong rounding).
  A surviving mutant means a missing test, never a reason to drop the mutant.
- **Integers only across the contract boundary.** Values round up (D12). Wh as `uint64`.
- **D10:** a submission that only reduces a policy's quantity is never rejected by it. A policy
  that overrides this (S6, A10) declares it in NatSpec and has a test for it.
- **Fail closed** on unjudgeable inputs, unless the spec declares fail-open (A10, S10's static
  fallback), with the reason in the code.
- **Distinct trust anchors.** METER and ENVELOPE signers differ from BMS and PV signers and from
  every agent address, checked at registration.
- **Nothing on-chain loops over a list the agent controls** without a fixed bound.
- **No secrets in any file.** Private keys, RPC URLs, Pimlico and Turnkey credentials come from
  me through git-ignored env files.
- **Nothing outside Section 11.1 gets built**, however small. The market layer (11.5) is the next
  paper: keep interfaces open for it (config records carry their author), but don't build it.

## Evidence rules
- Numbers in reports come from runs in this repo, with the command that produced them.
- Gas: report per policy and combined, at the horizons the spec names (k = 8, 48, 96). Respect
  the per-transaction cap (EIP-7825, 16,777,216).
- Never report anvil or Hardhat wall times as latency.
- False-positive rates come from the honest HEMS arms (B0, B2; A0 and A1 once run), over every
  available data day. Score against B2, not B1.
- An attack counts as blocked only if the same test also shows it passing with the policy
  removed (or under the baseline window class).

## Branches and commits
- One step of the build order (v0.2 Section 11.6) per branch, named `v0.2/<n>-<name>`
  (`v0.2/1-oracles-aggregation`, `v0.2/2-breaker-recipient`, …), stacked on the previous step.
- At the end of a step, stop and hand me: the branch, what the acceptance criteria showed (with
  numbers), a one-line commit message (`feat: …`, `fix: …`, `test: …`, `chore: …`) and three or
  four lines of pull request text.
- Commit or push only when I ask. Commits carry my name only: no `Co-Authored-By` line and no
  Claude footer.

## How I want you to work
- I'm on Windows. Commands must work in PowerShell: no `VAR=x cmd`; use env files.
- For anything larger than one contract or one test file, use plan mode first and show me the
  plan.
- Small, reviewable changes. Before calling a step done, run and pass:
  - Hardhat Solidity tests: `npm test` (new test files must be added to the list in
    `package.json`).
  - Off-chain tests: `npm run test:offchain`.
  - Foundry, including the four real accounts: Docker only, since Smart App Control blocks
    `forge.exe`. Ask me before starting Docker. The command is in the runbook of
    `docs/guide/project-guide.md`: `docker run --rm -v "${PWD}:/repo" -v foundry-svm:/home/foundry/.svm -w /repo --entrypoint forge ghcr.io/foundry-rs/foundry:v1.8.5 test`.
  - Mutation suite: `npm run mutate -- <catalogue>` for the catalogues a step touches;
    `npm run mutate -- --check` to confirm every pattern is still in place. All catalogues take
    about two hours.
  - Verifier agreement: `npm run verify:window`.
  - Gas: the `test_gas_*` tests in the step's acceptance file, run under `npm test`; the report
    goes in `docs/reports/`.
- When the spec is silent or ambiguous, ask me. Don't guess. If something in the repo contradicts
  the spec (an interface that can't carry what a policy needs, a market without a view the
  decoder requires), stop and report before building around it.
- Write tight: short, precise sentences in docs, NatSpec and reports. No filler.

## Where we are
v0.1 is done on `feature/policy-gate-v0.1` (commit `1259622`): PolicyGate, the ledger, the mock
market, WindowLib with five window classes, A1–A6, S1–S6, OracleVerifier (BMS, PV). Evidence:
411 Hardhat, 419 Foundry (4 account implementations), 29 off-chain tests; every mutant caught.
Next: v0.2 step 1 (C1–C5, the four new oracle kinds, signer distinctness). C4, aggregation
across markets, comes first: every sequence policy depends on it.
