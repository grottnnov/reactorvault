// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IMorphoUsdc} from "../../src/adapters/MorphoUsdcAdapter.sol";

interface IERC20Raw {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Isolating the withdraw panic: a raw EOA against the real
///      Morpho — without our adapter. If it fails here too, the
///      problem is the market/fork; if not, it is in the adapter.
contract MorphoRawProbeTest is Test {
    string rpc = vm.envOr("MAINNET_RPC", string(""));

    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV = 0.915e18;

    address eoa = makeAddr("eoa");

    function _mp() internal pure returns (IMorphoUsdc.MarketParams memory) {
        return IMorphoUsdc.MarketParams({loanToken: USDC, collateralToken: WETH, oracle: ORACLE, irm: IRM, lltv: LLTV});
    }

    function setUp() public {
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
    }

    /// Live lesson 17.11, pinned by this probe: a full withdrawal "by
    /// assets" panics (Morpho rounds shares up: it needs S+1 vs S);
    /// a full exit is possible only "by shares".
    function testRawFullExitBySharesNotAssets() public {
        bytes32 id = keccak256(abi.encode(_mp()));
        deal(USDC, eoa, 200e6, true);
        vm.startPrank(eoa);
        IERC20Raw(USDC).approve(MORPHO, 100e6);
        IMorphoUsdc(MORPHO).supply(_mp(), 100e6, 0, eoa, "");
        uint256 shares = IMorphoUsdc(MORPHO).position(id, eoa).supplyShares;
        assertGt(shares, 0, "supplied");

        vm.expectRevert(); // panic 0x11: a by-assets exit cannot be complete
        IMorphoUsdc(MORPHO).withdraw(_mp(), 100e6, 0, eoa, eoa);

        (uint256 out,) = IMorphoUsdc(MORPHO).withdraw(_mp(), 0, shares, eoa, eoa);
        assertApproxEqAbs(out, 100e6, 1000, "full exit by shares works");
        vm.stopPrank();
    }
}
