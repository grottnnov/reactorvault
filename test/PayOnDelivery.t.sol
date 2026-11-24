// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AssetVault} from "../src/AssetVault.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @notice Pay-on-delivery fee accounting (ADR-GAS-ARCHITECTURE, 24.11):
///         1) a deposit takes NOTHING beyond working capital (entry = 0,
///            no percentage of the deposit in any form);
///         2) an executor fee is ACCRUED as an accounting entry — no
///            transfer at action time, so a fully deployed (staked) safe
///            can never fail to pay;
///         3) an anomalous fee is auto-refused by the safe itself
///            (hard cap: revert + event, no UI needed);
///         4) collection happens at cash events (deposit in this slice;
///            redeem and capital transit follow).
contract PayOnDeliveryTest is Test {
    AssetVault vault;
    address owner = makeAddr("owner");
    address executor = makeAddr("executor");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner);
        vault = new AssetVault();
        vm.prank(owner);
        vault.authorizeExecutor(executor);
        vm.deal(alice, 10 ether);
    }

    function test_deposit_takes_nothing_beyond_working_capital() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        assertEq(vault.totalDeposited(), 1 ether, "entry must be free");
        assertEq(address(vault).balance, 1 ether);
        assertEq(vault.treasurySent(), 0);
    }

    function test_executor_fee_is_accrued_not_transferred() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        uint256 balBefore = address(vault).balance;
        vm.prank(executor);
        vault.chargeFee(0.01 ether);
        assertEq(vault.accruedFees(), 0.01 ether, "accounting entry");
        assertEq(address(vault).balance, balBefore, "no transfer at action time");
    }

    function test_anomalous_fee_is_auto_refused() public {
        vm.prank(owner);
        vault.setFeeCap(0.05 ether);
        vm.prank(executor);
        vm.expectRevert();
        vault.chargeFee(0.06 ether);
    }

    function test_fee_cap_change_is_announced() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit AssetVault.FeeCapSet(0.05 ether);
        vm.prank(owner);
        vault.setFeeCap(0.05 ether);
    }

    function test_fees_collected_at_cash_event() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.prank(executor);
        vault.chargeFee(0.01 ether);
        // a new deposit is a cash event: accrued fees leave with it
        vm.prank(alice);
        vault.deposit{value: 0.1 ether}();
        assertEq(vault.accruedFees(), 0, "collected at the cash event");
        assertEq(vault.totalDeposited(), 1.1 ether);
        assertEq(address(vault).balance, 1.09 ether);
        assertEq(executor.balance, 0.01 ether, "fees go to the executor");
    }

    function test_only_executor_can_charge() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.chargeFee(1 wei);
    }

    function test_fee_cap_cannot_be_set_by_stranger() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setFeeCap(1 ether);
    }

    function test_fees_settle_at_redeem() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.prank(executor);
        vault.chargeFee(0.01 ether);
        uint256 aliceBefore = alice.balance;
        uint256 shares = vault.shareOf(alice);
        vm.prank(alice);
        vault.redeem(shares);
        assertEq(vault.accruedFees(), 0, "settled at exit");
        assertEq(alice.balance - aliceBefore, 0.99 ether, "user gets assets minus fees");
        assertEq(executor.balance, 0.01 ether);
        assertEq(address(vault).balance, 0, "safe is empty");
    }

    function test_redeem_always_works_when_fees_exceed_balance() public {
        // fully "staked" scenario: fee accrued beyond free cash settles
        // partially from the payout, never blocks the exit
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.prank(executor);
        vault.chargeFee(0.1 ether);
        uint256 shares = vault.shareOf(alice);
        vm.prank(alice);
        vault.redeem(shares);
        assertEq(address(vault).balance, 0);
        assertEq(executor.balance, 0.1 ether);
    }

    function test_buffer_keeps_settlement_cash_undeployed() public {
        MockPool pool = new MockPool();
        vm.prank(owner);
        vault.authorizePoolAdapter(address(pool));
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.prank(owner);
        vault.setBufferWei(0.3 ether);
        vm.prank(executor);
        vm.expectRevert();
        vault.deployToPool(address(pool), 0.8 ether); // would eat the buffer
        vm.prank(executor);
        vault.deployToPool(address(pool), 0.7 ether); // leaves 0.3 free
        assertEq(address(vault).balance, 0.3 ether, "buffer stays in cash");
        // recall transit settles fees without a new cash event
        vm.prank(executor);
        vault.chargeFee(0.05 ether);
        vm.prank(executor);
        vault.recallFromPool(address(pool), 0.2 ether);
        assertEq(vault.accruedFees(), 0, "transit is a cash event");
        assertEq(executor.balance, 0.05 ether);
    }
}
