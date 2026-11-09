// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {RulesEngine} from "../src/RulesEngine.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";

contract RulesEngineTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 constant RATE_CHANGE_TOPIC = uint256(
        keccak256(
            "ReserveDataUpdated(uint256 indexed reserve,uint256 liquidityRate,uint256 stableBorrowRate,uint256 variableBorrowRate,uint256 liquidityIndex,uint256 variableBorrowIndex)"
        )
    );
    uint64 constant COOLDOWN = 6 hours;

    OmniMockSystem sys;
    RulesEngine engine;
    address origin = makeAddr("origin");
    address executor = makeAddr("executor");
    address stranger = makeAddr("stranger");

    function setUp() public {
        OmniMockSystem impl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);
        sys = OmniMockSystem(payable(OMNI_SYSTEM));

        engine = new RulesEngine();
        engine.initialize(origin, RATE_CHANGE_TOPIC, executor, COOLDOWN);
        vm.warp(COOLDOWN);
    }

    function _log(uint256 topic0_, uint256 blockNumber_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 11155111,
            contractAddress: origin,
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
        engine.react(_log(topic0_, blockNumber_));
    }

    function testInitializeSubscribesOnce() public view {
        assertEq(sys.subscriptionCount(), 1);
        (
            uint256 sChainId,
            address sContract,
            uint256 sTopic0,
            uint256 sTopic1,
            uint256 sTopic2,
            uint256 sTopic3,
            address sSubscriber
        ) = sys.subscriptions(0);
        assertEq(sChainId, 11155111);
        assertEq(sContract, origin);
        assertEq(sTopic0, RATE_CHANGE_TOPIC);
        assertEq(sTopic1, REACTIVE_IGNORE);
        assertEq(sTopic2, REACTIVE_IGNORE);
        assertEq(sTopic3, REACTIVE_IGNORE);
        assertEq(sSubscriber, address(engine));
    }

    function testInitializeOnlyOnce() public {
        vm.expectRevert(RulesEngine.AlreadyInitialized.selector);
        engine.initialize(origin, RATE_CHANGE_TOPIC, executor, COOLDOWN);
    }

    function testReactOnlyFromSystem() public {
        vm.prank(stranger);
        vm.expectRevert();
        engine.react(_log(RATE_CHANGE_TOPIC, 100));
        assertEq(engine.firedCount(), 0);
        assertEq(sys.callbackCount(), 0);
    }

    function testReactFiresCallback() public {
        vm.expectEmit(true, false, false, true);
        emit RuleFired(RATE_CHANGE_TOPIC, 100);
        _react(RATE_CHANGE_TOPIC, 100);

        assertEq(engine.firedCount(), 1);
        assertEq(sys.callbackCount(), 1);

        (uint256 cChainId, address cRecipient, uint64 cGasLimit, bytes memory cPayload, address cRequester) =
            sys.callbackRequests(0);
        assertEq(cChainId, 11155111);
        assertEq(cRecipient, executor);
        assertEq(cGasLimit, 900_000);
        assertEq(cRequester, address(engine));
        assertEq(cPayload, abi.encodeWithSignature("rebalance(address,uint256)", address(0), uint256(100)));
    }

    function testReactInactiveRuleSkipped() public {
        engine.setRule(RATE_CHANGE_TOPIC, false, COOLDOWN);
        _react(RATE_CHANGE_TOPIC, 100);
        assertEq(engine.firedCount(), 0);
        assertEq(sys.callbackCount(), 0);
    }

    function testReactUnknownTopicSkipped() public {
        _react(uint256(keccak256("UnknownEvent()")), 100);
        assertEq(engine.firedCount(), 0);
        assertEq(sys.callbackCount(), 0);
    }

    function testReactCooldownBlocksSecondFire() public {
        _react(RATE_CHANGE_TOPIC, 100);
        assertEq(engine.firedCount(), 1);

        vm.warp(block.timestamp + COOLDOWN / 2);
        _react(RATE_CHANGE_TOPIC, 200);
        assertEq(engine.firedCount(), 1);
        assertEq(sys.callbackCount(), 1);

        vm.warp(block.timestamp + COOLDOWN);
        _react(RATE_CHANGE_TOPIC, 300);
        assertEq(engine.firedCount(), 2);
        assertEq(sys.callbackCount(), 2);
    }

    /// Idempotency (UF §14): a duplicate event (chain, block, topic) —
    /// one firing, even after the cooldown.
    function testReactDuplicateEventSingleFire() public {
        _react(RATE_CHANGE_TOPIC, 100);
        assertEq(engine.firedCount(), 1);

        // an immediate duplicate of the same block — no second callback
        _react(RATE_CHANGE_TOPIC, 100);
        assertEq(engine.firedCount(), 1);
        assertEq(sys.callbackCount(), 1);

        // a duplicate after the cooldown — still one: the key is the same
        vm.warp(block.timestamp + COOLDOWN * 2);
        _react(RATE_CHANGE_TOPIC, 100);
        assertEq(engine.firedCount(), 1);
        assertEq(sys.callbackCount(), 1);

        // a new block — a new firing
        _react(RATE_CHANGE_TOPIC, 101);
        assertEq(engine.firedCount(), 2);
    }

    event RuleFired(uint256 indexed topic0, uint256 originBlockNumber);
}
