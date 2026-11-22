# ReactorVault

**A self-healing personal vault on [Reactive Network](https://reactive.network).**
Deposit native ETH once — the vault runs itself: it reacts to on-chain
events, keeps its own gas tanks full, converts operating margin into
reactive fuel, and is watched over by a watchdog that can never be
silenced by a dead battery. *Set it and forget it.*

> Built for the **Reactive Omni Buildathon**, track *Set It and Forget It*.

## How it works (C4 container view)

```
                     Sepolia (destination chain)              Reactive Lasna (reactive chain)
 ┌──────────────────────────────────────────────────┐   ┌─────────────────────────────────────────────┐
 │                                                  │   │                                             │
 │  client ──ETH──▶ ┌────────────────────┐          │   │  ┌──────────────┐   react()   ┌───────────┐ │
 │                  │ AssetVault (safe)  │          │   │  │ GasPayer     │◀───────────│ any event │ │
 │                  │ pockets: gas/fund │          │   │  │ (cashier)    │            └───────────┘ │
 │                  └────────┬───────────┘          │   │  └──────┬───────┘                          │
 │                           │ capital transit      │   │         │ orders refill                    │
 │  ┌────────────────┐       ▼                      │   │         ▼                                  │
 │  │ Executor       │◀──── callback ───────────────┼───┼── RulesEngine (brain)                       │
 │  │ (the hands)    │  rebalance / refuel          │   │  ┌──────────────┐                           │
 │  └───────┬────────┘                              │   │  │ FuelConverter│── HorizonAlert ──┐        │
 │          │ deploy/recall                         │   │  └──────────────┘                 ▼        │
 │  ┌───────▼────────┐   ┌──────────────────┐       │   │  ┌──────────────┐  buyFuel   ┌───────────┐ │
 │  │ pool adapters  │   │ GasVault         │       │   │  │ ReliefFund   │◀──callback─│FuelBuyer  │ │
 │  │ Aave / Morpho  │   │ (battery)        │       │   │  │ (fuel depot) │──lREACT──▶ feeds all  │ │
 │  └────────────────┘   └──────────────────┘       │   │  └──────────────┘           reactive   │ │
 │  ┌────────────────┐   ┌──────────────────┐       │   │  ┌──────────────┐           contracts  │ │
 │  │ OneToOneOracle │   │ FuelBuyer        │───────┼───┼─▶             │  (SYSTEM deposits)     │ │
 │  └────────────────┘   │ (ETH fund exit)  │       │   │  │ Watchdog     │  cron patrol + cry      │ │
 │                      └──────────────────┘       │   │  │ (patrol)     │  relay                  │ │
 │                                                  │   │  └──────────────┘                         │ │
 └──────────────────────────────────────────────────┘   └─────────────────────────────────────────────┘
```

1. **The safe** (`AssetVault`, destination chain) takes a native-ETH
   deposit and splits it into pockets: the client's gas reserve and the
   treasury share (the ETH fund). Accounting invariant:
   `balance + treasurySent ≡ totalDeposited` — fuzz-tested. The
   **battery** (`GasVault`) is the single gas pocket of the system
   (client fuel + treasury), invariant `reserve + treasury ≡ balance`.
2. **The brain** (`RulesEngine`, Reactive) subscribes to events and
   fires `rebalance` callbacks. Product logic only — no cash handling.
3. **The cashier** (`GasPayer`, Reactive) watches the executor's ETH
   tank and the client's reserve mirror, and orders refills with a
   margin into the treasury. Tariffs are ETH-native: no price feeds.
4. **The depot** (`ReliefFund`, Lasna) holds lREACT and feeds every
   reactive contract by real numbers (`reserves − debts` on the SYSTEM
   contract). Feeding is a data registry — a new ward is a record, not
   code.
5. **The watchdog** (`Watchdog`, Reactive) patrols on a Cron10000
   alarm and relays `LowGas` cries; zero cost when everything is fine.
6. **The auto-faucet** (`FuelConverter` + `FuelBuyer`) turns the ETH
   fund into lREACT: when the depot's horizon drops below 30 days, the
   converter orders a purchase; on mainnet the same slot is a
   Uniswap+bridge adapter.

The system is designed so that no single quiet failure kills it:
reactive gas is prepaid as SYSTEM debt, every tank has a cry threshold,
the watchdog re-checks by real numbers, and the faucet refuels the
depot autonomously.

## Contracts

| Contract | File | Chain | Role |
|---|---|---|---|
| `AssetVault` | `src/AssetVault.sol` | Sepolia | ETH safe: pockets, deposit split, invariant accounting |
| `GasVault` | `src/GasVault.sol` | Sepolia | battery: the single gas pocket (client fuel + treasury) |
| `Executor` | `src/Executor.sol` | Sepolia | callback receiver: rebalance + ETH-tank refills, two valid senders |
| `AavePoolAdapter` / `MorphoPoolAdapter` | `src/adapters/` | Sepolia | pool plugins (IPoolAdapter); capital transits through the safe |
| `OneToOneOracle` | `src/OneToOneOracle.sol` | Sepolia | fixed 1:1 rate source for the demo market |
| `FuelBuyer` | `src/FuelBuyer.sol` | Sepolia | ETH fund → faucet/DEX → lREACT to the depot |
| `RulesEngine` | `src/RulesEngine.sol` | Reactive | event rules → callbacks; idempotent, cooldowns, gas cry |
| `GasPayer` | `src/GasPayer.sol` | Reactive | cashier: tariff, refill orders, reserve mirror, gas cry |
| `FuelConverter` | `src/FuelConverter.sol` | Reactive | depot horizon listener → purchase orders |
| `ReliefFund` | `src/ReliefFund.sol` | Lasna | fuel depot: ward registry, real-number feeding, horizon alerts |
| `Watchdog` | `src/Watchdog.sol` | Lasna/Reactive | cron patrol + cry relay, zero idle cost |

### Live testnet stand (checked 19.11)

| Contract | Chain | Address |
|---|---|---|
| RulesEngine (subscribe hatch, 1.2M callback gas) | Lasna | `0x0D05bDab2480e2c915A8aE4ACaD30B17c66B1cFA` |
| GasPayer v2.1 (executor rewirable) | Lasna | `0xfccf439DAB2a4dcE34E2FAabdB395EEB4C2ed0ef` |
| ReliefFund (fund4, ward registry) | Lasna | `0x55cE527bd6962f2ec492980C7269f595323a9EaE` |
| Watchdog v6 | Lasna | `0x479ea63Ff2DFc4C553611BE0d87445EFf2C62136` |
| FuelConverter v3 (auto-faucet brain) | Lasna | `0x63ae2563BE276A896A9D2E1E318b43426dE32A15` |
| AssetVault (safe, live) | Sepolia | `0x49D76fc16130DEe93c2BE760e2FBcdEe8765fa15` |
| Executor v2 | Sepolia | `0xE6507Cad930C899DDBe4af2d211823e1e1e196E2` |
| GasVault (battery) | Sepolia | `0xF72f7cdAD29fE63c9Bf9E3a753f625958D84a199` |
| FuelBuyer v2 | Sepolia | `0xAD9a56E4ac63502952aBE9873D3BbbA25b56EA88` |
| OneToOneOracle | Sepolia | `0x69fFF7C44763918C0399991928F421654AF21D7A` |
| AavePoolAdapter (WETH) | Sepolia | `0x11809F0a5bd83516B9f73f1b94dB3227D73368d0` |
| MorphoPoolAdapter (own WETH/WETH market) | Sepolia | `0x5312A8A0C307B0318320FB77b0C24AC7a8a40EE3` |

End-to-end proof (deploy-day loop, tx hashes in the buildathon
evidence): a deposit → the brain reacts (Lasna) → callback → the
executor rebalances (Sepolia) → the capital is placed in Aave WETH
through the pool adapter. The alarm-clock rule (cron, daily cooldown)
re-checks rates locally at execution time and moves capital only above
a 1% APY spread.

## Quickstart (an hour, testnet from zero)

```bash
# 1. Build and test (Foundry; unit + invariant suites, no RPC needed)
git clone --recurse-submodules https://github.com/grottnnov/reactorvault
cd reactorvault
forge build && forge test          # 185 tests + 6 fork tests
SEPOLIA_RPC_URL=… forge test --match-path 'test/fork/*'   # fork suite vs live Sepolia (optional)

# 2. Faucets: Lasna lREACT (https://dev.reactive.network) + Sepolia ETH.
#    Fund one deployer EOA on both chains.

# 3. Configure (the key lives in your secret store, env is transport)
cp .env.example .env               # fill DEPLOYER_PRIVATE_KEY
export DEPLOYER_PRIVATE_KEY=$(cat ~/.secrets/deployer)

# 4. Optional but recommended: the minimal cross-chain probe
#    (subscription → react → callback delivery mechanics reference)
script/deploy-probe.sh

# 5. Deploy the family: destination trio (safe/battery/buyer…), then the
#    Lasna side (depot, watchdog, converter) — every cross-chain address
#    is precomputed and verified against the deployed one; wiring last.
script/deploy-w2.sh && script/deploy-w21-fund.sh && script/wire-w2.sh

# 6. Prove the loop: send a small deposit to your AssetVault and watch
#    the rebalance land (Lasna react → Sepolia callback), or run the
#    sensor-free check: cast call the executor's rebalanceCount().
```

Every script has a self-documenting header — read it before running.
Deploy gas is auto-estimated (never capped: a capped `forge create`
burns a nonce and kills precompute — a lesson paid for on 09.11).

## Build & test

```bash
forge build
forge test        # 185 unit/invariant tests, no RPC keys required
```

Fork tests (6) run against live Sepolia when `SEPOLIA_RPC_URL` is set —
they assert real gas budgets of the heaviest path (a full Aave→Morpho
rebalance delivered by the live callback proxy).

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
  `NoDelegateCall` on owner paths, events before external calls (the
  settlement-call exception is documented and guarded — recall is
  atomic, a failed settlement reverts the whole operation).
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
- [ ] W3: engineering pass (event-emitting setters, P9 event ordering,
      cooldown semantics) + family redeploy
- [ ] Mainnet: Uniswap + Reactive Bridge adapter for the fuel loop,
      multi-token entry

## Security

Testnet software, unaudited. Not production-ready; do not deposit
funds you cannot afford to lose.

## License

MIT — see [LICENSE](./LICENSE).
