// SPDX-License-License: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AaveUsdcAdapter} from "../../src/adapters/AaveUsdcAdapter.sol";
import {MorphoUsdcAdapter, IMorphoUsdc} from "../../src/adapters/MorphoUsdcAdapter.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Мейн-форк доказательства USDC-адаптеров ДО деплоя (канон
///      «слабейшее место — деньги-логика без живой обкатки»): НАСТОЯЩИЙ
///      Aave v3 Pool Ethereum, НАСТОЯЩИЙ Morpho Blue с реальным рынком
///      USDC/WETH 91.5%. Скипается без MAINNET_RPC.
///      Адреса mainnet (ethereum-lists + доки Aave/Morpho, сверяются
///      живьём symbol()/market() ниже — канон live-check).
contract UsdcAdaptersForkTest is Test {
    string rpc = vm.envOr("MAINNET_RPC", string(""));

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// Chainlink USDC/ETH (дока Morpho: рынок USDC/WETH LLTV 91.5%).
    address constant ORACLE_USDC_ETH = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    /// AdaptiveCurveIRM mainnet (не путать с Sepolia-адресом!).
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

        // live-check канона: адрес без вопроса цепи — не адрес
        assertEq(IERC20Meta(USDC).symbol(), "USDC", "live check: USDC");
        assertEq(IERC20Meta(WETH).symbol(), "WETH", "live check: WETH");
    }

    /// Рынок USDC/WETH 91.5% существует на синглтоне и живой.
    function testForkMorphoUsdcMarketExists() public view {
        bytes32 id = keccak256(abi.encode(_mp()));
        IMorphoUsdc.Market memory m = IMorphoUsdc(MORPHO).market(id);
        assertGt(m.lastUpdate, 0, "USDC/WETH 86% market must exist on mainnet");
    }

    /// Полный цикл Aave: сейф пушит 100 USDC → адаптер кладёт →
    /// withdraw возвращает ровно столько же сейфу.
    function testForkAaveUsdcCycle() public {
        AaveUsdcAdapter adapter = new AaveUsdcAdapter(vault, AAVE_POOL, USDC);
        uint256 amount = 100e6; // 100 USDC

        deal(USDC, vault, amount, true);
        // push: сейф переводит адаптеру (мокируем поведение сейфа)
        vm.prank(vault);
        (bool ok,) = USDC.call(abi.encodeWithSignature("transfer(address,uint256)", address(adapter), amount));
        require(ok, "push failed");

        vm.prank(vault);
        adapter.supply(amount);
        assertEq(adapter.totalSupplied(), amount);
        assertGt(adapter.supplyRatePerYear(), 0, "mainnet USDC rate > 0");

        vm.prank(vault);
        adapter.withdraw(amount);
        // индексное округление: остаток ≤ пылевого допуска сейфа (0.01 USDC)
        assertLe(adapter.totalSupplied(), 10_000, "dust only remains");
        uint256 back = IERC20Meta(USDC).balanceOf(vault);
        assertLe(amount - back, 10_000, "settled back within dust");
    }

    /// Гвард #19: чужак не может ни положить, ни забрать.
    function testForkAaveUsdcOnlyVault() public {
        AaveUsdcAdapter adapter = new AaveUsdcAdapter(vault, AAVE_POOL, USDC);
        vm.prank(attacker);
        vm.expectRevert(AaveUsdcAdapter.NotVault.selector);
        adapter.supply(1);
        vm.prank(attacker);
        vm.expectRevert(AaveUsdcAdapter.NotVault.selector);
        adapter.withdraw(1);
    }

    /// Полный цикл Morpho (настоящий рынок): пуш → supply → withdraw →
    /// точный расчёт. NOTE: при высокой утилизации выход ликвидность-
    /// ограничен — на живом рынке USDC/WETH 100 USDC выходят свободно.
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
        assertGe(adapter.supplyRatePerYear(), 0); // вид читается; >0 при займах
    }

    /// Гвард #19 для Morpho.
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
