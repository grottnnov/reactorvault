// SPDX-License-License: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AaveUsdcAdapter} from "../../src/adapters/AaveUsdcAdapter.sol";
import {MorphoUsdcAdapter, IMorphoUsdc} from "../../src/adapters/MorphoUsdcAdapter.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Mainnet fork proof of the USDC adapters BEFORE deploy (canon:
///      "the weakest spot is money logic without a live shakeout"):
///      the REAL Aave v3 Pool on Ethereum, the REAL Morpho Blue with
///      the live USDC/WETH 91.5% market. Skips without MAINNET_RPC.
///      Mainnet addresses (ethereum-lists + Aave/Morpho docs, verified
///      live via symbol()/market() below — the live-check canon).
contract UsdcAdaptersForkTest is Test {
    string rpc = vm.envOr("MAINNET_RPC", string(""));

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// Chainlink USDC/ETH (Morpho docs: the USDC/WETH market, LLTV 91.5%).
    address constant ORACLE_USDC_ETH = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    /// AdaptiveCurveIRM mainnet (do not confuse with the Sepolia address!).
    address constant IRM_MAINNET = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV = 0.86e18;

    address vault = makeAddr("vault");
    address attacker = makeAddr("attacker");

    function _mp() internal pure returns (IMorphoUsdc.MarketParams memory) {
        return IMorphoUsdc.MarketParams({
            loanToken: USDC, collateralToken: WETH, oracle: ORACLE_USDC_ETH, irm: IRM_MAINNET, lltv: LLTV
        });
    }

    function setUp() public {
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        // the canon live-check: an address without the chain question is not an address
        assertEq(IERC20Meta(USDC).symbol(), "USDC", "live check: USDC");
        assertEq(IERC20Meta(WETH).symbol(), "WETH", "live check: WETH");
    }

    /// The USDC/WETH 91.5% market exists on the singleton and is alive.
    function testForkMorphoUsdcMarketExists() public view {
        bytes32 id = keccak256(abi.encode(_mp()));
        IMorphoUsdc.Market memory m = IMorphoUsdc(MORPHO).market(id);
        assertGt(m.lastUpdate, 0, "USDC/WETH 86% market must exist on mainnet");
    }

    /// Full Aave cycle: the safe pushes 100 USDC → the adapter deposits →
    /// withdraw returns exactly the same amount to the safe.
    function testForkAaveUsdcCycle() public {
        AaveUsdcAdapter adapter = new AaveUsdcAdapter(vault, AAVE_POOL, USDC);
        uint256 amount = 100e6; // 100 USDC

        deal(USDC, vault, amount, true);
        // push: the safe transfers to the adapter (mocking the safe's behavior)
        vm.prank(vault);
        (bool ok,) = USDC.call(abi.encodeWithSignature("transfer(address,uint256)", address(adapter), amount));
        require(ok, "push failed");

        vm.prank(vault);
        adapter.supply(amount);
        assertEq(adapter.totalSupplied(), amount);
        assertGt(adapter.supplyRatePerYear(), 0, "mainnet USDC rate > 0");

        vm.prank(vault);
        adapter.withdraw(amount);
        // index rounding: the remainder ≤ the safe's dust tolerance (0.01 USDC)
        assertLe(adapter.totalSupplied(), 10_000, "dust only remains");
        uint256 back = IERC20Meta(USDC).balanceOf(vault);
        assertLe(amount - back, 10_000, "settled back within dust");
    }

    /// Guard #19: a stranger can neither deposit nor withdraw.
    function testForkAaveUsdcOnlyVault() public {
        AaveUsdcAdapter adapter = new AaveUsdcAdapter(vault, AAVE_POOL, USDC);
        vm.prank(attacker);
        vm.expectRevert(AaveUsdcAdapter.NotVault.selector);
        adapter.supply(1);
        vm.prank(attacker);
        vm.expectRevert(AaveUsdcAdapter.NotVault.selector);
        adapter.withdraw(1);
    }

    /// Full Morpho cycle (a real market): push → supply → withdraw →
    /// exact settlement. NOTE: at high utilization the exit is
    /// liquidity-limited — on the live USDC/WETH market 100 USDC exits freely.
    function testForkMorphoUsdcCycle() public {
        bytes32 id = keccak256(abi.encode(_mp()));
        MorphoUsdcAdapter adapter = new MorphoUsdcAdapter(vault, MORPHO, _mp(), IRM_MAINNET, id);
        uint256 amount = 100e6;
        deal(USDC, vault, amount, true);

        vm.prank(vault);
        (bool ok,) = USDC.call(abi.encodeWithSignature("transfer(address,uint256)", address(adapter), amount));
        require(ok, "push failed");

        vm.prank(vault);
        adapter.supply(amount);
        assertEq(adapter.totalSupplied(), amount);

        vm.prank(vault);
        adapter.withdraw(amount);
        assertLe(adapter.totalSupplied(), 10_000, "dust only remains");
        uint256 back = IERC20Meta(USDC).balanceOf(vault);
        assertLe(amount - back, 10_000, "settled back within dust");
        assertGe(adapter.supplyRatePerYear(), 0); // the view reads; >0 with borrows
    }

    /// Guard #19 for Morpho.
    function testForkMorphoUsdcOnlyVault() public {
        bytes32 id = keccak256(abi.encode(_mp()));
        MorphoUsdcAdapter adapter = new MorphoUsdcAdapter(vault, MORPHO, _mp(), IRM_MAINNET, id);
        vm.prank(attacker);
        vm.expectRevert(MorphoUsdcAdapter.NotVault.selector);
        adapter.supply(1);
        vm.prank(attacker);
        vm.expectRevert(MorphoUsdcAdapter.NotVault.selector);
        adapter.withdraw(1);
    }
}
