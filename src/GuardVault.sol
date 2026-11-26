// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IGuardVault} from "./IGuardVault.sol";
import {ISwapAdapter} from "./ISwapAdapter.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

/// @title GuardVault — the two-sided safe of the guard vertical
///        (ADR-GUARD-RULES §2, ADR-EXPANSION §2)
/// @notice Holds exactly two tokens on the destination chain: the
///         risky one (a tokenized stock, 18 decimals) and the stable
///         one (USDG, 6 decimals). The executor is the ONLY guard
///         caller (immutable pair); the owner deposits, withdraws and
///         tunes policy. The brain computes WHEN, the executor
///         verifies NOW, THIS computes HOW MUCH — the share math with
///         real decimals (feed 8) — and swaps through the adapter
///         plugin (capital transits the safe; the executor never
///         holds it). Fees: pay-on-delivery — accrue as accounting
///         debt, settle at cash events out of the STABLE side, fee
///         cap = auto-refuse. The exit always works: fees settle
///         bounded, a failing settlement defers (never blocks).
/// @dev Custody invariant: token balances change only through
///      explicit channels — owner deposit/withdraw, fee settlement
///      (stable), and swap transits (executor-guarded). Price-free by
///      design: no value invariant depends on the feed. P10
///      noDelegateCall on every entry point; the swap event is
///      emitted after the fill (amountOut is only known then — the
///      reentrancy surface is closed by role guards, n.b. vs P9).
contract GuardVault is IGuardVault {
    address public owner;
    address public immutable executor; // the guard pair, fixed at deploy
    address public immutable asset;
    address public immutable stable;
    IAggregatorV3 public feed; // owner-rewirable (a feed proxy swap)
    ISwapAdapter public swapAdapter; // owner-rewirable (router updates happen)

    /// @notice Slippage bound for every guard swap (bps off the quote).
    uint64 public slippageBps = 300;

    /// ------------------------------------------------ Pay-on-delivery (ADR-GAS)
    /// @notice Service fees owed to the system — stable-denominated
    ///         wei (the guard executor calibrates its per-action fee
    ///         in stable units). An ACCOUNTING entry, never a
    ///         transfer at action time.
    uint256 public accruedFees;
    uint256 public feesPaidOut;

    /// @notice Hard cap on a single charge — the safe auto-refuses an
    ///         anomalous charge (revert + event). Default 1 stable unit.
    uint256 public feeCap = 1 * 10 ** 6;

    address private immutable _original;

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, uint256 assetAmount, uint256 stableAmount);
    event GuardSwap(
        uint8 indexed kind, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event FeeAccrued(uint256 weiAmount);
    event FeesCollected(address indexed to, uint256 weiAmount);
    event FeeCapSet(uint256 cap);
    event SlippageSet(uint64 bps);
    event FeedSet(address feed);
    event SwapAdapterSet(address adapter);

    error NotOwner();
    error NotExecutor();
    error ZeroAddress();
    error ZeroAmount();
    error BadParams();
    error TransferFailed();
    error DelegateCallNotAllowed();
    error FeeAboveCap(uint256 asked, uint256 cap);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    modifier noDelegateCall() {
        if (address(this) != _original) revert DelegateCallNotAllowed();
        _;
    }

    /// @dev owner_ = address(0) keeps the direct-deploy semantics
    ///      (owner = msg.sender); the FACTORY passes its client
    ///      (D-2611-3: the vault belongs to the client, not the
    ///      deploying factory). Custody assignment only — the money
    ///      logic is untouched.
    constructor(
        address asset_,
        address stable_,
        address feed_,
        address swapAdapter_,
        address executor_,
        address owner_
    ) {
        if (
            asset_ == address(0) || stable_ == address(0) || feed_ == address(0) || swapAdapter_ == address(0)
                || executor_ == address(0) || asset_ == stable_
        ) {
            revert ZeroAddress();
        }
        owner = owner_ == address(0) ? msg.sender : owner_;
        executor = executor_;
        asset = asset_;
        stable = stable_;
        feed = IAggregatorV3(feed_);
        swapAdapter = ISwapAdapter(swapAdapter_);
        _original = address(this);
    }

    // ------------------------------------------------------------- config

    function setFeeCap(uint256 cap_) external onlyOwner noDelegateCall {
        if (cap_ == 0) revert ZeroAmount();
        feeCap = cap_;
        emit FeeCapSet(cap_);
    }

    function setSlippage(uint64 bps_) external onlyOwner noDelegateCall {
        if (bps_ >= 10_000) revert BadParams();
        slippageBps = bps_;
        emit SlippageSet(bps_);
    }

    function setFeed(address feed_) external onlyOwner noDelegateCall {
        if (feed_ == address(0)) revert ZeroAddress();
        feed = IAggregatorV3(feed_);
        emit FeedSet(feed_);
    }

    function setSwapAdapter(address adapter_) external onlyOwner noDelegateCall {
        if (adapter_ == address(0)) revert ZeroAddress();
        swapAdapter = ISwapAdapter(adapter_);
        emit SwapAdapterSet(adapter_);
    }

    // ------------------------------------------------------------- custody

    function depositAsset(uint256 amount_) external onlyOwner noDelegateCall {
        if (amount_ == 0) revert ZeroAmount();
        emit Deposited(msg.sender, asset, amount_);
        if (!_pull(asset, msg.sender, amount_)) revert TransferFailed();
        _collectFees(); // a deposit is a cash event (ADR-GAS)
    }

    function depositStable(uint256 amount_) external onlyOwner noDelegateCall {
        if (amount_ == 0) revert ZeroAmount();
        emit Deposited(msg.sender, stable, amount_);
        if (!_pull(stable, msg.sender, amount_)) revert TransferFailed();
        _collectFees();
    }

    /// @notice The exit that always works: fees settle bounded out of
    ///         the stable side first (a failing settlement DEFERS —
    ///         accrued debt stays, the exit never blocks), then both
    ///         balances leave in full.
    function withdrawAll() external onlyOwner noDelegateCall {
        _collectFees();
        uint256 assetAmt = assetBalance();
        uint256 stableAmt = stableBalance();
        emit Withdrawn(msg.sender, assetAmt, stableAmt);
        if (assetAmt > 0 && !_push(asset, msg.sender, assetAmt)) revert TransferFailed();
        if (stableAmt > 0 && !_push(stable, msg.sender, stableAmt)) revert TransferFailed();
    }

    // ------------------------------------------------------------- views

    function assetToken() external view override returns (address) {
        return asset;
    }

    function stableToken() external view override returns (address) {
        return stable;
    }

    function assetBalance() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function stableBalance() public view override returns (uint256) {
        return IERC20(stable).balanceOf(address(this));
    }

    /// @notice Current share of the risky asset (bps of total value).
    ///         0 when the feed is dead or the safe is empty.
    function shareBps() external view returns (uint256) {
        uint256 price = _price();
        if (price == 0) return 0;
        uint256 total = _totalValue(price);
        if (total == 0) return 0;
        return _assetValue(price) * 10_000 / total;
    }

    // ------------------------------------------------------------- guard actions

    /// @notice Trim back toward the target share: sells asset when the
    ///         share is above target+band; a no-op inside the band.
    function guardTrim(uint256 targetBps_, uint256 bandBps_)
        external
        override
        onlyExecutor
        noDelegateCall
        returns (uint256 amountIn, uint256 amountOut)
    {
        uint256 price = _price();
        if (price == 0) return (0, 0);
        uint256 total = _totalValue(price);
        if (total == 0) return (0, 0);
        uint256 share = _assetValue(price) * 10_000 / total;
        if (share <= targetBps_ + bandBps_) return (0, 0);
        uint256 desired = total * targetBps_ / 10_000;
        amountIn = (_assetValue(price) - desired) * 1e20 / price;
        if (amountIn == 0) return (0, 0);
        amountOut = _swap(1, asset, stable, amountIn);
    }

    /// @notice Sell `fractionBps` of the current asset balance
    ///         (10_000 = full exit).
    function guardExit(uint256 fractionBps_)
        external
        override
        onlyExecutor
        noDelegateCall
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (fractionBps_ == 0 || fractionBps_ > 10_000) return (0, 0);
        amountIn = assetBalance() * fractionBps_ / 10_000;
        if (amountIn == 0) return (0, 0);
        amountOut = _swap(2, asset, stable, amountIn);
    }

    /// @notice Buy the asset back up to the target share when the
    ///         share is below target-band; a no-op at/above the band.
    function guardRebuy(uint256 targetBps_, uint256 bandBps_)
        external
        override
        onlyExecutor
        noDelegateCall
        returns (uint256 amountIn, uint256 amountOut)
    {
        uint256 price = _price();
        if (price == 0) return (0, 0);
        uint256 total = _totalValue(price);
        if (total == 0) return (0, 0);
        uint256 share = _assetValue(price) * 10_000 / total;
        if (share >= targetBps_ - bandBps_) return (0, 0);
        uint256 desired = total * targetBps_ / 10_000;
        amountIn = desired - _assetValue(price); // affordable by construction (target < 100%)
        if (amountIn == 0) return (0, 0);
        amountOut = _swap(3, stable, asset, amountIn);
    }

    // ------------------------------------------------------------- fees

    /// @notice Executor service fee: ACCRUED, never transferred here.
    ///         An anomalous charge reverts (cap = auto-refuse).
    function chargeFee(uint256 weiAmount_) external override onlyExecutor noDelegateCall {
        if (weiAmount_ == 0) revert ZeroAmount();
        if (weiAmount_ > feeCap) revert FeeAboveCap(weiAmount_, feeCap);
        accruedFees += weiAmount_;
        emit FeeAccrued(weiAmount_);
    }

    /// @dev Cash-event settlement: accrued fees leave to the executor
    ///      out of the STABLE side, bounded by what is actually there;
    ///      a failing transfer defers (the debt stays accrued) — the
    ///      exit is never blocked by the fee circuit.
    function _collectFees() internal {
        uint256 pay = accruedFees;
        if (pay == 0) return;
        uint256 have = stableBalance();
        if (pay > have) pay = have;
        if (pay == 0) return;
        accruedFees -= pay;
        feesPaidOut += pay;
        emit FeesCollected(executor, pay);
        if (!_push(stable, executor, pay)) {
            // non-standard token behavior: revert the accounting, keep
            // the debt accrued, never block the caller
            accruedFees += pay;
            feesPaidOut -= pay;
        }
    }

    // ------------------------------------------------------------- internals

    /// @dev The swap transit: exact per-swap allowance, minOut from
    ///      the live quote minus the slippage bound. A fill below the
    ///      bound reverts — a silent bad fill is worse than a paid
    ///      revert (the executor retries on the next event). The
    ///      event carries the real amounts, hence after the fill.
    function _swap(uint8 kind, address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        ISwapAdapter ad = swapAdapter;
        uint256 quoted = ad.getAmountOut(tokenIn, tokenOut, amountIn);
        uint256 minOut = quoted * (10_000 - slippageBps) / 10_000;
        if (!_approve(tokenIn, address(ad), amountIn)) revert TransferFailed();
        amountOut = ad.swap(tokenIn, tokenOut, amountIn, minOut);
        emit GuardSwap(kind, tokenIn, tokenOut, amountIn, amountOut);
        _collectFees(); // a swap is a capital transit — a cash event
    }

    function _price() private view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        return answer > 0 ? uint256(answer) : 0;
    }

    /// @dev Asset value in stable-wei: balance(1e18) × price(1e8) / 1e20.
    function _assetValue(uint256 price) private view returns (uint256) {
        return assetBalance() * price / 1e20;
    }

    function _totalValue(uint256 price) private view returns (uint256) {
        return _assetValue(price) + stableBalance();
    }

    function _pull(address token, address from, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _push(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _approve(address token, address spender, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}
