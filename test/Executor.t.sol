// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AssetVault, IAssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";
import {Executor, IExecutorVault} from "../src/Executor.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";
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
        executor =
            new Executor(rulesEngine, IPayable(payable(proxy)), IExecutorVault(address(vault)), battery, gasPayer);
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

    /// rebalance — from the brain (the first sender): without pools set
    /// only the counter grows; the cashier may not rebalance.
    function testRebalanceFromRulesEngine() public {
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 42);
        assertEq(executor.rebalanceCount(), 1);

        vm.prank(proxy);
        vm.expectRevert(); // the cashier may not rebalance
        executor.rebalance(gasPayer, 43);
    }

    // ---------------------------------------------------------------
    // Pool placement (W2): local rate decision, transit through the
    // safe, spread gate between pools.
    // ---------------------------------------------------------------

    event Rebalanced(address indexed sender, uint256 originBlockNumber, uint256 amount);

    function _armedPools() internal returns (MockPool a, MockPool b) {
        a = new MockPool(); // 5%/yr
        b = new MockPool(); // 5%/yr
        vm.startPrank(alice);
        vault.authorizePoolAdapter(address(a));
        vault.authorizePoolAdapter(address(b));
        vm.stopPrank();
    }

    function _rebalance() internal {
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 1);
    }

    /// Idle capital goes to the better pool unconditionally.
    function testRebalancePlacesFreeCapitalInBetterPool() public {
        (MockPool a, MockPool b) = _armedPools();
        b.setRatePerYear(0.09e18);
        vm.deal(address(executor), 0.1 ether); // tank full — no cry noise
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(rulesEngine, 1, 1 ether);
        _rebalance();

        assertEq(vault.inPoolOf(address(b)), 1 ether, "all-in the better pool");
        assertEq(vault.inPoolOf(address(a)), 0);
        assertEq(address(vault).balance, 0, "no free left");
        assertEq(address(vault).balance + vault.totalInPools(), vault.totalDeposited(), "safe invariant");
    }

    /// A spread above the gate moves capital between pools (through the
    /// safe); below it the placement stays.
    function testRebalanceMovesBetweenPoolsOnlyAboveSpread() public {
        (MockPool a, MockPool b) = _armedPools();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        b.setRatePerYear(0.06e18); // +1% = exactly the gate
        _rebalance();
        assertEq(vault.inPoolOf(address(b)), 1 ether, "moved at the gate");
        assertEq(a.totalSupplied(), 0);

        b.setRatePerYear(0.055e18); // +0.5% — below the gate
        _rebalance();
        assertEq(vault.inPoolOf(address(b)), 1 ether, "stays below the gate");
        assertEq(executor.rebalanceCount(), 2);
    }

    /// Equal rates: the tie goes to poolA; nothing flaps.
    function testRebalanceTieStaysInPoolA() public {
        (MockPool a, MockPool b) = _armedPools();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        _rebalance();
        assertEq(vault.inPoolOf(address(a)), 1 ether);
        assertEq(vault.inPoolOf(address(b)), 0);
    }

    /// P10: delegatecall is denied.
    function testNoDelegateCall() public {
        DelegateCaller c = new DelegateCaller();
        vm.deal(address(c), 1 ether);
        vm.expectRevert(Executor.DelegateCallNotAllowed.selector);
        c.callRefuel(address(executor), proxy, gasPayer);
    }

    /// v3: the vault registry — add/remove + a separate battery.
    function testVaultRegistry() public {
        AssetVault newVault = new AssetVault();
        GasVault newBattery = new GasVault();

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(Executor.NotOwner.selector);
        executor.addVault(IExecutorVault(address(newVault)));

        vm.prank(alice);
        executor.addVault(IExecutorVault(address(newVault)));
        assertEq(executor.vaultCount(), 2);
        assertTrue(executor.isVault(address(newVault)));

        // a duplicate add and removing a nonexistent vault — revert
        vm.startPrank(alice);
        vm.expectRevert(Executor.ZeroAddress.selector);
        executor.addVault(IExecutorVault(address(newVault)));
        vm.expectRevert(Executor.ZeroAddress.selector);
        executor.removeVault(IExecutorVault(address(makeAddr("ghost"))));
        executor.removeVault(IExecutorVault(address(newVault)));
        vm.stopPrank();
        assertEq(executor.vaultCount(), 1);
        assertFalse(executor.isVault(address(newVault)));

        vm.prank(alice);
        executor.setGasVault(newBattery);
        assertEq(address(executor.gasVault()), address(newBattery));
    }

    /// Multi-asset: both safes are rebalanced by one tick — each by
    /// its OWN pools (the v3 ETH + USDC scenario).
    function testRebalanceCoversAllVaults() public {
        (MockPool a, MockPool b) = _armedPools();
        b.setRatePerYear(0.09e18);
        vm.deal(address(executor), 0.1 ether);

        AssetVault vault2 = new AssetVault();
        vault2.authorizeExecutor(address(executor));
        MockPool c = new MockPool(); // 7%
        MockPool d = new MockPool(); // 3%
        c.setRatePerYear(0.07e18);
        d.setRatePerYear(0.03e18);
        vault2.authorizePoolAdapter(address(c));
        vault2.authorizePoolAdapter(address(d));
        vm.prank(alice);
        executor.addVault(IExecutorVault(address(vault2)));

        vm.deal(alice, 2 ether);
        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault2.deposit{value: 1 ether}();
        vm.stopPrank();

        vm.prank(proxy);
        executor.rebalance(rulesEngine, 1);

        assertEq(vault.inPoolOf(address(b)), 1 ether, "vault1: best pool (b)");
        assertEq(vault2.inPoolOf(address(c)), 1 ether, "vault2: best pool (c)");
        assertEq(vault2.inPoolOf(address(d)), 0);
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

/// @dev Incident #15 (12.11): a delivery attempt at an empty tank leaves
///      the recipient in debt to the callback proxy; debt > 0 = delivery
///      pause (InDebt), and plain balance top-ups do NOT clear it — only
///      the recipient itself paying via _coverDebt() does. Live proof:
///      debt(executor) = 82e-9 ETH > 0 while balance was 0.017 ETH.
contract ExecutorDebtTest is Test {
    MockCallbackProxy proxy;
    Executor executor;

    address alice = makeAddr("alice");
    address rulesEngine = makeAddr("rulesEngine");
    address gasPayer = makeAddr("gasPayer");

    function setUp() public {
        proxy = new MockCallbackProxy();
        AssetVault vault = new AssetVault();
        GasVault battery = new GasVault();
        executor = new Executor(
            rulesEngine, IPayable(payable(address(proxy))), IExecutorVault(address(vault)), battery, gasPayer
        );
        vault.authorizeExecutor(address(executor));
        battery.authorizeExecutor(address(executor));
    }

    /// RED before the fix: no coverDebt() hatch exists — a funded
    /// recipient with a dust debt stays paused forever.
    function testCoverDebtClearsProxyDebtAndLiftsPause() public {
        proxy.setDebt(address(executor), 82_000_000_000 wei); // the live 12.11 reading
        vm.deal(address(executor), 0.005 ether);

        assertGt(proxy.debt(address(executor)), 0, "precondition: in debt");
        assertGt(address(executor).balance, proxy.debt(address(executor)), "precondition: funded");

        // Anyone may call: the payment only ever goes to the proxy for
        // our own debt — not a privileged action.
        vm.prank(makeAddr("anyone"));
        executor.coverDebt();

        assertEq(proxy.debt(address(executor)), 0, "debt cleared - deliveries resume");
        assertEq(address(executor).balance, 0.005 ether - 82_000_000_000 wei);
    }
}
