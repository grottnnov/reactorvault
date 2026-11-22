// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPoolAdapter} from "../src/IPoolAdapter.sol";
import {MorphoPoolAdapter} from "../src/adapters/MorphoPoolAdapter.sol";
import {IMorpho} from "../src/adapters/MorphoPoolAdapter.sol";

/// @dev ERC-165: pool plugins announce their interface — the safe can
///      verify a candidate before whitelisting it. The Morpho adapter
///      deploys without external calls (dummy addresses are fine); the
///      Aave adapter's constructor reads the live pool, so its ERC-165
///      check lives in the fork suite.
contract PoolAdapter165Test is Test {
    function test_MorphoAdapterSupportsInterface() public {
        IMorpho.MarketParams memory mp = IMorpho.MarketParams({
            loanToken: address(1), collateralToken: address(0), oracle: address(0), irm: address(2), lltv: 0.915e18
        });
        MorphoPoolAdapter m = new MorphoPoolAdapter(address(1), address(2), mp, address(3));
        assertTrue(m.supportsInterface(type(IPoolAdapter).interfaceId), "IPoolAdapter");
        assertTrue(m.supportsInterface(0x01ffc9a7), "ERC-165 itself");
        assertFalse(m.supportsInterface(0xffffffff), "no wildcard");
        assertFalse(m.supportsInterface(bytes4(0xdeadbeef)), "unknown id");
    }
}
