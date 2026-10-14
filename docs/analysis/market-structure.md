# Market structure: porting the P2P flexibility market

Written 2026-10-14. Status: decided with Dan; the port is in progress.

The mock market of build step 2 was a stand-in. It is replaced by a port of the
peer-to-peer energy flexibility market Dan designed and built in two projects,
BRIGHT and DEDALUS, described in his PhD thesis, chapter 3. The structure and
logic are kept, because they have a record and they are Dan's. This document
records how the two projects were read, what the port keeps, what it changes,
and why. The decisions themselves are entries 2.20 to 2.31 of
`docs/decisions/design-decisions.md`.

Sources read:

- BRIGHT, `bright-blockchain-api/blockchain-api/contracts/`, Solidity 0.7.4:
  `MarketsManager`, `AssetMarketSession`, `EFlexibleEntity`, `LockableERC20`,
  `ERC721`, `ClassicSettlement`, `GridOperableLibrary`.
- DEDALUS, `dedalus-blockchain-api/contracts/`, Solidity 0.8.10: `Building`,
  `Apartment`, `MarketSession`, `LockableERC1155`, `ERC1155TokenIdMasks`,
  `ClassicSettlement`, `BuildingChainlink`, and `scripts/deploy.js`.
- The thesis text on the market design (actors, contracts, phases, figure 3.3).

---

## 1. The market as built in both projects

### Phases

| Phase | What happens |
|---|---|
| Registration | The market manager whitelists each prosumer and the assets behind it |
| Market session | The manager opens a session (one per energy type, per day for a day-ahead market). Prosumers submit bids and offers for the session's hours |
| Matching | At session end an off-chain module reads all bids and offers, matches them into energy transactions and registers the transactions on chain |
| Commitment | Each registered transaction becomes a commitment of the buyer and of the seller, per hour |
| Settlement | Monitored values per hour are compared with the commitments. Within 10% the collateral is released; beyond it the prosumer pays a penalty |

### Contracts

| Role | BRIGHT | DEDALUS | What it does |
|---|---|---|---|
| Market manager | `MarketsManager` | `Building` | Registers prosumers and certificates, creates sessions, holds `realTimePrice` and `hourDeposit`, receives penalties |
| Prosumer | `EFlexibleEntity` | `Apartment` (and `Building` for bids) | Owned by the prosumer. Places orders, locks collateral, mints energy tokens for offers, holds commitments per hour, is settled |
| Market session | `AssetMarketSession` | `MarketSession` | Stores the session's bids and offers; registers trades; at session end refunds unmatched bids and burns unmatched offers |
| Payment | `LockableERC20` | `LockableERC1155`, fungible id | Collateral locked per order, unlocked or transferred on trade and settlement |
| Energy | `ERC721` with quantities | `LockableERC1155`, one id per minter, hour and energy type | Minted per offer, moved seller to buyer on trade, burned if unmatched |
| Settlement rule | `ClassicSettlement` | same | Deviation over 10%: penalty = deviation × `realTimePrice` |
| Matching | off-chain | off-chain | Reads orders, writes trades |
| Monitoring | the prosumer owner calls `monitor` | encrypted values, compared by a Chainlink oracle | Supplies the measured value per hour |

### The flow, numbered as in thesis figure 3.3

1. The manager registers the prosumer as buyer or seller (1a, 1b).
2. The manager starts the session (2).
3. The prosumer contract publishes bids and offers (3a, 3b), locks collateral
   (4) and, for offers, mints energy tokens (5). Collateral: an offer locks
   quantity × `realTimePrice`; a bid locks quantity × price.
4. The matcher fetches all orders (6), matches them (7) and registers the
   trades (8). Per trade: the energy token moves from seller to buyer, the
   buyer's locked funds pay the seller, the seller's collateral beyond the
   matched quantity is unlocked, and both commitments are updated. Unmatched
   bids are refunded and unmatched offers burned.
5. Monitored data is gathered and stored (10), and each prosumer is settled
   per hour (9, 11).

---

## 2. How it maps onto this project

The prosumer contract stays a separate contract, as in both projects. Its owner
is the prosumer's ERC-7579 smart account instead of an externally owned
address.

```
agent ──submit──▶ PolicyGate ──▶ smart account ──order calls──▶ Prosumer ──▶ Session
                                 (owner of Prosumer)
matcher ──registerTrades──▶ Session ──▶ Prosumer commitments, token and payment transfers
sensor ──monitored values──▶ Prosumer ──▶ settlement
manager ──registration, sessions, prices──▶ Manager
```

| In the thesis | Here |
|---|---|
| Forecasting service that produces the orders | The autonomous agent, through the gate |
| Prosumer owner | The prosumer's smart account; the human owner acts through its validator |
| Matching module | A registered matcher address: an off-chain service linked to an oracle |
| Smart meter | A registered sensor address per prosumer |
| Market operator | The manager's operator address |

What the enforcement layer reads from the market, through the decoder:

- the prosumer contract's order calls, as legs (a batch is one leg per order);
- per order: matched quantity, whether it is still open, and the session's
  closing time.

The gate, the agent registry, the configuration manager and the position
ledger are unchanged in role. The ledger stays the enforcement layer's own
record; the prosumer contract's commitments stay the market's.

---

## 3. What the port keeps, changes and drops

### Kept

- The five roles and their division into contracts: manager, session,
  prosumer, lockable token, settlement.
- The ERC-1155 template of DEDALUS: one lockable ERC-1155 contract for the
  fungible payment token and for the energy tokens, with token ids that encode
  the minter, the slot and the energy type.
- Orders in batches, collateral locked at placement, energy tokens minted for
  offers.
- Matching off chain; trades registered on chain by the matching service.
- Commitments per prosumer and slot.
- Unmatched bids refunded and unmatched offers burned at session end.
- `ClassicSettlement`: 10% threshold, penalty = deviation × `realTimePrice`.

### Changed

| Change | Why |
|---|---|
| The number of slots in a session is a parameter, and the slot length too | Both projects hard-code 24 hours. A day-ahead session of 24 hourly slots is the starting case; an intraday session of 6 hours, or 30-minute slots, must be possible (spec amendment A2) |
| A batch names its slots: up to the session's slot count, each order for one slot | "Custom arrays, not 24" |
| Orders can be cancelled and modified until the session closes | Neither project has them. Without them there is no spoofing attack, and the cancellation quota S6 and the spec's modification tests have nothing to act on |
| A view of how much of each order is matched, and whether it is still open | The position ledger books fills through the decoder |
| Every function that moves funds, tokens or commitments checks its caller | See section 4 |
| Monitored values come from a registered sensor address, never from the owner | The owner is the smart account the agent acts through. Readings the agent could choose would settle in the agent's favour |
| Solidity 0.8.25 | This project's compiler |

### Dropped

Encryption, the Chainlink comparison, the VPP or community mode, behind-the-meter
asset modelling, and the building-and-apartment hierarchy of DEDALUS. None is
needed for the enforcement layer, and each can return later.

---

## 4. Why the port adds caller checks

In this project the agent is an ordinary address. Any public function that moves
funds or tokens without checking its caller is a way around the gate, because
the agent can call it directly. Reading BRIGHT, as far as the code shows:

| Finding | Effect if ported unchanged |
|---|---|
| The energy token's `transferFrom(from, …)` checks that `from`, not the caller, is owner or approved | Anyone moves anyone's energy tokens |
| `AssetMarketSession.registerTrades` has no caller check | Anyone registers fabricated trades |
| `EFlexibleEntity.updateCommitments` has no caller check, and pays locked funds to `trade.efeSellingAddress`, which the caller supplies | Anyone redirects a prosumer's locked funds |
| `setQuantityCommitmentForTimeIndex`, `resetCommitments`, `setBaseline` have no caller check | Anyone rewrites a prosumer's commitments |
| `registerProsumer`, `setEnergyCertificateRegistry` have no caller check | Anyone joins the market or swaps its certificate |
| `monitor` takes the value from the prosumer owner | The account the agent acts through reports its own deliveries |

These are reasonable for a closed demonstrator, which is what both projects
were. They would invalidate the enforcement claims here. Each function in the
port names who may call it: the manager's operator, the session, the matcher,
the sensor, or the prosumer's owner.

---

## 5. Open points

- **Price per slot or per batch.** The thesis gives a day-ahead order one price;
  DEDALUS gives each hour its own. The port follows DEDALUS: every order in a
  batch has its own price. Proposed (decision 2.23).
- **Manager separate from the prosumers.** DEDALUS merges the manager into
  `Building`, which is specific to its building community. The port follows the
  thesis and BRIGHT: a separate manager. Proposed (decision 2.22).
- **How the sensor delivers.** The port has the sensor call the contract from
  its registered address. Signed readings that anyone relays would let a meter
  without a funded key report; the signature check already in this repository
  (`MeterReadings.sol`) would serve. Proposed (decision 2.27).
- **Currency.** The payment token's unit is still open (spec amendment A4).
