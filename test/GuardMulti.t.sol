// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {RulesEngine} from "../src/RulesEngine.sol";
import {GuardItem} from "../src/IGuardVault.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";

/// @dev Multi-client guard, red-first (D-2611-3: per-client vaults +
///      batch fan-out + reactive self-service onboarding).
///      The contract under test:
///      - guard rules are per (feed, vault): each client keeps its OWN
///        anchor (max of entry and high-water mark SINCE ARMING), its
///        own rung and cooldown; feed freshness and pause stay
///        feed-level (they are properties of the feed, not the client);
///      - one price event fires ONE callback carrying a BATCH of the
///        triggered clients (REACT burn independent of client count);
///      - the batch payload keeps the sender as the FIRST 32-byte slot
///        (the network's first-payload-slot substitution — the W2.2
///        canon — must survive the format change);
///      - the factory's GuardSafeCreated event arms the client rule by
///        itself (reactive onboarding, no operator in the loop);
///        re-arming the same vault re-sets the rule, never duplicates;
///      - a feed with no clients is silent.
contract GuardMultiTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;

    uint256 constant SOURCE_CHAIN = 11155111;
    uint256 constant GUARD_CHAIN = 4663; // Robinhood Chain
    uint256 constant DEST_CHAIN = 11155111;

    uint256 constant RATE_CHANGE_TOPIC = uint256(
        keccak256(
            "ReserveDataUpdated(uint256 indexed reserve,uint256 liquidityRate,uint256 stableBorrowRate,uint256 variableBorrowRate,uint256 liquidityIndex,uint256 variableBorrowIndex)"
        )
    );
    uint256 constant ANSWER_UPDATED = 0x0559884fd3a460db3073b7fc96cc77986f16e378210ded43186175bf646fc5f;
    /// GuardSafeCreated(client indexed, vault indexed, asset indexed,
    /// feed, level, entryRef, warnBps, midBps, hardBps, targetBps,
    /// bandBps, cooldown, maxStaleSec)
    uint256 constant GUARD_SAFE_CREATED = uint256(
        keccak256(
            "GuardSafeCreated(address,address,address,address,uint8,uint256,uint64,uint64,uint64,uint64,uint64,uint64,uint64)"
        )
    );

    // guard fixtures (numbers are test fixtures; live calibration at deploy)
    uint256 constant ENTRY = 100e8;
    uint64 constant WARN = 500; // 5%
    uint64 constant MID = 1000; // 10%
    uint64 constant HARD = 2000; // 20%
    uint64 constant TARGET = 5000; // 50% share
    uint64 constant BAND = 1000; // ±10%
    uint64 constant MAX_STALE = 900;
    uint64 constant GUARD_COOLDOWN = 1 hours;

    OmniMockSystem sys;
    RulesEngine engine;
    address origin = makeAddr("origin");
    address executor = makeAddr("executor");
    address feed = makeAddr("tslaFeed");
    address asset = makeAddr("tsla");
    address factory = makeAddr("factory");
    address vaultA = makeAddr("vaultA");
    address vaultB = makeAddr("vaultB");
    address vaultC = makeAddr("vaultC");
    uint256 blockN = 1000;

    function setUp() public {
        OmniMockSystem impl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);
        sys = OmniMockSystem(payable(OMNI_SYSTEM));

        engine = new RulesEngine();
        engine.initialize(origin, SOURCE_CHAIN, RATE_CHANGE_TOPIC, executor, DEST_CHAIN, 1 hours);
        engine.setExecutor(GUARD_CHAIN, executor);
        // the generic alarm rule stays OFF here: count-based assertions
        // must see guard callbacks only
        engine.setRule(SOURCE_CHAIN, RATE_CHANGE_TOPIC, false, 1 hours, DEST_CHAIN);
        vm.warp(4 hours);
    }

    // ------------------------------------------------------------ helpers

    function _policy(address vault_, uint256 entryRef_, uint64 cooldown_)
        internal
        view
        returns (RulesEngine.GuardPolicy memory p)
    {
        p.chainId = GUARD_CHAIN;
        p.feed = feed;
        p.asset = asset;
        p.vault = vault_;
        p.destChainId = GUARD_CHAIN;
        p.entryRef = entryRef_;
        p.warnBps = WARN;
        p.midBps = MID;
        p.hardBps = HARD;
        p.targetBps = TARGET;
        p.bandBps = BAND;
        p.maxStaleSec = MAX_STALE;
        p.cooldown = cooldown_;
    }

    function _feedLog(uint256 price, uint256 blockNumber) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: GUARD_CHAIN,
            contractAddress: feed,
            topic0: ANSWER_UPDATED,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(int256(price), uint256(1), uint256(block.timestamp)),
            blockNumber: blockNumber,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _reactFeed(uint256 price, uint256 blockNumber) internal {
        vm.prank(OMNI_SYSTEM);
        engine.react(_feedLog(price, blockNumber));
    }

    function _onboard(address client, address vault, uint256 entryRef, uint256 blockNumber) internal {
        vm.prank(OMNI_SYSTEM);
        engine.react(
            IReactive.LogRecord({
                chainId: GUARD_CHAIN,
                contractAddress: factory,
                topic0: GUARD_SAFE_CREATED,
                topic1: uint256(uint160(client)),
                topic2: uint256(uint160(vault)),
                topic3: uint256(uint160(asset)),
                data: abi.encode(feed, uint8(1), entryRef, WARN, MID, HARD, TARGET, BAND, GUARD_COOLDOWN, MAX_STALE),
                blockNumber: blockNumber,
                opCode: 0,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
    }

    function _reactCron(uint256 blockNumber) internal {
        vm.prank(OMNI_SYSTEM);
        engine.react(
            IReactive.LogRecord({
                chainId: SOURCE_CHAIN,
                contractAddress: origin,
                topic0: RATE_CHANGE_TOPIC,
                topic1: 0,
                topic2: 0,
                topic3: 0,
                data: "",
                blockNumber: blockNumber,
                opCode: 0,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
    }

    /// @dev The expected FLAT batch: the sender placeholder is the
    ///      first encoded word (the network substitution slot).
    function _expectedPayload(address feed_, address asset_, uint256 originBlock, GuardItem[] memory items)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "guardAction(address,address,address,uint256,(address,uint8,uint256,uint256,uint256)[])",
            address(0),
            feed_,
            asset_,
            originBlock,
            items
        );
    }

    function _hasRequest(bytes memory payload) internal view returns (bool) {
        uint256 n = sys.callbackCount();
        for (uint256 i = 0; i < n; i++) {
            (,, uint64 gasLimit, bytes memory p, address requester) = sys.callbackRequests(i);
            if (
                keccak256(p) == keccak256(payload) && gasLimit == engine.CALLBACK_GAS_LIMIT()
                    && requester == address(engine)
            ) {
                return true;
            }
        }
        return false;
    }

    function _lastPayload() internal view returns (bytes memory) {
        (,,, bytes memory p,) = sys.callbackRequests(sys.callbackCount() - 1);
        return p;
    }

    function _item(address vault, uint8 kind, uint256 param, uint256 param2, uint256 bound)
        internal
        pure
        returns (GuardItem memory)
    {
        return GuardItem({vault: vault, kind: kind, param: param, param2: param2, bound: bound});
    }

    // ------------------------------------------------------------- tests

    /// Two clients on one feed, one hard-rung event: exactly ONE
    /// callback, the batch carries BOTH, each with its own vault.
    function test_TwoClientsOneEvent_SingleBatchedCallback() public {
        engine.setGuardRule(_policy(vaultA, ENTRY, GUARD_COOLDOWN));
        engine.setGuardRule(_policy(vaultB, ENTRY, GUARD_COOLDOWN));
        uint256 before = sys.callbackCount();

        _reactFeed(80e8, blockN); // -20% from the anchor: hard rung

        assertEq(sys.callbackCount(), before + 1, "one event -> one callback, whatever the client count");
        GuardItem[] memory items = new GuardItem[](2);
        items[0] = _item(vaultA, 2, 10_000, 0, 80e8);
        items[1] = _item(vaultB, 2, 10_000, 0, 80e8);
        assertTrue(
            _hasRequest(_expectedPayload(feed, asset, blockN, items)), "the batch carries both clients, hard-exit each"
        );
    }

    /// The batch payload keeps the sender as the FIRST 32-byte slot —
    /// the delivery network substitutes exactly that word.
    function test_BatchPayloadFirstSlotIsTheSender() public {
        engine.setGuardRule(_policy(vaultA, ENTRY, GUARD_COOLDOWN));
        _reactFeed(80e8, blockN);
        (,,, bytes memory payload,) = sys.callbackRequests(sys.callbackCount() - 1);
        assertGe(payload.length, 36, "payload has a head");
        bytes32 firstSlot;
        assembly {
            firstSlot := mload(add(payload, 0x24))
        }
        assertEq(firstSlot, bytes32(0), "first arg slot must be the sender word (zero placeholder)");
    }

    /// Per-client history: A rode the spike to 150; B armed AFTER it.
    /// The same 110 price is a hard rung for A (anchor 150) and a
    /// no-op for B (anchor 100) — the batch carries A alone.
    function test_PerClientAnchors() public {
        engine.setGuardRule(_policy(vaultA, ENTRY, GUARD_COOLDOWN));
        _reactFeed(150e8, blockN); // A's HWM rides to 150
        engine.setGuardRule(_policy(vaultB, ENTRY, GUARD_COOLDOWN)); // B arms fresh AFTER the spike

        _reactFeed(110e8, blockN + 1);

        GuardItem[] memory items = new GuardItem[](1);
        items[0] = _item(vaultA, 2, 10_000, 0, 120e8); // A: anchor 150 -> bound 150*0.8
        assertTrue(
            _hasRequest(_expectedPayload(feed, asset, blockN + 1, items)),
            "only A fired (B armed after the spike: no rung)"
        );
    }

    /// Reactive onboarding: the factory event arms the client rule by
    /// itself; the next price event serves the new client with the
    /// policy numbers carried by the event.
    function test_ReactiveOnboardingArmsClient() public {
        engine.setGuardFactory(GUARD_CHAIN, factory);
        uint256 before = sys.callbackCount();

        _onboard(makeAddr("clientC"), vaultC, ENTRY, blockN);

        assertEq(sys.callbackCount(), before, "onboarding itself fires no callback");
        assertTrue(engine.guardClientActiveOf(GUARD_CHAIN, feed, vaultC), "client rule armed");
        assertEq(engine.guardClientCountOf(GUARD_CHAIN, feed), 1);

        _reactFeed(95e8, blockN + 1); // -5%: warn rung
        GuardItem[] memory items = new GuardItem[](1);
        items[0] = _item(vaultC, 1, TARGET, BAND, 95e8); // warn bound: anchor 100 * 0.95
        assertTrue(
            _hasRequest(_expectedPayload(feed, asset, blockN + 1, items)),
            "the onboarding event's policy serves the new client"
        );
    }

    /// A re-broadcast onboarding for the SAME vault re-sets the rule,
    /// never duplicates the client list.
    function test_OnboardingReplayDoesNotDuplicate() public {
        engine.setGuardFactory(GUARD_CHAIN, factory);
        _onboard(makeAddr("clientC"), vaultC, ENTRY, blockN);
        _onboard(makeAddr("clientC"), vaultC, ENTRY, blockN + 1);
        assertEq(engine.guardClientCountOf(GUARD_CHAIN, feed), 1, "one client, re-set not append");
    }

    /// Pause is feed-level: one stale episode fires ONE callback with a
    /// single pause item (no per-client duplication).
    function test_PauseIsFeedLevel() public {
        engine.setGuardRule(_policy(vaultA, ENTRY, GUARD_COOLDOWN));
        engine.setGuardRule(_policy(vaultB, ENTRY, GUARD_COOLDOWN));
        _reactFeed(100e8, blockN);
        vm.warp(block.timestamp + MAX_STALE + 1);
        uint256 before = sys.callbackCount();

        _reactCron(blockN + 2); // staleness patrol

        assertEq(sys.callbackCount(), before + 1, "one pause callback");
        GuardItem[] memory items = new GuardItem[](1);
        items[0] = _item(address(0), 4, 0, 0, 0);
        assertTrue(_hasRequest(_expectedPayload(feed, asset, block.number, items)), "feed-level pause: a single item");
    }

    /// A feed with no clients is silent.
    function test_NoClientsSilent() public {
        uint256 before = sys.callbackCount();
        _reactFeed(80e8, blockN);
        assertEq(sys.callbackCount(), before, "no clients -> no callback");
    }

    /// Per-client cooldown: A's cooldown is 1h, B's is 2h. Both trim at
    /// t0. At t0+90min the price fully recovers: A's rebuy gate is open,
    /// B's is not — the batch carries A alone.
    function test_CooldownPerClient() public {
        engine.setGuardRule(_policy(vaultA, ENTRY, GUARD_COOLDOWN));
        engine.setGuardRule(_policy(vaultB, ENTRY, 2 hours));
        _reactFeed(95e8, blockN); // both TRIM at t0
        vm.warp(block.timestamp + GUARD_COOLDOWN + 30 minutes); // t0+90min

        _reactFeed(99e8, blockN + 1); // full recovery: the rebuy gate

        GuardItem[] memory items = new GuardItem[](1);
        items[0] = _item(vaultA, 3, TARGET, BAND, 0);
        assertTrue(_hasRequest(_expectedPayload(feed, asset, blockN + 1, items)), "only A's cooldown has passed");
    }
}
