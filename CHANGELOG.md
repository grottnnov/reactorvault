# Changelog

All notable changes to ReactorVault. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the contract family has no releases yet — versions name stand generations.

## [Unreleased] — the Robinhood Chain exchange leg (26.11)

The guard's HOW gets a live exchange: real TSLA→USDG swaps through the
Uniswap v4 singleton on chain 4663, proven on a live mainnet fork.

### Added
- **`UniswapV4RhSwapAdapter`** (ISwapAdapter, ADR-EXPANSION §4): talks
  to the Robinhood Chain PoolManager DIRECTLY, bypassing the forked
  Universal Router entirely (the router fork adds an undocumented
  `minHopPriceX36` word to every v4 swap input — stock SDK calldata
  reverts — while the PoolManager itself speaks the plain
  monorepo-era v4 ABI; verified against the live bytecode and the
  Blockscout-verified source). One hookless pool per pair pinned by
  measurement; the fill is bound against minOut BEFORE any
  settlement, payment is exact-delta, `take()` pays the original
  caller (the safe) — the adapter holds nothing between calls. The
  unlock callback is pool-manager-only (incident-#19 canon).
- **`script/rh-pool-discovery.sh`**: enumerates every
  `Initialize` for the pair on the live chain (the full-topic getLogs
  trick — the RH RPC silently empties wide topic-filtered ranges),
  ranks pools by StateView liquidity/depth, filters hookless with a
  sane fee, prints the chosen PoolKey with sources. Chose
  TSLA/USDG fee 3000 / tickSpacing 60 / no hook, ~$3.0M deep
  (116 pools found; the rest is launchpad spam at L=0).
- **`test/fork/RhV4SwapAdapter.t.sol`**: live-fork proof — real
  sell, real rebuy, the slippage bound reverting cleanly, the quote
  cross-checked against the pool's own slot0 (a quote above the
  frictionless amount is impossible; >1.5% below it is broken).
  Skips without `RH_RPC` (CI gets the public RPC).

### Changed
- **`ISwapAdapter.getAmountOut` is no longer `view`**: the Robinhood
  V4Quoter delivers quotes through a caught revert inside
  `poolManager.unlock`, and both steps write transient storage — a
  staticcall dies with an empty revert (measured live: eth_call
  fails, a transaction call returns the quote). `GuardVault` is
  unaffected — it quotes from non-view action paths only.

## [Unreleased] — the guard rules and the two-sided safe (25.11, ADR-GUARD-RULES)

The Robinhood risk guardian lands in the code: the brain computes WHEN from
price history, the executor verifies NOW against the live feed, the
guard safe computes HOW MUCH and swaps. Decision record:
`ADR-GUARD-RULES` (internal).

### Added
- **Guard rules in the brain** (RulesEngine): per-feed rules keyed by
  (chainId, emitter) — the idempotency key gains the emitter so two
  feeds in one block no longer swallow each other. The anchor is
  `max(entry, HWM)`: one mechanism gives both capital protection and
  the trailing floor; three rungs from the anchor (warn → trim to
  target share, mid → exit half, hard → exit all). Deepening bypasses
  the cooldown, the rebuy gate is cooldown-gated; a staleness patrol on
  any non-feed event pauses a silent feed once per episode, the fresh
  `AnswerUpdated` resumes it.
- **`guardAction` in the executor**: re-verification at execution time
  — answer positive, freshness within `guardMaxStalenessSec`, pause
  flag down, EXIT bound still crossed (a recovered price is a quiet
  skip). Acts through the guard safe, bills pay-on-delivery ONLY a
  real swap.
- **GuardVault — the two-sided safe** (stock + stable): share math on
  real decimals (asset 18, stable 6, feed 8), band no-ops, exact-
  allowance swap transits with a minOut slippage bound (a silent bad
  fill is worse than a paid revert). The executor is the immutable
  guard pair; fees accrue and settle out of the stable side; the exit
  always works (bounded settlement, failure defers, never blocks).
- **`ISwapAdapter`** (the exchange plugin interface, ADR-EXPANSION §4)
  and **`IAggregatorV3`** (minimal Chainlink view for re-verification).
- **`deployments.json`** — the machine-readable single source of truth
  for addresses and event topic0 (agent-facing: events are the push
  channel). Guarded by `DeploymentsManifestTest`: schema and
  public-artifact hygiene offline, live cross-check with RPC vars.
- **`script/feed-registry.sh`**: joins the official Chainlink RDD with
  the Robinhood asset registry, live-verifies every pair on 4663
  (token symbol, feed description, positive answer), measures cadence
  by walking the feeds' own round history (the 4663 RPC's address-
  filtered getLogs is silently empty).

## [Unreleased] — pay-on-delivery gas economy (24.11, ADR-GAS)

The prepaid client pocket and the cashier refuel circuit are gone: an
action pays for itself. Architectural decision record:
`ADR-GAS-ARCHITECTURE` (internal).

### Removed
- **GasPayer (the cashier)** is out of the family: no refuel orders, no
  reserve mirror, no GasReserveUpdated subscription. The old generation
  stays conserved on-chain, silent by construction.
- **The prepaid gas pocket** in GasVault (`depositFuel`,
  `consumeGasReserve`, `releaseReserveTo`, `gasReserve`): the degenerated
  manual-refill path dies (it broke "set it and forget it" at the door).
- **The MVP owner sweep** (`withdrawAll`) on both safes (decision 22.11):
  the exit is `redeem` — per-user, recalls from pools itself.
- `refuelEthTank` and the cashier sender-guard in Executor; the
  constructor loses its `gasPayerSender` argument.

### Added
- **Accrued service fees on the safe** (AssetVault): `chargeFee`
  (executor-only, hard cap with auto-refusal — an anomalous charge
  reverts), `accruedFees` accounting settled at cash events (deposit,
  redeem payout, recall transit). A fully staked safe cannot fail to pay.
- **Settlement buffer** (`bufferWei`): free capital that never deploys —
  fee settlement always has live cash.
- **Executor v3 billing**: every served safe is charged per action
  (per-vault isolation, a refusing vault never blocks the others); the
  tank self-sustains and everything above `tankTargetWei` is swept into
  the fund as margin.
- **GasVault is the fund** (two-halves treasury): margin intake
  (`earned` counter), owner profit extraction (`ownerWithdrawn`), and
  the buyer PULLS its purchase funds itself (`pullForPurchase`) — capped
  per purchase, bounded by "spend no more than earned". The last manual
  operational step dies.

## [Unreleased] — engineering pass (22.11)

Before the buildathon submission: one-repo consolidation and an audit-
driven hardening round (judge review 22.11).

### Added
- ReliefFund (fuel depot) and Watchdog v6 joined the family from the watcher
  line: `src/ReliefFund.sol`, `src/Watchdog.sol`,
  `src/AbstractPausableReactiveOmni.sol` + 66 tests (registry feeding,
  horizon escalation/deadlock repeat, mirror decay, pause/resume rewiring).
- Every threshold setter now emits an event (RulesEngine.setExecutor,
  GasPayer.setTariff/setOwnTank, Executor.setEthLowThreshold/setMinSpread,
  FuelConverter.setTrigger, ReliefFund policy setters): thresholds are
  money — off-chain observers must hear every retune.
- ERC-165 `supportsInterface` on the ETH pool adapters.
- CI fork job: the fork suites run against live Sepolia/mainnet via
  public RPCs — the gas-budget evidence reproduces automatically.
- This CHANGELOG.

### Changed
- English-only codebase: every Russian comment translated (~470 lines),
  measurements and incident references preserved verbatim.
- Internal ops tooling (stand sensor, Reactive MCP wrapper) removed from
  the tracked tree — kept locally.
- `withdrawAll` (AssetVault, GasVault, Erc20AssetVault) emits `Withdrawn`
  before the external transfer (Uniswap P9: events before calls).
- Deploy scripts point at local sources (repo-local paths only); keys are
  required via `:?` env guards, never sourced from another repo's .env;
  every script runs under `set -euo pipefail`.

### Fixed
- **Cooldown no longer burns on an unwired chain**: RulesEngine advanced
  `lastFiredAt` even when the destination chain had no executor, muting a
  freshly wired chain for the whole cooldown window (red test first).
- GasVault invariant handler exercised the treasury exit under the wrong
  caller (always reverted NotOwner) — the fuzzer now runs the real path.

## [W2.2] — 2026-11-11..17

Live stand generation (addresses in README): full family on Lasna +
Sepolia, lending pools (Aave + an own Morpho market), rate-driven
rebalance with a spread gate.

### Fixed (incident log)
- #15 callback-proxy debt silently pausing deliveries → public
  `coverDebt()` hatch (12.11).
- #16 quiet OOG on the faucet order → budget = need × 1.3 + 200k,
  invariant-tested (16.11).
- #19 missing caller check on pool adapters → immutable `onlyVault`
  guards, old adapters drained (17.11).

## [W2] — 2026-11-09

Initial public release: the self-healing vault family, end-to-end
deposit → brain → callback → rebalance cycle on deploy day.
