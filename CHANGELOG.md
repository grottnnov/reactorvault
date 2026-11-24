# Changelog

All notable changes to ReactorVault. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the contract family has no releases yet — versions name stand generations.

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
