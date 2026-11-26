// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {UniswapV4RhSwapAdapter, IPoolManagerRh} from "../src/adapters/UniswapV4RhSwapAdapter.sol";

/// @dev Pure-logic guards of the RH adapter: every check tested here
///      fires BEFORE any external call, so no chain is needed — the
///      live money path lives in test/fork/RhV4SwapAdapter.t.sol.
contract UniswapV4RhSwapAdapterTest is Test {
    address constant PM = address(0x1234);
    address constant QUOTER = address(0x5678);
    address constant TOKEN_A = address(0xaaa1);
    address constant TOKEN_B = address(0xbbb2);
    address constant OTHER = address(0xccc3);

    IPoolManagerRh.PoolKey key;

    function setUp() public {
        key = IPoolManagerRh.PoolKey({
            currency0: TOKEN_A, currency1: TOKEN_B, fee: 3000, tickSpacing: 60, hooks: address(0)
        });
    }

    function deploy() private returns (UniswapV4RhSwapAdapter) {
        return new UniswapV4RhSwapAdapter(PM, QUOTER, key);
    }

    function testConstructorZeroPoolManager() public {
        vm.expectRevert(UniswapV4RhSwapAdapter.ZeroAddress.selector);
        new UniswapV4RhSwapAdapter(address(0), QUOTER, key);
    }

    function testConstructorZeroQuoter() public {
        vm.expectRevert(UniswapV4RhSwapAdapter.ZeroAddress.selector);
        new UniswapV4RhSwapAdapter(PM, address(0), key);
    }

    function testConstructorCurrenciesOutOfOrder() public {
        key = IPoolManagerRh.PoolKey({
            currency0: TOKEN_B, currency1: TOKEN_A, fee: 3000, tickSpacing: 60, hooks: address(0)
        });
        vm.expectRevert(UniswapV4RhSwapAdapter.CurrenciesOutOfOrder.selector);
        new UniswapV4RhSwapAdapter(PM, QUOTER, key);
    }

    /// Incident-#19 canon: every money-moving entry checks its own
    /// caller. Two layers: unlockCallback takes only the PoolManager,
    /// _swapCallback takes only this contract (the self-call).
    function testCallbackRejectsStrangers() public {
        UniswapV4RhSwapAdapter a = deploy();
        vm.prank(OTHER);
        vm.expectRevert(UniswapV4RhSwapAdapter.NotPoolManager.selector);
        a.unlockCallback("");
        vm.prank(OTHER);
        vm.expectRevert(UniswapV4RhSwapAdapter.NotSelf.selector);
        a._swapCallback("");
    }

    function testGetAmountOutBadPair() public {
        UniswapV4RhSwapAdapter a = deploy();
        vm.expectRevert(UniswapV4RhSwapAdapter.BadPair.selector);
        a.getAmountOut(OTHER, TOKEN_B, 1);
        vm.expectRevert(UniswapV4RhSwapAdapter.BadPair.selector);
        a.getAmountOut(TOKEN_A, OTHER, 1);
        vm.expectRevert(UniswapV4RhSwapAdapter.BadPair.selector);
        a.getAmountOut(TOKEN_A, TOKEN_A, 1);
    }

    function testGetAmountOutZeroAndTooBig() public {
        UniswapV4RhSwapAdapter a = deploy();
        vm.expectRevert(UniswapV4RhSwapAdapter.ZeroAmount.selector);
        a.getAmountOut(TOKEN_A, TOKEN_B, 0);
        // fires before the quoter call: no chain needed
        vm.expectRevert(UniswapV4RhSwapAdapter.AmountTooBig.selector);
        a.getAmountOut(TOKEN_A, TOKEN_B, uint256(type(uint128).max) + 1);
    }

    function testSwapZeroAndTooBig() public {
        UniswapV4RhSwapAdapter a = deploy();
        vm.expectRevert(UniswapV4RhSwapAdapter.ZeroAmount.selector);
        a.swap(TOKEN_A, TOKEN_B, 0, 0);
        vm.expectRevert(UniswapV4RhSwapAdapter.AmountTooBig.selector);
        a.swap(TOKEN_A, TOKEN_B, uint256(type(uint128).max) + 1, 0);
    }

    function testSwapBadPair() public {
        UniswapV4RhSwapAdapter a = deploy();
        vm.expectRevert(UniswapV4RhSwapAdapter.BadPair.selector);
        a.swap(OTHER, TOKEN_B, 1, 0);
    }
}
