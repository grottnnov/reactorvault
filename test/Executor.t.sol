// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AssetVault, IAssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";
import {Executor} from "../src/Executor.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev Executor v2 (ADR-v2 + ADR-EXPANSION §2): the assetVault+gasVault
///      pair. refuelEthTank draws from the battery (need into the tank,
///      margin into the treasury), no swap involved.
contract ExecutorTest is Test {
    AssetVault vault;
    GasVault battery;
    Executor executor;

    address alice = makeAddr("alice");
    address proxy = makeAddr("proxy"); // callback proxy = service provider
    address rulesEngine = makeAddr("rulesEngine");
    address gasPayer = makeAddr("gasPayer");

    event EthTankRefueled(uint256 needWei, uint256 marginWei);
    event ExecutorLowEth(uint256 balance, uint256 threshold);

    function setUp() public {
        vm.startPrank(alice);
        vault = new AssetVault();
        battery = new GasVault();
        executor = new Executor(rulesEngine, IPayable(payable(proxy)), vault, battery, gasPayer);
        vault.setGasVault(battery);
        vault.authorizeExecutor(address(executor));
        battery.authorizeExecutor(address(executor));
        vm.stopPrank();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        battery.depositFuel{value: 1 ether}();
    }

    function _refuel(uint256 need, uint256 margin) internal {
        vm.prank(proxy);
        executor.refuelEthTank(gasPayer, need, margin);
    }

    /// Full path: need into the executor's tank, margin into the battery treasury.
    function testRefuelTankMovesFunds() public {
        vm.expectEmit(true, true, true, true);
        emit EthTankRefueled(0.4 ether, 0.04 ether);
        _refuel(0.4 ether, 0.04 ether);

        assertEq(address(executor).balance, 0.4 ether, "executor tank");
        assertEq(battery.treasury(), 0.04 ether, "treasury pocket");
        assertEq(battery.gasReserve(), 1 ether - 0.44 ether, "reserve minus need+margin");
        assertEq(battery.gasReserve() + battery.treasury(), address(battery).balance, "pockets == balance");
        assertEq(executor.totalTankedEth(), 0.4 ether);
    }

    /// Only the proxy may deliver callbacks.
    function testRefuelOnlyServiceProvider() public {
        vm.prank(alice);
        vm.expectRevert(); // NotAuthorized from AbstractPayer
        executor.refuelEthTank(gasPayer, 0.1 ether, 0.01 ether);
    }

    /// Only the cashier is the second valid sender.
    function testRefuelOnlyGasPayerSender() public {
        vm.prank(proxy);
        vm.expectRevert();
        executor.refuelEthTank(rulesEngine, 0.1 ether, 0.01 ether);
    }

    function testRefuelMarginAboveNeedReverts() public {
        vm.prank(proxy);
        vm.expectRevert(Executor.BadMargin.selector);
        executor.refuelEthTank(gasPayer, 0.1 ether, 0.2 ether);
    }

    /// Reserve exhausted — the second refill reverts atomically (P1).
    function testRefuelBeyondReserveRevertsAtomically() public {
        _refuel(0.9 ether, 0.09 ether);
        assertEq(battery.gasReserve(), 0.01 ether);

        vm.prank(proxy);
        vm.expectRevert(GasVault.InsufficientReserve.selector);
        executor.refuelEthTank(gasPayer, 0.5 ether, 0.05 ether);

        // nothing changed
        assertEq(address(executor).balance, 0.9 ether);
        assertEq(battery.treasury(), 0.09 ether);
    }

    /// After a refill the tank is still below the threshold → the
    /// ExecutorLowEth cry (the cashier will hear it).
    function testLowEthCryAfterRefuelStillLow() public {
        vm.prank(alice);
        executor.setEthLowThreshold(2 ether); // threshold above any possible refill

        vm.expectEmit(false, false, false, true);
        emit ExecutorLowEth(0.4 ether, 2 ether);
        _refuel(0.4 ether, 0.04 ether);
    }

    /// Bootstrap-cry (red №1, 10.11): with an EMPTY tank the rebalance
    /// callback itself must cry ExecutorLowEth — refuelEthTank is the
    /// only cry site today, so with an empty tank the cashier can never
    /// learn the executor needs its first refill.
    function testRebalanceCriesWhenTankEmpty() public {
        assertEq(address(executor).balance, 0);

        vm.expectEmit(false, false, false, true);
        emit ExecutorLowEth(0, 0.005 ether);
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 1);
    }

    /// rebalance — from the brain (the first sender): the counter grows,
    /// no funds touched (W2).
    function testRebalanceFromRulesEngine() public {
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 42);
        assertEq(executor.rebalanceCount(), 1);

        vm.prank(proxy);
        vm.expectRevert(); // the cashier may not rebalance
        executor.rebalance(gasPayer, 43);
    }

    /// P10: delegatecall is denied.
    function testNoDelegateCall() public {
        DelegateCaller c = new DelegateCaller();
        vm.deal(address(c), 1 ether);
        vm.expectRevert(Executor.DelegateCallNotAllowed.selector);
        c.callRefuel(address(executor), proxy, gasPayer);
    }

    /// ADR-EXPANSION: пара сейф+батарея меняется атомарно одним сеттером.
    function testSetVaultsAtomicPair() public {
        AssetVault newVault = new AssetVault();
        GasVault newBattery = new GasVault();

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(Executor.NotOwner.selector);
        executor.setVaults(newVault, newBattery);

        vm.prank(alice);
        vm.expectRevert(Executor.ZeroAddress.selector);
        executor.setVaults(IAssetVault(address(0)), newBattery);

        vm.startPrank(alice);
        executor.setVaults(newVault, newBattery);
        vm.stopPrank();
        assertEq(address(executor.assetVault()), address(newVault));
        assertEq(address(executor.gasVault()), address(newBattery));
    }
}

contract DelegateCaller {
    function callRefuel(address target, address, address) external payable {
        (bool ok, bytes memory ret) = target.delegatecall(
            abi.encodeWithSignature("refuelEthTank(address,uint256,uint256)", address(0), 0.1 ether, 0.01 ether)
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
