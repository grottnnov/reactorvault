// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {VaultCore} from "../src/VaultCore.sol";
import {Executor} from "../src/Executor.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev The Sepolia half of the stand (ADR-v2): the ETH safe + the
///      executor. Env: RULES_ENGINE_ADDRESS, CALLBACK_PROXY_ADDRESS,
///      GAS_PAYER_ADDRESS (all Lasna addresses).
contract Deploy is Script {
    function run() external returns (VaultCore vault, Executor executor) {
        address rulesEngine_ = vm.envAddress("RULES_ENGINE_ADDRESS");
        address callbackProxy_ = vm.envAddress("CALLBACK_PROXY_ADDRESS");
        address gasPayer_ = vm.envAddress("GAS_PAYER_ADDRESS");
        vm.startBroadcast();
        vault = new VaultCore();
        executor = new Executor(rulesEngine_, IPayable(payable(callbackProxy_)), vault, gasPayer_);
        vm.stopBroadcast();
    }
}
