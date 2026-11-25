// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {RulesEngine} from "../src/RulesEngine.sol";
import {GuardMsg} from "../src/IGuardVault.sol";
import {Executor, IExecutorVault} from "../src/Executor.sol";
import {AssetVault} from "../src/AssetVault.sol";
import {GasVault} from "../src/GasVault.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";
import {MockGuardVault} from "./mocks/MockGuardVault.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev Guard rules, red-first (ADR-GUARD-RULES). The brain keeps the
///      price HISTORY (anchor = max(entry, high-water mark)), derives
///      the ladder rung and fires typed guardAction callbacks; the
///      executor re-verifies NOW (freshness, bound) and acts through
///      the guard safe. Numbers: entry 100e8, warn 5%, mid 10%,
///      hard 20%, target share 50%, band ±10%, staleness 900 s.
contract GuardBrainTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 constant SOURCE_CHAIN = 11155111;
    uint256 constant GUARD_CHAIN = 4663; // Robinhood Chain
    uint256 constant DEST_CHAIN = 11155111;

    uint256 constant RATE_CHANGE_TOPIC = uint256(
        keccak256(
            "ReserveDataUpdated(uint256 indexed reserve,uint256 liquidityRate,uint256 stableBorrowRate,uint256 variableBorrowRate,uint256 liquidityIndex,uint256 variableBorrowIndex)"
        )
    );
    uint256 constant ANSWER_UPDATED = 0x0559884fd3a460db3073b7fc96cc77986f16e378210ded43186175bf646fc5f;
    uint64 constant COOLDOWN = 6 hours;

    // guard policy (numbers are test fixtures; live calibration 28-30.11)
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
    uint256 blockN = 1000;

    // brain events (mirror)
    event GuardRuleSet(bytes32 indexed key, uint256 chainId, address feed, address asset, uint256 entryRef);
    event GuardFired(uint8 kind, address indexed feed, uint256 chainId, uint256 price, uint256 anchor, uint8 rung);
    event GuardStale(address indexed feed, uint256 lastUpdateTs, uint256 age);

    function setUp() public {
        OmniMockSystem impl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);
        sys = OmniMockSystem(payable(OMNI_SYSTEM));

        engine = new RulesEngine();
        engine.initialize(origin, SOURCE_CHAIN, RATE_CHANGE_TOPIC, executor, DEST_CHAIN, COOLDOWN);
        engine.setExecutor(GUARD_CHAIN, executor); // the guard vertical wires 4663
        vm.warp(COOLDOWN);
    }

    function _setGuardRule() internal {
        engine.setGuardRule(_policy(feed, asset));
    }

    function _policy(address feed_, address asset_) internal view returns (RulesEngine.GuardPolicy memory) {
        RulesEngine.GuardPolicy memory p;
        p.chainId = GUARD_CHAIN;
        p.feed = feed_;
        p.asset = asset_;
        p.destChainId = GUARD_CHAIN;
        p.entryRef = ENTRY;
        p.warnBps = WARN;
        p.midBps = MID;
        p.hardBps = HARD;
        p.targetBps = TARGET;
        p.bandBps = BAND;
        p.maxStaleSec = MAX_STALE;
        p.cooldown = GUARD_COOLDOWN;
        return p;
    }

    function _feedLog(uint256 price, uint256 updatedAt, uint256 blockNumber, address feed_)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: GUARD_CHAIN,
            contractAddress: feed_,
            topic0: ANSWER_UPDATED,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(int256(price), uint256(1), uint256(updatedAt)),
            blockNumber: blockNumber,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _reactFeed(uint256 price, uint256 updatedAt, uint256 blockNumber, address feed_) internal {
        vm.prank(OMNI_SYSTEM);
        engine.react(_feedLog(price, updatedAt, blockNumber, feed_));
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

    function _msg(address feed_, uint8 kind, uint256 param, uint256 param2, uint256 bound, uint256 originBlock)
        internal
        view
        returns (GuardMsg memory m)
    {
        m.sender = address(0);
        m.feed = feed_;
        m.asset = asset;
        m.kind = kind;
        m.param = param;
        m.param2 = param2;
        m.bound = bound;
        m.originBlockNumber = originBlock;
    }

    function _expectedPayload(
        address feed_,
        uint8 kind,
        uint256 param,
        uint256 param2,
        uint256 bound,
        uint256 originBlock
    ) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "guardAction((address,address,address,uint8,uint256,uint256,uint256,uint256))",
            _msg(feed_, kind, param, param2, bound, originBlock)
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

    // -------------------------------------------------------------
    // setup
    // -------------------------------------------------------------

    function testSetGuardRule_SubscribesAndStores() public {
        _setGuardRule();
        assertEq(sys.subscriptionCount(), 2, "init + guard subscriptions");
        (uint256 sChainId, address sContract, uint256 sTopic0,,,,) = sys.subscriptions(1);
        assertEq(sChainId, GUARD_CHAIN);
        assertEq(sContract, feed);
        assertEq(sTopic0, ANSWER_UPDATED);

        assertTrue(engine.guardActiveOf(GUARD_CHAIN, feed));
        (address gAsset, uint256 destChain, uint64 warn, uint64 mid, uint64 hard,,,,) =
            engine.guardConfigOf(GUARD_CHAIN, feed);
        assertEq(gAsset, asset);
        assertEq(destChain, GUARD_CHAIN);
        assertEq(warn, WARN);
        assertEq(mid, MID);
        assertEq(hard, HARD);
        assertEq(engine.guardHwmOf(GUARD_CHAIN, feed), ENTRY, "anchor starts at entry");
    }

    function testSetGuardRule_RejectsBadLadder() public {
        RulesEngine.GuardPolicy memory p = _policy(feed, asset);
        p.warnBps = MID; // not strictly below mid
        vm.expectRevert(RulesEngine.BadGuardParams.selector);
        engine.setGuardRule(p);
    }

    // -------------------------------------------------------------
    // price history: HWM, rungs, callbacks
    // -------------------------------------------------------------

    function testPriceRise_UpdatesHwm_NoFire() public {
        _setGuardRule();
        uint256 before = sys.callbackCount();
        _reactFeed(120e8, block.timestamp, blockN, feed);
        assertEq(engine.guardHwmOf(GUARD_CHAIN, feed), 120e8, "hwm follows the high");
        assertEq(sys.callbackCount(), before, "no fire on a rise");
    }

    function testDipInsideWarn_NoFire() public {
        _setGuardRule();
        _reactFeed(120e8, block.timestamp, blockN, feed);
        uint256 before = sys.callbackCount();
        _reactFeed(116e8, block.timestamp, blockN + 1, feed); // -3.3% from anchor
        assertEq(sys.callbackCount(), before, "inside warn: silent");
    }

    function testWarnRung_FiresTrim() public {
        _setGuardRule();
        _reactFeed(120e8, block.timestamp, blockN, feed);

        vm.expectEmit(true, false, false, true);
        emit GuardFired(1, feed, GUARD_CHAIN, 113e8, 120e8, 1);
        _reactFeed(113e8, block.timestamp, blockN + 1, feed); // -5.8% from anchor 120e8

        assertTrue(
            _hasRequest(_expectedPayload(feed, 1, TARGET, BAND, 114e8, blockN + 1)),
            "TRIM callback: target/band + the warn trigger price 120e8*0.95"
        );
        assertEq(engine.guardHwmOf(GUARD_CHAIN, feed), 120e8, "hwm unchanged on a dip");
        assertEq(engine.guardRungOf(GUARD_CHAIN, feed), 1);
    }

    function testDeepening_BypassesCooldown() public {
        _setGuardRule();
        _reactFeed(120e8, block.timestamp, blockN, feed);
        _reactFeed(113e8, block.timestamp, blockN + 1, feed); // rung 1 fires
        vm.warp(block.timestamp + 600); // cooldown NOT passed

        _reactFeed(108e8, block.timestamp, blockN + 2, feed); // -10% from anchor
        assertTrue(
            _hasRequest(_expectedPayload(feed, 2, 5_000, 0, 108e8, blockN + 2)),
            "deeper rung fires within cooldown: EXIT 50% at the mid trigger price"
        );
    }

    function testHardRung_FromEntry_ExitsAll() public {
        _setGuardRule();
        _reactFeed(79e8, block.timestamp, blockN, feed); // -21% from entry anchor
        assertTrue(
            _hasRequest(_expectedPayload(feed, 2, 10_000, 0, 80e8, blockN)),
            "hard rung straight from entry: EXIT 100% at entry*0.80"
        );
    }

    function testRecovery_RebuyGatedByCooldown() public {
        _setGuardRule();
        _reactFeed(79e8, block.timestamp, blockN, feed); // hard exit at T
        uint256 firedAt = block.timestamp;

        vm.warp(firedAt + 600); // inside cooldown
        _reactFeed(96e8, block.timestamp, blockN + 1, feed); // -4%: full recovery
        assertFalse(
            _hasRequest(_expectedPayload(feed, 3, TARGET, BAND, 0, blockN + 1)), "rebuy suppressed inside cooldown"
        );

        vm.warp(firedAt + GUARD_COOLDOWN + 60);
        _reactFeed(96e8, block.timestamp, blockN + 2, feed);
        assertTrue(
            _hasRequest(_expectedPayload(feed, 3, TARGET, BAND, 0, blockN + 2)),
            "rebuy fires after cooldown on recovery"
        );
    }

    // -------------------------------------------------------------
    // staleness pause / resume
    // -------------------------------------------------------------

    function testStaleness_PauseOnOtherEvent() public {
        _setGuardRule();
        _reactFeed(100e8, block.timestamp, blockN, feed); // lastUpdate = now
        vm.warp(block.timestamp + MAX_STALE + 1100);

        vm.expectEmit(true, false, false, true);
        emit GuardStale(feed, block.timestamp - MAX_STALE - 1100, MAX_STALE + 1100);
        _reactCron(blockN + 1); // any non-feed event runs the patrol

        assertTrue(
            _hasRequest(_expectedPayload(feed, 4, 0, 0, 0, block.number)), "PAUSE callback fired on the cron patrol"
        );
        assertTrue(engine.guardPausedOf(GUARD_CHAIN, feed));
    }

    function testStaleness_NoDoublePause() public {
        _setGuardRule();
        _reactFeed(100e8, block.timestamp, blockN, feed);
        vm.warp(block.timestamp + MAX_STALE + 1100);
        _reactCron(blockN + 1);
        uint256 afterFirst = sys.callbackCount();
        _reactCron(blockN + 2);
        // zero new requests: the patrol is paused-flagged, the generic
        // rule sits in its 6h cooldown (lastFired seconds ago)
        assertEq(sys.callbackCount(), afterFirst, "no second PAUSE, no rebalance spam");
    }

    function testFreshFeed_ResumesAfterPause() public {
        _setGuardRule();
        _reactFeed(100e8, block.timestamp, blockN, feed);
        vm.warp(block.timestamp + MAX_STALE + 1100);
        _reactCron(blockN + 1); // pause

        _reactFeed(100e8, block.timestamp, blockN + 2, feed); // fresh answer
        assertTrue(_hasRequest(_expectedPayload(feed, 5, 0, 0, 0, blockN + 2)), "fresh feed answer RESUMES the guard");
        assertFalse(engine.guardPausedOf(GUARD_CHAIN, feed));
    }

    // -------------------------------------------------------------
    // multi-feed correctness + sanity
    // -------------------------------------------------------------

    function testTwoFeeds_SameBlock_BothEvaluated() public {
        address feedB = makeAddr("nvdaFeed");
        engine.setGuardRule(_policy(feedB, asset));
        _setGuardRule();

        // same block, same topic0, two emitters: the processed key must
        // not swallow the second feed
        _reactFeed(90e8, block.timestamp, blockN, feed); // rung 2 on feed A
        _reactFeed(120e8, block.timestamp, blockN, feedB); // new high on feed B

        assertEq(engine.guardHwmOf(GUARD_CHAIN, feedB), 120e8, "feed B was evaluated too");
        assertTrue(_hasRequest(_expectedPayload(feed, 2, 5_000, 0, 90e8, blockN)), "feed A fired its rung");
    }

    function testNonPositivePrice_Ignored() public {
        _setGuardRule();
        _reactFeed(100e8, block.timestamp, blockN, feed);
        uint256 before = sys.callbackCount();
        _reactFeed(0, block.timestamp, blockN + 1, feed); // zero answer
        _reactFeed(uint256(int256(-5e8)), block.timestamp, blockN + 2, feed); // negative answer
        assertEq(engine.guardHwmOf(GUARD_CHAIN, feed), 100e8, "no state corruption on a bad answer");
        assertEq(sys.callbackCount(), before, "no fires on a bad answer");
        assertEq(engine.guardLastUpdateOf(GUARD_CHAIN, feed), block.timestamp, "lastUpdate untouched by a bad answer");
    }
}

/// @dev The executor side: verify NOW, then act. Freshness re-check,
///      pause semantics, EXIT bound verification, pay-on-delivery
///      billing only on a real swap.
contract GuardExecutorTest is Test {
    address asset = makeAddr("tsla");
    address usdg = makeAddr("usdg");
    address rulesEngine = makeAddr("rulesEngine");
    address proxy = makeAddr("proxy");
    address feedAddr = makeAddr("feed");

    AssetVault vault;
    GasVault fund;
    Executor executor;
    MockGuardVault guardVault;
    MockFeed feed;

    uint8 constant TRIM = 1;
    uint8 constant EXIT = 2;
    uint8 constant REBUY = 3;
    uint8 constant PAUSE = 4;
    uint8 constant RESUME = 5;

    // executor events (mirror)
    event GuardActed(uint8 indexed kind, address indexed asset, uint256 price, uint256 amountIn, uint256 amountOut);
    event GuardSkipped(uint8 indexed kind, address indexed feed, address indexed asset, uint8 reason);
    event GuardPaused(address indexed asset, address indexed feed);
    event GuardResumed(address indexed asset, address indexed feed);

    function setUp() public {
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        vault = new AssetVault();
        fund = new GasVault();
        executor = new Executor(rulesEngine, IPayable(payable(proxy)), IExecutorVault(address(vault)), fund);
        vault.setGasVault(fund);
        vault.authorizeExecutor(address(executor));
        fund.authorizeExecutor(address(executor));
        guardVault = new MockGuardVault(asset, usdg);
        feed = new MockFeed();
        executor.addGuardVault(asset, address(guardVault));
        executor.setGuardStaleness(900);
        vm.stopPrank();
        vm.deal(alice, 10 ether);
        vm.warp(10_000);
    }

    function _guard(uint8 kind, uint256 param, uint256 param2, uint256 bound) internal {
        vm.prank(proxy);
        executor.guardAction(_msg(address(feed), kind, param, param2, bound, 77));
    }

    function _msg(address feed_, uint8 kind, uint256 param, uint256 param2, uint256 bound, uint256 originBlock)
        internal
        view
        returns (GuardMsg memory m)
    {
        m.sender = rulesEngine; // the network slot-substitution result
        m.feed = feed_;
        m.asset = asset;
        m.kind = kind;
        m.param = param;
        m.param2 = param2;
        m.bound = bound;
        m.originBlockNumber = originBlock;
    }

    function testGuardTrim_ActsAndBills() public {
        feed.setRound(100e8, block.timestamp);
        guardVault.setSwapResults(1e18, 900e6, 0, 0, 0, 0);

        vm.expectEmit(true, true, false, true);
        emit GuardActed(TRIM, asset, 100e8, 1e18, 900e6);
        _guard(TRIM, 5000, 1000, 0);

        assertEq(guardVault.lastTrimTargetBps(), 5000, "vault got the target");
        assertEq(guardVault.lastTrimBandBps(), 1000, "vault got the band");
        assertEq(guardVault.billedTotal(), executor.feePerActionWei(), "billed once per served action");
        assertEq(executor.feesBilled(), executor.feePerActionWei());
    }

    function testGuardSkips_Stale() public {
        feed.setRound(100e8, block.timestamp - 2000); // older than 900 s

        vm.expectEmit(true, true, true, true);
        emit GuardSkipped(TRIM, address(feed), asset, 1);
        _guard(TRIM, 5000, 1000, 0);

        assertEq(guardVault.lastTrimTargetBps(), 0, "no vault call on stale");
        assertEq(guardVault.billedTotal(), 0, "no bill for a skipped check");
    }

    function testPause_BlocksThenResume_Restores() public {
        feed.setRound(100e8, block.timestamp - 5000); // pause must NOT require freshness

        vm.expectEmit(true, true, false, true);
        emit GuardPaused(asset, address(feed));
        _guard(PAUSE, 0, 0, 0);
        assertTrue(executor.guardPaused(asset));

        _guard(TRIM, 5000, 1000, 0); // blocked while paused
        assertEq(guardVault.lastTrimTargetBps(), 0, "paused blocks actions");

        vm.expectEmit(true, true, false, true);
        emit GuardResumed(asset, address(feed));
        _guard(RESUME, 0, 0, 0);
        assertFalse(executor.guardPaused(asset));

        feed.setRound(100e8, block.timestamp); // fresh answer: actions live again
        _guard(TRIM, 5000, 1000, 0); // acts after resume
        assertEq(guardVault.lastTrimTargetBps(), 5000);
    }

    function testGuardExit_VerifiesBound() public {
        feed.setRound(95e8, block.timestamp);
        guardVault.setSwapResults(0, 0, 5e17, 450e6, 0, 0);

        _guard(EXIT, 5000, 0, 100e8); // price 95e8 <= bound 100e8
        assertEq(guardVault.lastExitFractionBps(), 5000, "exit executes under the bound");

        vm.expectEmit(true, true, true, true);
        emit GuardSkipped(EXIT, address(feed), asset, 3); // recovered
        _guard(EXIT, 5000, 0, 90e8); // price 95e8 > bound 90e8
        assertEq(guardVault.billedTotal(), executor.feePerActionWei(), "only the acted exit is billed");
    }

    function testGuardRebuy_Acts() public {
        feed.setRound(100e8, block.timestamp);
        guardVault.setSwapResults(0, 0, 0, 0, 500e6, 9e17);
        _guard(REBUY, 5000, 1000, 0);
        assertEq(guardVault.lastRebuyTargetBps(), 5000);
        assertEq(guardVault.lastRebuyBandBps(), 1000);
    }

    function testNoopSwap_NotBilled() public {
        feed.setRound(100e8, block.timestamp);
        guardVault.setSwapResults(0, 0, 0, 0, 0, 0); // inside band: no swap
        _guard(TRIM, 5000, 1000, 0);
        assertEq(guardVault.billedTotal(), 0, "a no-op is not a served action");
    }

    function testOnlyBrain_CanSend() public {
        feed.setRound(100e8, block.timestamp);
        GuardMsg memory m = _msg(address(feed), TRIM, 5000, 1000, 0, 77);
        m.sender = makeAddr("fake");
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSignature("CallbackNotAuthorized(address,address)", m.sender, rulesEngine));
        executor.guardAction(m);

        m.sender = rulesEngine;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized(address,address)", makeAddr("stranger"), proxy));
        executor.guardAction(m);
    }
}
