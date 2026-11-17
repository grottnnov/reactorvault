// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @dev AssetVault (ADR-EXPANSION §2): pure working capital, per-asset
///      instance; the treasury share is routed to the battery at
///      deposit. Invariant: balance + totalInPools + treasurySent
///      ≡ totalDeposited — capital lives in the safe or in authorized
///      pool adapters, rebalancing transits THROUGH the safe.
contract AssetVaultTest is Test {
    AssetVault public vault;
    GasVault public battery;
    address alice = makeAddr("alice");
    address executor = makeAddr("executor");

    function setUp() public {
        vm.startPrank(alice);
        vault = new AssetVault(); // owner = alice
        battery = new GasVault(); // owner = alice
        vault.setGasVault(battery);
        vault.authorizeExecutor(executor);
        vm.stopPrank();
        vm.deal(alice, 100 ether);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit{value: amount}();
    }

    function testDepositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(AssetVault.ZeroAmount.selector);
        vault.deposit{value: 0}();
    }

    /// Deposit with a 5% treasury share: the share lands in the battery,
    /// the rest is working capital; the invariant holds across both
    /// contracts.
    function testDepositRoutesTreasuryToBattery() public {
        vm.prank(alice);
        vault.setTreasuryBps(500); // 5%
        _deposit(1 ether);

        // fee-on-mint (17.11): totalDeposited считает РАБОЧИЙ капитал;
        // казна уехала в батарею, доли наминчены на 0.95
        assertEq(vault.totalDeposited(), 0.95 ether);
        assertEq(vault.treasurySent(), 0.05 ether);
        assertEq(address(vault).balance, 0.95 ether, "free = value - treasury");
        assertEq(battery.treasury(), 0.05 ether, "share in the battery");
        assertEq(vault.rebalanceTarget(), 0.95 ether);
        assertEq(vault.totalShares(), 0.95 ether, "shares for working assets");
        assertEq(address(vault).balance + vault.treasurySent(), vault.totalDeposited() + 0.05 ether, "physical == working + sent");
    }

    /// Доли: первый депозит при пустом сейфе — доли = рабочие активы.
    function testSharesFirstDepositProportional() public {
        _deposit(1 ether);
        assertEq(vault.totalShares(), 1 ether);
        assertEq(vault.shareOf(alice), 1 ether);
        assertEq(vault.totalAssets(), 1 ether, "NAV == assets");
    }

    /// redeem отзывает из пулов при нехватке свободных — выход всегда.
    function testRedeemRecallsFromPools() public {
        _deposit(1 ether);
        MockPool mp = _adapter();
        _deploy(address(mp), 1 ether);

        uint256 sh = vault.shareOf(alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.redeem(sh);
        assertEq(alice.balance - before, 1 ether, "full exit (delta)");
        assertEq(vault.totalShares(), 0);
        assertEq(vault.inPoolOf(address(mp)), 0);
    }

    /// Zero bps: nothing leaves the safe (ETH-only MVP default).
    function testDepositWithoutTreasuryShare() public {
        _deposit(1 ether);
        assertEq(address(vault).balance, 1 ether);
        assertEq(vault.treasurySent(), 0);
        assertEq(battery.treasury(), 0);
    }

    function testBpsGuard() public {
        vm.prank(alice);
        vm.expectRevert(AssetVault.BadParams.selector);
        vault.setTreasuryBps(10_001);
    }

    /// A deposit with bps > 0 but no battery wired fails atomically
    /// (GasVaultNotSet) — nothing is half-book.
    function testDepositFailsWithoutBattery() public {
        vm.startPrank(alice);
        AssetVault bare = new AssetVault();
        bare.setTreasuryBps(500);
        vm.stopPrank();
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(AssetVault.GasVaultNotSet.selector);
        bare.deposit{value: 1 ether}();

        assertEq(address(bare).balance, 0, "atomic - nothing kept");
    }

    /// P7/G15: direct transfers (donations) are reverted.
    function testDonationsReverted() public {
        vm.expectRevert(AssetVault.DonationsNotAllowed.selector);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        ok;
    }

    /// P10: delegatecall into a foreign context is denied.
    function testNoDelegateCall() public {
        DelegateCaller caller = new DelegateCaller();
        vm.deal(address(caller), 1 ether);
        vm.expectRevert(AssetVault.DelegateCallNotAllowed.selector);
        caller.callDeposit(address(vault));
    }

    /// withdrawAll: MVP sweep — the client always has an exit.
    function testWithdrawAllSweeps() public {
        vm.prank(alice);
        vault.setTreasuryBps(500);
        _deposit(1 ether);
        uint256 ownerBefore = alice.balance;

        vm.prank(alice);
        vault.withdrawAll();

        assertEq(alice.balance, ownerBefore + 0.95 ether);
        assertEq(vault.totalDeposited(), 0);
        assertEq(vault.treasurySent(), 0);
        assertEq(address(vault).balance, 0);
    }

    // ---------------------------------------------------------------
    // Pool accounting (W2): deploy/recall, strict settlement, the
    // invariant balance + totalInPools + treasurySent ≡ totalDeposited.
    // ---------------------------------------------------------------

    function _invariant(string memory where) internal view {
        // working-семантика: balance + inPools ≡ totalDeposited (рабочие);
        // казна (treasurySent) уехала в батарею и в ledger не входит
        assertEq(
            address(vault).balance + vault.totalInPools(),
            vault.totalDeposited(),
            string.concat("invariant: ", where)
        );
    }

    function _adapter() internal returns (MockPool pool) {
        pool = new MockPool();
        vm.prank(alice);
        vault.authorizePoolAdapter(address(pool));
    }

    function _deploy(address pool, uint256 amount) internal {
        vm.prank(executor);
        vault.deployToPool(pool, amount);
    }

    function _recall(address pool, uint256 amount) internal {
        vm.prank(executor);
        vault.recallFromPool(pool, amount);
    }

    /// Deploy and recall: ETH moves safe↔adapter, the invariant holds
    /// at every stop.
    function testDeployAndRecallFlow() public {
        MockPool pool = _adapter();
        _deposit(1 ether);

        _deploy(address(pool), 0.8 ether);
        assertEq(address(vault).balance, 0.2 ether, "free after deploy");
        assertEq(vault.inPoolOf(address(pool)), 0.8 ether);
        assertEq(pool.totalSupplied(), 0.8 ether, "pool position");
        assertEq(pool.supplyRatePerYear(), 0.05e18, "rate normalization WAD/yr");
        _invariant("after deploy");

        _recall(address(pool), 0.5 ether);
        assertEq(address(vault).balance, 0.7 ether, "free after recall");
        assertEq(vault.inPoolOf(address(pool)), 0.3 ether);
        assertEq(pool.totalSupplied(), 0.3 ether);
        _invariant("after recall");
    }

    /// Guards: executor-only entry, unknown adapters, above-free and
    /// above-position amounts.
    function testPoolGuards() public {
        MockPool pool = _adapter();
        _deposit(1 ether);

        vm.prank(alice);
        vm.expectRevert(AssetVault.NotExecutor.selector);
        vault.deployToPool(address(pool), 0.1 ether);

        vm.prank(executor);
        vm.expectRevert(AssetVault.AdapterUnknown.selector);
        vault.deployToPool(makeAddr("unknown"), 0.1 ether);

        vm.prank(executor);
        vm.expectRevert(AssetVault.InsufficientFree.selector);
        vault.deployToPool(address(pool), 2 ether);

        vm.prank(executor);
        vm.expectRevert(AssetVault.InsufficientInPool.selector);
        vault.recallFromPool(address(pool), 1 ether);

        vm.prank(alice);
        vm.expectRevert(AssetVault.AdapterAlreadyKnown.selector);
        vault.authorizePoolAdapter(address(pool));
    }

    /// The client's exit always works: withdrawAll recalls every pool
    /// before sweeping.
    function testWithdrawAllRecallsFromPools() public {
        MockPool pool = _adapter();
        _deposit(1 ether);
        _deploy(address(pool), 1 ether); // all-in
        assertEq(address(vault).balance, 0);
        uint256 ownerBefore = alice.balance;

        vm.prank(alice);
        vault.withdrawAll();

        assertEq(alice.balance, ownerBefore + 1 ether, "owner got everything");
        assertEq(pool.totalSupplied(), 0, "pool empty");
        assertEq(vault.inPoolOf(address(pool)), 0);
        assertEq(address(vault).balance, 0);
        _invariant("after withdrawAll");
    }

    /// Donation policy unchanged outside the settlement window: a
    /// direct transfer still reverts even with adapters around.
    function testDonationsStillRevertedWithPools() public {
        _adapter();
        vm.expectRevert(AssetVault.DonationsNotAllowed.selector);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        ok;
    }
}

contract DelegateCaller {
    function callDeposit(address target) external payable {
        (bool ok, bytes memory ret) = target.delegatecall(abi.encodeWithSignature("deposit()"));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
