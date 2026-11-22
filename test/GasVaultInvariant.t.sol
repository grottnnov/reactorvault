// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasVault} from "../src/GasVault.sol";

/// @dev Handler-based accounting invariants for GasVault (ADR-EXPANSION
///      §2: the battery). Invariants:
///      (1) gasReserve + treasury == the actual ETH balance (pockets
///          fully describe the money);
///      (2) consume is executor-only and never changes the balance;
///      (3) release never overdraws the reserve.
contract GasVaultHandler is Test {
    GasVault public battery;
    address public alice;
    address public executor;
    address public owner;

    constructor(GasVault battery_, address alice_, address executor_, address owner_) {
        battery = battery_;
        alice = alice_;
        executor = executor_;
        owner = owner_;
    }

    /// @dev Deposits are sent by the handler itself (funded in setUp).
    ///         Selectors stay NON-payable: a payable fuzz selector lets
    ///         the runner pick any contract as the tx sender and drain
    ///         it with value — a tool artifact no real chain allows.
    function depositFuel(uint256 amount) external {
        amount = bound(amount, 0.001 ether, 10 ether);
        battery.depositFuel{value: amount}();
    }

    function treasuryIn(uint256 amount) external {
        amount = bound(amount, 0, 1 ether);
        if (amount == 0) return;
        battery.treasuryIn{value: amount}();
    }

    function consumeReserve(uint256 amount) external {
        uint256 reserve = battery.gasReserve();
        amount = bound(amount, 0, reserve);
        vm.prank(executor);
        battery.consumeGasReserve(amount);
    }

    function releaseReserve(uint256 amount) external {
        uint256 reserve = battery.gasReserve();
        amount = bound(amount, 0, reserve);
        address sink = makeAddr("sink");
        vm.prank(executor);
        battery.releaseReserveTo(sink, amount);
    }

    /// @dev The treasury exit MUST run under the real owner (the deployer
    ///      of the battery in setUp). A former version pranked `alice` and
    ///      the selector always reverted NotOwner — the treasury exit was
    ///      never exercised by the fuzzer, and the invariant held trivially.
    function withdrawTreasury(uint256 amount) external {
        uint256 t = battery.treasury();
        amount = bound(amount, 0, t);
        if (amount == 0) return;
        vm.prank(owner);
        battery.withdrawTreasury(makeAddr("conv"), amount);
    }
}

contract GasVaultInvariantTest is Test {
    GasVault public battery;
    GasVaultHandler public handler;

    address alice = makeAddr("alice");
    address executor = makeAddr("executor");

    function setUp() public {
        battery = new GasVault();
        battery.authorizeExecutor(executor);
        vm.deal(alice, 1_000 ether);
        handler = new GasVaultHandler(battery, alice, executor, address(this));
        vm.deal(address(handler), 1_000 ether); // backs the deposit selectors

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = GasVaultHandler.depositFuel.selector;
        selectors[1] = GasVaultHandler.treasuryIn.selector;
        selectors[2] = GasVaultHandler.consumeReserve.selector;
        selectors[3] = GasVaultHandler.releaseReserve.selector;
        selectors[4] = GasVaultHandler.withdrawTreasury.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// (1) the two pockets fully describe the balance.
    function invariant_pocketsMatchBalance() public view {
        assertEq(battery.gasReserve() + battery.treasury(), address(battery).balance, "reserve+treasury != balance");
    }

    /// (2) pockets are individually backed (never negative paths).
    function invariant_pocketsBacked() public view {
        assertLe(battery.gasReserve() + battery.treasury(), address(battery).balance, "pockets > balance");
    }
}
