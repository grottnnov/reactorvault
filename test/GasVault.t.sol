// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasVault} from "../src/GasVault.sol";

/// @dev GasVault (ADR-EXPANSION §2): the ONE gas pocket — client fuel
///      reserve + treasury. Invariant: pockets ≡ balance; NoDelegateCall,
///      donation guard; executor-only draws.
contract GasVaultTest is Test {
    GasVault public battery;
    address alice = makeAddr("alice");
    address executor = makeAddr("executor");

    function setUp() public {
        vm.prank(alice);
        battery = new GasVault(); // owner = alice
        vm.prank(alice);
        battery.authorizeExecutor(executor);
        vm.deal(alice, 100 ether);
    }

    function _fuel(uint256 amount) internal {
        vm.prank(alice);
        battery.depositFuel{value: amount}();
    }

    function testDepositFuelZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(GasVault.ZeroAmount.selector);
        battery.depositFuel{value: 0}();
    }

    /// Fuel top-up: everything lands in the client pocket.
    function testDepositFuelFillsReserve() public {
        _fuel(1 ether);
        assertEq(battery.gasReserve(), 1 ether);
        assertEq(battery.treasury(), 0);
        assertEq(address(battery).balance, 1 ether, "pockets == balance");
    }

    /// consumeGasReserve: reserve → treasury reshuffle, ETH never leaves
    /// the battery (margin accounting).
    function testConsumeMovesReserveToTreasury() public {
        _fuel(1 ether);
        uint256 balanceBefore = address(battery).balance;

        vm.prank(executor);
        battery.consumeGasReserve(0.3 ether);

        assertEq(battery.gasReserve(), 0.7 ether);
        assertEq(battery.treasury(), 0.3 ether);
        assertEq(address(battery).balance, balanceBefore, "ETH stays inside");
    }

    function testConsumeInsufficientReverts() public {
        _fuel(1 ether);
        vm.prank(executor);
        vm.expectRevert(GasVault.InsufficientReserve.selector);
        battery.consumeGasReserve(1.1 ether);
    }

    function testConsumeOnlyExecutor() public {
        _fuel(1 ether);
        vm.prank(alice);
        vm.expectRevert(GasVault.NotExecutor.selector);
        battery.consumeGasReserve(0.1 ether);
    }

    /// releaseReserveTo: exact wei withdrawal to the executor's tank.
    function testReleaseReserveExact() public {
        _fuel(1 ether);
        address sink = makeAddr("sink");

        vm.prank(executor);
        battery.releaseReserveTo(sink, 0.4 ether);

        assertEq(sink.balance, 0.4 ether);
        assertEq(battery.gasReserve(), 0.6 ether);
        assertEq(battery.treasury(), 0);
        assertEq(address(battery).balance, 0.6 ether, "balance == remaining pocket");
    }

    /// treasuryIn: an explicit intake (from an AssetVault deposit share
    /// or a partner) — the invariant holds.
    function testTreasuryIn() public {
        vm.deal(address(this), 0.1 ether);
        battery.treasuryIn{value: 0.1 ether}();
        assertEq(battery.treasury(), 0.1 ether);
        assertEq(address(battery).balance, 0.1 ether, "pockets == balance");
    }

    /// withdrawTreasury: treasury → converter/buyer, owner only.
    function testWithdrawTreasury() public {
        vm.deal(address(this), 0.1 ether);
        battery.treasuryIn{value: 0.1 ether}();
        address converter = makeAddr("converter");

        vm.prank(alice);
        battery.withdrawTreasury(converter, 0.1 ether);

        assertEq(converter.balance, 0.1 ether);
        assertEq(battery.treasury(), 0);

        vm.prank(alice);
        vm.expectRevert(GasVault.InsufficientTreasury.selector);
        battery.withdrawTreasury(converter, 1 wei);
    }

    function testWithdrawTreasuryOnlyOwner() public {
        vm.deal(address(this), 1 wei);
        battery.treasuryIn{value: 1 wei}();
        vm.prank(executor);
        vm.expectRevert(GasVault.NotOwner.selector);
        battery.withdrawTreasury(executor, 1 wei);
    }

    /// P7/G15: direct transfers (donations) are reverted — explicitness
    /// over drift (depositFuel/treasuryIn are the entries).
    function testDonationsReverted() public {
        vm.expectRevert(GasVault.DonationsNotAllowed.selector);
        (bool ok,) = address(battery).call{value: 1 ether}("");
        ok; // the revert is already checked by expectRevert
    }

    /// P10: delegatecall into a foreign context is denied.
    function testNoDelegateCall() public {
        _fuel(1 ether);

        DelegateCaller caller = new DelegateCaller();
        vm.deal(address(caller), 1 ether);
        vm.expectRevert(GasVault.DelegateCallNotAllowed.selector);
        caller.callDepositFuel(address(battery));
    }

    /// withdrawAll: MVP sweep — the client can always take everything.
    function testWithdrawAllSweeps() public {
        _fuel(1 ether);
        vm.deal(address(this), 0.1 ether);
        battery.treasuryIn{value: 0.1 ether}();
        uint256 ownerBefore = alice.balance;

        vm.prank(alice);
        battery.withdrawAll();

        assertEq(alice.balance, ownerBefore + 1.1 ether);
        assertEq(battery.gasReserve(), 0);
        assertEq(battery.treasury(), 0);
    }

    /// P9 order regression: the withdrawal event is emitted before the
    /// transfer, after the pocket events — the log sequence is part of
    /// the contract's observable behavior.
    function testWithdrawAllEventOrder() public {
        _fuel(0.4 ether);
        vm.deal(address(this), 0.1 ether);
        battery.treasuryIn{value: 0.1 ether}();

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(battery));
        emit GasVault.GasReserveUpdated(0);
        vm.expectEmit(true, true, true, true, address(battery));
        emit GasVault.TreasuryUpdated(0);
        vm.expectEmit(true, true, true, true, address(battery));
        emit GasVault.Withdrawn(alice, 0.5 ether);
        battery.withdrawAll();
    }
}

/// @dev P9: state and events settle BEFORE the external transfer — a
///      reentrant owner receiver cannot observe a half-settled vault
///      (the nested sweep sees zeros and pays out nothing twice).
contract ReentrantSweepOwner {
    GasVault public battery;
    bool public reentered;

    constructor() payable {
        battery = new GasVault();
        battery.depositFuel{value: 0.5 ether}();
        battery.treasuryIn{value: 0.1 ether}();
    }

    function sweep() external {
        battery.withdrawAll();
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            battery.withdrawAll(); // the reentrant second sweep must see zeros
        }
    }
}

contract GasVaultReentrantTest is Test {
    /// The nested sweep inside receive() sees a fully settled vault
    /// (reserve 0, treasury 0, balance 0) — nothing is paid twice and
    /// nothing reverts. State settles before the external call (P9).
    function testWithdrawAllReentrantOwnerSafe() public {
        ReentrantSweepOwner owner = new ReentrantSweepOwner{value: 1 ether}();
        GasVault battery = owner.battery();

        owner.sweep();

        assertTrue(owner.reentered(), "the nested sweep did run");
        assertEq(address(owner).balance, 1 ether, "0.4 constructor rest + 0.6 paid exactly once");
        assertEq(battery.gasReserve(), 0);
        assertEq(battery.treasury(), 0);
        assertEq(address(battery).balance, 0);
    }
}

contract DelegateCaller {
    function callDepositFuel(address target) external payable {
        (bool ok, bytes memory ret) = target.delegatecall(abi.encodeWithSignature("depositFuel()"));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
