// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasVault} from "../src/GasVault.sol";

/// @dev Handler-based accounting invariants for GasVault — the fund
///      (ADR-GAS-ARCHITECTURE): the prepaid pocket is gone. Invariants:
///      (1) treasury == the actual ETH balance (the fund fully
///          describes its money);
///      (2) earned == ownerWithdrawn + buyerSpent + treasury (every wei
///          is either still here or left through an announced door);
///      (3) buyerSpent + ownerWithdrawn <= earned (the fund spends no
///          more than it has earned — the anti-subsidy guard).
contract GasVaultHandler is Test {
    GasVault public fund;
    address public executor;
    address public owner;
    address public buyer;

    constructor(GasVault fund_, address executor_, address owner_, address buyer_) {
        fund = fund_;
        executor = executor_;
        owner = owner_;
        buyer = buyer_;
    }

    /// @dev Margin intake is sent by the handler itself (funded in
    ///      setUp). Selectors stay NON-payable: a payable fuzz selector
    ///      lets the runner pick any contract as the tx sender and drain
    ///      it with value — a tool artifact no real chain allows.
    function treasuryIn(uint256 amount) external {
        amount = bound(amount, 0, 1 ether);
        if (amount == 0) return;
        vm.prank(executor);
        fund.treasuryIn{value: amount}();
    }

    /// @dev The profit exit runs under the real owner (the deployer of
    ///      the fund in setUp). A former version pranked a stranger and
    ///      the selector always reverted NotOwner — the exit was never
    ///      exercised and the invariant held trivially.
    function withdrawTreasury(uint256 amount) external {
        uint256 t = fund.treasury();
        amount = bound(amount, 0, t);
        if (amount == 0) return;
        vm.prank(owner);
        fund.withdrawTreasury(makeAddr("profit"), amount);
    }

    /// @dev The buyer pull, bounded by BOTH guards (cap and earned-room)
    ///      so the selector exercises the happy path; the guards
    ///      themselves are red-tested in GasVault.t.sol.
    function pullForPurchase(uint256 amount) external {
        uint256 room = fund.earned() - fund.ownerWithdrawn() - fund.buyerSpent();
        uint256 cap = fund.buyCapWei();
        uint256 maxOk = room < cap ? room : cap;
        amount = bound(amount, 0, maxOk);
        if (amount == 0) return;
        vm.prank(buyer);
        fund.pullForPurchase(amount);
    }
}

contract GasVaultInvariantTest is Test {
    GasVault public fund;
    GasVaultHandler public handler;

    address executor = makeAddr("executor");
    address buyer = makeAddr("buyer");

    function setUp() public {
        fund = new GasVault();
        fund.authorizeExecutor(executor);
        fund.authorizeBuyer(buyer, 0.05 ether);
        handler = new GasVaultHandler(fund, executor, address(this), buyer);
        vm.deal(address(handler), 1_000 ether); // backs the intake selector
        vm.deal(buyer, 1 ether); // gas for receiving pulls

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = GasVaultHandler.treasuryIn.selector;
        selectors[1] = GasVaultHandler.withdrawTreasury.selector;
        selectors[2] = GasVaultHandler.pullForPurchase.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// (1) the fund fully describes its balance.
    function invariant_treasuryMatchesBalance() public view {
        assertEq(fund.treasury(), address(fund).balance, "treasury != balance");
    }

    /// (2) every earned wei is either still in the fund or left through
    ///     an announced door (owner profit, buyer purchase).
    function invariant_earnedFullyAccounted() public view {
        assertEq(
            fund.earned(),
            fund.ownerWithdrawn() + fund.buyerSpent() + fund.treasury(),
            "earned != withdrawn+spent+treasury"
        );
    }

    /// (3) the anti-subsidy guard holds under fuzz: never spent more
    ///     than earned.
    function invariant_neverSpentAboveEarned() public view {
        assertLe(fund.ownerWithdrawn() + fund.buyerSpent(), fund.earned(), "spent > earned");
    }
}
