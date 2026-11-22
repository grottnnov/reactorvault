// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/**
 * @title AbstractPausableReactiveOmni
 * @notice A port of the legacy AbstractPausableReactive (reactive-lib) to
 *         the omni library (reactive-lib-omni, SYSTEM = 0x8888) — phase B1,
 *         TODO.md 15.10. The omni library has no pause/resume base
 *         (NATIVE-ARCHITECTURE §3 item 11): subscribe/unsubscribe go through
 *         the SYSTEM endpoint 0x8888.
 * @dev Differences from the legacy base:
 *      - service (variable) → SYSTEM (constant 0x8888);
 *      - rnOnly/detectVm/vm are gone: omni is a SINGLE environment (one copy
 *        of the contract; "RVM is retired", the "Completes" post 07.10) —
 *        there is nothing to split; react() is guarded by onlySystem from
 *        AbstractReactive;
 *      - owner = msg.sender (as in legacy), onlyOwner kept for v6 contracts.
 */
abstract contract AbstractPausableReactiveOmni is AbstractReactive {
    struct Subscription {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
    }

    address internal owner;
    bool internal paused;

    constructor() {
        owner = msg.sender;
    }

    /// @notice The subscription list for pause/resume (implementations return their own criteria).
    function getPausableSubscriptions() internal view virtual returns (Subscription[] memory);

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    /// @notice Pause: unsubscribe from the implementation's criteria (idle cost of a paused layer = 0).
    function pause() external onlyOwner {
        require(!paused, "Already paused");
        Subscription[] memory subscriptions = getPausableSubscriptions();
        for (uint256 ix = 0; ix != subscriptions.length; ++ix) {
            SYSTEM.unsubscribe(
                subscriptions[ix].chain_id,
                subscriptions[ix]._contract,
                subscriptions[ix].topic_0,
                subscriptions[ix].topic_1,
                subscriptions[ix].topic_2,
                subscriptions[ix].topic_3
            );
        }
        paused = true;
    }

    /// @notice Resume: re-subscribe by the same criteria.
    function resume() external onlyOwner {
        require(paused, "Not paused");
        Subscription[] memory subscriptions = getPausableSubscriptions();
        for (uint256 ix = 0; ix != subscriptions.length; ++ix) {
            SYSTEM.subscribe(
                subscriptions[ix].chain_id,
                subscriptions[ix]._contract,
                subscriptions[ix].topic_0,
                subscriptions[ix].topic_1,
                subscriptions[ix].topic_2,
                subscriptions[ix].topic_3
            );
        }
        paused = false;
    }
}
