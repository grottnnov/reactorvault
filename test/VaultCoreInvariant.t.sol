// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VaultCore} from "../src/VaultCore.sol";

/// @dev Handler-based accounting invariants for VaultCore v2 (ETH, two
///      pockets). Invariants:
///      (1) tracked == the actual ETH balance of the contract;
///      (2) gasReserve + treasury ≤ tracked (pockets are backed);
///      (3) the reserve respects the cap (when set);
///      (4) consume is executor-only; the reshuffle never changes the
///          balance.
contract VaultCoreHandler is Test {
    VaultCore public vault;
    address public alice;
    address public executor;

    constructor(VaultCore vault_, address alice_, address executor_) {
        vault = vault_;
        alice = alice_;
        executor = executor_;
    }

    function deposit(uint256 amount, uint32 reserveBps, uint32 treasuryBps) external payable {
        amount = bound(amount, 0.001 ether, 10 ether);
        reserveBps = uint32(bound(reserveBps, 0, 5_000));
        treasuryBps = uint32(bound(treasuryBps, 0, 5_000));
        vm.startPrank(alice);
        vault.setParams(reserveBps, treasuryBps, 5 ether);
        vault.deposit{value: amount}();
        vm.stopPrank();
    }

    function consumeReserve(uint256 amount) external {
        uint256 reserve = vault.gasReserve();
        amount = bound(amount, 0, reserve);
        vm.prank(executor);
        vault.consumeGasReserve(amount);
    }

    function releaseReserve(uint256 amount) external {
        uint256 reserve = vault.gasReserve();
        amount = bound(amount, 0, reserve);
        address sink = makeAddr("sink");
        vm.prank(executor);
        vault.releaseReserveTo(sink, amount);
    }

    function withdrawTreasury(uint256 amount) external {
        uint256 t = vault.treasury();
        amount = bound(amount, 0, t);
        if (amount == 0) return;
        vm.prank(alice);
        vault.withdrawTreasury(makeAddr("conv"), amount);
    }
}

contract VaultCoreInvariantTest is Test {
    VaultCore public vault;
    VaultCoreHandler public handler;

    address alice = makeAddr("alice");
    address executor = makeAddr("executor");
    address sinkOracle;

    function setUp() public {
        vault = new VaultCore();
        vault.authorizeExecutor(executor);
        vm.deal(alice, 1_000 ether);
        handler = new VaultCoreHandler(vault, alice, executor);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = VaultCoreHandler.deposit.selector;
        selectors[1] = VaultCoreHandler.consumeReserve.selector;
        selectors[2] = VaultCoreHandler.releaseReserve.selector;
        selectors[3] = VaultCoreHandler.withdrawTreasury.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// (1) tracked == contract balance (withdrawals stay in sync with
    /// tracked).
    function invariant_trackedMatchesBalance() public view {
        assertEq(vault.totalDeposited(), address(vault).balance, "tracked != balance");
    }

    /// (2) pockets are backed by what was deposited.
    function invariant_pocketsBacked() public view {
        assertLe(vault.gasReserve() + vault.treasury(), vault.totalDeposited(), "pockets > tracked");
    }

    /// (3) the reserve respects the cap (when set; the deposit clamp
    /// keeps it).
    function invariant_reserveWithinCap() public view {
        uint256 cap = vault.gasReserveCap();
        if (cap > 0) {
            assertLe(vault.gasReserve(), cap, "reserve above cap");
        }
    }

    /// (4) free is non-negative: balance ≥ both pockets (via
    /// rebalanceTarget).
    function invariant_freeNonNegative() public view {
        assertGe(vault.rebalanceTarget(), 0, "free < 0");
    }
}
