// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Executor, IExecutorVault} from "../src/Executor.sol";
import {AssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";
import {GuardVault} from "../src/GuardVault.sol";
import {GuardItem} from "../src/IGuardVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev The full vertical slice: executor (guardAction: verify NOW)
///      → GuardVault (HOW MUCH: real share math) → swap adapter —
///      the same wiring the 4663 deploy will use, on mocks of the
///      chain pieces only (tokens/feed/AMM). The brain's WHEN is
///      covered by GuardBrainTest; this pins the money path.
contract GuardIntegrationTest is Test {
    MockERC20 stock; // 18 dec
    MockERC20 usdg; // 6 dec
    MockFeed feed; // 8 dec
    MockSwapAdapter adapter;
    GuardVault guardVault;
    AssetVault vault; // the pool-family safe (constructor's first)
    GasVault fund;
    Executor executor;

    address alice = makeAddr("alice"); // owner of the guard safe
    address bob = makeAddr("bob"); // deployer of the executor family
    address rulesEngine = makeAddr("rulesEngine");
    address proxy = makeAddr("proxy");
    address feedAddr; // the Chainlink emitter id in messages

    uint256 constant PRICE = 100e8;
    uint64 constant TARGET = 5000;
    uint64 constant BAND = 1000;

    uint8 constant TRIM = 1;
    uint8 constant EXIT = 2;
    uint8 constant PAUSE = 4;
    uint8 constant RESUME = 5;

    event GuardActed(uint8 indexed kind, address indexed asset, uint256 price, uint256 amountIn, uint256 amountOut);

    function setUp() public {
        stock = new MockERC20("TSLA", 18);
        usdg = new MockERC20("USDG", 6);
        feed = new MockFeed();
        adapter = new MockSwapAdapter(address(stock), address(usdg), PRICE);
        feedAddr = address(feed);

        vm.startPrank(bob);
        vault = new AssetVault();
        fund = new GasVault();
        executor = new Executor(rulesEngine, IPayable(payable(proxy)), IExecutorVault(address(vault)), fund);
        vault.setGasVault(fund);
        vault.authorizeExecutor(address(executor));
        fund.authorizeExecutor(address(executor));
        vm.stopPrank();

        vm.prank(alice);
        guardVault = new GuardVault(address(stock), address(usdg), feedAddr, address(adapter), address(executor));

        vm.startPrank(bob);
        executor.addGuardVault(address(stock), address(guardVault));
        executor.setGuardStaleness(900);
        // stable-denominated per-action fee for the guard vertical
        executor.setFeeTariff(500_000, 0.02 ether);
        vm.stopPrank();

        stock.mint(alice, 1000e18);
        usdg.mint(alice, 100_000e6);
        stock.mint(address(adapter), 1000e18);
        usdg.mint(address(adapter), 100_000e6);
        vm.warp(10_000); // timestamp sanity: local chains start at 1
        feed.setRound(int256(PRICE), block.timestamp); // fresh AFTER the warp

        vm.startPrank(alice);
        stock.approve(address(guardVault), 10e18);
        usdg.approve(address(guardVault), 300e6);
        guardVault.depositAsset(10e18);
        guardVault.depositStable(300e6);
        vm.stopPrank();
        // share now ≈ 76.9%: outside the 40..60% band
    }

    function _guard(uint8 kind, uint256 param, uint256 param2, uint256 bound) internal {
        GuardItem[] memory items = new GuardItem[](1);
        items[0] = GuardItem({vault: address(guardVault), kind: kind, param: param, param2: param2, bound: bound});
        vm.prank(proxy);
        // the wire is flat: sender first (the network substitution slot)
        executor.guardAction(rulesEngine, feedAddr, address(stock), 77, items);
    }

    function testTrim_FullMoneyPath() public {
        vm.expectEmit(true, true, false, true);
        emit GuardActed(TRIM, address(stock), PRICE, 3.5e18, 350e6);
        _guard(TRIM, TARGET, BAND, 0);

        // the safe is back inside the band: share = 50%
        assertEq(guardVault.assetBalance(), 6.5e18, "share restored");
        assertEq(guardVault.stableBalance(), 650e6);
        // pay-on-delivery (ADR-GAS): the served action ACCRUED the fee;
        // settlement rides the next cash event (the AssetVault pattern)
        assertEq(guardVault.accruedFees(), 500_000, "fee accrued at the served action");
        assertEq(executor.feesBilled(), 500_000);

        vm.startPrank(alice);
        usdg.approve(address(guardVault), 1e6);
        guardVault.depositStable(1e6); // any cash event settles
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(executor)), 500_000, "settled at the next cash event");
    }

    function testStale_SkipIsFree() public {
        feed.setRound(int256(PRICE), block.timestamp - 5000);
        _guard(TRIM, TARGET, BAND, 0);
        assertEq(guardVault.assetBalance(), 10e18, "no swap on a stale feed");
        assertEq(guardVault.accruedFees(), 0, "a skipped check is not billed");
    }

    function testPause_BlocksThenResumes() public {
        _guard(PAUSE, 0, 0, 0);
        assertTrue(executor.guardPaused(address(stock)));
        _guard(TRIM, TARGET, BAND, 0);
        assertEq(guardVault.assetBalance(), 10e18, "paused: no action");

        _guard(RESUME, 0, 0, 0);
        assertFalse(executor.guardPaused(address(stock)));
        _guard(TRIM, TARGET, BAND, 0);
        assertEq(guardVault.assetBalance(), 6.5e18, "resumed: the trim lands");
    }

    function testExit_VerifiedBound() public {
        feed.setRound(101e8, block.timestamp); // price above the trigger
        _guard(EXIT, 10_000, 0, 100e8); // bound 100e8 < price: recovered
        assertEq(guardVault.assetBalance(), 10e18, "recovered: no exit");

        feed.setRound(99e8, block.timestamp);
        _guard(EXIT, 10_000, 0, 100e8); // price below the bound: exits
        assertEq(guardVault.assetBalance(), 0, "full exit");
        assertGt(guardVault.stableBalance(), 990e6, "stable received");
    }
}
