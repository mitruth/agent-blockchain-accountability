# Delegated-authority enforcement for a home energy agent

Owner-side policies an autonomous energy-trading agent operates under and cannot
change. The prosumer's smart account checks every order before it reaches the
market, through an ERC-7579 executor module, `PolicyGate`. The agent holds no
key on the account.

Built so far: the gate, the key model and configuration (step 1); the order
lifecycle and the position ledger (step 2); a port of the P2P energy market the
agent trades on; the whole system running on a local node; and `WindowLib`, its
independent verifier and the mutation suite (step 3). No policy checks an order
yet: that is step 4.

**Documentation is in [`docs/`](docs/README.md).** Start with
[`docs/guide/project-guide.md`](docs/guide/project-guide.md) for what the
project contains today, what the tests prove and how to run everything.

## Layout

| Folder | What is in it |
| ------ | ------------- |
| `contracts/gate/` | `PolicyGate` and its parts, the `PositionLedger` |
| `contracts/policies/` | `WindowLib`, the counting over time the sequence policies share; the policies of step 4 go here |
| `contracts/market/` | The P2P market: token, manager, sessions, prosumer contracts, settlement, the gate's decoder |
| `contracts/interfaces/` | ERC-7579 pieces, the decoder and policy interfaces |
| `contracts/harness/` | Stand-ins for tests and the local system, not part of the system |
| `test/` | Solidity tests, one folder per contract folder; `test/accounts/` runs under Foundry only |
| `offchain/` | The JavaScript around the contracts, one package per job: `chain`, `deploy`, `matcher`, `keeper`, `sensor`, `scenarios`, `verifier`, `mutation` |
| `docs/` | Guide, specification, decision log, roadmap, analyses |
| `earlier-design/`, and `contracts/earlier-design/`, `test/earlier-design/` | The project this one replaces, kept running until step 4 |

## Running it

```bash
npm install
npm test
```

The local system, in two terminals:

```bash
npm run node
```

```bash
npm run demo:deploy
npm run demo:flow
```
