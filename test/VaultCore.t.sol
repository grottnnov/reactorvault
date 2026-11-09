// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VaultCore} from "../src/VaultCore.sol";

/// @dev VaultCore v2 (ADR-v2): native ETH, two pockets (client reserve /
///      treasury), the tracked == balance invariant, NoDelegateCall,
///      donation guard.
contract VaultCoreTest is Test {
    VaultCore public vault;
    address alice = makeAddr("alice");
    address executor = makeAddr("executor");

    function setUp() public {
        vm.prank(alice);
        vault = new VaultCore(); // owner = alice
        vm.prank(alice);
        vault.authorizeExecutor(executor);
        vm.deal(alice, 100 ether);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit{value: amount}();
    }

    function testDepositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(VaultCore.ZeroAmount.selector);
        vault.deposit{value: 0}();
    }

    /// Deposit with shares: 10% reserve (≤ cap), 5% treasury, rest free.
    function testDepositSplitsIntoPockets() public {
        vm.prank(alice);
        vault.setParams(1_000, 500, 1 ether); // 10% / 5%, cap 1 ETH
        _deposit(1 ether);

        assertEq(vault.gasReserve(), 0.1 ether);
        assertEq(vault.treasury(), 0.05 ether);
        assertEq(vault.totalDeposited(), 1 ether);
        assertEq(vault.rebalanceTarget(), 0.85 ether, "free = value - pockets");
        assertEq(address(vault).balance, 1 ether, "tracked == balance");
    }

    /// Cap clamp: the reserve never exceeds the cap; the excess share
    /// stays free.
    function testReserveClampedByCap() public {
        vm.prank(alice);
        vault.setParams(10_000, 0, 0.05 ether); // 100% to reserve, but cap 0.05
        _deposit(1 ether);
        assertEq(vault.gasReserve(), 0.05 ether, "reserve = cap");
        assertEq(vault.rebalanceTarget(), 0.95 ether, "excess stays free");
    }

    function testParamsGuards() public {
        vm.prank(alice);
        vm.expectRevert(VaultCore.BadParams.selector);
        vault.setParams(6_000, 5_000, 1 ether); // shares sum > 100%
        vm.startPrank(alice);
        vault.setParams(1_000, 0, 1 ether);
        vm.stopPrank();
        _deposit(1 ether);
        uint256 below = vault.gasReserve() - 1;
        vm.prank(alice);
        vm.expectRevert(VaultCore.CapBelowReserve.selector);
        vault.setParams(1_000, 0, below); // tightening the cap below the fact
    }

    /// consumeGasReserve: reserve → treasury reshuffle, ETH never leaves
    /// the safe.
    function testConsumeMovesReserveToTreasury() public {
        vm.startPrank(alice);
        vault.setParams(10_000, 0, 1 ether);
        vm.stopPrank();
        _deposit(1 ether);
        uint256 balanceBefore = address(vault).balance;

        vm.prank(executor);
        vault.consumeGasReserve(0.3 ether);

        assertEq(vault.gasReserve(), 0.7 ether);
        assertEq(vault.treasury(), 0.3 ether);
        assertEq(address(vault).balance, balanceBefore, "ETH stays inside");
        assertEq(vault.totalDeposited(), 1 ether);
    }

    function testConsumeInsufficientReverts() public {
        vm.startPrank(alice);
        vault.setParams(10_000, 0, 1 ether);
        vm.stopPrank();
        _deposit(1 ether);
        vm.prank(executor);
        vm.expectRevert(VaultCore.InsufficientReserve.selector);
        vault.consumeGasReserve(1.1 ether);
    }

    function testConsumeOnlyExecutor() public {
        vm.startPrank(alice);
        vault.setParams(10_000, 0, 1 ether);
        vm.stopPrank();
        _deposit(1 ether);
        vm.prank(alice);
        vm.expectRevert(VaultCore.NotExecutor.selector);
        vault.consumeGasReserve(0.1 ether);
    }

    /// releaseReserveTo: exact wei withdrawal, the tracked == balance
    /// invariant holds.
    function testReleaseReserveExact() public {
        vm.startPrank(alice);
        vault.setParams(10_000, 0, 1 ether);
        vm.stopPrank();
        _deposit(1 ether);
        address sink = makeAddr("sink");

        vm.prank(executor);
        vault.releaseReserveTo(sink, 0.4 ether);

        assertEq(sink.balance, 0.4 ether);
        assertEq(vault.gasReserve(), 0.6 ether);
        assertEq(vault.totalDeposited(), 0.6 ether);
        assertEq(address(vault).balance, vault.totalDeposited(), "tracked == balance");
    }

    /// withdrawTreasury: treasury → converter, owner only.
    function testWithdrawTreasury() public {
        vm.prank(alice);
        vault.setParams(0, 1_000, 1 ether); // 10% to treasury
        _deposit(1 ether);
        address converter = makeAddr("converter");
        assertEq(vault.treasury(), 0.1 ether);

        vm.prank(alice);
        vault.withdrawTreasury(converter, 0.1 ether);

        assertEq(converter.balance, 0.1 ether);
        assertEq(vault.treasury(), 0);
        assertEq(vault.totalDeposited(), 0.9 ether);
        assertEq(address(vault).balance, 0.9 ether);

        vm.prank(alice);
        vm.expectRevert(VaultCore.InsufficientTreasury.selector);
        vault.withdrawTreasury(converter, 1 wei);
    }

    /// P7/G15: direct transfers (donations) are reverted — explicitness
    /// over drift.
    function testDonationsReverted() public {
        vm.expectRevert(VaultCore.DonationsNotAllowed.selector);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        ok; // the revert is already checked by expectRevert
    }

    /// P10: delegatecall into a foreign context is denied.
    function testNoDelegateCall() public {
        vm.startPrank(alice);
        vault.setParams(10_000, 0, 1 ether);
        vm.stopPrank();
        _deposit(1 ether);

        // A man-in-the-middle: delegatecall into vault.deposit()
        DelegateCaller caller = new DelegateCaller();
        vm.deal(address(caller), 1 ether);
        vm.expectRevert(VaultCore.DelegateCallNotAllowed.selector);
        caller.callDeposit(address(vault));
    }

    /// withdrawAll: MVP sweep (P5 debt G15: must not survive per-user
    /// deposits).
    function testWithdrawAllSweeps() public {
        vm.startPrank(alice);
        vault.setParams(1_000, 500, 1 ether);
        vm.stopPrank();
        _deposit(1 ether);
        uint256 ownerBefore = alice.balance;

        vm.prank(alice);
        vault.withdrawAll();

        assertEq(alice.balance, ownerBefore + 1 ether);
        assertEq(vault.gasReserve(), 0);
        assertEq(vault.treasury(), 0);
        assertEq(vault.totalDeposited(), 0);
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
