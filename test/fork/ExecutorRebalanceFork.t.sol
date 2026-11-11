// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {OneToOneOracle} from "../../src/OneToOneOracle.sol";
import {MorphoPoolAdapter, IMorpho} from "../../src/adapters/MorphoPoolAdapter.sol";
import {AavePoolAdapter} from "../../src/adapters/AavePoolAdapter.sol";
import {AssetVault} from "../../src/AssetVault.sol";
import {GasVault} from "../../src/GasVault.sol";
import {Executor} from "../../src/Executor.sol";
import {IWETH9} from "../../src/adapters/AavePoolAdapter.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev Fork proof of the HEAVIEST alarm-clock path before it ever runs
///      live: a cron delivery (proxy → executor.rebalance) that recalls
///      the whole position from Aave and re-deploys it into the
///      operator-levered Morpho market — inside the brain's
///      CALLBACK_GAS_LIMIT budget. The 10.11 lesson: paid deliveries
///      that revert are silent money burn; gas is measured, not assumed.
contract ExecutorRebalanceForkTest is Test {
    string rpc = vm.envOr("SEPOLIA_RPC", string(""));

    /// The live Sepolia callback proxy — the only allowed deliverer.
    IPayable constant PROXY = IPayable(payable(0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4));

    address constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant MORPHO = 0xd011EE229E7459ba1ddd22631eF7bF528d424A14;
    address constant IRM = 0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c;
    address constant WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
    uint256 constant LLTV = 0.915e18;

    /// Mirrors the brain's constant (RulesEngine.CALLBACK_GAS_LIMIT);
    /// kept local so a bump there forces a conscious look here.
    uint64 constant BRAIN_CALLBACK_GAS = 900_000;
    /// The proxy's own bookkeeping shares the delivery gas budget.
    uint256 constant PROXY_OVERHEAD_MARGIN = 100_000;

    OneToOneOracle oracle;
    MorphoPoolAdapter morphoAdapter;
    AavePoolAdapter aaveAdapter;
    AssetVault vault;
    GasVault battery;
    Executor executor;

    address brain = makeAddr("brain");
    address cashier = makeAddr("cashier");
    address user = makeAddr("user");
    address operator = makeAddr("operator");

    function setUp() public {
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        oracle = new OneToOneOracle();
        IMorpho.MarketParams memory mp = _mp();
        IMorpho(MORPHO).createMarket(mp);

        aaveAdapter = new AavePoolAdapter(AAVE_POOL, WETH);
        morphoAdapter = new MorphoPoolAdapter(MORPHO, mp, IRM);
        vm.deal(address(aaveAdapter), 0); // fork-address inheritance guard
        vm.deal(address(morphoAdapter), 0);

        vault = new AssetVault();
        battery = new GasVault();
        executor = new Executor(brain, PROXY, vault, battery, cashier);

        vault.setGasVault(battery);
        vault.setTreasuryBps(500);
        vault.authorizeExecutor(address(executor));
        vault.authorizePoolAdapter(address(aaveAdapter));
        vault.authorizePoolAdapter(address(morphoAdapter));
        battery.authorizeExecutor(address(executor));
        executor.setPools(address(aaveAdapter), address(morphoAdapter));

        vm.deal(user, 0.05 ether);
        vm.prank(user);
        vault.deposit{value: 0.02 ether}();
    }

    function _mp() internal view returns (IMorpho.MarketParams memory) {
        return
            IMorpho.MarketParams({
                loanToken: WETH, collateralToken: WETH, oracle: address(oracle), irm: IRM, lltv: LLTV
            });
    }

    /// A live-style cron delivery: from the proxy, sender slot = brain,
    /// capped at the brain's callback gas budget.
    function _rebalance(uint256 originBlock_) internal returns (uint256 used) {
        uint256 g = gasleft();
        vm.prank(address(PROXY));
        executor.rebalance{gas: BRAIN_CALLBACK_GAS}(brain, originBlock_);
        used = g - gasleft();
    }

    /// First placement: all free capital goes to the best pool (Aave —
    /// the fresh Morpho market yields zero). The light path.
    function testForkFirstPlacementFitsBudget() public {
        uint256 used = _rebalance(1000);
        assertGt(executor.rebalanceCount(), 0, "fired");
        assertGt(vault.inPoolOf(address(aaveAdapter)), 0, "capital placed with Aave");
        assertEq(vault.inPoolOf(address(morphoAdapter)), 0);
        assertLt(used, BRAIN_CALLBACK_GAS - PROXY_OVERHEAD_MARGIN, "gas must fit the budget");
        emit log_named_uint("first placement gas", used);
    }

    /// The heaviest path: the operator lever drives the Morpho rate
    /// above the 1% spread gate → the next alarm recalls EVERYTHING
    /// from Aave and re-deploys into Morpho, still inside the budget.
    function testForkFullMoveWithLeverFitsBudget() public {
        _rebalance(1000); // baseline: everything sits with Aave

        // The demo lever, exactly as it will run live (W2.2 step 3).
        // Bootstrap truth: borrowing needs loan liquidity, and the
        // vault's capital still sits with Aave (the fresh Morpho market
        // yields zero) — so the operator SEEDS the market as a lender
        // first, then collateralizes and borrows. That is the live
        // bootstrapping shape ("оператор финансирует доходность").
        vm.deal(operator, 0.1 ether);
        IMorpho.MarketParams memory mp = _mp();
        vm.startPrank(operator);
        IWETH9(WETH).deposit{value: 0.045 ether}();
        IWETH9(WETH).approve(MORPHO, type(uint256).max);
        IMorpho(MORPHO).supply(mp, 0.02 ether, 0, operator, "");
        IMorpho(MORPHO).supplyCollateral(mp, 0.025 ether, operator, "");
        IMorpho(MORPHO).borrow(mp, 0.018 ether, 0, operator, operator);
        vm.stopPrank();
        assertGt(morphoAdapter.supplyRatePerYear(), 0.01e18, "lever drives the Morpho rate");

        uint256 aaveBefore = vault.inPoolOf(address(aaveAdapter));
        assertGt(aaveBefore, 0);

        uint256 used = _rebalance(2000);
        assertEq(vault.inPoolOf(address(aaveAdapter)), 0, "recalled from Aave");
        assertGt(vault.inPoolOf(address(morphoAdapter)), 0, "re-deployed into Morpho");
        assertLt(used, BRAIN_CALLBACK_GAS - PROXY_OVERHEAD_MARGIN, "gas must fit the budget");
        emit log_named_uint("full move gas", used);
    }
}
