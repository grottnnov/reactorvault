// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractPausableReactiveOmni} from "./AbstractPausableReactiveOmni.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";

/**
 * @title Watchdog (v6 omni: "honest mirror + a voice on fund starvation")
 * @notice A watcher over the watcher: mailbox pulse (mailbox events),
 *         an instant bark on blacklists (watcher/mailbox/fund), a bark on
 *         the watcher's financial exhaustion, a bark on the insurer's
 *         exhaustion (LowFund), and feeding by an honest balance mirror.
 * @dev A v4.6 port to the omni library (phase B1): react(LogRecord),
 *      callbacks via requestCallbackV_1_0, subscriptions through
 *      SYSTEM = 0x8888 (system-event emitter 0xfffFfF, NATIVE-ARCH §1).
 *      Callback guards: delivered by the SYSTEM proxy (0x8888), the source
 *      in the rvm_ slot = the Watchdog itself (a replacement for the legacy
 *      AbstractCallback authorizedSenderOnly/rvmIdOnly — without diamond
 *      inheritance of two AbstractPayer contracts).
 *      The deployer MUST differ from the watcher's deployer (a different
 *      EOA → independent fault tolerance).
 *      The single omni environment: rnOnly/vmOnly are gone; the v4.5
 *      "mirror" (the latest balanceAfter from DogFed plus TICK_BURN decay)
 *      is preserved 1:1 — fund reports arrive by subscription (the
 *      subscription conveyor is alive, M0/A2/A3), not by callback.
 */
contract Watchdog is AbstractPausableReactiveOmni {
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice The system-event (Cron) emitter — 0xfffFfF in every network generation.
    address internal constant SYSTEM_EVENTS_EMITTER = address(0x0000000000000000000000000000000000fffFfF);

    /// @notice Accounting events (Blacklist/Whitelist/Subscribe — live check
    ///         16.10: emitted by 0x8888, not 0xfffFfF!) — wildcard by contract.
    address internal constant ACCOUNTING_ANY = address(0);

    /// @notice The hunger threshold: below this last-known real balance we ask for a ration.
    uint256 public constant DOG_FEED_BELOW = 0.15 ether;
    /// @notice A conservative burn per tick (mainnet measurement 20.09:
    ///         react on tick 68.7k + react on pulse 82k gas × 100 gwei ≈ 0.015;
    ///         we take 0.02 with a margin).
    uint256 public constant TICK_BURN = 0.02 ether;
    /// @notice The ration we ask the fund for. The fund decides by the real
    ///         balance — this is only the upper bound of the request.
    uint256 public constant RATION = 0.05 ether;

    uint256 public immutable chainId;
    /// @notice Partners are replaceable by the owner (ADR-EXPANSION: guards
    ///         are set in stone, partners are maintenance hatches). Address
    ///         migration: pause() → set*() → resume() — subscriptions move
    ///         to the current fields (getPausableSubscriptions below).
    address public mailbox; // the pulse source (AlertReceived)
    address public reliefFund; // who we bark at and who feeds us; its
    // events = our balance mirror
    address public watcherAddress; // blacklist topic1 + the revival target
    uint256 public immutable watcherSilenceWindow; // blocks; > 1 heartbeat period (~22h) + margin

    /// @notice Ward-cry fast chain (ADR-v2, moved from legacy 09.11 into the
    ///         omni port): a subscription to a ward's LowGas — zero cost
    ///         while the ward is silent; a cry → a direct relay to the fund's
    ///         onWardHungry (the fund decides by real numbers, it does not
    ///         trust the cry).
    uint256 public constant WARD_LOW_GAS_TOPIC = uint256(keccak256("LowGas(uint256,uint256)"));
    address[] public wardCrySources;
    mapping(address => bool) public wardCrySubscribed;
    uint256 public immutable cron10000Topic;
    uint256 public immutable blacklistTopic;
    uint256 public immutable mailboxAlertTopic; // topic0 AlertReceived
    uint256 public immutable dogFedTopic; // topic0 DogFed(dog,uint256,uint256)
    uint256 public immutable watcherLowReserveTopic; // topic0 WatcherLowReserve(...)
    uint256 public immutable lowFundTopic; // topic0 LowFund(uint256,uint256)

    // ------------------------------------------------------------- RVM state
    /// @dev Silent patrol: the last block where a watcher alert (a mailbox
    ///      cell) was seen. No alarm before the first pulse ("no data" ≠ "dead").
    uint256 public lastPulseBlock;
    bool public pulsesSeen;

    /// @dev Balance mirror (v4.5): the latest balanceAfter from the fund's
    ///      DogFed — the only honest source (the fund's reality). Between
    ///      reports we decay by TICK_BURN: network gas charges are silent.
    uint256 public lastKnownBalance;
    bool public mirrorSeen;

    // -------------------------------------------------------------- RN state
    uint256 public barkCount; // alarms raised (RN-visible via events)

    /// @notice A watchdog alarm (isRecovery=true — the first pulse after a bark).
    ///         Financial-exhaustion barks of the watcher land here too (v4.5).
    event WatchdogAlert(uint256 lastPulseBlock, uint256 currentBlock, bool isRecovery);

    constructor(
        uint256 chainId_,
        uint256 watcherSilenceWindow_,
        address mailbox_,
        address reliefFund_,
        address watcherAddress_,
        uint256 cron10000Topic_,
        uint256 blacklistTopic_,
        uint256 mailboxAlertTopic_,
        uint256 dogFedTopic_,
        uint256 watcherLowReserveTopic_,
        uint256 lowFundTopic_
    ) payable {
        chainId = chainId_;
        watcherSilenceWindow = watcherSilenceWindow_;
        mailbox = mailbox_;
        reliefFund = reliefFund_;
        watcherAddress = watcherAddress_;
        cron10000Topic = cron10000Topic_;
        blacklistTopic = blacklistTopic_;
        mailboxAlertTopic = mailboxAlertTopic_;
        dogFedTopic = dogFedTopic_;
        watcherLowReserveTopic = watcherLowReserveTopic_;
        lowFundTopic = lowFundTopic_;
    }

    /// @notice Subscriptions — an init() tx after deploy (the v5 deploy canon).
    /// @dev Eight: (1) watcher blacklist — an instant bark; (2) mailbox
    ///      blacklist — the death of the alarm receiver; (3) fund blacklist —
    ///      the death of the feeder; (4) mailbox events — the pulse;
    ///      (5) Cron10000 — the daily tick + feeding; (6) the fund's DogFed
    ///      (topic1 = us) — balance-mirror calibration; (7) the fund's
    ///      WatcherLowReserve (topic1 = watcher) — an exhaustion bark;
    ///      (8) the fund's LowFund — an insurer-exhaustion bark.
    function init() external onlyOwner {
        SYSTEM.subscribe(
            chainId, ACCOUNTING_ANY, blacklistTopic, uint256(uint160(watcherAddress)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            chainId, ACCOUNTING_ANY, blacklistTopic, uint256(uint160(mailbox)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            chainId, ACCOUNTING_ANY, blacklistTopic, uint256(uint160(reliefFund)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(chainId, mailbox, mailboxAlertTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(
            chainId, SYSTEM_EVENTS_EMITTER, cron10000Topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            chainId, reliefFund, dogFedTopic, uint256(uint160(address(this))), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            chainId,
            reliefFund,
            watcherLowReserveTopic,
            uint256(uint160(watcherAddress)),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(chainId, reliefFund, lowFundTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        lastPulseBlock = block.number; // fix #2 (audit 27.08): no false alarm before the first pulse
    }

    /// @notice Subscribe to a ward's cry (brain/cashier/future ones):
    ///         zero cost while the ward is silent. Owner-only.
    function subscribeWardCry(address source_) external onlyOwner {
        require(source_ != address(0), "zero source");
        require(!wardCrySubscribed[source_], "already subscribed");
        wardCrySubscribed[source_] = true;
        wardCrySources.push(source_);
        SYSTEM.subscribe(chainId, source_, WARD_LOW_GAS_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function getPausableSubscriptions() internal view override returns (Subscription[] memory) {
        // Eight base + active cry ones — from the CURRENT fields:
        // pause() unsubscribes by fact, resume() subscribes anew.
        uint256 cries = wardCrySources.length;
        Subscription[] memory subs = new Subscription[](8 + cries);
        subs[0] = Subscription(
            chainId, ACCOUNTING_ANY, blacklistTopic, uint256(uint160(watcherAddress)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subs[1] = Subscription(
            chainId, ACCOUNTING_ANY, blacklistTopic, uint256(uint160(mailbox)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subs[2] = Subscription(
            chainId, ACCOUNTING_ANY, blacklistTopic, uint256(uint160(reliefFund)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subs[3] = Subscription(chainId, mailbox, mailboxAlertTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        subs[4] = Subscription(
            chainId, SYSTEM_EVENTS_EMITTER, cron10000Topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subs[5] = Subscription(
            chainId, reliefFund, dogFedTopic, uint256(uint160(address(this))), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subs[6] = Subscription(
            chainId,
            reliefFund,
            watcherLowReserveTopic,
            uint256(uint160(watcherAddress)),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        subs[7] = Subscription(chainId, reliefFund, lowFundTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        for (uint256 i = 0; i < cries; i++) {
            subs[8 + i] = Subscription(
                chainId, wardCrySources[i], WARD_LOW_GAS_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        return subs;
    }

    // ------------------------------------------------------------- RVM: react()

    function react(LogRecord calldata log_) external override onlySystem {
        uint256 t0 = log_.topic0;

        if (t0 == blacklistTopic) {
            // An instant bark: the blacklisted one is the watcher (the
            // observer's death), the mailbox (the alarm receiver's death)
            // or the fund (the feeder's death).
            address who = address(uint160(log_.topic1));
            if (who == watcherAddress || who == mailbox || who == reliefFund) {
                _bark(log_.blockNumber, false);
            }
            return;
        }
        if (t0 == mailboxAlertTopic) {
            // Pulse: any watcher alert in the mailbox = a sign of life
            // (a heartbeat of ~22h guarantees a lower bound on frequency).
            // Monotonicity (audit #3): a late-delivered pulse does not
            // rewind time.
            if (log_.blockNumber > lastPulseBlock) {
                bool wasSilent = pulsesSeen && log_.blockNumber > lastPulseBlock + watcherSilenceWindow;
                lastPulseBlock = log_.blockNumber;
                if (!pulsesSeen) {
                    pulsesSeen = true;
                } else if (wasSilent) {
                    // Recovery after a missed window: a public all-clear bark.
                    _relay(
                        address(this),
                        abi.encodeWithSignature(
                            "onBark(address,uint256,uint256,bool)",
                            address(this),
                            lastPulseBlock,
                            log_.blockNumber,
                            true
                        )
                    );
                }
            }
            return;
        }
        if (t0 == dogFedTopic) {
            // The fund's report (the mirror): DogFed(dog, amount, balanceAfter).
            // topic1 is already filtered by our address, but we re-check in
            // the data — data is more reliable.
            (address who,, uint256 balanceAfter) = abi.decode(log_.data, (address, uint256, uint256));
            if (who == address(this)) {
                lastKnownBalance = balanceAfter;
                mirrorSeen = true;
            }
            return;
        }
        if (t0 == watcherLowReserveTopic) {
            // The fund's eyes saw the watcher starving — our voice: a public bark.
            _bark(log_.blockNumber, false);
            return;
        }
        if (t0 == lowFundTopic) {
            // The insurer is empty — a public bark WITHOUT onRevive (the
            // fund is alive, there is nothing to revive; the signal is for
            // a human: top up the ReliefFund). A hungry dog does not fall
            // silent by itself: LowFund repeats on every feeding tick while
            // the reserve is below the floor.
            _relay(
                address(this),
                abi.encodeWithSignature(
                    "onBark(address,uint256,uint256,bool)", address(this), lastPulseBlock, log_.blockNumber, false
                )
            );
            return;
        }
        if (t0 == WARD_LOW_GAS_TOPIC) {
            // A ward's cry → a direct relay to the fund: onWardHungry(the
            // watchdog, the crying emitter). The fund does not trust cries —
            // only numbers.
            _relay(
                reliefFund,
                abi.encodeWithSignature("onWardHungry(address,address)", address(this), log_.contractAddress)
            );
            return;
        }

        if (t0 == cron10000Topic) {
            // The daily tick: silence > window → a bark + wake the fund
            // (self-healing). Then feeding by the mirror ("one recipient per
            // tick": when barking, we do not duplicate).
            bool barked = false;
            if (pulsesSeen && log_.blockNumber > lastPulseBlock + watcherSilenceWindow) {
                _bark(log_.blockNumber, false);
                barked = true;
            }
            if (!barked) {
                _askForFood();
            }
            return;
        }
    }

    // --------------------------------------------------------------- internals

    /// @dev A bark: (1) wake the fund — revive the watcher (a top-up +
    ///      coverDebt with its own money); (2) a public WatchdogAlert event
    ///      through a direct self-call. v6.1 (RCA 30.10): platform callback
    ///      queues are not posted for new contracts — the relay is direct
    ///      from react() (proven by the A1L-v3 probe).
    function _bark(uint256 blockNumber_, bool instant_) private {
        instant_; // both barks are published the same way — the context is in the block
        _relay(
            reliefFund,
            abi.encodeWithSignature("onRevive(address,address,uint256)", address(this), watcherAddress, 0.3 ether)
        );
        _relay(
            address(this),
            abi.encodeWithSignature(
                "onBark(address,uint256,uint256,bool)", address(this), lastPulseBlock, blockNumber_, false
            )
        );
    }

    /// @dev v6.1: direct delivery (single-env). The rvm slot = address(this).
    ///      A recipient's failure reverts the reaction — loud is better
    ///      than a silent death.
    function _relay(address recipient_, bytes memory payload_) private {
        (bool ok,) = recipient_.call(payload_);
        require(ok, "direct relay failed");
    }

    /// @dev An honest feeding request: decay the mirror by the conservative
    ///      per-tick burn and ask for a ration if the latest data says we
    ///      are hungry. The fund will re-check for real and answer
    ///      DogFed(..., balanceAfter) — the mirror is honest again
    ///      (including the answer "sated, 0"). Before the first report we
    ///      ask: the pot must be filled in advance (a one-shot bootstrap).
    function _askForFood() private {
        if (mirrorSeen) {
            lastKnownBalance = lastKnownBalance > TICK_BURN ? lastKnownBalance - TICK_BURN : 0;
        }
        if (!mirrorSeen || lastKnownBalance < DOG_FEED_BELOW) {
            _relay(
                reliefFund,
                abi.encodeWithSignature("onFeedDog(address,address,uint256)", address(this), address(this), 0)
            );
        }
    }

    // --------------------------------------------------------- RN: callbacks

    /// @dev A public bark: the WatchdogAlert event + a counter. v6.1: a
    ///      DIRECT self-call from react() (the rvm_ slot = the Watchdog
    ///      itself); the platform callback (0x8888) remains as a second
    ///      legal path. isRecovery=true — the first pulse after a bark.
    function onBark(address rvm_, uint256 lastPulse_, uint256 blockNumber_, bool isRecovery_) external {
        require(msg.sender == address(SYSTEM) || msg.sender == address(this), "callback sender only");
        require(rvm_ == address(this), "self callback only");
        barkCount += 1;
        emit WatchdogAlert(lastPulse_, blockNumber_, isRecovery_);
    }

    // ------------------------------------------------------------------ owner

    /// @notice Partner hatches (ADR-EXPANSION): the owner changes an address
    ///         without a redeploy; subscription migration is pause() →
    ///         set*() → resume(). The zero address is forbidden; every
    ///         change emits an event.
    event PartnerRewired(string indexed role, address indexed from, address to);

    function setMailbox(address mailbox_) external onlyOwner {
        require(mailbox_ != address(0), "zero address");
        emit PartnerRewired("mailbox", mailbox, mailbox_);
        mailbox = mailbox_;
    }

    function setReliefFund(address reliefFund_) external onlyOwner {
        require(reliefFund_ != address(0), "zero address");
        emit PartnerRewired("reliefFund", reliefFund, reliefFund_);
        reliefFund = reliefFund_;
    }

    function setWatcherAddress(address watcherAddress_) external onlyOwner {
        require(watcherAddress_ != address(0), "zero address");
        emit PartnerRewired("watcher", watcherAddress, watcherAddress_);
        watcherAddress = watcherAddress_;
    }

    /// @notice Owner withdrawal of the EXCESS over the untouchable floor
    ///         (debt + DOG_FEED_BELOW). Lesson v4.3: rations piled up on
    ///         the contract with no withdrawal method — ~0.55 REACT frozen
    ///         forever. The excess may be taken; starving the dog to zero
    ///         (and into the blacklist) is impossible: the floor always
    ///         stays for life.
    function withdrawExcess(address to_) external onlyOwner {
        uint256 debt = _debtOf(address(this));
        uint256 bal = address(this).balance;
        uint256 floor = debt + DOG_FEED_BELOW;
        uint256 amount = bal > floor ? bal - floor : 0;
        require(amount > 0, "no excess");
        (bool ok,) = to_.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    /// @dev debts(address) on SYSTEM (0x8888) — the signatures are alive (checked 16.10).
    function _debtOf(address who_) private view returns (uint256) {
        (bool ok, bytes memory ret) = address(SYSTEM).staticcall(abi.encodeWithSignature("debts(address)", who_));
        return (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 0;
    }
}
