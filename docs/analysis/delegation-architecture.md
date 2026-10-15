# Delegation architecture: comparison with deployed systems

Written 2026-10-14. Status: **decided on 2026-10-15: option 3** (section 10).
It reopened spec decision D1, "executor module; the agent holds no key on the
account", which the brief settled without a comparison with existing systems.

The question: how should an autonomous agent be given bounded authority over a
prosumer's smart account, given that the bounds this project needs are
sequence-level (over a window of orders) and depend on time, oracle data and
market state? And is the architecture built in step 1 a defensible answer?

Each claim below is marked by how it was established:

- **[source]** read in the primary text: the standard, the contract code or
  the vendor's own documentation, listed at the end.
- **[unverified]** believed true but not yet checked against a primary source
  or a test. Section 8 lists how to check each one.

---

## 1. Summary

1. Deployed systems give agents bounded authority in two ways. **Session keys**
   check the agent's actions while the account validates the transaction.
   **Delegation managers** check them while the transaction executes. Both are
   industry practice.
2. The step 1 gate is a delegation manager, built as an ERC-7579 executor
   module. It is the same family as MetaMask's Delegation Framework and
   Coinbase's Spend Permissions, not a new method.
3. The sequence policies of this project need the current time, oracle data
   and market state. The validation phase forbids reading the time and most
   external storage. Session-key systems therefore cannot host these policies
   without workarounds. The delegation-manager family can.
4. Within that family there are three options: keep the bespoke gate, adopt
   MetaMask's ERC-7710 framework, or keep the gate and authenticate the agent
   with a Rhinestone Smart Session. They differ in the agent's entry point and
   in how configuration changes, not in the policies themselves.
5. Switching between the options costs the same now as after build steps 2 and
   3, provided two seams are kept clean (section 7). It costs noticeably more
   after step 4, when the policies plug into the entry point. D1 should be
   re-decided, with evidence from a short prototype, before step 4 starts.

---

## 2. Two families of delegated authority

| | Session keys | Delegation managers |
|---|---|---|
| Deployed examples | Rhinestone and Biconomy Smart Sessions **[source]** | MetaMask Delegation Framework, standardised as ERC-7710 **[source]**. Coinbase Spend Permissions **[source]** |
| What the agent holds | A key registered on the account, scoped by policies | Nothing on the account. It calls a manager contract from its own address |
| Proof of authority | The session key's signature on a user operation | MetaMask: a delegation signed by the account owner, passed in the call. Coinbase: a permission the owner signed and registered |
| When the bounds are checked | While the account validates the user operation | While the manager executes the call |
| How the account acts | It executes its own user operation | The manager makes it act. MetaMask's manager calls the account's `executeFromExecutor` **[source]**. Coinbase's manager is registered as an owner of the wallet **[source]** |
| What the checks may read | Restricted by ERC-7562: no time, little external storage (section 3) | Anything on chain |
| A refused action | Never reaches the chain | Reverts, or, in this project's gate, is recorded and returned (section 4) |

### Where each system sits

**Rhinestone Smart Sessions.** An ERC-7579 validator module. A session scopes
an agent's key to actions (target and function selector), with policies on user
operations, on actions and on ERC-1271 signatures **[source]**. Rhinestone and
Alchemy present it as the way to give agents scoped permissions **[source]**.

**Rhinestone's automation executors.** Rhinestone's own scheduling modules are
executors, but they are triggered by the account itself: their execution
function reads the job from `executionLog[msg.sender]` and executes on the
caller, so the caller must be the account **[source]**. An outside service
reaches them through a session key on the account. That is a hybrid: the session
key authenticates, the executor holds the stateful logic.

**MetaMask Delegation Framework.** The delegate, here the agent, calls
`redeemDelegations` on the Delegation Manager with the owner-signed delegation.
The manager verifies the signature, runs every caveat enforcer's `beforeHook`,
calls `executeFromExecutor` on the delegating account, then runs the
`afterHook`s **[source]**. Caveat enforcers are stateful contracts; MetaMask ships
periodic transfer limits among them, and the spec already uses
`ERC20PeriodTransferEnforcer` as a baseline.

**Coinbase Spend Permissions.** A `SpendPermissionManager` contract is added as
an owner of the Coinbase Smart Wallet. The spender, from its own account, calls
the manager to spend; the manager enforces a per-token allowance per period
**[source]**.

**This project, step 1.** `PolicyGate` is an ERC-7579 executor. The agent calls
`submit` from its own address; the gate checks the agent, the approved call and,
from step 4, the policies; then it calls `executeFromExecutor` on the account.
Structurally this is the MetaMask flow with a registry in place of signed
delegations.

---

## 3. Why the sequence policies cannot live in validation

ERC-7562 sets the rules every bundler applies to the validation phase of the
shared mempool, and builders and standalone bundlers are expected to enforce
them as well **[source]**:

- **OP-011** blocks the environment opcodes, including `TIMESTAMP` and `NUMBER`
  **[source]**.
- **Storage.** The account's own storage is always allowed (STO-010). Storage
  associated with the account in another contract, meaning slots keyed by the
  account's address, is allowed under conditions (STO-021, STO-022). Read-only
  access to any storage of another contract (STO-033) is granted to staked
  entities, which the text lists as paymasters and factories **[source]**.

What each policy needs, against those rules:

| Policy | Needs | Allowed in validation? |
|---|---|---|
| S1 owner budget, S2 export and import caps, S6 cancel quota, S4 cycles | The current time, to place the order in a window bucket | No: OP-011 |
| S3 deliverability | The PV forecast, which a relay posts to a shared contract; slot gate times from the market | No: not storage of the account, nor keyed by it |
| S6 on a cancel | The order's remaining quantity, read from the market | No: market storage |
| S3, S4 | Signed BMS readings | Signature check yes; the staleness bound needs the time, so no |
| S5 ramp, and S3's position terms | The position ledger | Possibly, if keyed by account first; but the ledger is only correct if `reconcile` has read fills from the market |
| A6 target-slot horizon | The current slot | No: OP-011 |
| Every policy | A record of the refusal, for recomputability and for the attack matrix | No: a user operation that fails validation never reaches the chain and emits nothing |

### The workarounds, stated fairly

"Impossible" would overstate it, as the brief's wording did.

- **Time.** A validator can return a validity window, `validAfter` and
  `validUntil`, in its validation data, and the entry point enforces it. The
  agent could claim a window bucket, and validation would check the order
  against that bucket and return its time range **[unverified]** as a working
  pattern for sliding windows. It shifts the time logic into an agent-supplied
  claim plus a range check, for every policy.
- **External storage.** STO-033 extends reads to staked entities. Whether the
  account or a validator module can rely on it, rather than a paymaster or
  factory, is **[unverified]**.
- **Private submission.** A bundler that does not use the shared mempool need
  not apply these rules. That gives up censorship resistance and the standard
  infrastructure, which is the reason for using ERC-4337 at all.

None of the three restores the record of a refused order.

---

## 4. Reasons to stay in the delegation-manager family

In order of strength for a reviewer.

1. **Refusals must be on chain.** The spec requires a refused order to emit
   `Rejected` and a result per policy, so enforcement is recomputable from the
   log alone and the evaluation can count what was blocked. Validation-time
   enforcement cannot produce this record. This is specific to the research and
   does not depend on any workaround argument.
2. **The policies need time, oracle data and market state** (section 3). In
   validation that means a workaround for every policy; in execution it means
   ordinary reads.
3. **The agent can sign nothing for the account.** With a session key, the
   bound on the agent depends on the session being configured exactly right.
   Smart Sessions supports ERC-1271 signing as a policy type **[source]**;
   whether a session can sign without one is **[unverified]**. A key that can
   sign for the account could sign token permits that bypass every policy. In
   the delegation-manager family the agent has no signature authority on the
   account at all. This is the lesson of audit finding F1.
4. **The baselines are deployed systems of the same family.** Coinbase's
   allowance and MetaMask's period enforcer are per-period budgets, so they are
   tumbling windows **[unverified for MetaMask's exact semantics; check the
   enforcer source]**. Under a tumbling window a burst around a period boundary
   admits twice the limit; under a sliding window, at most the limit plus one
   bucket. The comparison is then against what is deployed, not against a straw
   man.

---

## 5. Criticism to expect

| A reviewer may ask | Current answer | Strength |
|---|---|---|
| Why not use Rhinestone's Smart Sessions, the ERC-7579 standard tool for agents? | Section 3 and reason 1 of section 4: the policies cannot run in validation, and refusals would leave no record | Strong for hosting the policies. It does not answer why the agent is not authenticated by a session: see option 3 below |
| Why a bespoke manager rather than ERC-7710, the standard for this family? | Not yet answered. Possible obstacles: enforcers run only when a delegation is redeemed, but expiry credits come from a separate `reconcile` call; an enforcer can only refuse by reverting; delegation terms are signed and fixed, so "tighten now, widen after 24 hours" has no direct equivalent | **Weak until tested.** ERC-7710 leaves the account interface open **[source]**, so whether MetaMask's manager works on a generic ERC-7579 account is **[unverified]** |
| The agent must hold ETH to call the gate | True, as for a Coinbase spender. It may use its own 4337 account with a paymaster | Acceptable |
| Is the gate audited and registered? | No. A Safe7579 account that enforces the Rhinestone module registry would refuse to install it until it is attested | Acceptable for a research prototype; must be stated |

---

## 6. The options for D1

| | 1. Keep the bespoke gate (as built) | 2. MetaMask framework, ERC-7710 | 3. Gate plus Smart Sessions authentication |
|---|---|---|---|
| Agent's entry point | `PolicyGate.submit`, agent registered in the gate | `DelegationManager.redeemDelegations` with an owner-signed delegation | A user operation from the account, signed with a session key scoped to `PolicyGate.submit` only |
| Where policies run | Execution, in the gate | Execution, as caveat enforcers | Execution, in the gate |
| Refusal | Recorded, non-reverting | Revert only | Recorded, non-reverting |
| Configuration, tighten now and widen later | As built | No direct equivalent; needs a design | As built |
| Agent's key on the account | None | None | Scoped session key; its signing scope must be shown to exclude ERC-1271 |
| Standard alignment | ERC-7579 executor; bespoke manager | ERC-7710 plus ERC-7579 | ERC-7579 executor plus Smart Sessions |
| Agent's gas | Its own | Its own | The account's 4337 flow and paymaster |
| Main unknown | None technical; the cost is the reviewer's "why bespoke" | Does it work on Safe7579 or Nexus; can the spec's semantics survive revert-only refusal | Can a session be scoped so it signs nothing else |

---

## 7. Cost of changing later

What each build step touches, if D1 changes after it.

| Component | Built in | If option 2 is chosen later | If option 3 is chosen later |
|---|---|---|---|
| Agent registry, `submit` | Step 1 | Replaced by signed delegations and `redeemDelegations` | Registry replaced by the session; `submit` checks "caller is the account" |
| Call allowlist and decoders | Step 1 | Becomes an enforcer, or a contract an enforcer consults | Unchanged |
| Configuration manager | Step 1 | Needs a new design | Unchanged |
| Mock market, decoder, position ledger, `reconcile` | Step 2 | Unchanged, **if** the ledger's writer is an allowlisted address and not hard-wired to the gate | Unchanged |
| `WindowLib`, verifier, mutation suite | Step 3 | Unchanged; the verifier reads different events | Unchanged |
| Per-action policies, S1, S2, S6 | Step 4 | Called from an enforcer instead of the gate; refusal becomes a revert | Unchanged |
| Oracle verification, S3, S4, S5 | Step 5 | As step 4 | Unchanged |
| Evaluation | Step 6 | Rerun | Rerun |

Two seams keep a later change cheap:

1. **Policies do not know who calls them.** A policy exposes "check this order
   for this account" and "commit it", and trusts an allowlisted caller. Under
   option 2 a single adapter enforcer calls the same policies.
2. **The position ledger is written by an allowlisted address.** Not by "the
   gate" as a constant.

With both seams, changing D1 after step 3 costs what it costs today: step 1's
entry point and its tests. After step 4 it also costs the policies' calling
code, their tests and the event semantics.

---

## 8. Checks before deciding

| # | Check | How | Settles |
|---|---|---|---|
| 1 | Does MetaMask's Delegation Manager work on Safe7579 and Nexus, installed as an executor, with one stateful caveat enforcer? | A prototype on ModuleKit accounts, like `test/accounts/` | Whether option 2 is available on the accounts this project uses |
| 2 | In MetaMask's framework, can a caveat refuse without reverting, or with a recorded reason? Does a "try" execution mode change that? | Read `DelegationManager.sol`; prototype | Whether option 2 can keep the spec's refusal record |
| 3 | Can a Smart Session be scoped to one function of one contract with no ERC-1271 signing at all? | Read the Smart Sessions source; prototype on ModuleKit | Whether option 3 keeps reason 3 of section 4 |
| 4 | What exactly do `ERC20PeriodTransferEnforcer` and Coinbase's period allowance enforce: a tumbling period from a fixed start? | Read both sources | The baseline framing of reason 4 |
| 5 | Can the validity-range pattern of section 3 implement a sliding window soundly? | A short written argument, or a prototype policy | How hard the "why not validation" question can be answered |

Checks 1 to 3 are a prototype of one or two days. They need no change to the
project's own code.

---

## 9. Recommendation

- **Do not move the policies into validation.** Reasons 1 and 2 of section 4.
- **Continue with build steps 2 and 3 unchanged.** They are independent of D1.
  Keep the two seams of section 7.
- **Run checks 1 to 3 alongside**, and re-decide D1 before step 4 starts.
- **In the paper, present the gate as a delegation manager**, compared with
  Smart Sessions (session keys), the MetaMask Delegation Framework and Coinbase
  Spend Permissions, with sections 3 and 4 as the argument. Whichever option is
  chosen, that framing stays.

---

## 10. Results of the checks, and the decision

Run on 15 October 2026. Checks 2, 3 and 4 decided between the options; check 1
only matters for option 2, which check 2 rules out; check 5 is a written
argument for the paper and remains open.

| # | Check | Result | How |
|---|---|---|---|
| 2 | Can a MetaMask caveat refuse without reverting? | **No.** The four hooks are plain calls with no try/catch; the code's own comment: "If any hook fails, the entire transaction reverts." The execution mode is passed to the account unchanged | Read `DelegationManager.sol`, main **[source]** |
| 4 | What do the deployed period limits enforce? | **Tumbling windows, both.** MetaMask's `ERC20PeriodTransferEnforcer`: period index (now − startDate) / periodDuration + 1; "unused tokens are forfeited once the period ends". Coinbase's `SpendPermissionManager`: periods "[start + n * period, ...)", spend reset each period | Read both, main **[source]** |
| 3a | Can a Smart Session be scoped to one function of one contract? | **Yes.** A call to a (target, selector) with no policies falls to the fallback action; with no fallback policy it reverts. Delegatecall, try-mode, `executeUserOp` and nested `execute` self-calls are refused outright; a direct call to the account needs its own action | Read `SmartSession.sol`, `PolicyLib.sol` at v1.0.0 and main **[source]**; prototype |
| 3b | Can such a session sign for the account (ERC-1271)? | **No, if it has no ERC-7739 content.** Every session signature must be ERC-7739 nested typed data (`PersonalSign` is refused); the content type must be on the session's allowlist; v1.0.0 and later also require at least one ERC-1271 policy | Read the same at v1.0.0, main, and the 2024 build ModuleKit bundles **[source]**; prototype |
| 3c | Does the hybrid work on real accounts? | **Yes, on all four.** Prototype below | `test/accounts/SessionGate.t.sol` |

**The prototype.** `test/accounts/SessionGate.t.sol`, Foundry in Docker, on the
ERC-7579 reference account, Safe7579, Nexus and Kernel, with ModuleKit 0.5.9's
Smart Sessions. A test double of the gate as option 3 would make it
(`SessionGateProbe`) is installed as an executor; the agent holds a session
whose only action is the gate's `submit`, with no signing content. On every
account:

1. Through the session, `submit` runs, and the gate makes the account call the
   market from inside the same execution: the account is re-entered through
   `executeFromExecutor`, and the market sees the account as caller.
2. A refusal by the gate is recorded: the user operation succeeds and the
   refusal's event is in its log.
3. The session reaches nothing else: not the market directly, not the gate's
   owner function, not `installModule` or `uninstallModule`, not the
   account's own `execute`. Giving the session a second action, the market's
   `placeOrder`, makes all four tests fail at exactly that assertion: the
   test can tell.
4. The session cannot sign for the account. On Nexus a session configured to
   sign does sign, with the same signature format: the refusal is the
   session's scope.

**What the prototype found about the accounts.**

- **Kernel** runs a hooked validator's user operations through
  `executeUserOp`, which Smart Sessions refuses. The Smart Sessions validator
  must be installed on Kernel without a hook.
- **Kernel** hands a validator its own wrapped hash for ERC-1271, so on Kernel
  no session signature verifies at all.
- **The reference account and Safe7579**, as ModuleKit deploys them, have no
  `eip712Domain()`, which Smart Sessions reads to check a session signature: on
  them too no session can sign. Only Nexus supports session signatures here,
  and there the content allowlist is what refuses the agent.

**A version difference to carry into deployment.** ModuleKit 0.5.9 bundles a
Smart Sessions build of September 2024, before v1.0.0. In it, only the ERC-7739
content allowlist guards signing (its ERC-1271 policy minimum is 0). From
v1.0.0 a session needs both allowed content and at least one ERC-1271 policy.
A deployment should use v1.0.0 or later, and give the agent's session an empty
`erc7739Policies`.

### The decision

**Option 3: the agent authenticates with a Rhinestone Smart Session scoped to
`PolicyGate.submit`; the policies run in the gate, an ERC-7579 executor.**
Dan agreed to option 3 on condition that the checks work out (15 October); they
did. It answers section 5's first two questions:

- **Why not Smart Sessions?** It is used, for what it is built for:
  authenticating the agent with a scoped key.
- **Why not ERC-7710?** MetaMask's manager can only refuse by reverting, so a
  refused order would leave no record.

The policies stay in execution for section 3's reasons, as Rhinestone's own
automation executors do.

**What changes, in step 4 (section 7, column "option 3").**

- `submit` is called by the account itself: "the caller is an account with the
  gate installed", the owner-path check of step 1.
- The gate's agent registry goes. Who may act, until when and whether revoked
  becomes the session's business: `removeSession`, and a time-frame user-op
  policy for expiry.
- The agent's operations are user operations of the account. They are paid by
  the account or a paymaster, not by an agent key.
- Everything from steps 2 and 3 is unchanged: the ledger, the decoders,
  reconcile, `WindowLib`, the verifier, the mutation suite. So is the
  configuration manager.

**What is given up.** The gate no longer sees which agent submitted; it sees the
account. A policy cannot tell the owner's own `submit` from the agent's, and
checks both, which is the safe direction. Events name the account, not the
agent.

---

## Sources

Primary texts:

- [ERC-7579: Minimal Modular Smart Accounts](https://ercs.ethereum.org/ERCS/erc-7579)
- [ERC-7562: Account Abstraction Validation Scope Rules](https://eips.ethereum.org/EIPS/eip-7562)
- [ERC-7710: Smart Contract Delegation](https://eips.ethereum.org/EIPS/eip-7710)
- [Smart Sessions repository](https://github.com/erc7579/smartsessions)
- [Rhinestone ModuleKit, `SchedulingBase.sol`](https://raw.githubusercontent.com/rhinestonewtf/modulekit/main/src/module-bases/SchedulingBase.sol)
- [Rhinestone core modules, `ScheduledTransfers.sol`](https://raw.githubusercontent.com/rhinestonewtf/core-modules/main/src/ScheduledTransfers/ScheduledTransfers.sol)
- [MetaMask Smart Accounts Kit: delegation](https://docs.metamask.io/smart-accounts-kit/concepts/delegation/overview/)
- [Base: Spend Permissions](https://docs.base.org/identity/smart-wallet/features/spend-permissions)
- [Base: Build with Spend Permissions](https://docs.base.org/smart-wallet/guides/spend-permissions)
- [Coinbase CDP: Spend Permissions](https://docs.cdp.coinbase.com/wallet-api/v2/evm-features/spend-permissions)

Audits and secondary:

- [Consensys Diligence: MetaMask Delegation Framework audit, 2024](https://diligence.consensys.io/audits/2024/08/metamask-delegation-framework)
- [Ackee: Rhinestone Safe7579 adapter audit summary](https://ackee.xyz/blog/rhinestone-erc-7579-safe-adapter-audit-summary/)
- [Biconomy: Smart Session policies](https://docs.biconomy.io/new/smart-sessions/policies)
- [OpenZeppelin: account modules](https://docs.openzeppelin.com/community-contracts/account-modules)
- [Rhinestone on Alchemy](https://www.alchemy.com/dapps/rhinestone)

Read for the checks of section 10:

- [MetaMask Delegation Framework, `DelegationManager.sol`](https://github.com/MetaMask/delegation-framework/blob/main/src/DelegationManager.sol)
- [MetaMask Delegation Framework, `ERC20PeriodTransferEnforcer.sol`](https://github.com/MetaMask/delegation-framework/blob/main/src/enforcers/ERC20PeriodTransferEnforcer.sol)
- [Coinbase, `SpendPermissionManager.sol`](https://github.com/coinbase/spend-permissions/blob/main/src/SpendPermissionManager.sol)
- [Smart Sessions, `SmartSession.sol` at v1.0.0](https://github.com/erc7579/smartsessions/blob/v1.0.0/contracts/SmartSession.sol), and at main and at commit `49498d2` (September 2024, the build ModuleKit 0.5.9 bundles)
- [Smart Sessions, `PolicyLib.sol` at v1.0.0](https://github.com/erc7579/smartsessions/blob/v1.0.0/contracts/lib/PolicyLib.sol)
- [ModuleKit v0.5.9](https://github.com/rhinestonewtf/modulekit/tree/v0.5.9)
