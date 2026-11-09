// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/**
 * @title OmniMockSystem
 * @notice A mock of the omni system contract (SYSTEM = 0x8888) for
 *         v6-style tests. The official MockSystemContract
 *         (reactive-test-lib submodule — do not touch) does not know
 *         requestCallbackV_1_0/depositTo. Here: subscriptions + callback
 *         configs (recorded for asserts) + debt/debts/reserves stubs.
 * @dev Usage (strategy A + the 0x8888 adaptation, WatcherSkeleton.t
 *      pattern): vm.etch(0x8888.., address(omniMock).code) in setUp.
 */
contract OmniMockSystem {
    struct Subscription {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        address subscriber;
    }

    struct CallbackRequest {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
        address requester;
    }

    Subscription[] public subscriptions;
    CallbackRequest[] public callbackRequests;

    /// @notice A controllable per-address "debt" for floor/fallback
    ///         tests (0 by default).
    mapping(address => uint256) public debts;
    mapping(address => uint256) public reserves;

    // ---- ISubscriptionService ----

    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external {
        subscriptions.push(
            Subscription({
                chainId: chain_id,
                contractAddr: _contract,
                topic0: topic_0,
                topic1: topic_1,
                topic2: topic_2,
                topic3: topic_3,
                subscriber: msg.sender
            })
        );
    }

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external {
        uint256 len = subscriptions.length;
        for (uint256 i = 0; i < len; i++) {
            Subscription storage sub = subscriptions[i];
            if (
                sub.subscriber == msg.sender && sub.chainId == chain_id && sub.contractAddr == _contract
                    && sub.topic0 == topic_0 && sub.topic1 == topic_1 && sub.topic2 == topic_2 && sub.topic3 == topic_3
            ) {
                subscriptions[i] = subscriptions[len - 1];
                subscriptions.pop();
                return;
            }
        }
        revert("OmniMockSystem: subscription not found");
    }

    // ---- ISystemContract: callbacks ----

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external pure {
        revert("OmniMockSystem: versioned requestCallback not used by v6");
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests.push(
            CallbackRequest({
                chainId: config_.chainId,
                recipient: config_.recipient,
                gasLimit: config_.gasLimit,
                payload: config_.payload,
                requester: msg.sender
            })
        );
    }

    // ---- IPayable stubs ----

    function debt(address who_) external view returns (uint256) {
        return debts[who_];
    }

    function depositTo(address who_) external payable {
        reserves[who_] += msg.value;
    }

    receive() external payable {}

    // ---- Query helpers ----

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbackRequests.length;
    }

    function setDebt(address who_, uint256 amount_) external {
        debts[who_] = amount_;
    }
}
