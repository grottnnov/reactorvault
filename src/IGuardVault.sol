// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice The brain → executor guard message (single flat static
///         struct: one stack slot instead of eight arguments, the
///         byte layout is identical to the flat ABI encoding — the
///         network's first-payload-slot substitution (the sender
///         field) keeps working, W2.2 canon).
struct GuardMsg {
    address sender; // substituted by the network at delivery
    address feed; // the Chainlink emitter (origin chain)
    address asset; // the stock token inside the guard safe
    uint8 kind; // 1 trim, 2 exit, 3 rebuy, 4 pause, 5 resume
    uint256 param; // kind-specific (targetBps / fractionBps)
    uint256 param2; // bandBps for trim/rebuy
    uint256 bound; // the trigger price for the EXIT verification
    uint256 originBlockNumber; // the causal-feed block
}

/// @title IGuardVault — the two-sided safe of the guard vertical
///        (ADR-GUARD-RULES §2)
/// @notice A guard safe holds exactly two assets on the destination
///         chain: the risky one (a tokenized stock) and the stable one
///         (USDG). The brain computes WHEN (price history: anchor,
///         rungs), the executor verifies NOW (feed freshness, bound),
///         this vault computes HOW MUCH (share math with real token
///         and feed decimals) and swaps through its swap adapter.
///         Capital transits through the safe — the executor never
///         holds it (canon).
interface IGuardVault {
    function assetToken() external view returns (address);
    function stableToken() external view returns (address);

    /// @dev Raw balances (asset decimals / stable decimals).
    function assetBalance() external view returns (uint256);
    function stableBalance() external view returns (uint256);

    /// @notice Trim back toward the target share: sell asset when the
    ///         share is above target+band. No-op inside the band.
    ///         Returns (amountIn, amountOut) — zeros when no swap.
    function guardTrim(uint256 targetBps, uint256 bandBps) external returns (uint256 amountIn, uint256 amountOut);

    /// @notice Sell `fractionBps` of the current asset balance.
    ///         10_000 = full exit. Returns (amountIn, amountOut).
    function guardExit(uint256 fractionBps) external returns (uint256 amountIn, uint256 amountOut);

    /// @notice Buy the asset back up to the target share when the
    ///         share is below target-band. No-op inside/above band.
    ///         Returns (amountIn, amountOut) — zeros when no swap.
    function guardRebuy(uint256 targetBps, uint256 bandBps) external returns (uint256 amountIn, uint256 amountOut);

    /// @notice Pay-on-delivery (ADR-GAS): the executor bills a served
    ///         safe. Same selector family as the pool safes.
    function chargeFee(uint256 weiAmount) external;
}
