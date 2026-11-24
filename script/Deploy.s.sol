// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {AssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";
import {Executor, IExecutorVault} from "../src/Executor.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev The Sepolia half of the stand (ADR-GAS-ARCHITECTURE): the asset
///      safe + the fund + the executor (pay-on-delivery: no cashier in
///      the family). Env: RULES_ENGINE_ADDRESS, CALLBACK_PROXY_ADDRESS
///      (Lasna addresses).
contract Deploy is Script {
    function run() external returns (AssetVault vault, GasVault battery, Executor executor) {
        address rulesEngine_ = vm.envAddress("RULES_ENGINE_ADDRESS");
        address callbackProxy_ = vm.envAddress("CALLBACK_PROXY_ADDRESS");
        vm.startBroadcast();
        vault = new AssetVault();
        battery = new GasVault();
        executor =
            new Executor(rulesEngine_, IPayable(payable(callbackProxy_)), IExecutorVault(address(vault)), battery);
        vm.stopBroadcast();
    }
}
