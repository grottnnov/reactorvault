// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AssetVault, IAssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";
import {Executor, IExecutorVault} from "../src/Executor.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev Executor v3 (ADR-GAS-ARCHITECTURE): the only callback sender is
///      the brain. Pay-on-delivery: a served safe is charged its fee
///      (accrued on the safe, never a transfer), the tank self-sustains,
///      and everything above the tank target is swept into the fund as
///      margin.
contract ExecutorTest is Test {
    AssetVault vault;
    GasVault fund;
    Executor executor;

    address alice = makeAddr("alice");
    address proxy = makeAddr("proxy"); // callback proxy = service provider
    address rulesEngine = makeAddr("rulesEngine");

    event ExecutorLowEth(uint256 balance, uint256 threshold);
    event VaultUnpaid(address indexed vault);
    event MarginSwept(uint256 weiAmount);
    event Rebalanced(address indexed sender, uint256 originBlockNumber, uint256 amount);

    function setUp() public {
        vm.startPrank(alice);
        vault = new AssetVault();
        fund = new GasVault();
        executor = new Executor(rulesEngine, IPayable(payable(proxy)), IExecutorVault(address(vault)), fund);
        vault.setGasVault(fund);
        vault.authorizeExecutor(address(executor));
        fund.authorizeExecutor(address(executor));
        vm.stopPrank();

        vm.deal(alice, 10 ether);
    }

    // ---------------------------------------------------------------
    // Authorization surface (the cashier circuit is gone — only the
    // brain may send callbacks now).
    // ---------------------------------------------------------------

    /// Bootstrap-cry (red №1, 10.11, preserved): with an EMPTY tank the
    /// rebalance callback itself cries ExecutorLowEth — pay-on-delivery
    /// answer: the cry means "recalibrate tariffs", not "wait for a
    /// refill order".
    function testRebalanceCriesWhenTankEmpty() public {
        assertEq(address(executor).balance, 0);

        vm.expectEmit(false, false, false, true);
        emit ExecutorLowEth(0, 0.005 ether);
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 1);
    }

    /// rebalance — from the brain only; nobody else may send.
    function testRebalanceFromRulesEngineOnly() public {
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 42);
        assertEq(executor.rebalanceCount(), 1);

        vm.prank(proxy);
        vm.expectRevert(); // any non-brain sender
        executor.rebalance(makeAddr("stranger"), 43);
    }

    // ---------------------------------------------------------------
    // Pay-on-delivery: billing + margin sweep
    // ---------------------------------------------------------------

    /// A served safe is charged the action fee — accrued, not moved.
    function testRebalanceBillsServedVault() public {
        vm.deal(address(executor), 0.03 ether); // tank at target — no sweep noise
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        vm.prank(proxy);
        executor.rebalance(rulesEngine, 1);

        assertEq(vault.accruedFees(), executor.feePerActionWei(), "fee accrued on the served safe");
        assertEq(executor.feesBilled(), executor.feePerActionWei());
        assertEq(address(vault).balance, 1 ether, "no transfer at action time");
    }

    /// The tank self-sustains: above the target everything is margin —
    /// it leaves for the fund (P9: the event precedes the transfer).
    function testMarginSweptIntoFund() public {
        vm.deal(address(executor), 0.5 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit MarginSwept(0.48 ether);
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 1);

        assertEq(address(executor).balance, 0.02 ether, "tank left at target");
        assertEq(fund.treasury(), 0.48 ether, "margin in the fund");
        assertEq(fund.earned(), 0.48 ether);
    }

    /// A vault that refuses to be billed (here: a safe whose executor is
    /// somebody else) is skipped loudly and never blocks the others.
    function testUnpaidVaultDoesNotBlockOthers() public {
        vm.deal(address(executor), 0.03 ether);
        AssetVault strangerVault = new AssetVault();
        vm.prank(alice);
        executor.addVault(IExecutorVault(address(strangerVault)));
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        vm.expectEmit(true, true, true, true, address(executor));
        emit VaultUnpaid(address(strangerVault));
        vm.prank(proxy);
        executor.rebalance(rulesEngine, 1);

        assertEq(vault.accruedFees(), executor.feePerActionWei(), "the paying vault is still billed");
        assertEq(executor.rebalanceCount(), 1);
    }

    /// Tariffs are money: the retune is announced.
    function testFeeTariffSetEmits() public {
        vm.expectEmit(true, true, true, true, address(executor));
        emit Executor.FeeTariffSet(0.001 ether, 0.05 ether);
        vm.prank(alice);
        executor.setFeeTariff(0.001 ether, 0.05 ether);
        assertEq(executor.feePerActionWei(), 0.001 ether);
    }

    // ---------------------------------------------------------------
    // Pool placement (W2, unchanged): local rate decision, transit
    // through the safe, spread gate between pools.
    // ---------------------------------------------------------------

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
        vm.deal(address(executor), 0.1 ether); // tank above target — no cry noise
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(rulesEngine, 1, 1 ether);
        _rebalance();

        assertEq(vault.inPoolOf(address(b)), 1 ether, "all-in the better pool");
        assertEq(vault.inPoolOf(address(a)), 0);
        assertEq(vault.totalInPools() + address(vault).balance + vault.feesPaidOut(), vault.totalDeposited());
    }

    /// A spread above the gate moves capital between pools (through the
    /// safe); below it the placement stays.
    function testRebalanceMovesBetweenPoolsOnlyAboveSpread() public {
        (MockPool a, MockPool b) = _armedPools();
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
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        _rebalance();
        assertEq(vault.inPoolOf(address(a)), 1 ether);
        assertEq(vault.inPoolOf(address(b)), 0);
    }

    /// P10: the money path rejects a delegatecall into a foreign context.
    function testNoDelegateCall() public {
        DelegateCaller c = new DelegateCaller();
        vm.deal(address(c), 1 ether);
        vm.expectRevert(Executor.DelegateCallNotAllowed.selector);
        c.callTariff(address(executor));
    }

    /// v3: the vault registry — add/remove + a separate fund.
    function testVaultRegistry() public {
        AssetVault newVault = new AssetVault();
        GasVault newFund = new GasVault();

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(Executor.NotOwner.selector);
        executor.addVault(IExecutorVault(address(newVault)));

        vm.prank(alice);
        executor.addVault(IExecutorVault(address(newVault)));
        assertEq(executor.vaultCount(), 2);
        assertTrue(executor.isVault(address(newVault)));

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
        executor.setGasVault(newFund);
        assertEq(address(executor.gasVault()), address(newFund));
    }

    /// Multi-asset: both safes are rebalanced by one tick — each by
    /// its OWN pools (the ETH + USDC scenario) — and both are billed.
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
        assertEq(vault2.accruedFees(), executor.feePerActionWei(), "both safes billed");
    }
}

contract DelegateCaller {
    function callTariff(address target) external payable {
        (bool ok, bytes memory ret) =
            target.delegatecall(abi.encodeWithSignature("setFeeTariff(uint256,uint256)", 1, 1));
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
///      the recipient itself paying via _coverDebt() does.
contract ExecutorDebtTest is Test {
    MockCallbackProxy proxy;
    Executor executor;

    address alice = makeAddr("alice");
    address rulesEngine = makeAddr("rulesEngine");

    function setUp() public {
        proxy = new MockCallbackProxy();
        AssetVault vault = new AssetVault();
        GasVault fund = new GasVault();
        executor = new Executor(rulesEngine, IPayable(payable(address(proxy))), IExecutorVault(address(vault)), fund);
        vault.authorizeExecutor(address(executor));
        fund.authorizeExecutor(address(executor));
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

    /// Thresholds are money: retunes are announced on-chain.
    function test_ThresholdSettersEmit() public {
        vm.expectEmit(true, true, true, true, address(executor));
        emit Executor.EthLowThresholdSet(0.01 ether);
        executor.setEthLowThreshold(0.01 ether);

        vm.expectEmit(true, true, true, true, address(executor));
        emit Executor.MinSpreadSet(0.005e18);
        executor.setMinSpread(0.005e18);
    }

    /// P10: the money path rejects a delegatecall into a foreign context
    ///      (the guard runs before the sender checks, so no proxy setup needed).
    function test_RevertWhen_RebalanceDelegateCall() public {
        DelegateRelay relay = new DelegateRelay();
        vm.expectRevert(abi.encodeWithSelector(Executor.DelegateCallNotAllowed.selector));
        relay.call(address(executor), abi.encodeWithSignature("rebalance(address,uint256)", address(0), 0));
    }
}

contract DelegateRelay {
    function call(address target, bytes memory data) external {
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
