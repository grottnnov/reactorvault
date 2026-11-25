// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {GuardMsg} from "./IGuardVault.sol";

/// @title RulesEngine — the brain (ADR-v2 + ADR-EXPANSION)
/// @notice Product logic ONLY: "if X → ACT" rules, callbacks into the
///         Executor. A rule is keyed by (origin chainId, topic0) so the
///         same event signature from two chains (Chainlink feeds on
///         Sepolia vs Robinhood, Aave events on Sepolia vs Base Sepolia)
///         stays two independent rules. The callback destination chain
///         is configured data, not a code constant — a per-chain
///         Executor instance is the expansion path (ADR-EXPANSION §3).
///         Cash-handling lives elsewhere, not here (P3 canon: mechanics
///         ≠ product; pay-on-delivery billing is the executor's job,
///         ADR-GAS-ARCHITECTURE). Free eyes on its own lREACT tank in
///         every react() + a LowGas cry. Idempotency: a processed-set
///         of (chainId, blockNumber, topic0). P10: noDelegateCall on
///         owner entry points.
contract RulesEngine is AbstractReactive {
    /// @dev The heaviest callback in the system is the alarm rebalance:
    ///      a full pool move measured 796k live (Aave supply with rewards
    ///      accrual dominates). The delivery proxy keeps ~200k of the
    ///      budget for itself (live 11.11: 900k budget → ~705k reached
    ///      the call → revert swallowed by the proxy). 1.2M leaves the
    ///      call ~1M — headroom for market-state variance.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_200_000;

    address public owner;

    /// @notice v2 (chain universality, directive 17.11): every rule
    ///         carries ITS OWN destination chain, executors are a
    ///         "destChainId → address" registry. A new network =
    ///         setExecutor(chain, addr) + a rule with destChain=chain.
    ///         Not a single chain in code.
    mapping(uint256 => address) public executors;

    /// @notice Subscription source chain (set at initialize) and the
    ///         DEFAULT destination chain for rules (per-rule overrides).
    uint256 public sourceChainId;
    uint256 public destChainId;

    bool public initialized;

    struct Rule {
        bool active;
        uint64 cooldown;
        uint64 lastFiredAt;
        uint256 destChainId;
    }

    /// @dev Rule key = keccak256(origin chainId ‖ topic0). Two chains
    ///      emitting the same topic0 → two keys, two cooldowns.
    mapping(bytes32 => Rule) public rules;
    uint256 public firedCount;

    uint256 public gasLowThresholdWei;
    uint256 public gasRefillTargetWei;
    bool public gasAlertArmed = true;

    /// @dev Idempotency (UF §14: duplicate deliveries are the norm):
    ///      one (chainId, emitter, blockNumber, topic0) → one firing.
    ///      The emitter is part of the key since the guard vertical
    ///      (ADR-GUARD-RULES §6): every stock has its own feed on the
    ///      same chain with the SAME AnswerUpdated topic — without the
    ///      emitter two feeds in one block would swallow each other.
    mapping(bytes32 => bool) public processed;

    // ------------------------------------------------------------------
    // Guard vertical (ADR-GUARD-RULES, 25.11): the brain keeps the
    // price HISTORY (anchor = max(entry, high-water mark)) and fires
    // typed guardAction callbacks; the executor re-verifies NOW.
    // ------------------------------------------------------------------

    /// @dev 3-arg AnswerUpdated topic0 (canon: subscribe to the
    ///      emitter aggregator, never the proxy).
    uint256 public constant ANSWER_UPDATED_TOPIC = 0x0559884fd3a460db3073b7fc96cc77986f16e378210ded43186175bf646fc5f;

    uint8 public constant GUARD_TRIM = 1;
    uint8 public constant GUARD_EXIT = 2;
    uint8 public constant GUARD_REBUY = 3;
    uint8 public constant GUARD_PAUSE = 4;
    uint8 public constant GUARD_RESUME = 5;

    /// @notice One guard rule per feed. The anchor (max(entryRef, hwm))
    ///         gives BOTH capital protection (hwm ≈ entry early) and
    ///         the trailing floor (the anchor follows the high). The
    ///         ladder: warn → trim to target share; mid → exit half;
    ///         hard → exit all. Deepening bypasses the cooldown; the
    ///         cooldown guards the rebuy flap; the vault band no-ops
    ///         bound the trim-rebuy cycle.
    struct GuardRule {
        bool active;
        address feed; // the Chainlink emitter on the origin chain
        address asset; // the stock token inside the guard safe
        uint256 destChainId;
        uint64 warnBps; // rung 1: trim
        uint64 midBps; // rung 2: exit 50%
        uint64 hardBps; // rung 3: exit 100%
        uint64 targetBps;
        uint64 bandBps;
        uint64 maxStaleSec;
        uint64 cooldown;
        uint64 lastFiredAt;
        uint256 entryRef;
        uint256 hwm;
        uint256 lastUpdateTs;
        uint8 rung;
        bool paused;
    }

    /// @dev Guard key = keccak256(origin chainId ‖ feed emitter).
    ///      INTERNAL on purpose: the auto-generated getter of a
    ///      17-field struct hits the stack limit — the narrow views
    ///      below are the public surface (tests, sensor, landing).
    mapping(bytes32 => GuardRule) internal guardRules;
    bytes32[] public guardFeedList;

    /// @dev The full policy is readable via guardRules(key) + the
    ///      narrow views; the event carries the identity only.
    event GuardRuleSet(bytes32 indexed key, uint256 chainId, address feed, address asset, uint256 entryRef);
    event GuardFired(uint8 kind, address indexed feed, uint256 chainId, uint256 price, uint256 anchor, uint8 rung);
    event GuardStale(address indexed feed, uint256 lastUpdateTs, uint256 age);

    error BadGuardParams();

    /// @dev P10: immutable against delegatecall.
    address private immutable _original;

    event RuleSet(bytes32 indexed key, uint256 chainId, uint256 topic0, bool active, uint64 cooldown);
    event RuleFired(uint256 indexed topic0, uint256 originChainId, uint256 originBlockNumber);
    event Subscribed(uint256 chainId, address indexed origin, uint256 topic0);
    event LowGas(uint256 balance, uint256 target);

    error NotOwner();
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error BadGasParams();
    error DelegateCallNotAllowed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier noDelegateCall() {
        if (address(this) != _original) revert DelegateCallNotAllowed();
        _;
    }

    constructor() {
        owner = msg.sender;
        _original = address(this);
    }

    function ruleKey(uint256 chainId_, uint256 topic0_) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId_, topic0_));
    }

    function guardKey(uint256 chainId_, address feed_) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId_, feed_));
    }

    /// @notice Owner-facing policy of one guard rule (calldata struct:
    ///         one argument instead of twelve — stack and readability).
    struct GuardPolicy {
        uint256 chainId; // origin (the feed's chain)
        address feed; // the Chainlink emitter
        address asset; // the stock token inside the guard safe
        uint256 destChainId; // the executor's chain
        uint256 entryRef; // feed-decimals reference at setup
        uint64 warnBps; // rung 1: trim to target share
        uint64 midBps; // rung 2: exit 50%
        uint64 hardBps; // rung 3: exit 100%
        uint64 targetBps;
        uint64 bandBps;
        uint64 maxStaleSec;
        uint64 cooldown; // rebuy flap guard
    }

    /// @notice Configure + subscribe a guard rule. Requires a wired
    ///         executor on the destination chain (a subscription
    ///         without a callback destination would waste paid
    ///         deliveries). Re-setting resets the price state.
    function setGuardRule(GuardPolicy calldata p_) external onlyOwner noDelegateCall {
        if (!initialized) revert NotInitialized();
        if (executors[p_.destChainId] == address(0)) revert ZeroAddress();
        if (p_.entryRef == 0) revert BadGuardParams();
        if (!(p_.warnBps > 0 && p_.warnBps < p_.midBps && p_.midBps < p_.hardBps && p_.hardBps <= 10_000)) {
            revert BadGuardParams();
        }
        if (p_.targetBps > 10_000 || p_.bandBps >= p_.targetBps) revert BadGuardParams();

        bytes32 key = guardKey(p_.chainId, p_.feed);
        GuardRule storage g = guardRules[key];
        if (!g.active) {
            guardFeedList.push(key);
        }
        g.active = true;
        g.feed = p_.feed;
        g.asset = p_.asset;
        g.destChainId = p_.destChainId;
        g.warnBps = p_.warnBps;
        g.midBps = p_.midBps;
        g.hardBps = p_.hardBps;
        g.targetBps = p_.targetBps;
        g.bandBps = p_.bandBps;
        g.maxStaleSec = p_.maxStaleSec;
        g.cooldown = p_.cooldown;
        g.lastFiredAt = 0;
        g.entryRef = p_.entryRef;
        g.hwm = p_.entryRef; // the anchor starts at entry
        g.lastUpdateTs = 0;
        g.rung = 0;
        g.paused = false;

        SYSTEM.subscribe(p_.chainId, p_.feed, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit GuardRuleSet(key, p_.chainId, p_.feed, p_.asset, p_.entryRef);
    }

    // Narrow views (the sensor and the landing feed read these; tests
    // avoid the 17-field tuple destructure).
    function guardHwmOf(uint256 chainId_, address feed_) external view returns (uint256) {
        return guardRules[guardKey(chainId_, feed_)].hwm;
    }

    function guardRungOf(uint256 chainId_, address feed_) external view returns (uint8) {
        return guardRules[guardKey(chainId_, feed_)].rung;
    }

    function guardPausedOf(uint256 chainId_, address feed_) external view returns (bool) {
        return guardRules[guardKey(chainId_, feed_)].paused;
    }

    function guardLastUpdateOf(uint256 chainId_, address feed_) external view returns (uint256) {
        return guardRules[guardKey(chainId_, feed_)].lastUpdateTs;
    }

    function guardActiveOf(uint256 chainId_, address feed_) external view returns (bool) {
        return guardRules[guardKey(chainId_, feed_)].active;
    }

    function guardConfigOf(uint256 chainId_, address feed_)
        external
        view
        returns (
            address asset,
            uint256 destChainId,
            uint64 warnBps,
            uint64 midBps,
            uint64 hardBps,
            uint64 targetBps,
            uint64 bandBps,
            uint64 maxStaleSec,
            uint64 cooldown
        )
    {
        GuardRule storage g = guardRules[guardKey(chainId_, feed_)];
        return
            (g.asset, g.destChainId, g.warnBps, g.midBps, g.hardBps, g.targetBps, g.bandBps, g.maxStaleSec, g.cooldown);
    }

    function initialize(
        address origin_,
        uint256 sourceChainId_,
        uint256 rateChangeTopic_,
        address executor_,
        uint256 destChainId_,
        uint64 cooldown_
    ) external onlyOwner noDelegateCall {
        if (initialized) revert AlreadyInitialized();
        if (executor_ == address(0)) revert ZeroAddress();
        initialized = true;
        executors[destChainId_] = executor_;
        sourceChainId = sourceChainId_;
        destChainId = destChainId_;
        rules[ruleKey(sourceChainId_, rateChangeTopic_)] =
            Rule({active: true, cooldown: cooldown_, lastFiredAt: 0, destChainId: destChainId_});
        SYSTEM.subscribe(sourceChainId_, origin_, rateChangeTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit Subscribed(sourceChainId_, origin_, rateChangeTopic_);
    }

    function setRule(uint256 chainId_, uint256 topic0_, bool active_, uint64 cooldown_, uint256 destChainId_)
        external
        onlyOwner
        noDelegateCall
    {
        rules[ruleKey(chainId_, topic0_)] =
            Rule({active: active_, cooldown: cooldown_, lastFiredAt: 0, destChainId: destChainId_});
        emit RuleSet(ruleKey(chainId_, topic0_), chainId_, topic0_, active_, cooldown_);
    }

    /// @notice The executor registry: destination chain → the instance on it.
    event ExecutorSet(uint256 indexed destChainId, address executor);

    function setExecutor(uint256 destChainId_, address executor_) external onlyOwner noDelegateCall {
        if (executor_ == address(0)) revert ZeroAddress();
        executors[destChainId_] = executor_;
        emit ExecutorSet(destChainId_, executor_);
    }

    /// @notice Point the network at an emitter of an already-set rule.
    ///         initialize wires only the FIRST rule; the alarm-clock
    ///         rule (the cron emitter, W2.2) arrives this way — the
    ///         live W2.1 brain lacked this hatch and had to be
    ///         redeployed for it. Requires initialization: a
    ///         subscription without a callback destination would waste
    ///         paid deliveries.
    function subscribe(uint256 chainId_, address origin_, uint256 topic0_) external onlyOwner noDelegateCall {
        if (!initialized) revert NotInitialized();
        SYSTEM.subscribe(chainId_, origin_, topic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit Subscribed(chainId_, origin_, topic0_);
    }

    /// @notice The default destination chain (ADR-EXPANSION §1).
    function setDestChain(uint256 destChainId_) external onlyOwner noDelegateCall {
        destChainId = destChainId_;
    }

    /// @notice Cry threshold: half the depot patrol floor (a safety net
    ///         that fires only when patrols were missed — see ADR-v2).
    function setGasAlert(uint256 thresholdWei_, uint256 targetWei_) external onlyOwner noDelegateCall {
        if (targetWei_ <= thresholdWei_) revert BadGasParams();
        gasLowThresholdWei = thresholdWei_;
        gasRefillTargetWei = targetWei_;
        gasAlertArmed = true;
    }

    function _checkGasEdge() private {
        if (gasLowThresholdWei == 0) {
            return;
        }
        if (!gasAlertArmed) {
            if (address(this).balance >= gasRefillTargetWei) {
                gasAlertArmed = true;
            }
        }
        if (gasAlertArmed && address(this).balance < gasLowThresholdWei) {
            gasAlertArmed = false;
            emit LowGas(address(this).balance, gasRefillTargetWei);
        }
    }

    /// @dev Delivery semantics (judge review 22.11): a `processed` mark is
    ///      written for every consumed event — including one absorbed by an
    ///      inactive rule or by the cooldown. Rules are repeatable sources
    ///      (cron re-emits, alerts re-fire), so an absorbed event is not a
    ///      loss; one-shot rules would need a queue and are out of MVP
    ///      scope. The cooldown, however, only starts counting on a REAL
    ///      fire: an unwired destination chain never burns it.
    ///      Guard vertical: a feed event is consumed by the guard path
    ///      (answer sanity → history → rungs); every other event runs
    ///      the staleness patrol first, then the generic path.
    function react(LogRecord calldata log_) external override onlySystem {
        _checkGasEdge();
        bytes32 key = keccak256(abi.encodePacked(log_.chainId, log_.contractAddress, log_.blockNumber, log_.topic0));
        if (processed[key]) {
            return;
        }
        processed[key] = true;

        if (log_.topic0 == ANSWER_UPDATED_TOPIC) {
            GuardRule storage g = guardRules[guardKey(log_.chainId, log_.contractAddress)];
            if (g.active) {
                _guardEvaluate(g, log_);
                return;
            }
        }
        _checkGuardStaleness();

        Rule storage rule = rules[ruleKey(log_.chainId, log_.topic0)];
        if (!rule.active) {
            return;
        }
        if (uint64(block.timestamp) < rule.lastFiredAt + rule.cooldown) {
            return;
        }
        address executor = executors[rule.destChainId];
        if (executor == address(0)) {
            return; // destination chain not wired — the rule stays silent, the cooldown is NOT burned
        }
        rule.lastFiredAt = uint64(block.timestamp);
        firedCount += 1;
        emit RuleFired(log_.topic0, log_.chainId, log_.blockNumber);
        bytes memory payload = abi.encodeWithSignature("rebalance(address,uint256)", address(0), log_.blockNumber);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: rule.destChainId, recipient: executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }

    // ------------------------------------------------------------------
    // Guard internals (ADR-GUARD-RULES)
    // ------------------------------------------------------------------

    /// @dev AnswerUpdated(int256 current, uint256 roundId, uint256
    ///      updatedAt) — the 3-arg canon. Sanity first (answer > 0),
    ///      then history (hwm, lastUpdate), then the ladder.
    function _guardEvaluate(GuardRule storage g, LogRecord calldata log_) private {
        (int256 current,, uint256 updatedAt) = abi.decode(log_.data, (int256, uint256, uint256));
        if (current <= 0) {
            return; // sanity canon: a bad answer never touches the state
        }
        uint256 price = uint256(current);
        if (price > g.hwm) {
            g.hwm = price;
        }
        g.lastUpdateTs = updatedAt;

        if (g.paused) {
            g.paused = false;
            _fireGuard(g, GUARD_RESUME, 0, 0, 0, log_.blockNumber);
        }

        uint256 anchor = g.hwm > g.entryRef ? g.hwm : g.entryRef;
        uint8 rung = _rungOf(g, anchor, price);

        if (rung > g.rung) {
            // Deepening (or first crossing): fires regardless of the
            // cooldown — worse news does not wait (ADR-GUARD-RULES §4).
            if (rung == 1) {
                emit GuardFired(GUARD_TRIM, g.feed, log_.chainId, price, anchor, rung);
                _fireGuard(g, GUARD_TRIM, g.targetBps, g.bandBps, _pct(anchor, 10_000 - g.warnBps), log_.blockNumber);
            } else if (rung == 2) {
                emit GuardFired(GUARD_EXIT, g.feed, log_.chainId, price, anchor, rung);
                _fireGuard(g, GUARD_EXIT, 5_000, 0, _pct(anchor, 10_000 - g.midBps), log_.blockNumber);
            } else {
                emit GuardFired(GUARD_EXIT, g.feed, log_.chainId, price, anchor, rung);
                _fireGuard(g, GUARD_EXIT, 10_000, 0, _pct(anchor, 10_000 - g.hardBps), log_.blockNumber);
            }
            g.rung = rung;
            g.lastFiredAt = uint64(block.timestamp);
        } else if (rung == 0 && g.rung > 0) {
            // Full recovery above warn: the rebuy gate, cooldown-gated
            // (flap guard). The vault no-ops inside the band, so the
            // trim-rebuy cycle is bounded by the band, not the price.
            if (uint64(block.timestamp) >= g.lastFiredAt + g.cooldown) {
                emit GuardFired(GUARD_REBUY, g.feed, log_.chainId, price, anchor, 0);
                _fireGuard(g, GUARD_REBUY, g.targetBps, g.bandBps, 0, log_.blockNumber);
                g.rung = 0;
                g.lastFiredAt = uint64(block.timestamp);
            }
        }
    }

    /// @dev Staleness patrol: runs on any non-feed event (the cron
    ///      ladder of the destination networks). One PAUSE per stale
    ///      episode; the fresh AnswerUpdated resumes.
    function _checkGuardStaleness() private {
        uint256 n = guardFeedList.length;
        if (n == 0) {
            return;
        }
        for (uint256 i = 0; i < n; i++) {
            GuardRule storage g = guardRules[guardFeedList[i]];
            if (!g.active || g.paused || g.lastUpdateTs == 0) {
                continue;
            }
            uint256 age = block.timestamp - g.lastUpdateTs;
            if (age > g.maxStaleSec) {
                g.paused = true;
                emit GuardStale(g.feed, g.lastUpdateTs, age);
                _fireGuard(g, GUARD_PAUSE, 0, 0, 0, block.number);
            }
        }
    }

    function _rungOf(GuardRule storage g, uint256 anchor, uint256 price) private view returns (uint8) {
        // anchor ≥ price always (hwm was just updated), so no underflow
        uint256 dd = (anchor - price) * 10_000 / anchor;
        if (dd >= g.hardBps) return 3;
        if (dd >= g.midBps) return 2;
        if (dd >= g.warnBps) return 1;
        return 0;
    }

    function _pct(uint256 value, uint256 bps) private pure returns (uint256) {
        return value * bps / 10_000;
    }

    function _fireGuard(
        GuardRule storage g,
        uint8 kind,
        uint256 param,
        uint256 param2,
        uint256 bound,
        uint256 originBlockNumber
    ) private {
        address executor = executors[g.destChainId];
        if (executor == address(0)) {
            return; // not wired — silent (the state machine already advanced)
        }
        // One stack slot instead of eight arguments (GuardMsg):
        // the byte layout equals the flat encoding, so the network's
        // first-payload-slot substitution (the sender) is untouched.
        GuardMsg memory m;
        m.sender = address(0); // replaced by the delivery network
        m.feed = g.feed;
        m.asset = g.asset;
        m.kind = kind;
        m.param = param;
        m.param2 = param2;
        m.bound = bound;
        m.originBlockNumber = originBlockNumber;
        bytes memory payload =
            abi.encodeWithSignature("guardAction((address,address,address,uint8,uint256,uint256,uint256,uint256))", m);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: g.destChainId, recipient: executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }
}
