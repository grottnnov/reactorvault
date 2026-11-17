// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {FuelBuyer, IFuelSource} from "../../src/FuelConverter.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev ADR-PURCHASE-SAFETY B2 fork proof: the v2 buyer (pause hatch)
///      against the REAL Sepolia faucet — the full live purchase path
///      on the new pair, exactly as it will run after the swap.
///      Skips without SEPOLIA_RPC (CI).
contract FuelBuyerForkTest is Test {
    string rpc = vm.envOr("SEPOLIA_RPC", string(""));

    /// The live Sepolia callback proxy — the only allowed deliverer.
    address constant PROXY = 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
    /// The live faucet (INSTRUCTIONS 63-70): request{value}(recipient).
    address constant FAUCET = 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434;

    FuelBuyer buyer;
    address converter = makeAddr("converter");
    address fund = makeAddr("fund");

    function setUp() public {
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        buyer = new FuelBuyer(IPayable(payable(PROXY)), converter, fund);
        vm.prank(buyer.owner());
        buyer.setFaucet(IFuelSource(FAUCET));
        vm.deal(address(buyer), 0.05 ether);
    }

    /// The live path: a proxy-delivered order buys from the REAL
    /// faucet; the pause hatch must not disturb it.
    function testForkLiveFaucetPurchase() public {
        vm.prank(PROXY);
        buyer.buyFuel(converter, 1000);
        assertEq(buyer.buysCount(), 1);
        assertEq(buyer.totalSpentWei(), 0.02 ether);
        assertEq(address(buyer).balance, 0.03 ether, "0.02 went to the faucet");
    }

    /// Runbook stop on the live faucet: pause → revert; unpause → the
    /// same order settles.
    function testForkPauseBlocksLivePurchase() public {
        vm.prank(buyer.owner());
        buyer.pause();

        vm.prank(PROXY);
        vm.expectRevert(FuelBuyer.Paused.selector);
        buyer.buyFuel(converter, 1000);
        assertEq(buyer.buysCount(), 0);

        vm.prank(buyer.owner());
        buyer.unpause();
        vm.prank(PROXY);
        buyer.buyFuel(converter, 1001);
        assertEq(buyer.buysCount(), 1);
    }
}
