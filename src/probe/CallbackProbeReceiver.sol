// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

contract CallbackProbeReceiver is AbstractCallback {
    uint256 public callbacksReceived;
    uint256 public lastPingCount;
    uint256 public lastCallbackBlock;
    address public lastObservedSender;

    event ProbeReceived(address indexed sender, uint256 indexed pingCount, uint256 blockNumber);

    constructor(IPayable callbackProxy_, address callbackSender_) AbstractCallback(callbackProxy_, callbackSender_) {}

    function onProbe(address sender_, uint256 pingCount_) external onlyServiceProvider onlyCallbackSender(sender_) {
        callbacksReceived += 1;
        lastPingCount = pingCount_;
        lastCallbackBlock = block.number;
        lastObservedSender = sender_;
        emit ProbeReceived(sender_, pingCount_, block.number);
    }

    function coverDebt() external {
        _coverDebt();
    }
}
