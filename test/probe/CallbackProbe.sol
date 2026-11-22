// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

contract CallbackProbe is AbstractReactive {
    uint256 public constant ORIGIN_CHAIN_ID = 5318007;
    uint256 public constant DEST_CHAIN_ID = 11155111;
    uint64 public constant CALLBACK_GAS_LIMIT = 900_000;
    /// @notice Phase-1 tick at which react() unsubscribes itself and
    ///         subscribes to resubTopic — live check #1 (the GasPayer
    ///         gate): subscribing from inside react().
    uint256 public constant RESUBSCRIBE_AT = 4;
    /// @notice Phase-2 ticks before the final unsubscribe (the stand
    ///         must not burn gas forever).
    uint256 public constant MAX_PINGS2 = 3;

    address public constant SYSTEM_EVENTS_EMITTER = address(0x0000000000000000000000000000000000fffFfF);

    uint256 public immutable cronTopic;
    uint256 public immutable resubTopic;

    address public owner;
    address public receiver;
    bool public subscribed;
    bool public resubscribed;

    uint256 public pingCount;
    uint256 public pings2;
    uint256 public callbacksRequested;

    event ProbeReact(uint256 indexed blockNumber, uint256 indexed pingCount);
    event ProbeReact2(uint256 indexed blockNumber, uint256 indexed pings2);
    event ReceiverSet(address receiver);
    event Subscribed(uint256 topic);
    event ResubscribedFromReact(uint256 indexed oldTopic, uint256 indexed newTopic);
    event ProbeFinished(uint256 pings1, uint256 pings2Total);

    error NotOwner();
    error ZeroAddress();
    error AlreadySubscribed();
    error ReceiverNotSet();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 cronTopic_, uint256 resubTopic_) {
        owner = msg.sender;
        cronTopic = cronTopic_;
        resubTopic = resubTopic_;
    }

    function init() external onlyOwner {
        if (subscribed) revert AlreadySubscribed();
        subscribed = true;
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, SYSTEM_EVENTS_EMITTER, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit Subscribed(cronTopic);
    }

    function setReceiver(address receiver_) external onlyOwner {
        if (receiver_ == address(0)) revert ZeroAddress();
        receiver = receiver_;
        emit ReceiverSet(receiver_);
    }

    function react(LogRecord calldata log_) external override onlySystem {
        if (log_.topic0 == cronTopic && !resubscribed) {
            pingCount += 1;
            emit ProbeReact(log_.blockNumber, pingCount);
            if (pingCount >= RESUBSCRIBE_AT) {
                // Live check #1: both unsubscribe AND subscribe from
                // inside react(). A revert of the whole tx on denial
                // would leave the state consistent.
                SYSTEM.unsubscribe(
                    ORIGIN_CHAIN_ID, SYSTEM_EVENTS_EMITTER, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
                SYSTEM.subscribe(
                    ORIGIN_CHAIN_ID,
                    SYSTEM_EVENTS_EMITTER,
                    resubTopic,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                resubscribed = true;
                emit ResubscribedFromReact(cronTopic, resubTopic);
                return;
            }
            if (receiver == address(0)) revert ReceiverNotSet();
            callbacksRequested += 1;
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: DEST_CHAIN_ID,
                    recipient: receiver,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: abi.encodeWithSignature("onProbe(address,uint256)", address(0), pingCount)
                })
            );
            return;
        }
        if (log_.topic0 == resubTopic && resubscribed) {
            pings2 += 1;
            emit ProbeReact2(log_.blockNumber, pings2);
            if (pings2 >= MAX_PINGS2) {
                SYSTEM.unsubscribe(
                    ORIGIN_CHAIN_ID,
                    SYSTEM_EVENTS_EMITTER,
                    resubTopic,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                emit ProbeFinished(pingCount, pings2);
                return;
            }
            if (receiver == address(0)) revert ReceiverNotSet();
            callbacksRequested += 1;
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: DEST_CHAIN_ID,
                    recipient: receiver,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: abi.encodeWithSignature("onProbe(address,uint256)", address(0), pings2)
                })
            );
            return;
        }
    }
}
