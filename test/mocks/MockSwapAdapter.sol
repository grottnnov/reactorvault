// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISwapAdapter} from "../../src/ISwapAdapter.sol";

/// @dev A rate-based swap mock for the guard safe unit tests: out =
///      in × price with real decimals (asset 18, stable 6, price 1e8),
///      minus a configurable spread (slippage simulation). Reverts
///      below minOut like a real AMM.
contract MockSwapAdapter is ISwapAdapter {
    address public immutable asset;
    address public immutable stable;
    uint256 public price; // feed-style 1e8
    uint64 public spreadBps;

    constructor(address asset_, address stable_, uint256 price_) {
        asset = asset_;
        stable = stable_;
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setSpread(uint64 bps_) external {
        spreadBps = bps_;
    }

    /// @dev The QUOTE is clean rate math — the spread models real
    ///      slippage: it hits the FILL, not the quote (that is what
    ///      makes the vault's minOut meaningful).
    function getAmountOut(address tokenIn, address, uint256 amountIn) external override returns (uint256) {
        if (tokenIn == asset) {
            // asset(1e18) → stable(1e6): value = amountIn × price / 1e20
            return amountIn * price / 1e20;
        }
        // stable(1e6) → asset(1e18): amount = amountIn × 1e20 / price
        return amountIn * 1e20 / price;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        override
        returns (uint256 amountOut)
    {
        amountOut = this.getAmountOut(tokenIn, tokenOut, amountIn) * (10_000 - spreadBps) / 10_000;
        require(amountOut >= minOut, "minOut");
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

interface MockERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}
