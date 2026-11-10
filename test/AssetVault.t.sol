// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";

/// @dev AssetVault (ADR-EXPANSION §2): pure working capital, per-asset
///      instance; the treasury share is routed to the battery at
///      deposit. Invariant: balance + treasurySent ≡ totalDeposited.
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

        assertEq(vault.totalDeposited(), 1 ether);
        assertEq(vault.treasurySent(), 0.05 ether);
        assertEq(address(vault).balance, 0.95 ether, "free = value - treasury");
        assertEq(battery.treasury(), 0.05 ether, "share in the battery");
        assertEq(vault.rebalanceTarget(), 0.95 ether);
        assertEq(address(vault).balance + vault.treasurySent(), vault.totalDeposited(), "balance + sent == tracked");
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
