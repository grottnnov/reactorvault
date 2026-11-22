// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {CallbackProbe} from "../test/probe/CallbackProbe.sol";
import {CallbackProbeReceiver} from "../test/probe/CallbackProbeReceiver.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

contract CallbackProbeTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;

    uint256 constant CRON_TOPIC = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    uint256 constant RESUB_TOPIC = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;

    OmniMockSystem sys;
    CallbackProbe probe;
    address receiver = makeAddr("receiver");
    address stranger = makeAddr("stranger");

    function setUp() public {
        OmniMockSystem impl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);
        sys = OmniMockSystem(payable(OMNI_SYSTEM));

        probe = new CallbackProbe(CRON_TOPIC, RESUB_TOPIC);
    }

    function _log(uint256 topic0_, uint256 blockNumber_) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 5318007,
            contractAddress: address(0x0000000000000000000000000000000000fffFfF),
            topic0: topic0_,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: blockNumber_,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _react(uint256 topic0_, uint256 blockNumber_) internal {
        vm.prank(OMNI_SYSTEM);
        probe.react(_log(topic0_, blockNumber_));
    }

    function testInitSubscribes() public {
        probe.init();
        assertEq(sys.subscriptionCount(), 1);
        (uint256 chainId, address emitter, uint256 topic0,,,, address subscriber) = sys.subscriptions(0);
        assertEq(chainId, 5318007);
        assertEq(emitter, address(0x0000000000000000000000000000000000fffFfF));
        assertEq(topic0, CRON_TOPIC);
        assertEq(subscriber, address(probe));
    }

    function testInitOnlyOnce() public {
        probe.init();
        vm.expectRevert(CallbackProbe.AlreadySubscribed.selector);
        probe.init();
    }

    function testReactOnlyFromSystem() public {
        probe.init();
        vm.prank(stranger);
        vm.expectRevert();
        probe.react(_log(CRON_TOPIC, 100));
        assertEq(probe.pingCount(), 0);
    }

    function testReactWithoutReceiverRevertsLoudly() public {
        probe.init();
        vm.prank(OMNI_SYSTEM);
        vm.expectRevert(CallbackProbe.ReceiverNotSet.selector);
        probe.react(_log(CRON_TOPIC, 100));
    }

    function testReactRequestsCallback() public {
        probe.init();
        probe.setReceiver(receiver);
        _react(CRON_TOPIC, 100);

        assertEq(probe.pingCount(), 1);
        assertEq(probe.callbacksRequested(), 1);
        assertEq(sys.callbackCount(), 1);

        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload, address requester) =
            sys.callbackRequests(0);
        assertEq(chainId, 11155111);
        assertEq(recipient, receiver);
        assertEq(gasLimit, 900_000);
        assertEq(requester, address(probe));
        assertEq(payload, abi.encodeWithSignature("onProbe(address,uint256)", address(0), uint256(1)));
    }

    function testReactForeignTopicIgnored() public {
        probe.init();
        probe.setReceiver(receiver);
        _react(uint256(keccak256("SomeOtherEvent()")), 100);
        assertEq(probe.pingCount(), 0);
        assertEq(sys.callbackCount(), 0);
    }

    /// Live check #1: react() unsubscribes itself from phase 1 and
    /// subscribes to the new topic (the RESUBSCRIBE_AT-th tick, no
    /// callback in that tick).
    function testResubscribeFromReact() public {
        probe.init();
        probe.setReceiver(receiver);
        for (uint256 i = 0; i < probe.RESUBSCRIBE_AT() - 1; i++) {
            _react(CRON_TOPIC, 100 + i);
        }
        assertEq(probe.callbacksRequested(), probe.RESUBSCRIBE_AT() - 1);
        assertEq(sys.subscriptionCount(), 1);

        _react(CRON_TOPIC, 999);
        assertEq(probe.pingCount(), probe.RESUBSCRIBE_AT());
        assertTrue(probe.resubscribed());
        assertEq(probe.callbacksRequested(), probe.RESUBSCRIBE_AT() - 1);
        assertEq(sys.callbackCount(), probe.RESUBSCRIBE_AT() - 1);

        assertEq(sys.subscriptionCount(), 1);
        (uint256 chainId, address emitter, uint256 topic0,,,, address subscriber) = sys.subscriptions(0);
        assertEq(chainId, 5318007);
        assertEq(emitter, address(0x0000000000000000000000000000000000fffFfF));
        assertEq(topic0, RESUB_TOPIC);
        assertEq(subscriber, address(probe));
    }

    /// Phase 2: callbacks carry ping=pings2; after MAX_PINGS2 — the
    /// final unsubscribe from react(), no subscriptions left.
    function testPhase2CallbacksAndFinalUnsubscribe() public {
        probe.init();
        probe.setReceiver(receiver);
        for (uint256 i = 0; i < probe.RESUBSCRIBE_AT(); i++) {
            _react(CRON_TOPIC, 100 + i);
        }
        assertTrue(probe.resubscribed());

        for (uint256 i = 0; i < probe.MAX_PINGS2() - 1; i++) {
            _react(RESUB_TOPIC, 200 + i);
        }
        uint256 callbacksBefore = sys.callbackCount();
        assertEq(probe.pings2(), probe.MAX_PINGS2() - 1);
        assertEq(callbacksBefore, (probe.RESUBSCRIBE_AT() - 1) + (probe.MAX_PINGS2() - 1));
        assertEq(sys.subscriptionCount(), 1);

        _react(RESUB_TOPIC, 999);
        assertEq(probe.pings2(), probe.MAX_PINGS2());
        assertEq(sys.callbackCount(), callbacksBefore);
        assertEq(sys.subscriptionCount(), 0);
    }

    /// A phase-1 tick after the resubscribe is ignored (unsubscribed —
    /// and the react() guard must also cut a repeated/duplicate log of
    /// the old topic).
    function testPhase1TopicIgnoredAfterResub() public {
        probe.init();
        probe.setReceiver(receiver);
        for (uint256 i = 0; i < probe.RESUBSCRIBE_AT(); i++) {
            _react(CRON_TOPIC, 100 + i);
        }
        uint256 pings = probe.pingCount();

        _react(CRON_TOPIC, 300);
        assertEq(probe.pingCount(), pings);
        assertEq(sys.callbackCount(), probe.RESUBSCRIBE_AT() - 1);
        assertEq(sys.subscriptionCount(), 1);
    }
}

contract CallbackProbeReceiverTest is Test {
    CallbackProbeReceiver rcv;
    address probe = makeAddr("probe");
    address proxy = makeAddr("proxy");

    function setUp() public {
        rcv = new CallbackProbeReceiver(IPayable(payable(proxy)), probe);
    }

    function testCallbackViaProxyAccepted() public {
        vm.prank(proxy);
        rcv.onProbe(probe, 7);
        assertEq(rcv.callbacksReceived(), 1);
        assertEq(rcv.lastPingCount(), 7);
        assertEq(rcv.lastObservedSender(), probe);
    }

    function testDirectCallBlocked() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, makeAddr("attacker"), proxy));
        rcv.onProbe(probe, 7);
    }

    function testWrongSenderSlotBlocked() public {
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBEEF), probe));
        rcv.onProbe(address(0xBEEF), 7);
    }
}
