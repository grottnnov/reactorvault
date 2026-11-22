// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {Watchdog} from "../src/Watchdog.sol";
import {ReliefFund} from "../src/ReliefFund.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";

/**
 * @title WatchdogTest (v6)
 * @notice v6.1 (RCA 30.10): relays are DIRECT from react() (single-env;
 *         platform callback queues are not posted for new contracts).
 *         Asserts — on the real ReliefFund (fedCount/revivedCount) and on
 *         the dog's barkCount().
 * @dev The single omni environment: react() is delivered by
 *      vm.prank(0x8888); onBark guards: msg.sender == 0x8888 (the proxy,
 *      the legacy path) OR the Watchdog itself (the direct relay).
 */
contract WatchdogTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant EMITTER = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant REACTIVE_CHAIN = 5318007; // Reactive Lasna testnet

    uint256 internal constant T_CRON10000 = uint256(keccak256("Cron10000(uint256)"));
    uint256 internal constant T_BLACKLIST = uint256(keccak256("BlacklistContract(address)"));
    uint256 internal constant T_MAILBOX_ALERT =
        uint256(keccak256("AlertReceived(uint8,uint16,address,uint256,address,uint256)"));
    uint256 internal constant T_DOG_FED = uint256(keccak256("DogFed(address,uint256,uint256)"));
    uint256 internal constant T_WATCHER_LOW = uint256(keccak256("WatcherLowReserve(address,uint256,uint256)"));
    uint256 internal constant T_LOW_FUND = uint256(keccak256("LowFund(uint256,uint256)"));

    uint256 internal constant SILENCE_WINDOW = 45_000;

    Watchdog internal dog;
    OmniMockSystem internal omniSys;
    ReliefFund internal fundC;
    address internal mailbox;
    address internal fund;
    address internal watcherAddress;
    address internal attacker;

    function setUp() public {
        OmniMockSystem mockImpl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(mockImpl).code);
        omniSys = OmniMockSystem(payable(OMNI_SYSTEM));

        mailbox = makeAddr("mailbox");
        watcherAddress = makeAddr("watcherAddress");
        attacker = makeAddr("attacker");

        // v6.1: a real fund (precompute — the dog's constructor needs the fund's address).
        address fundPred = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        dog = new Watchdog{value: 0.05 ether}(
            REACTIVE_CHAIN,
            SILENCE_WINDOW,
            mailbox,
            fundPred,
            watcherAddress,
            T_CRON10000,
            T_BLACKLIST,
            T_MAILBOX_ALERT,
            T_DOG_FED,
            T_WATCHER_LOW,
            T_LOW_FUND
        );
        fundC = new ReliefFund(
            address(this), OMNI_SYSTEM, watcherAddress, OMNI_SYSTEM, address(dog), mailbox, watcherAddress
        );
        vm.deal(address(fundC), 10 ether);
        fund = address(fundC);
        dog.init();
    }

    // ------------------------------------------------------------- helpers

    function _log0(uint256 t0, uint256 block_, address origin) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: REACTIVE_CHAIN,
            contractAddress: origin,
            topic0: t0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(block_),
            blockNumber: block_,
            opCode: 0,
            blockHash: 0,
            txHash: block_,
            logIndex: 0
        });
    }

    function _sys(uint256 t0, uint256 block_) internal view returns (IReactive.LogRecord memory) {
        return _log0(t0, block_, EMITTER);
    }

    /// @dev A pulse: a mailbox event (origin = mailbox, topic0 = AlertReceived).
    function _pulseLog(uint256 block_) internal view returns (IReactive.LogRecord memory m) {
        m = _log0(T_MAILBOX_ALERT, block_, mailbox);
        m.topic1 = uint256(uint160(watcherAddress)); // client
    }

    /// @dev An address blacklist: topic1 = the address, origin = the system emitter.
    function _blacklistLog(uint256 block_, address who) internal view returns (IReactive.LogRecord memory m) {
        m = _sys(T_BLACKLIST, block_);
        m.topic1 = uint256(uint160(who));
    }

    /// @dev The fund's feeding report (the mirror): origin = fund, topic0 = DogFed,
    ///      topic1 = the dog, data = (dog, amount, balanceAfter).
    function _dogFedLog(uint256 block_, address who, uint256 amount_, uint256 balanceAfter_)
        internal
        view
        returns (IReactive.LogRecord memory m)
    {
        m = _log0(T_DOG_FED, block_, fund);
        m.topic1 = uint256(uint160(who));
        m.data = abi.encode(who, amount_, balanceAfter_);
    }

    /// @dev The watcher's exhaustion (the fund's eyes): origin = fund, topic0 = WatcherLowReserve.
    function _watcherLowLog(uint256 block_) internal view returns (IReactive.LogRecord memory m) {
        m = _log0(T_WATCHER_LOW, block_, fund);
        m.topic1 = uint256(uint160(watcherAddress));
        m.data = abi.encode(watcherAddress, 1 ether, 1 ether);
    }

    /// @dev The insurer's exhaustion: origin = fund, topic0 = LowFund (no indexed address).
    function _lowFundLog(uint256 block_, uint256 reserve_, uint256 floor_)
        internal
        view
        returns (IReactive.LogRecord memory m)
    {
        m = _log0(T_LOW_FUND, block_, fund);
        m.data = abi.encode(reserve_, floor_);
    }

    function _react(IReactive.LogRecord memory m) internal {
        vm.prank(OMNI_SYSTEM);
        dog.react(m);
    }

    function _bark(uint256 lastPulse_, uint256 block_, bool recovery_) internal {
        vm.prank(OMNI_SYSTEM);
        dog.onBark(address(dog), lastPulse_, block_, recovery_);
    }

    function _rnDog(uint256 value_) internal returns (Watchdog rnDog) {
        rnDog = new Watchdog{value: value_}(
            REACTIVE_CHAIN,
            SILENCE_WINDOW,
            mailbox,
            fund,
            watcherAddress,
            T_CRON10000,
            T_BLACKLIST,
            T_MAILBOX_ALERT,
            T_DOG_FED,
            T_WATCHER_LOW,
            T_LOW_FUND
        );
    }

    // ------------------------------------------------------------- tests: init

    function test_InitSubscribesEight() public view {
        assertEq(omniSys.subscriptionCount(), 8, "3 blacklists + pulse + cron + 3 fund events");
        // instant barks: the blacklist of the watcher and of both receivers (RCA 18.09)
        (,, uint256 t0, uint256 t1,,,) = omniSys.subscriptions(0);
        assertEq(t0, T_BLACKLIST, "blacklist criterion");
        assertEq(t1, uint256(uint160(watcherAddress)), "filtered by watcher address");
        (,, t0, t1,,,) = omniSys.subscriptions(1);
        assertEq(t1, uint256(uint160(mailbox)), "filtered by mailbox address");
        (,, t0, t1,,,) = omniSys.subscriptions(2);
        assertEq(t1, uint256(uint160(fund)), "filtered by fund address");
        // the pulse: mailbox events
        (, address origin,,,,,) = omniSys.subscriptions(3);
        assertEq(origin, mailbox, "pulse origin = mailbox");
        // the fund's events — the mirror and the watcher's exhaustion
        (, origin, t0, t1,,,) = omniSys.subscriptions(5);
        assertEq(origin, fund, "mirror origin = fund");
        assertEq(t0, T_DOG_FED, "mirror topic = DogFed");
        assertEq(t1, uint256(uint160(address(dog))), "mirror filtered by self");
        (, origin, t0, t1,,,) = omniSys.subscriptions(6);
        assertEq(origin, fund, "watcher-low origin = fund");
        assertEq(t0, T_WATCHER_LOW, "watcher-low topic");
        assertEq(t1, uint256(uint160(watcherAddress)), "watcher-low filtered by watcher");
        // the fund's LowFund — the insurer-exhaustion bark (a wildcard filter:
        // the event is not indexed by address, the fund is the one — filter by origin)
        (, origin, t0,,,,) = omniSys.subscriptions(7);
        assertEq(origin, fund, "low-fund origin = fund");
        assertEq(t0, T_LOW_FUND, "low-fund topic");
    }

    /// @dev Audit 27.08 #2: init sets lastPulseBlock — no false alarm at the start.
    function test_InitSetsLastPulse() public view {
        assertGt(dog.lastPulseBlock(), 0, "lastPulseBlock initialized");
        assertFalse(dog.pulsesSeen(), "no pulses seen yet");
    }

    // ------------------------------------------------------------- tests: pulse

    function test_MailboxPulseSetsState() public {
        _react(_pulseLog(100));
        assertTrue(dog.pulsesSeen(), "pulse seen");
        assertEq(dog.lastPulseBlock(), 100, "lastPulseBlock");

        // a second pulse does not rewind the block (delivery monotonicity)
        _react(_pulseLog(90));
        assertEq(dog.lastPulseBlock(), 100, "late pulse does not rewind");
    }

    function test_StrangerTopicIgnored() public {
        _react(_log0(uint256(keccak256("Noise(uint256)")), 100, mailbox));
        assertFalse(dog.pulsesSeen(), "foreign topic is not a pulse");
    }

    // ------------------------------------------------------------- tests: the silence patrol

    /// @dev No alarm before the first pulse ("no data"); without a mirror —
    ///      a bootstrap feeding request (the pot is filled in advance,
    ///      the answer calibrates).
    function test_NoBarkBeforeFirstPulse() public {
        uint256 fed = fundC.fedCount();
        _react(_sys(T_CRON10000, 100_000));
        assertEq(dog.barkCount(), 0, "no bark without pulses");
        assertEq(fundC.fedCount() - fed, 1, "bootstrap feed ask");
    }

    /// @dev Silence past the window: every tick is a bark (self-healing).
    ///      "One recipient per tick": in a bark tick the fund receives
    ///      only onRevive (feeding is postponed).
    function test_SilenceBarksEveryTick() public {
        _react(_pulseLog(100));

        uint256 revived = fundC.revivedCount();
        _react(_sys(T_CRON10000, 50_000));
        assertEq(fundC.revivedCount() - revived, 1, "bark wakes fund");
        assertEq(dog.barkCount(), 1, "public bark");
        assertEq(fundC.fedCount(), 0, "no feed in bark tick");

        revived = fundC.revivedCount();
        _react(_sys(T_CRON10000, 51_000));
        assertEq(fundC.revivedCount() - revived, 1, "bark repeats while silent");
    }

    function test_QuietWithinWindow() public {
        _react(_pulseLog(100));
        uint256 revived = fundC.revivedCount();
        _react(_sys(T_CRON10000, 10_000));
        assertEq(fundC.revivedCount() - revived, 0, "within window: no bark");
    }

    // ------------------------------------------------------------- tests: the instant bark

    /// @dev The watcher blacklisted → a bark immediately, without waiting for the window.
    function test_BlacklistBarksInstantly() public {
        _react(_blacklistLog(555, watcherAddress));
        assertEq(fundC.revivedCount(), 1, "fund awakened");
        assertEq(dog.barkCount(), 1, "public bark");
    }

    /// @dev RCA 13-18.09: the alarm receiver's death (the mailbox is blacklisted) — an instant bark.
    function test_BlacklistMailboxBarksInstantly() public {
        _react(_blacklistLog(555, mailbox));
        assertEq(fundC.revivedCount(), 1, "fund awakened");
        assertEq(dog.barkCount(), 1, "public bark");
    }

    /// @dev The feeder's death (the fund is blacklisted) — an instant bark: feeding would not arrive.
    function test_BlacklistFundBarksInstantly() public {
        _react(_blacklistLog(555, fund));
        assertEq(fundC.revivedCount(), 1, "fund awakened");
        assertEq(dog.barkCount(), 1, "public bark");
    }

    /// @dev A stranger's blacklist (topic1 ∉ {watcher, mailbox, fund}) — not our trigger.
    function test_BlacklistOfStrangerIgnored() public {
        _react(_blacklistLog(555, attacker));
        assertEq(fundC.revivedCount(), 0, "stranger death is not ours");
    }

    /// @dev Recovery: a pulse after the window → a public all-clear (isRecovery=true).
    function test_RecoveryAfterSilence() public {
        _react(_pulseLog(100));
        _react(_sys(T_CRON10000, 50_000)); // a bark
        _react(_pulseLog(51_000)); // the pulse returned — the lateness exceeds the window
        assertEq(dog.barkCount(), 2, "recovery bark");
    }

    // ------------------------------------------------- tests: the watcher-exhaustion bark

    /// @dev WatcherLowReserve (the fund's eyes) — the dog barks publicly and wakes the fund.
    function test_WatcherLowReserveBarks() public {
        _react(_pulseLog(100)); // a live pulse — this is NOT a silence bark
        _react(_watcherLowLog(555));
        assertEq(fundC.revivedCount(), 1, "fund awakened");
        assertEq(dog.barkCount(), 1, "public bark on watcher low reserve");
    }

    // ------------------------------------------------- tests: the insurer-exhaustion bark

    /// @dev LowFund(reserve, floor) — the fund is alive but broke. A public
    ///      bark WITHOUT onRevive (nothing to revive: the signal is for a
    ///      human, "top up").
    function test_LowFundBarksWithoutRevive() public {
        _react(_lowFundLog(777, 0.4 ether, 1 ether));
        assertEq(dog.barkCount(), 1, "public bark on low fund");
        assertEq(fundC.revivedCount(), 0, "no revive: fund is alive, it is broke");
    }

    // ------------------------------------------------------------- tests: the balance mirror

    /// @dev Calibration: DogFed(dog, amount, balanceAfter) writes the real number into the mirror.
    function test_MirrorCalibratesOnDogFed() public {
        assertFalse(dog.mirrorSeen(), "no mirror before first report");
        _react(_dogFedLog(200, address(dog), 0, 1 ether));
        assertTrue(dog.mirrorSeen(), "mirror seen");
        assertEq(dog.lastKnownBalance(), 1 ether, "balanceAfter stored");

        // a new report overwrites (including a zero portion with a full bowl)
        _react(_dogFedLog(300, address(dog), 0, 0.5 ether));
        assertEq(dog.lastKnownBalance(), 0.5 ether, "mirror follows latest report");
    }

    /// @dev A stranger dog (topic1/data ≠ us) does not touch the mirror.
    function test_MirrorIgnoresStrangerDog() public {
        _react(_dogFedLog(200, attacker, 0.05 ether, 2 ether));
        assertFalse(dog.mirrorSeen(), "stranger report ignored");
        assertEq(dog.lastKnownBalance(), 0, "mirror untouched");
    }

    /// @dev A dog that is sated by the mirror does NOT ask for food — we no
    ///      longer burn the fund's receiver fee on every tick (the
    /// "perpetually hungry" incident, 20.09).
    function test_FedByMirrorStaysSilent() public {
        _react(_dogFedLog(200, address(dog), 0, 1 ether));
        _react(_pulseLog(100));
        uint256 fed = fundC.fedCount();
        _react(_sys(T_CRON10000, 10_000));
        assertEq(fundC.fedCount() - fed, 0, "mirror-fed dog is silent");
    }

    /// @dev Decay: between reports the mirror melts by TICK_BURN per tick;
    ///      it asks when the latest data says it is hungry
    ///      (0.16 − 0.02 = 0.14 < 0.15).
    function test_MirrorDecayAsksWhenHungry() public {
        _react(_dogFedLog(200, address(dog), 0, 0.16 ether));
        _react(_pulseLog(100));
        uint256 fed = fundC.fedCount();
        _react(_sys(T_CRON10000, 10_000));
        assertEq(fundC.fedCount() - fed, 1, "decayed below threshold: ask");
        assertEq(dog.lastKnownBalance(), 0.14 ether, "mirror decayed by TICK_BURN");
    }

    /// @dev The mirror's live cycle: after a request the fund answers (the
    ///      balance goes up) — the dog stays silent for many ticks again.
    ///      The decay error is on the safe side.
    function test_MirrorRefilledStaysSilentManyTicks() public {
        _react(_dogFedLog(200, address(dog), 0, 0.3 ether));
        _react(_pulseLog(100));
        for (uint256 b = 10_000; b < 60_000; b += 10_000) {
            _react(_sys(T_CRON10000, b)); // 5 ticks: 0.3 → 0.2 — still sated
            if (b == 40_000) _react(_pulseLog(41_000)); // a pulse inside the silence window
        }
        assertEq(dog.lastKnownBalance(), 0.2 ether, "five ticks decayed");
        uint256 fed = fundC.fedCount();
        _react(_sys(T_CRON10000, 60_000)); // 6th: 0.18 — still sated
        assertEq(fundC.fedCount() - fed, 0, "still above threshold");
        fed = fundC.fedCount();
        _react(_sys(T_CRON10000, 70_000)); // 7th: 0.16 — sated; the 8th would be 0.14
        assertEq(fundC.fedCount() - fed, 0, "0.16 still above 0.15");
        fed = fundC.fedCount();
        _react(_sys(T_CRON10000, 80_000)); // 8th tick: 0.14 < 0.15 — it asks
        assertEq(fundC.fedCount() - fed, 1, "finally asks");
        // the fund answered: filled up to 0.35 — the mirror is honest, silence for 10 more ticks
        _react(_dogFedLog(80_100, address(dog), 0.21 ether, 0.35 ether));
        assertEq(dog.lastKnownBalance(), 0.35 ether, "mirror corrected by fund answer");
    }

    // ------------------------------------------------------------- tests: callbacks

    function test_OnBarkEmitsAndCounts() public {
        vm.expectEmit(true, true, true, true, address(dog));
        emit Watchdog.WatchdogAlert(100, 20_000, false);
        _bark(100, 20_000, false);
        assertEq(dog.barkCount(), 1, "counted");
    }

    /// @dev v6.1 guards: the sender is the SYSTEM proxy (0x8888) OR the
    ///      Watchdog itself (the direct relay from react); anyone else — rejected.
    function test_RevertWhen_SenderNotSystem() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("callback sender only"));
        dog.onBark(address(dog), 1, 2, false);
    }

    /// @dev The rvm_ slot (the network's injection) — only the Watchdog itself (a self-callback).
    function test_RevertWhen_BarkWrongRvm() public {
        vm.prank(OMNI_SYSTEM);
        vm.expectRevert(bytes("self callback only"));
        dog.onBark(attacker, 1, 2, false);
    }

    // ------------------------------------------------------------- tests: the owner withdrawal

    /// @dev Lesson v4.3: rations piled up with no withdrawal (~0.55 REACT frozen forever).
    function test_WithdrawExcessKeepsFloor() public {
        Watchdog rnDog = _rnDog(1 ether);
        address keeper = makeAddr("keeper");
        uint256 before = keeper.balance;
        rnDog.withdrawExcess(keeper);
        assertEq(keeper.balance - before, 0.85 ether, "excess over floor withdrawn");
        assertEq(address(rnDog).balance, 0.15 ether, "floor stays for life");
    }

    function test_RevertWhen_WithdrawNoExcess() public {
        Watchdog rnDog = _rnDog(0.05 ether); // below the floor — nothing to withdraw
        vm.expectRevert(bytes("no excess"));
        rnDog.withdrawExcess(attacker);
    }

    function test_RevertWhen_WithdrawNotOwner() public {
        Watchdog rnDog = _rnDog(1 ether);
        vm.prank(attacker);
        vm.expectRevert(bytes("Unauthorized"));
        rnDog.withdrawExcess(attacker);
    }

    // ------------------------------------------- partner hatches (ADR-EXPANSION)

    /// @dev Depot migration without a redeploy: pause() removes all 8
    ///      subscriptions by the OLD fields, setReliefFund changes the
    ///      address, resume() puts the subscriptions back by the NEW ones.
    ///      The emitter-depot subscriptions move.
    function test_PauseSetResumeRewiresSubscriptions() public {
        uint256 base = omniSys.subscriptionCount(); // the setUp dog is already subscribed
        Watchdog rnDog = _rnDog(1 ether);
        rnDog.init();
        assertEq(omniSys.subscriptionCount(), base + 8, "init: 8 subs");

        rnDog.pause();
        assertEq(omniSys.subscriptionCount(), base, "pause removed all");

        address newFund = makeAddr("newFund");
        vm.prank(attacker);
        vm.expectRevert(bytes("Unauthorized"));
        rnDog.setReliefFund(newFund);

        vm.expectRevert(bytes("zero address"));
        rnDog.setReliefFund(address(0));

        rnDog.setReliefFund(newFund);
        assertEq(rnDog.reliefFund(), newFund);

        rnDog.resume();
        assertEq(omniSys.subscriptionCount(), base + 8, "resume rewired");
        // the depot-dependent subscriptions' emitters moved to the new address
        bool seenNewFund = false;
        for (uint256 i = 0; i < omniSys.subscriptionCount(); i++) {
            (, address contractAddr,,,,, address sub) = omniSys.subscriptions(i);
            if (contractAddr == newFund && sub == address(rnDog)) seenNewFund = true;
            assertFalse(contractAddr == fund && sub == address(rnDog), "old fund left in subs");
        }
        assertTrue(seenNewFund, "new fund not in subs");
    }

    /// The ward-cry fast chain (the ADR-v2 move into the omni port): a
    /// ward's cry → a direct relay to the depot's onWardHungry → the depot
    /// feeds by the real numbers (a ward with a zero eff gets a portion).
    function test_WardCryRelayFeedsWard() public {
        address ward = makeAddr("ward");
        fundC.addWard(ward, 0.05 ether, 0.1 ether);
        vm.deal(address(fundC), 1 ether);

        Watchdog rnDog = _rnDog(1 ether);
        rnDog.init();
        fundC.setDogContract(address(rnDog)); // a partner hatch: replacing the dog without a redeploy
        rnDog.subscribeWardCry(ward);
        assertTrue(rnDog.wardCrySubscribed(ward), "subscribed");

        uint256 T_CRY = uint256(keccak256("LowGas(uint256,uint256)"));
        vm.prank(OMNI_SYSTEM);
        rnDog.react(_log0(T_CRY, 500, ward));

        // The 11.11 pocket fix: feeding lands in the SYSTEM reserve (the
        // reactive ward's gas pocket), not in the native balance.
        assertEq(omniSys.reserves(ward), 0.1 ether, "ward fed via cry relay");
    }
}
