// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasVault} from "../src/GasVault.sol";

/// @dev GasVault — the fund (ADR-GAS-ARCHITECTURE): the ETH half of the
///      treasury, fed by executor margin sweeps; the prepaid client
///      pocket and its reserve plumbing are GONE. The buyer pulls its
///      purchase funds itself, capped per purchase and bounded by
///      "spend no more than earned". Invariant: treasury == balance.
contract GasVaultTest is Test {
    GasVault fund;
    address owner = makeAddr("owner");
    address executor = makeAddr("executor");
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.prank(owner);
        fund = new GasVault();
        vm.prank(owner);
        fund.authorizeExecutor(executor);
        vm.prank(owner);
        fund.authorizeBuyer(buyer, 0.05 ether);
        vm.deal(owner, 10 ether);
        vm.deal(executor, 10 ether); // backs the margin-sweep transfers
        vm.deal(buyer, 1 ether); // gas for receiving (an EOA accepts anyway)
    }

    // ------------------------------------------------- margin intake

    function test_treasuryIn_accrues_treasury_and_earned() public {
        vm.expectEmit(false, false, false, true, address(fund));
        emit GasVault.TreasuryUpdated(0.48 ether);
        vm.prank(executor);
        fund.treasuryIn{value: 0.48 ether}();
        assertEq(fund.treasury(), 0.48 ether);
        assertEq(fund.earned(), 0.48 ether, "income counter");
        assertEq(address(fund).balance, 0.48 ether, "invariant: treasury == balance");
    }

    // ------------------------------------------------- owner hand

    function test_withdrawTreasury_profit_extraction() public {
        vm.prank(executor);
        fund.treasuryIn{value: 1 ether}();

        vm.prank(owner);
        fund.withdrawTreasury(owner, 0.4 ether);
        assertEq(fund.treasury(), 0.6 ether);
        assertEq(fund.ownerWithdrawn(), 0.4 ether, "profit withdrawals counted");
        assertEq(owner.balance, 10 ether + 0.4 ether); // executor funded the sweep, not the owner
    }

    function test_withdrawTreasury_insufficient_reverts() public {
        vm.prank(executor);
        fund.treasuryIn{value: 0.1 ether}();
        vm.prank(owner);
        vm.expectRevert(GasVault.InsufficientTreasury.selector);
        fund.withdrawTreasury(owner, 0.2 ether);
    }

    function test_withdrawTreasury_only_owner() public {
        vm.prank(buyer);
        vm.expectRevert(GasVault.NotOwner.selector);
        fund.withdrawTreasury(buyer, 1 wei);
    }

    // ------------------------------------------------- buyer pull

    function test_buyer_pulls_within_cap_and_earned() public {
        vm.prank(executor);
        fund.treasuryIn{value: 1 ether}();

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        fund.pullForPurchase(0.05 ether);
        assertEq(buyer.balance - buyerBefore, 0.05 ether, "purchase funds received");
        assertEq(fund.buyerSpent(), 0.05 ether);
        assertEq(fund.treasury(), 0.95 ether);
    }

    function test_pull_above_cap_is_refused() public {
        vm.prank(executor);
        fund.treasuryIn{value: 1 ether}();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(GasVault.CapExceeded.selector, 0.06 ether, 0.05 ether));
        fund.pullForPurchase(0.06 ether);
    }

    /// The core guard: the fund may spend no more than it has EARNED.
    function test_pull_above_earned_is_refused() public {
        vm.prank(executor);
        fund.treasuryIn{value: 0.01 ether}();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(GasVault.SpentAboveEarned.selector, 0.02 ether, 0.01 ether));
        fund.pullForPurchase(0.02 ether); // within the cap, above the earned
    }

    /// Owner profit extraction reduces what the buyer may spend.
    function test_owner_withdrawal_shrinks_buyer_room() public {
        vm.prank(executor);
        fund.treasuryIn{value: 0.05 ether}();
        vm.prank(owner);
        fund.withdrawTreasury(owner, 0.03 ether);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(GasVault.SpentAboveEarned.selector, 0.05 ether, 0.02 ether));
        fund.pullForPurchase(0.05 ether); // cap allows, earned-room is 0.02

        vm.prank(buyer);
        fund.pullForPurchase(0.02 ether); // exactly the room
        assertEq(fund.buyerSpent(), 0.02 ether);
    }

    function test_pull_only_buyer() public {
        vm.prank(executor);
        fund.treasuryIn{value: 1 ether}();
        vm.prank(owner);
        vm.expectRevert(GasVault.NotBuyer.selector);
        fund.pullForPurchase(0.01 ether);
    }

    function test_buyer_cap_change_is_announced() public {
        vm.expectEmit(false, false, false, true, address(fund));
        emit GasVault.BuyCapSet(0.1 ether);
        vm.prank(owner);
        fund.setBuyCap(0.1 ether);
        assertEq(fund.buyCapWei(), 0.1 ether);
    }

    // ------------------------------------------------- hygiene

    /// Donation policy: a direct transfer reverts — the invariant must
    /// not drift (G15 canon).
    function test_donations_denied() public {
        vm.prank(owner);
        vm.expectRevert(GasVault.DonationsNotAllowed.selector);
        address(fund).call{value: 1 wei}("");
    }

    /// No pull is possible before the system earns its first margin —
    /// the bootstrap gap is covered by the depot's starter supply.
    function test_no_pull_before_income() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(GasVault.SpentAboveEarned.selector, 0.01 ether, 0));
        fund.pullForPurchase(0.01 ether);
    }
}
