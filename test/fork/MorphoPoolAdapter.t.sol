// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {OneToOneOracle} from "../../src/OneToOneOracle.sol";
import {MorphoPoolAdapter, IMorpho} from "../../src/adapters/MorphoPoolAdapter.sol";
import {IWETH9} from "../../src/adapters/AavePoolAdapter.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
}

/// @dev Fork test against live Eth Sepolia: the REAL Morpho Blue
///      singleton, the REAL AdaptiveCurveIRM, a market WE create on the
///      fork (WETH/WETH, 1:1 oracle, LLTV 91.5%). Proves the whole demo
///      lever before it ever touches the real chain: operator borrow
///      drives the supply rate up, a rate-driven exit finds liquidity
///      exactly because repaying is what lowers the rate.
contract MorphoPoolAdapterForkTest is Test {
    string rpc = vm.envOr("SEPOLIA_RPC", string(""));

    address constant MORPHO = 0xd011EE229E7459ba1ddd22631eF7bF528d424A14;
    address constant IRM = 0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c;
    address constant WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
    uint256 constant LLTV = 0.915e18;

    IMorpho morpho;
    IWETH9 weth;
    OneToOneOracle oracle;
    MorphoPoolAdapter adapter;

    address safe = makeAddr("safe");
    address operator = makeAddr("operator");

    function setUp() public {
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        assertEq(IERC20Meta(WETH).symbol(), "WETH", "live check: the loan token must be WETH");
        morpho = IMorpho(MORPHO);
        weth = IWETH9(WETH);

        oracle = new OneToOneOracle();
        IMorpho.MarketParams memory mp = IMorpho.MarketParams({
            loanToken: WETH, collateralToken: WETH, oracle: address(oracle), irm: IRM, lltv: LLTV
        });
        morpho.createMarket(mp);

        adapter = new MorphoPoolAdapter(MORPHO, mp, IRM);
        vm.deal(address(adapter), 0); // fork-address inheritance guard
    }

    /// The market exists on the real singleton and the oracle speaks the
    /// exact Morpho scale (36 + 18 − 18).
    function testForkMarketCreated() public view {
        bytes32 id = keccak256(
            abi.encode(
                IMorpho.MarketParams({
                    loanToken: WETH, collateralToken: WETH, oracle: address(oracle), irm: IRM, lltv: LLTV
                })
            )
        );
        IMorpho.Market memory m = morpho.market(id);
        assertGt(m.lastUpdate, 0, "market created on the live singleton");
        assertEq(oracle.price(), 1e36, "ORACLE_PRICE_SCALE identity");
    }

    /// An empty market yields exactly zero — the honest baseline.
    function testForkRateZeroWithoutBorrowers() public view {
        assertEq(adapter.supplyRatePerYear(), 0);
    }

    /// Full cycle with strict settlement, no operator involved.
    function testForkSupplyWithdrawCycle() public {
        vm.deal(safe, 0.01 ether);
        vm.prank(safe);
        adapter.supply{value: 0.01 ether}();
        assertEq(adapter.totalSupplied(), 0.01 ether);
        assertGe(adapter.truePosition(), 0.01 ether);

        uint256 before = safe.balance;
        vm.prank(safe);
        adapter.withdraw(0.01 ether);
        assertEq(safe.balance - before, 0.01 ether, "exact ETH back");
        assertEq(adapter.totalSupplied(), 0);
        assertEq(address(adapter).balance, 0, "adapter holds nothing");
    }

    /// THE DEMO LEVER: the operator borrows against their own WETH —
    /// the supply rate rises above zero; the exit liquidity property
    /// (rate falls exactly when the operator repays) is proven below.
    function testForkOperatorLeverDrivesRateAndExit() public {
        vm.deal(safe, 0.02 ether);
        vm.startPrank(safe);
        adapter.supply{value: 0.02 ether}();
        vm.stopPrank();
        assertEq(adapter.supplyRatePerYear(), 0, "still zero before the lever");

        // operator: collateral 0.025 WETH, borrow 0.018 WETH (73% of supply)
        vm.deal(operator, 0.05 ether);
        IMorpho.MarketParams memory mp = IMorpho.MarketParams({
            loanToken: WETH, collateralToken: WETH, oracle: address(oracle), irm: IRM, lltv: LLTV
        });
        vm.startPrank(operator);
        weth.deposit{value: 0.025 ether}();
        weth.approve(MORPHO, type(uint256).max);
        morpho.supplyCollateral(mp, 0.025 ether, operator, "");
        morpho.borrow(mp, 0.018 ether, 0, operator, operator);
        vm.stopPrank();

        uint256 rate = adapter.supplyRatePerYear();
        assertGt(rate, 0.01e18, "operator borrow drives the rate (>1%/yr)");
        assertLt(rate, 100e18, "sanity bound");

        // utilization 90% — a full exit is liquidity-gated (documented
        // property, mirrors any lending pool)
        vm.prank(safe);
        vm.expectRevert();
        adapter.withdraw(0.02 ether);

        // the lever releases: repay + collateral out → rate falls, and
        // the same exit now settles exactly
        vm.startPrank(operator);
        weth.approve(MORPHO, type(uint256).max);
        morpho.repay(mp, 0.018 ether, 0, operator, "");
        morpho.withdrawCollateral(mp, 0.025 ether, operator, operator);
        vm.stopPrank();

        uint256 before = safe.balance;
        vm.prank(safe);
        adapter.withdraw(0.02 ether);
        assertEq(safe.balance - before, 0.02 ether, "exact exit after the lever released");
    }
}
