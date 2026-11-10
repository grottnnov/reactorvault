// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title OneToOneOracle — fixed 1:1 collateral price for a same-asset market
/// @notice For a WETH/WETH market the price of one WETH quoted in WETH is
///         a mathematical identity, not data: exactly 1e36 on Morpho's
///         ORACLE_PRICE_SCALE (36 + loanDecimals − collateralDecimals).
///         Immutable, ownerless, never reverts — structurally immune to
///         the oracle-manipulation class (nothing to pump, nothing to go
///         stale). No mainnet same-asset market precedent known: this is
///         a demo-market component, disclosed as such in the README.
interface IOracle {
    function price() external view returns (uint256);
}

contract OneToOneOracle is IOracle {
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    function price() external pure returns (uint256) {
        return ORACLE_PRICE_SCALE;
    }
}
