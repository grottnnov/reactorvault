// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title ISwapAdapter — the guard safe's exchange plugin
///        (ADR-EXPANSION §4: обмен активов — плагин)
/// @notice The adapter pulls tokenIn from the caller (transferFrom,
///         exact per-swap allowance) and pushes tokenOut to the caller
///         within the same call. minOut is the slippage guard: a fill
///         below the bound reverts (a silent bad fill is worse than a
///         paid revert — the executor retries on the next event).
/// @dev getAmountOut is deliberately NOT view: a production quote can
///      require a full transaction context (the Robinhood v4 quoter
///      delivers results through a caught revert inside
///      poolManager.unlock, both steps write transient storage —
///      staticcall dies with an empty revert, measured 26.11). The
///      guard safe calls it from non-view action paths only.
interface ISwapAdapter {
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut);

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut);
}
