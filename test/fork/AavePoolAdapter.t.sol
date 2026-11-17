// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AavePoolAdapter} from "../../src/adapters/AavePoolAdapter.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
}

/// @dev Fork test against live Eth Sepolia: the REAL Aave v3 pool, the
///      REAL WETH reserve. Skips without SEPOLIA_RPC (CI). The symbol
///      check is the live cross-check canon (the USDC-was-LINK lesson,
///      09.11): never trust an address without asking the chain.
contract AavePoolAdapterForkTest is Test {
    string rpc = vm.envOr("SEPOLIA_RPC", string(""));

    address constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;

    AavePoolAdapter adapter;
    address safe = makeAddr("safe");

    function setUp() public {
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        assertEq(IERC20Meta(WETH).symbol(), "WETH", "live check: the reserve must be WETH");
        adapter = new AavePoolAdapter(safe, AAVE_POOL, WETH);
        // A deterministic CREATE address can collide with a funded
        // account on a live fork — zero the inherited balance so the
        // settlement asserts measure only our flows.
        vm.deal(address(adapter), 0);
    }

    /// Full cycle through the real pool: exact settlement both ways.
    function testForkSupplyWithdrawCycle() public {
        vm.deal(safe, 0.01 ether);

        vm.prank(safe);
        adapter.supply{value: 0.01 ether}();
        assertEq(adapter.totalSupplied(), 0.01 ether, "principal");
        assertGe(adapter.truePosition(), 0.01 ether, "aToken position");

        uint256 safeBefore = safe.balance;
        vm.prank(safe);
        adapter.withdraw(0.01 ether);
        assertEq(safe.balance - safeBefore, 0.01 ether, "exact ETH back to the caller");
        assertEq(adapter.totalSupplied(), 0);
        assertEq(address(adapter).balance, 0, "adapter holds nothing");
    }

    /// Partial recall settles exactly as well.
    function testForkPartialRecall() public {
        vm.deal(safe, 0.02 ether);
        vm.startPrank(safe);
        adapter.supply{value: 0.02 ether}();
        uint256 before = safe.balance;
        adapter.withdraw(0.005 ether);
        vm.stopPrank();

        assertEq(safe.balance - before, 0.005 ether);
        assertEq(adapter.totalSupplied(), 0.015 ether);
    }

    /// The rate view decodes sanely (WAD scale, bounded). Note: on the
    /// testnet the WETH liquidity rate is genuinely ZERO at times (no
    /// borrowers) — that is exactly why the demo pairs Aave with the
    /// operator-levered second pool.
    function testForkRateView() public view {
        uint256 rate = adapter.supplyRatePerYear();
        assertGe(rate, 0);
        assertLe(rate, 100e18, "sanity bound");
    }

    /// Incident #19 (red first): a stranger must not be able to settle
    /// the adapter's position to themselves — withdraw is vault-only
    /// (the Uniswap v4 onlyPoolManager / Yearn onlyVault pattern).
    function testForkWithdrawOnlyVault() public {
        vm.deal(safe, 0.01 ether);
        vm.prank(safe);
        adapter.supply{value: 0.01 ether}();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(AavePoolAdapter.NotVault.selector);
        adapter.withdraw(0.01 ether);
    }

    /// Incident #19: foreign supply pollutes the settlement basis
    /// (principal) — supply is vault-only too.
    function testForkSupplyOnlyVault() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 0.01 ether);
        vm.prank(attacker);
        vm.expectRevert(AavePoolAdapter.NotVault.selector);
        adapter.supply{value: 0.01 ether}();
    }
}
