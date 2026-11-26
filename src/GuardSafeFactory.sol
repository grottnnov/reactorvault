// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {GuardVault} from "./GuardVault.sol";
import {UniswapV4RhSwapAdapter, IPoolManagerRh} from "./adapters/UniswapV4RhSwapAdapter.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

interface IGuardExecutor {
    function addGuardVault(address asset_, address vault_) external;
}

/// @title GuardSafeFactory — the client's door into the guard vertical
///        (D-2611-3: per-client vaults + reactive self-service onboarding)
/// @notice The client (a human from the landing or an agent by a raw
///         contract call — the same function) brings their stock tokens
///         and picks ONE thing: the RISK LEVEL. The factory then:
///         reads the live feed price as the client's entry reference,
///         deploys the per-asset exchange adapter (once per asset,
///         reused after), deploys a GuardVault OWNED BY THE CLIENT,
///         registers it in the executor, and emits GuardSafeCreated.
///         The reactive brain subscribes to that event and arms the
///         client's rule by itself — no operator in the loop.
/// @dev The SPECTRUM (which assets are offerable, with which feed and
///      pool key) and the three risk presets are owner-set from the
///      measured output of script/rh-asset-selection.sh (the "index
///      committee": gates by measurement, review by re-run).
///      The position-size admission (client position <= 1% of the
///      measured pool depth) is checked at the deposit scale the
///      landing/agent knows; the honest bound lives in the selection
///      evidence and the landing copy.
///      Onboarding has a PAUSE (the kill-switch for the new-client
///      surface ONLY: existing clients and their exits are untouched —
///      the exit always works, in any system state).
contract GuardSafeFactory {
    address public owner;
    /// @dev P10: immutable against delegatecall.
    address private immutable _original;

    address public immutable executor;
    address public immutable stable; // USDG
    address public immutable poolManager;
    address public immutable quoter;

    /// @notice Admission gate for new clients (the new-surface
    ///         kill-switch; existing safes are never touched).
    bool public onboardingPaused;

    struct SpectrumEntry {
        bool active;
        address feed; // the Chainlink emitter on this chain
        uint24 fee; // the chosen v4 pool tier (hookless only)
        int24 tickSpacing;
    }
    mapping(address => SpectrumEntry) public spectrumOf;
    address[] public spectrumList;

    /// @notice One risk level = one fixed preset (the client's only
    ///         choice; the numbers come from the market anchors:
    ///         buffer-ladder 9/15/30% tiers, calibrated by the
    ///         selection script's measured volatility).
    struct RiskLevel {
        bool active;
        uint64 warnBps;
        uint64 midBps;
        uint64 hardBps;
        uint64 targetBps;
        uint64 bandBps;
        uint64 cooldown;
        uint64 maxStaleSec;
    }
    mapping(uint8 => RiskLevel) public riskLevelOf;

    /// @dev The per-asset exchange adapter (the pool is per-asset, the
    ///      adapter pins its key; created on first onboarding, reused).
    mapping(address => address) public adapterOf;

    /// @notice The onboarding event — the exact shape the brain's
    ///         GUARD_SAFE_CREATED subscription decodes. The seven
    ///         preset words travel PACKED in two words (the 13-arg
    ///         plain form does not fit the stack):
    ///         packedLadder = warn | mid<<64 | hard<<128 | target<<192
    ///         packedOps    = band | cooldown<<64 | maxStale<<128
    event GuardSafeCreated(
        address indexed client,
        address indexed vault,
        address indexed asset,
        address feed,
        uint8 level,
        uint256 entryRef,
        uint256 packedLadder,
        uint256 packedOps
    );
    event SpectrumAssetSet(address indexed asset, address feed, uint24 fee, int24 tickSpacing, bool active);
    event RiskLevelSet(uint8 indexed level, uint64 warnBps, uint64 midBps, uint64 hardBps);
    event OnboardingPausedSet(bool paused);

    error NotOwner();
    error ZeroAddress();
    error BadParams();
    error AssetNotOfferable();
    error LevelNotOfferable();
    error OnboardingPaused();
    error DeadFeed();
    error DelegateCallNotAllowed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier noDelegateCall() {
        if (address(this) != _original) revert DelegateCallNotAllowed();
        _;
    }

    constructor(address executor_, address stable_, address poolManager_, address quoter_) {
        if (executor_ == address(0) || stable_ == address(0) || poolManager_ == address(0) || quoter_ == address(0)) {
            revert ZeroAddress();
        }
        owner = msg.sender;
        executor = executor_;
        stable = stable_;
        poolManager = poolManager_;
        quoter = quoter_;
        _original = address(this);
    }

    // ------------------------------------------------------------- config

    /// @notice Pin one offerable asset (from the measured spectrum).
    function setSpectrumAsset(address asset_, address feed_, uint24 fee_, int24 tickSpacing_, bool active_)
        external
        onlyOwner
        noDelegateCall
    {
        if (asset_ == address(0) || feed_ == address(0) || asset_ == stable) revert ZeroAddress();
        if (fee_ == 0 || fee_ > 1_000_000 || tickSpacing_ <= 0) revert BadParams();
        SpectrumEntry storage e = spectrumOf[asset_];
        if (!e.active && active_) {
            spectrumList.push(asset_);
        }
        e.active = active_;
        e.feed = feed_;
        e.fee = fee_;
        e.tickSpacing = tickSpacing_;
        emit SpectrumAssetSet(asset_, feed_, fee_, tickSpacing_, active_);
    }

    /// @notice Pin one risk level's preset.
    function setRiskLevel(
        uint8 level_,
        uint64 warnBps_,
        uint64 midBps_,
        uint64 hardBps_,
        uint64 targetBps_,
        uint64 bandBps_,
        uint64 cooldown_,
        uint64 maxStaleSec_
    ) external onlyOwner noDelegateCall {
        if (!(warnBps_ > 0 && warnBps_ < midBps_ && midBps_ < hardBps_ && hardBps_ <= 10_000)) {
            revert BadParams();
        }
        if (targetBps_ > 10_000 || bandBps_ >= targetBps_ || cooldown_ == 0 || maxStaleSec_ == 0) revert BadParams();
        RiskLevel storage r = riskLevelOf[level_];
        r.active = true;
        r.warnBps = warnBps_;
        r.midBps = midBps_;
        r.hardBps = hardBps_;
        r.targetBps = targetBps_;
        r.bandBps = bandBps_;
        r.cooldown = cooldown_;
        r.maxStaleSec = maxStaleSec_;
        emit RiskLevelSet(level_, warnBps_, midBps_, hardBps_);
    }

    /// @notice The new-client kill-switch (existing safes: untouched).
    function setOnboardingPaused(bool paused_) external onlyOwner noDelegateCall {
        onboardingPaused = paused_;
        emit OnboardingPausedSet(paused_);
    }

    // ------------------------------------------------------- the client door

    /// @notice Bring your tokens, pick your risk level — the rest is
    ///         the machine's. Deploys YOUR vault (you are its owner:
    ///         your deposits, your always-working exit), fixes the
    ///         live feed price as YOUR entry reference, and emits the
    ///         event the reactive brain arms itself on.
    function createGuardSafe(address asset_, uint8 level_) external noDelegateCall returns (address vault) {
        if (onboardingPaused) revert OnboardingPaused();
        SpectrumEntry storage e = spectrumOf[asset_];
        if (!e.active) revert AssetNotOfferable();
        RiskLevel storage r = riskLevelOf[level_];
        if (!r.active) revert LevelNotOfferable();

        // the client's entry reference: the LIVE feed answer (a dead
        // feed refuses onboarding — honest, no arming on stale eyes)
        (, int256 answer,,,) = IAggregatorV3(e.feed).latestRoundData();
        if (answer <= 0) revert DeadFeed();
        uint256 entryRef = uint256(answer);

        // the per-asset exchange adapter (hookless pool, created once)
        address adapter = adapterOf[asset_];
        if (adapter == address(0)) {
            IPoolManagerRh.PoolKey memory key = IPoolManagerRh.PoolKey({
                currency0: asset_ < stable ? asset_ : stable,
                currency1: asset_ < stable ? stable : asset_,
                fee: e.fee,
                tickSpacing: e.tickSpacing,
                hooks: address(0)
            });
            adapter = address(new UniswapV4RhSwapAdapter(poolManager, quoter, key));
            adapterOf[asset_] = adapter;
        }

        vault = address(new GuardVault(asset_, stable, e.feed, adapter, executor, msg.sender));
        IGuardExecutor(executor).addGuardVault(asset_, vault);

        uint256 packedLadder = _packLadder(r);
        uint256 packedOps = _packOps(r);
        emit GuardSafeCreated(msg.sender, vault, asset_, e.feed, level_, entryRef, packedLadder, packedOps);
        return vault;
    }

    function _packLadder(RiskLevel memory r_) private pure returns (uint256) {
        return uint256(r_.warnBps) | (uint256(r_.midBps) << 64) | (uint256(r_.hardBps) << 128)
            | (uint256(r_.targetBps) << 192);
    }

    function _packOps(RiskLevel memory r_) private pure returns (uint256) {
        return uint256(r_.bandBps) | (uint256(r_.cooldown) << 64) | (uint256(r_.maxStaleSec) << 128);
    }

    /// @dev The per-asset exchange adapter: the pool key comes from the
    ///      spectrum entry (measured, hookless); created on the first
    ///      onboarding of the asset, reused after.
    function _adapterFor(address asset_, SpectrumEntry storage e) private returns (address) {
        address adapter = adapterOf[asset_];
        if (adapter == address(0)) {
            IPoolManagerRh.PoolKey memory key = IPoolManagerRh.PoolKey({
                currency0: asset_ < stable ? asset_ : stable,
                currency1: asset_ < stable ? stable : asset_,
                fee: e.fee,
                tickSpacing: e.tickSpacing,
                hooks: address(0)
            });
            adapter = address(new UniswapV4RhSwapAdapter(poolManager, quoter, key));
            adapterOf[asset_] = adapter;
        }
        return adapter;
    }
}
