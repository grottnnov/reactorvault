// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Executor-side mock of the guard safe (ADR-GUARD-RULES §2):
///      records calls, returns configurable swap results. The real
///      GuardVault (two-sided safe + Uniswap adapter on 4663) is the
///      next build step; this mock pins the interface.
contract MockGuardVault {
    address public immutable assetToken;
    address public immutable stableToken;

    uint256 public assetBal;
    uint256 public stableBal;

    uint256 public lastTrimTargetBps;
    uint256 public lastTrimBandBps;
    uint256 public lastExitFractionBps;
    uint256 public lastRebuyTargetBps;
    uint256 public lastRebuyBandBps;

    uint256 public trimResultIn;
    uint256 public trimResultOut;
    uint256 public exitResultIn;
    uint256 public exitResultOut;
    uint256 public rebuyResultIn;
    uint256 public rebuyResultOut;

    uint256 public billedTotal;
    uint256 public lastFeeCharged;

    constructor(address asset_, address stable_) {
        assetToken = asset_;
        stableToken = stable_;
    }

    function setBalances(uint256 assetBal_, uint256 stableBal_) external {
        assetBal = assetBal_;
        stableBal = stableBal_;
    }

    function setSwapResults(
        uint256 trimIn,
        uint256 trimOut,
        uint256 exitIn,
        uint256 exitOut,
        uint256 rebuyIn,
        uint256 rebuyOut
    ) external {
        trimResultIn = trimIn;
        trimResultOut = trimOut;
        exitResultIn = exitIn;
        exitResultOut = exitOut;
        rebuyResultIn = rebuyIn;
        rebuyResultOut = rebuyOut;
    }

    function assetBalance() external view returns (uint256) {
        return assetBal;
    }

    function stableBalance() external view returns (uint256) {
        return stableBal;
    }

    function guardTrim(uint256 targetBps_, uint256 bandBps_) external returns (uint256 amountIn, uint256 amountOut) {
        lastTrimTargetBps = targetBps_;
        lastTrimBandBps = bandBps_;
        return (trimResultIn, trimResultOut);
    }

    function guardExit(uint256 fractionBps_) external returns (uint256 amountIn, uint256 amountOut) {
        lastExitFractionBps = fractionBps_;
        return (exitResultIn, exitResultOut);
    }

    function guardRebuy(uint256 targetBps_, uint256 bandBps_) external returns (uint256 amountIn, uint256 amountOut) {
        lastRebuyTargetBps = targetBps_;
        lastRebuyBandBps = bandBps_;
        return (rebuyResultIn, rebuyResultOut);
    }

    function chargeFee(uint256 weiAmount_) external {
        lastFeeCharged = weiAmount_;
        billedTotal += weiAmount_;
    }
}
