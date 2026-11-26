// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {UniswapV4RhSwapAdapter, IPoolManagerRh} from "../../src/adapters/UniswapV4RhSwapAdapter.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev StateView slice: slot0 and liquidity prove the pinned pool is
///      the live one (extsload-based reads, staticcall-safe).
interface IStateViewRh {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

/// @dev Robinhood Chain (4663) live-fork proof of the v4 swap adapter
///      BEFORE any deploy (canon: "the weakest spot is money logic
///      without a live shakeout"). Everything here runs against the
///      REAL chain state: the real PoolManager singleton, the real
///      TSLA/USDG pool, the real V4Quoter. Skips without RH_RPC.
///
///      Pinned 26.11 from live measurement (every address re-verified
///      by the live checks below; sources in script/rh-pool-discovery.sh
///      and internal/docs/evidence/rh-pools-261126.json):
///      - PoolManager 0x8366a39c…40951: official Uniswap v4 deployments
///        page (chain 4663), 24,009 bytes of live code.
///      - V4Quoter 0x8Dc178eF…98F94, StateView 0xf3334192…673b: same
///        page; both answer live.
///      - TSLA 0x322F0929…3b2d (18d), USDG 0x5fc5360D…d168 (6d): the
///        official Robinhood asset registry snapshot 2026-09-02.
///      - The pool: fee 3000 / tickSpacing 60 / hookless — the deepest
///        hookless pool of the 116 TSLA/USDG pools found (L =
///        154,157,302,983,104,957 → ~$3.01M on the stable side),
///        Initialize at block 2,670,479, tx 0x39d928543db9488767f4…
contract RhV4SwapAdapterForkTest is Test {
    string rpc = vm.envOr("RH_RPC", string(""));

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev The measured pool key: fee 3000, tickSpacing 60, no hook
    ///      (structs cannot be constants — a function is the pin).
    function _key() private pure returns (IPoolManagerRh.PoolKey memory) {
        return IPoolManagerRh.PoolKey({currency0: TSLA, currency1: USDG, fee: 3000, tickSpacing: 60, hooks: address(0)});
    }
    /// @dev keccak256(abi.encode(KEY)) — the on-chain poolId (Initialize
    ///      log, block 2,670,479). Pins the encoding AND the key.
    bytes32 constant POOL_ID = 0x8517f8071ae5b831b738052f12125e8e3d6c158b78728aa44ce3b25e5104d32e;

    UniswapV4RhSwapAdapter adapter;
    address vault = makeAddr("vault"); // plays the guard safe

    function setUp() public {
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        adapter = new UniswapV4RhSwapAdapter(POOL_MANAGER, QUOTER, _key());
    }

    /// The canon live-check: an address without the chain question is
    /// not an address. Decimals are asserted because the pair is
    /// asymmetric (18/6) and every share calculation depends on it.
    function testForkLiveChecks() public view {
        assertEq(IERC20Meta(TSLA).symbol(), "TSLA", "live check: TSLA");
        assertEq(IERC20Meta(USDG).symbol(), "USDG", "live check: USDG");
        assertEq(IERC20Meta(TSLA).decimals(), 18, "TSLA decimals");
        assertEq(IERC20Meta(USDG).decimals(), 6, "USDG decimals");
        assertGt(POOL_MANAGER.code.length, 20_000, "live check: PoolManager code");
        assertGt(QUOTER.code.length, 1_000, "live check: Quoter code");

        assertEq(keccak256(abi.encode(_key())), POOL_ID, "pool key encoding drift");
        (uint160 sqrtP, int24 slotTick, uint24 protocolFee, uint24 lpFee) = IStateViewRh(STATE_VIEW).getSlot0(POOL_ID);
        assertGt(sqrtP, 0, "pool is live");
        assertLt(slotTick, 0, "TSLA/USDG price > 1: tick below zero");
        assertEq(lpFee, 3000, "lp fee pins the pool");
        assertGt(IStateViewRh(STATE_VIEW).getLiquidity(POOL_ID), 1e14, "depth: L > 100 TSLA-scale units");
    }

    /// The quote path (a full CALL: the quoter needs it — staticcall
    /// dies on transient storage). Cross-checked against the pool's own
    /// slot0 price: the quote may only sit BELOW the frictionless
    /// amount (fee + slippage), never above it.
    function testForkQuoteTslaToUsdg() public {
        uint256 amountIn = 1e18; // 1 TSLA
        uint256 quoted = adapter.getAmountOut(TSLA, USDG, amountIn);
        assertGt(quoted, 0, "quote must be positive");

        (uint160 sqrtP, int24 slotTick, uint24 pf, uint24 lf) = IStateViewRh(STATE_VIEW).getSlot0(POOL_ID);
        // frictionless raw amount: amountIn * (sqrtP^2 / 2^192) — the
        // product sqrtP*sqrtP (~2^163) then * amountIn (~2^60) fits 256
        // bits for every sane pool price, no full mulDiv needed
        uint256 ideal = amountIn * sqrtP * sqrtP / (1 << 192);
        // 0.30% fee + rounding: the quote loses at most ~1.5% even on
        // adversarial depth; anything above `ideal` is a broken quote
        assertLe(quoted, ideal, "quote above frictionless: impossible");
        assertGe(quoted, ideal * 985 / 1000, "quote more than 1.5% under frictionless");
    }

    /// THE proof: a real exact-input sell through the live pool — the
    /// money path the guard runs when a drawdown floor breaks.
    function testForkSwapTslaToUsdg() public {
        uint256 amountIn = 1e18; // 1 TSLA
        uint256 quoted = adapter.getAmountOut(TSLA, USDG, amountIn);
        uint256 minOut = quoted * 997 / 1000; // 0.3% slippage bound

        deal(TSLA, vault, amountIn, true);
        vm.startPrank(vault);
        IERC20Meta(TSLA).approve(address(adapter), amountIn);
        uint256 got = adapter.swap(TSLA, USDG, amountIn, minOut);
        vm.stopPrank();

        assertGe(got, minOut, "fill must clear the bound");
        assertEq(IERC20Meta(USDG).balanceOf(vault), got, "stable reached the caller, exactly the fill");
        assertEq(IERC20Meta(TSLA).balanceOf(vault), 0, "asset left the caller, all of it");
        assertEq(IERC20Meta(TSLA).balanceOf(address(adapter)), 0, "adapter holds nothing");
        assertEq(IERC20Meta(USDG).balanceOf(address(adapter)), 0, "adapter holds nothing");
    }

    /// The rebuy direction (guardRebuy): stable back into the stock.
    function testForkSwapUsdgToTsla() public {
        uint256 amountIn = 380e6; // 380 USDG
        uint256 quoted = adapter.getAmountOut(USDG, TSLA, amountIn);
        assertGt(quoted, 9e17, "380 USDG must quote ~1 TSLA");
        uint256 minOut = quoted * 997 / 1000;

        deal(USDG, vault, amountIn, true);
        vm.startPrank(vault);
        IERC20Meta(USDG).approve(address(adapter), amountIn);
        uint256 got = adapter.swap(USDG, TSLA, amountIn, minOut);
        vm.stopPrank();

        assertGe(got, minOut, "fill must clear the bound");
        assertEq(IERC20Meta(TSLA).balanceOf(vault), got, "asset reached the caller, exactly the fill");
        assertEq(IERC20Meta(USDG).balanceOf(vault), 0, "stable left the caller, all of it");
    }

    /// The slippage guard bites: an unreachable bound reverts the whole
    /// unlock (nothing stays half-paid), and the paid revert is the
    /// designed behavior — the executor retries on the next event.
    function testForkSlippageBoundReverts() public {
        uint256 amountIn = 1e18;
        uint256 quoted = adapter.getAmountOut(TSLA, USDG, amountIn);

        deal(TSLA, vault, amountIn, true);
        vm.startPrank(vault);
        IERC20Meta(TSLA).approve(address(adapter), amountIn);
        // expectRevert(selector) demands exact data, but TooLittleOut
        // carries its two args — catch and pin the selector by hand
        try adapter.swap(TSLA, USDG, amountIn, quoted + 1) {
            fail("an unreachable minOut must revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), bytes4(UniswapV4RhSwapAdapter.TooLittleOut.selector), "must be TooLittleOut");
        }
        vm.stopPrank();

        // the failed swap left no trace: balances and allowance intact
        assertEq(IERC20Meta(TSLA).balanceOf(vault), amountIn, "revert unwound the pull");
        assertEq(IERC20Meta(USDG).balanceOf(vault), 0, "no output leaked");
    }
}
