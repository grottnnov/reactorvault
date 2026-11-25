# ReactorVault

**A 24/7 risk guardian for tokenized equities on Robinhood Chain,
built on [Reactive Network](https://reactive.network).** Tokenized
equities trade around the clock while the reference market sleeps —
a position needs a guard that never sleeps. *Set it and forget it.*

The project grew one layer at a time: a watchdog patrol that keeps
the system alive, a self-healing vault economy that pays its own
gas, and now the risk guardian — the brain computes WHEN from price
history, the executor verifies NOW against the live feed, the guard
safe decides HOW MUCH. The vault stand (Lasna + Sepolia, live since
19.11) is the chassis economy the guardian runs on.

> Built for the **Reactive Omni Buildathon**, track *Set It and Forget It*.

## The risk guardian (Robinhood Chain, 4663)

The guard slice reuses the platform's chassis on the equity chain:

- **The brain computes WHEN** — guard rules per feed keyed by
  (chainId, emitter); the anchor is `max(entry, HWM)` — capital
  protection and the trailing floor in one mechanism — with three
  rungs from it: warn → trim to the target share, mid → exit half,
  hard → exit all. Deepening bypasses the cooldown; a stale feed
  pauses the rule and a fresh answer resumes it.
- **The executor verifies NOW** — at delivery it re-checks the live
  feed answer, freshness, the pause flag and the EXIT bound; a
  recovered price is a quiet skip, not a paid panic.
- **The guard safe decides HOW MUCH** — `GuardVault`, the two-sided
  safe (stock + stable, real decimals), band no-ops, bounded swaps
  with a minOut slippage guard; the exit always works.
- **The feed registry** (`script/feed-registry.sh`) joins the
  official Chainlink RDD with the Robinhood asset registry and
  live-verifies every pair on 4663.

The 4663 mainnet stand (Reactive 1597 brain + Robinhood executor and
safes) is the next step — see `deployments.json` ("main").

## The chassis: how it works (C4 container view)

```
                    Sepolia (destination chain)                Reactive Lasna (reactive chain)
 ┌────────────────────────────────────────────────┐   ┌─────────────────────────────────────────────┐
 │                                                │   │                                             │
 │ client ──ETH──▶ ┌────────────────────┐         │   │  ┌──────────────┐   react()   ┌───────────┐ │
 │  (entry free,   │ AssetVault (safe)  │         │   │  │ RulesEngine  │◀───────────│ any event │ │
 │   0% of deposit)│ fees accrue →      │         │   │  │ (brain)      │            └───────────┘ │
 │                 │ settle at cash     │         │   │  └──────┬───────┘                          │
 │                 │ events; hard cap   │         │   │         │ callback (the only sender)        │
 │                 └────────┬───────────┘         │   │         ▼                                  │
 │  ┌───────────────┐      │ capital transit      │   │  ┌──────────────┐                           │
 │  │ Executor v3   │◀──── callback ──────────────┼───┤  │ FuelConverter│── HorizonAlert ──┐        │
 │  │ bills served  │  rebalance + billing        │   │  └──────────────┘                 ▼        │
 │  │ safes; sweeps │      ▲ margin               │   │  ┌──────────────┐  buyFuel    ┌──────────┐│
 │  └───────┬───────┘      │                       │   │  │ ReliefFund   │◀─callback───│FuelBuyer ││
 │          │ deploy/recall│                       │   │  │ (fuel depot) │──lREACT──▶  └──────────┘│
 │  ┌───────▼────────┐  ┌──┴──────────────┐        │   │  └──────────────┘  feeds all   ▲ pulls    │
 │  │ pool adapters  │  │ GasVault        │        │   │  ┌──────────────┐  reactive    │ from the │
 │  │ Aave / Morpho  │  │ (the fund: REACT│────────┼───┼─▶│ Watchdog     │  contracts   │ fund     │
 │  └────────────────┘  │ half + execution│        │   │  │ (patrol)     │  cron patrol+cry        │
 │  ┌────────────────┐  │ half)           │        │   │  └──────────────┘                         │ │
 │  │ OneToOneOracle │  └─────────────────┘        │   │                                             │
 │  └────────────────┘                             │   │                                             │
 └────────────────────────────────────────────────┘   └─────────────────────────────────────────────┘
```

1. **The safe** (`AssetVault`, destination chain) takes a native-ETH
   deposit — the entry is free, zero percent of the deposit in any form.
   Accounting invariant:
   `balance + feesPaidOut + treasurySent + totalInPools ≡ totalDeposited`
   — fuzz-tested. The **fund** (`GasVault`) is the two-halves treasury:
   a REACT-obligations half (the depot feeds the reactive side directly)
   and an execution half; invariant `treasury ≡ balance`.
2. **The brain** (`RulesEngine`, Reactive) subscribes to events and
   fires `rebalance` callbacks. Product logic only — no cash handling.
3. **Pay on delivery** (ADR-GAS): every served action is billed to its
   safe as an ACCRUAL — no transfer at action time, a fully staked safe
   cannot fail to pay. Fees settle at cash events (deposit, redeem,
   capital transit); an anomalous charge is auto-refused by the safe
   (hard cap); a settlement buffer always stays in cash. The executor's
   tank self-sustains; everything above the tank target is swept into
   the fund as margin.
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
| `AssetVault` | `src/AssetVault.sol` | Sepolia | ETH safe: free entry, accrued fees, hard cap, settlement buffer, invariant accounting |
| `GasVault` | `src/GasVault.sol` | Sepolia | the fund: margin intake, buyer pulls (spend ≤ earned), invariant treasury ≡ balance |
| `Executor` | `src/Executor.sol` | Sepolia | callback receiver: rebalance + per-action billing + margin sweep (brain is the only sender) |
| `GuardVault` | `src/GuardVault.sol` | Robinhood 4663 | the two-sided guard safe (stock + stable): real-decimals share math, band no-ops, bounded swaps, the exit always works |
| `AavePoolAdapter` / `MorphoPoolAdapter` | `src/adapters/` | Sepolia | pool plugins (IPoolAdapter); capital transits through the safe |
| `OneToOneOracle` | `src/OneToOneOracle.sol` | Sepolia | fixed 1:1 rate source for the demo market |
| `FuelBuyer` | `src/FuelBuyer.sol` | Sepolia | pulls purchase funds from the fund itself → faucet/DEX → lREACT to the depot |
| `RulesEngine` | `src/RulesEngine.sol` | Reactive | event rules → callbacks; idempotent, cooldowns, gas cry |
| `FuelConverter` | `src/FuelConverter.sol` | Reactive | depot horizon listener → purchase orders |
| `ReliefFund` | `src/ReliefFund.sol` | Lasna | fuel depot: ward registry, real-number feeding, horizon alerts |
| `Watchdog` | `src/Watchdog.sol` | Lasna/Reactive | cron patrol + cry relay, zero idle cost |

### Live testnet stand (checked 25.11 — the W2.2 generation; superseded by the W3 pay-on-delivery family at the next redeploy)

All deployed addresses, chain endpoints and the event topic0 index live in
**`deployments.json`** — the machine-readable single source of truth. It is
kept honest by `test/DeploymentsManifest.t.sol`: schema and public-artifact
hygiene offline, and a live cross-check (with `LASNA_RPC`/`SEPOLIA_RPC` set)
that every address has code and its role getter answers. This README never
duplicates it — two copies of a fact drift apart, and an agent trusts the
stale copy.

For agents, the `events` section of the manifest is the push channel:
subscribe to a topic0 on the contract's chain and you learn about `LowGas`,
`Rebalanced` or `VaultUnpaid` before any dashboard renders them. All state is
public on-chain — no API keys, no auth.

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
forge build && forge test          # 190 passed offline + 7 RPC-gated live checks
SEPOLIA_RPC_URL=… forge test --match-path 'test/fork/*'   # fork suite vs live Sepolia (optional)
LASNA_RPC=… SEPOLIA_RPC=… forge test --match-contract DeploymentsManifestTest   # manifest vs live chains

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
- [x] The risk guardian in code (25.11): guard rules in the brain,
      the two-sided guard safe and the Robinhood feed registry (see
      *The risk guardian* above) — the 4663 mainnet stand is the next
      step (planned 28-30.11)
- [ ] W3: engineering pass + gas-economy rework — "pay on delivery":
      an action pays for itself (fees accrued as accounting entries,
      collected at cash events — deposit, redeem, capital transit);
      no prepaid gas pockets, no fixed % of deposits — fixed,
      cost-based fees only (gas units × current gas price × margin);
      a settlement buffer always stays free in the safe; an anomalous
      fee is auto-refused by the safe itself; the treasury is split
      into a REACT-obligations half and an execution half + family
      redeploy
- [ ] Mainnet (Reactive 1597): Base as the conservative retail chain,
      Uniswap + Reactive Bridge adapter for the fuel loop, multi-token
      entry

## Security

Testnet software, unaudited. Not production-ready; do not deposit
funds you cannot afford to lose.

## License

MIT — see [LICENSE](./LICENSE).
