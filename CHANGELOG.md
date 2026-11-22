# Changelog

All notable changes to ReactorVault. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the contract family has no releases yet — versions name stand generations.

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
