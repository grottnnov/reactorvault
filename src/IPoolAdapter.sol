// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IPoolAdapter — a lending-pool plugin behind the safe
/// @notice Adapters move capital between the AssetVault and exactly one
///         pool: native ETH in (supply), native ETH back to the caller
///         (withdraw). WETH wrap/unwrap is the adapter's own business
///         (ADR-EXPANSION §4: exchanges and pools are plugins). Rates
///         are normalized to WAD per year so heterogeneous pools
///         compare apples-to-apples.
interface IPoolAdapter {
    /// @notice Supply msg.value of native ETH to the pool.
    function supply() external payable;

    /// @notice Withdraw exactly ethAmount: the position shrinks and the
    ///         same amount of native ETH reaches msg.sender within this
    ///         call (the safe settles strictly).
    function withdraw(uint256 ethAmount) external;

    /// @notice The adapter's total position, ETH-denominated.
    function totalSupplied() external view returns (uint256);

    /// @notice Annual supply rate, WAD (1e18 = 100%/yr).
    function supplyRatePerYear() external view returns (uint256);
}
