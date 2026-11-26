// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GuardVault} from "../src/GuardVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";

/// @dev The two-sided safe (ADR-GUARD-RULES §2): stock + stable, share
///      math with REAL decimals (asset 18, stable 6, feed 8), band
///      no-ops, fee cap, and the exit that always works. The executor
///      is the only guard caller; the owner only deposits/withdraws
///      and tunes policy.
contract GuardVaultTest is Test {
    MockERC20 stock; // 18 decimals, like the real Stock Tokens
    MockERC20 usdg; // 6 decimals, like the real USDG
    MockFeed feed; // 8 decimals, like the real Chainlink stock feeds
    MockSwapAdapter adapter;
    GuardVault vault;

    address alice = makeAddr("alice"); // owner
    address bob = makeAddr("bob"); // executor
    address stranger = makeAddr("stranger");

    uint256 constant PRICE = 100e8; // $100
    uint64 constant TARGET = 5000; // 50%
    uint64 constant BAND = 1000; // ±10%

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, uint256 assetAmount, uint256 stableAmount);
    event GuardSwap(
        uint8 indexed kind, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event FeeAccrued(uint256 weiAmount);
    event FeesCollected(address indexed to, uint256 weiAmount);

    function setUp() public {
        stock = new MockERC20("TSLA", 18);
        usdg = new MockERC20("USDG", 6);
        feed = new MockFeed();
        adapter = new MockSwapAdapter(address(stock), address(usdg), PRICE);
        feed.setRound(int256(PRICE), block.timestamp);

        vm.prank(alice);
        vault = new GuardVault(address(stock), address(usdg), address(feed), address(adapter), bob, address(0));

        stock.mint(alice, 1000e18);
        usdg.mint(alice, 100_000e6);
        // the mock adapter is a pool: it needs both reserves
        stock.mint(address(adapter), 1000e18);
        usdg.mint(address(adapter), 100_000e6);
    }

    function _deposit(uint256 assetAmt, uint256 stableAmt) internal {
        vm.startPrank(alice);
        if (assetAmt > 0) {
            stock.approve(address(vault), assetAmt);
            vault.depositAsset(assetAmt);
        }
        if (stableAmt > 0) {
            usdg.approve(address(vault), stableAmt);
            vault.depositStable(stableAmt);
        }
        vm.stopPrank();
    }

    function _trim(uint64 target, uint64 band) internal returns (uint256 inAmt, uint256 outAmt) {
        vm.prank(bob);
        (inAmt, outAmt) = vault.guardTrim(target, band);
    }

    // -------------------------------------------------------------
    // custody: deposits and the always-works exit
    // -------------------------------------------------------------

    function testDeposit_BothTokens() public {
        vm.startPrank(alice);
        stock.approve(address(vault), 10e18);
        usdg.approve(address(vault), 900e6);
        vm.expectEmit(true, true, true, true);
        emit Deposited(alice, address(stock), 10e18);
        vault.depositAsset(10e18);
        vault.depositStable(900e6);
        vm.stopPrank();
        assertEq(vault.assetBalance(), 10e18);
        assertEq(vault.stableBalance(), 900e6);
    }

    function testWithdrawAll_AlwaysWorksWithAccruedFees() public {
        _deposit(10e18, 900e6);
        vm.prank(bob);
        vault.chargeFee(500_000); // 0.5 USDG accrued
        assertEq(vault.accruedFees(), 500_000);

        vm.prank(alice);
        vault.withdrawAll();
        // the fee settled out of the stable side; the rest left in full
        assertEq(stock.balanceOf(alice), 1000e18, "all stock back");
        assertEq(usdg.balanceOf(alice), 100_000e6 - 500_000, "stable minus the settled fee");
        assertEq(vault.assetBalance(), 0);
        assertEq(vault.stableBalance(), 0);
        assertEq(usdg.balanceOf(bob), 500_000, "executor got the fee");
    }

    // -------------------------------------------------------------
    // share math: the band
    // -------------------------------------------------------------

    function testTrim_NoOpInsideBand() public {
        _deposit(10e18, 900e6); // share ≈ 52.6% — inside 40..60%
        (uint256 inAmt, uint256 outAmt) = _trim(TARGET, BAND);
        assertEq(inAmt, 0);
        assertEq(outAmt, 0);
        assertEq(vault.assetBalance(), 10e18, "nothing moved");
    }

    function testTrim_SellsDownToTarget() public {
        _deposit(10e18, 300e6); // share ≈ 76.9% > 60%
        vm.expectEmit(true, true, true, true);
        emit GuardSwap(1, address(stock), address(usdg), 3.5e18, 350e6);
        (uint256 inAmt, uint256 outAmt) = _trim(TARGET, BAND);
        assertEq(inAmt, 3.5e18, "sells the excess worth $350");
        assertEq(outAmt, 350e6);
        assertEq(vault.assetBalance(), 6.5e18, "share back to 50%");
        assertEq(vault.stableBalance(), 650e6);
    }

    function testTrim_SlippageReverts() public {
        _deposit(10e18, 300e6);
        adapter.setSpread(1000); // 10% real slippage vs the 3% bound
        vm.prank(bob);
        vm.expectRevert("minOut");
        vault.guardTrim(TARGET, BAND);
    }

    function testRebuy_BuysUpToTarget() public {
        _deposit(2e18, 1000e6); // share ≈ 16.7% < 40%
        (uint256 inAmt, uint256 outAmt) = _rebuy(TARGET, BAND);
        assertEq(inAmt, 400e6, "buys $400 worth");
        assertEq(outAmt, 4e18);
        assertEq(inAmt, 400e6, "buys $400 worth");
        assertEq(outAmt, 4e18);
        assertEq(vault.assetBalance(), 6e18, "share back to 50%");
        assertEq(vault.stableBalance(), 600e6);
    }

    function testRebuy_NoOpAboveBand() public {
        _deposit(10e18, 900e6); // share ≈ 52.6% — inside the band
        (uint256 inAmt, uint256 outAmt) = _rebuy(TARGET, BAND);
        assertEq(inAmt, 0);
        assertEq(outAmt, 0);
    }

    function testExit_SellsFraction() public {
        _deposit(10e18, 0);
        vm.prank(bob);
        (uint256 inAmt, uint256 outAmt) = vault.guardExit(5000);
        assertEq(inAmt, 5e18, "half the position");
        assertEq(outAmt, 500e6);
        assertEq(vault.assetBalance(), 5e18);
        assertEq(vault.stableBalance(), 500e6);
    }

    function testTrim_EmptySafe_NoOp() public {
        (uint256 inAmt, uint256 outAmt) = _trim(TARGET, BAND);
        assertEq(inAmt, 0);
        assertEq(outAmt, 0);
    }

    function testTrim_BadPrice_NoOp() public {
        _deposit(10e18, 300e6);
        feed.setRound(0, block.timestamp); // a dead feed: the math refuses
        (uint256 inAmt, uint256 outAmt) = _trim(TARGET, BAND);
        assertEq(inAmt, 0);
        assertEq(outAmt, 0);
    }

    // -------------------------------------------------------------
    // pay-on-delivery fees
    // -------------------------------------------------------------

    function testFee_CapAutoRefuse() public {
        vm.prank(alice); // the depositor protects themselves from overcharging
        vault.setFeeCap(1_000_000); // 1 USDG
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GuardVault.FeeAboveCap.selector, 2_000_000, 1_000_000));
        vault.chargeFee(2_000_000);
    }

    function testFee_SettlesAtSwapTransit() public {
        _deposit(10e18, 300e6);
        vm.prank(bob);
        vault.chargeFee(500_000);
        _trim(TARGET, BAND); // a swap is a cash transit
        assertEq(vault.accruedFees(), 0, "settled");
        assertEq(usdg.balanceOf(bob), 500_000, "executor paid");
    }

    // -------------------------------------------------------------
    // authorization
    // -------------------------------------------------------------

    function testOnlyExecutor_GuardAndFees() public {
        _deposit(10e18, 300e6);
        vm.prank(stranger);
        vm.expectRevert(GuardVault.NotExecutor.selector);
        vault.guardTrim(TARGET, BAND);
        vm.prank(stranger);
        vm.expectRevert(GuardVault.NotExecutor.selector);
        vault.chargeFee(1);
    }

    function testOnlyOwner_DepositsAndExit() public {
        vm.prank(stranger);
        vm.expectRevert(GuardVault.NotOwner.selector);
        vault.depositAsset(1e18);
        vm.prank(stranger);
        vm.expectRevert(GuardVault.NotOwner.selector);
        vault.withdrawAll();
    }

    function _rebuy(uint64 target, uint64 band) internal returns (uint256 inAmt, uint256 outAmt) {
        vm.prank(bob);
        (inAmt, outAmt) = vault.guardRebuy(target, band);
    }
}
