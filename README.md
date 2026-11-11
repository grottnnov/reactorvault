# ReactorVault

**A self-healing personal vault on [Reactive Network](https://reactive.network).**
Deposit native ETH once — the vault runs itself: it reacts to on-chain
events, keeps its own gas tanks full, converts operating margin into
reactive fuel, and is watched over by a watchdog that can never be
silenced by a dead battery. *Set it and forget it.*

> Built for the **Reactive Omni Buildathon**, track *Set It and Forget It*.

## How it works

```
                Sepolia (destination)                 Reactive Network / Lasna
 ┌──────────────────────────────────────┐   ┌────────────────────────────────────────┐
 │                                      │   │                                        │
 │  client ──ETH──▶ ┌───────────────┐   │   │  ┌──────────────┐   react()   ┌─────┐ │
 │                 │   VaultCore   │   │   │  │  GasPayer    │◀────────────│ any │ │
 │                 │  (the safe)   │   │   │  │  (cashier)   │   events    │event│ │
 │                 │               │   │   │  └──────┬───────┘             └─────┘ │
 │                 │ pocket: gas   │   │   │         │ orders refill               │
 │                 │ pocket: fund  │   │   │         ▼                            │
 │                 └──────┬────────┘   │   │  ┌──────────────┐  callback          │
 │                        │            │   │  │  RulesEngine │──────────────┐      │
 │  ┌───────────────┐     │            │   │  │  (the brain) │              │      │
 │  │   Executor    │◀────┘            │   │  └──────────────┘              ▼      │
 │  │ (the hands)   │  rebalance /     │   │                         ┌──────────┐ │
 │  └───────────────┘  refuel          │   │   watchdog patrol ────▶ │ Fund     │ │
 │                                      │   │   (Cron10000 tick)     │ (depot)  │ │
 │  ┌───────────────┐  treasury ──▶ ETH fund ──▶ auto-faucet ──▶ lREACT ──▶ feeds  │
 │  │   FuelBuyer   │                 │   │   all reactive contracts (as SYSTEM   │
 │  └───────────────┘                 │   │   deposits, not plain transfers)      │
 └──────────────────────────────────────┘   └────────────────────────────────────────┘
```

1. **The safe** (`VaultCore`, destination chain) takes a native-ETH
   deposit and splits it into pockets: the client's gas reserve and the
   treasury share (the ETH fund). Accounting invariant:
   `free + reserve + treasury ≡ balance` — fuzz-tested.
2. **The brain** (`RulesEngine`, Reactive) subscribes to events and
   fires `rebalance` callbacks. Product logic only — no cash handling.
3. **The cashier** (`GasPayer`, Reactive) watches the executor's ETH
   tank and the client's reserve mirror, and orders refills with a
   10% margin into the treasury. Tariffs are ETH-native: no price
   feeds anywhere.
4. **The depot** (`ReliefFund v6`, Lasna) holds lREACT and feeds every
   reactive contract by real numbers (`balance − debt` on the SYSTEM
   contract). Feeding is a data registry — a new ward is a record, not
   code.
5. **The watchdog** (`Watchdog v6`, Reactive) patrols on a Cron10000
   alarm and relays `LowGas` cries; zero cost when everything is fine.
6. **The auto-faucet** (`FuelConverter` + `FuelBuyer`) turns the ETH
   fund into lREACT: when the depot's horizon drops below 30 days, the
   converter orders a purchase; on mainnet the same slot is an
   Uniswap+bridge adapter.

The system is designed so that no single quiet failure kills it:
reactive gas is prepaid as SYSTEM debt, every tank has a cry threshold,
the watchdog re-checks by real numbers, and the faucet refuels the
depot autonomously.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `VaultCore` | destination | ETH safe: pockets, deposit split, invariant accounting |
| `Executor` | destination | callback receiver: rebalance + ETH-tank refills, two valid senders |
| `RulesEngine` | Reactive | event rules → callbacks; idempotent, cooldowns, gas cry |
| `GasPayer` | Reactive | cashier: tariff, refill orders, reserve mirror, gas cry |
| `FuelConverter` | Reactive | depot horizon listener → purchase orders |
| `FuelBuyer` | destination | ETH fund → faucet/DEX → lREACT to the depot |
| `ReliefFund v6` | Lasna | fuel depot: ward registry, real-number feeding, horizon alerts |
| `Watchdog v6` | Reactive | cron patrol + cry relay, zero idle cost |

### Live testnet stand (W2.2, deployed 2026-11-11)

| Contract | Chain | Address |
|---|---|---|
| RulesEngine (subscribe hatch, 1.2M callback gas) | Lasna testnet | `0x0D05bDab2480e2c915A8aE4ACaD30B17c66B1cFA` |
| GasPayer v2.1 (executor rewirable) | Lasna testnet | `0xfccf439DAB2a4dcE34E2FAabdB395EEB4C2ed0ef` |
| ReliefFund v6.x (horizon re-emits while held) | Lasna testnet | `0x0DBbA5673272AEffaF9D5095CD3E65504f9e1B0c` |
| Watchdog v6.2 | Lasna testnet | `0x479ea63Ff2DFc4C553611BE0d87445EFf2C62136` |
| FuelConverter | Lasna testnet | `0xe9393939bCa7d559077c8F8835F600b38e959747` |
| AssetVault | Sepolia | `0x49D76fc16130DEe93c2BE760e2FBcdEe8765fa15` |
| GasVault (battery) | Sepolia | `0xF72f7cdAD29fE63c9Bf9E3a753f625958D84a199` |
| Executor v2 | Sepolia | `0x469247bb21b8AE30CAC6324b7F209926EA097423` |
| AavePoolAdapter (WETH) | Sepolia | `0x6b1Df2d2a56Dc219E333E1B0d47f7f8c9d3Bc959` |
| MorphoPoolAdapter (own WETH/WETH market, 1:1 oracle, LLTV 91.5%) | Sepolia | `0x8D916adaf036084cEF84945B505Ee9D87718638a` |
| OneToOneOracle | Sepolia | `0x69fFF7C44763918C0399991928F421654AF21D7A` |
| FuelBuyer | Sepolia | `0xd76C87E0EAA3373AaAb57E54adBb6DDD6ACa42BD` |

End-to-end proof on deploy day: a deposit → brain fires (Lasna) →
callback → executor rebalances (Sepolia) → the capital is placed in
Aave WETH through the pool adapter. The alarm-clock rule (cron, daily
cooldown) re-checks rates locally at execution time and moves capital
only above a 1% APY spread.

## Build & test

```bash
git clone --recurse-submodules https://github.com/grottnnov/reactorvault
cd reactorvault
forge build
forge test        # 61 tests: unit + handler-based invariant fuzzing
```

## Deploy

Scripts are self-documenting; read the header before running.

- `script/deploy-probe.sh` — a minimal cross-chain probe (subscription
  → react → callback delivery with sender-slot guards). The reference
  for Reactive Network delivery mechanics.
- `script/deploy-w2.sh` — deploys the v2 family: precomputes every
  circular cross-chain dependency, verifies each deployed address
  against the computation, wires tanks via `depositTo` on the SYSTEM
  contract.
- `script/wire-w2.sh` — subscriptions, ward registry, tanks, vault
  pockets.

## Design notes

- **Callback authorization** follows the network's delivery canon: the
  callback arrives from the proxy (`msg.sender`), with the first
  payload slot injected as the source address. Guards check both;
  tests emulate the live delivery.
- **Reactive gas is SYSTEM debt**, not address balance: feeding is a
  `depositTo`, never a plain transfer; every tank monitors
  `reserves − debts` on-chain.
- **Idempotency everywhere**: duplicate event deliveries (cross-chain
  norm) are cut by `(chainId, blockNumber, topic0)` sets.
- **Uniswap patterns** applied where they fit: invariants checked at the
  end of operations, singleton mechanics vs product plugins,
  `NoDelegateCall` on privileged paths, events before external calls.
- **Capital transits through the safe**: pool adapters are plugins
  (`IPoolAdapter`); the executor compares normalized WAD/yr rates
  locally at execution time and only orchestrates `deployToPool` /
  `recallFromPool` — it never holds capital. Settlement is strict: a
  recalled adapter must return exactly the recalled ETH inside the call.
- **Demo yield lever (disclosed)**: the second pool is an own
  WETH/WETH Morpho market with a fixed 1:1 oracle (price is a
  mathematical identity — nothing to manipulate) whose supply rate is
  driven by the operator borrowing against their own collateral. The
  yield is real mechanics funded by the operator — a demo-scale
  instrument, not organic market yield; production targets organic
  markets (Aave/Compound/public Morpho vaults). No mainnet same-asset
  market precedent is claimed. Note: Morpho governance may set a market
  fee up to 25% (paid to the protocol, not us) — a documented property
  of the singleton we accept on the testnet.

## Status & roadmap

- [x] W2: full family live on Lasna testnet + Sepolia, end-to-end
  deposit→reaction cycle, auto-faucet primed (first live cron feed
  11.11: the reborn watchdog fed the depot, converter ordered fuel)
- [x] W2 revision (code, fork-tested against live Sepolia): lending
  pools — AavePoolAdapter + MorphoPoolAdapter on an own market, vault
  pool accounting (`balance + inPools + treasury == tracked`),
  rate-driven rebalance with a spread gate, bootstrap-cry fix
- [ ] W2 live redeploy: the executor/vaults/adapters family + cashier
  rewire, then the full loop measurement (cron tick → react →
  rebalance → pools)
- [ ] Mainnet: Uniswap + Reactive Bridge adapter for the fuel loop,
  multi-token entry

## Security

Testnet software, unaudited. Not production-ready; do not deposit
funds you cannot afford to lose.

## License

MIT — see [LICENSE](./LICENSE).
