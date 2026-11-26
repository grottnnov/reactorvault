// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {GuardItem} from "./IGuardVault.sol";

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
    // Guard vertical (ADR-GUARD-RULES, 25.11; multi-client D-2611-3):
    // the brain keeps the price HISTORY per client (anchor = max(entry,
    // high-water mark SINCE ARMING) and fires ONE batched guardAction
    // callback per event; the executor re-verifies NOW. Freshness and
    // pause are FEED-level (properties of the feed, not the client);
    // the anchor, rung and cooldown are CLIENT-level (each client
    // entered at its own price and time).
    // ------------------------------------------------------------------

    /// @dev 3-arg AnswerUpdated topic0 (canon: subscribe to the
    ///      emitter aggregator, never the proxy).
    uint256 public constant ANSWER_UPDATED_TOPIC = 0x0559884fd3a460db3073b7fc96cc77986f16e378210ded43186175bf646fc5f;

    /// @dev GuardSafeCreated(client indexed, vault indexed, asset
    ///      indexed, feed, level, entryRef, warnBps, midBps, hardBps,
    ///      targetBps, bandBps, cooldown, maxStaleSec) — the factory's
    ///      onboarding event on the destination chain. The brain reacts
    ///      to it and arms the client rule by itself: a client (human
    ///      or agent) creates a safe on-chain and the guard turns on —
    ///      no operator in the loop.
    uint256 public constant GUARD_SAFE_CREATED_TOPIC = uint256(
        keccak256(
            "GuardSafeCreated(address,address,address,address,uint8,uint256,uint64,uint64,uint64,uint64,uint64,uint64,uint64)"
        )
    );

    uint8 public constant GUARD_TRIM = 1;
    uint8 public constant GUARD_EXIT = 2;
    uint8 public constant GUARD_REBUY = 3;
    uint8 public constant GUARD_PAUSE = 4;
    uint8 public constant GUARD_RESUME = 5;

    /// @notice FEED-level record: liveness, pause, routing, clients.
    struct GuardFeed {
        bool active; // at least one armed client
        address feed; // the Chainlink emitter on the origin chain
        address asset; // the stock token (one feed = one asset)
        uint256 destChainId;
        uint256 lastUpdateTs; // freshness patrol input
        bool paused;
        bytes32[] clients; // armed client keys
    }

    /// @notice CLIENT-level rule: policy + own price history.
    struct GuardClient {
        bool active;
        address vault; // the client's guard safe on the destination chain
        address asset;
        uint256 destChainId;
        uint256 entryRef; // the client's entry price (feed decimals)
        uint64 warnBps; // rung 1: trim
        uint64 midBps; // rung 2: exit 50%
        uint64 hardBps; // rung 3: exit 100%
        uint64 targetBps;
        uint64 bandBps;
        uint64 maxStaleSec;
        uint64 cooldown;
        uint64 lastFiredAt;
        uint256 hwm; // high-water mark SINCE ARMING (per client)
        uint8 rung;
    }

    /// @dev Feed key = keccak256(origin chainId ‖ feed emitter); client
    ///      key = keccak256(feed key ‖ vault). INTERNAL on purpose: the
    ///      auto-generated getters of wide structs hit the stack limit —
    ///      the narrow views below are the public surface.
    mapping(bytes32 => GuardFeed) internal guardFeeds;
    bytes32[] public guardFeedList;
    mapping(bytes32 => GuardClient) internal guardClients;

    /// @dev Origin chain → the guard safe factory whose onboarding
    ///      events arm client rules (reactive self-service).
    mapping(uint256 => address) public guardFactories;

    /// @dev The full policy is readable via the narrow views; the
    ///      event carries the identity only.
    event GuardClientSet(
        bytes32 indexed key, uint256 chainId, address feed, address vault, address asset, uint256 entryRef
    );
    event GuardFactorySet(uint256 indexed chainId, address factory);
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

    /// @notice Owner-facing policy of one client rule (calldata struct:
    ///         one argument instead of thirteen — stack and readability).
    struct GuardPolicy {
        uint256 chainId; // origin (the feed's chain)
        address feed; // the Chainlink emitter
        address asset; // the stock token inside the guard safe
        address vault; // the client's guard safe on the destination chain
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

    /// @notice Operator path: arm (or re-set) one client rule. Requires
    ///         a wired executor on the destination chain (a subscription
    ///         without a callback destination would waste paid
    ///         deliveries). Re-setting resets the client's price state
    ///         and never duplicates the client list. The self-service
    ///         twin is the factory's GuardSafeCreated event.
    function setGuardRule(GuardPolicy calldata p_) external onlyOwner noDelegateCall {
        if (!initialized) revert NotInitialized();
        _armClient(p_);
    }

    /// @notice Wire the guard safe factory: its GuardSafeCreated events
    ///         on that chain arm client rules by themselves. One static
    ///         subscription, whatever the client flow.
    function setGuardFactory(uint256 chainId_, address factory_) external onlyOwner noDelegateCall {
        if (!initialized) revert NotInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        if (executors[chainId_] == address(0)) revert ZeroAddress();
        guardFactories[chainId_] = factory_;
        SYSTEM.subscribe(
            chainId_, factory_, GUARD_SAFE_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit GuardFactorySet(chainId_, factory_);
    }

    /// @dev The shared arming path (operator and reactive onboarding).
    ///      Feed record + one-time subscription; client record keyed by
    ///      (feed, vault); the client list grows on NEW vaults only.
    function _armClient(GuardPolicy memory p_) private {
        if (executors[p_.destChainId] == address(0)) revert ZeroAddress();
        if (p_.entryRef == 0 || p_.vault == address(0) || p_.feed == address(0) || p_.asset == address(0)) {
            revert BadGuardParams();
        }
        if (!(p_.warnBps > 0 && p_.warnBps < p_.midBps && p_.midBps < p_.hardBps && p_.hardBps <= 10_000)) {
            revert BadGuardParams();
        }
        if (p_.targetBps > 10_000 || p_.bandBps >= p_.targetBps) revert BadGuardParams();

        bytes32 fkey = guardKey(p_.chainId, p_.feed);
        GuardFeed storage f = guardFeeds[fkey];
        if (!f.active) {
            f.active = true;
            f.feed = p_.feed;
            f.asset = p_.asset;
            f.destChainId = p_.destChainId;
            guardFeedList.push(fkey);
            SYSTEM.subscribe(
                p_.chainId, p_.feed, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }

        bytes32 ckey = clientKey(fkey, p_.vault);
        GuardClient storage c = guardClients[ckey];
        if (!c.active) {
            f.clients.push(ckey);
        }
        c.active = true;
        c.vault = p_.vault;
        c.asset = p_.asset;
        c.destChainId = p_.destChainId;
        c.warnBps = p_.warnBps;
        c.midBps = p_.midBps;
        c.hardBps = p_.hardBps;
        c.targetBps = p_.targetBps;
        c.bandBps = p_.bandBps;
        c.maxStaleSec = p_.maxStaleSec;
        c.cooldown = p_.cooldown;
        c.lastFiredAt = 0;
        c.entryRef = p_.entryRef;
        c.hwm = p_.entryRef; // the anchor starts at entry
        c.rung = 0;
        emit GuardClientSet(ckey, p_.chainId, p_.feed, p_.vault, p_.asset, p_.entryRef);
    }

    /// @dev Client key: (feed key, vault). A client re-creating their
    ///      safe gets a NEW vault address = a new rule; a re-broadcast
    ///      onboarding for the SAME vault re-sets it (idempotent).
    function clientKey(bytes32 feedKey_, address vault_) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(feedKey_, vault_));
    }

    // Narrow views (the sensor and the landing feed read these; tests
    // avoid wide tuple destructures).
    function guardHwmOf(uint256 chainId_, address feed_, address vault_) external view returns (uint256) {
        bytes32 ckey = clientKey(guardKey(chainId_, feed_), vault_);
        return guardClients[ckey].hwm;
    }

    function guardRungOf(uint256 chainId_, address feed_, address vault_) external view returns (uint8) {
        bytes32 ckey = clientKey(guardKey(chainId_, feed_), vault_);
        return guardClients[ckey].rung;
    }

    function guardClientActiveOf(uint256 chainId_, address feed_, address vault_) external view returns (bool) {
        bytes32 ckey = clientKey(guardKey(chainId_, feed_), vault_);
        return guardClients[ckey].active;
    }

    function guardClientCountOf(uint256 chainId_, address feed_) external view returns (uint256) {
        return guardFeeds[guardKey(chainId_, feed_)].clients.length;
    }

    function guardPausedOf(uint256 chainId_, address feed_) external view returns (bool) {
        return guardFeeds[guardKey(chainId_, feed_)].paused;
    }

    function guardLastUpdateOf(uint256 chainId_, address feed_) external view returns (uint256) {
        return guardFeeds[guardKey(chainId_, feed_)].lastUpdateTs;
    }

    function guardActiveOf(uint256 chainId_, address feed_) external view returns (bool) {
        return guardFeeds[guardKey(chainId_, feed_)].active;
    }

    function guardClientConfigOf(uint256 chainId_, address feed_, address vault_)
        external
        view
        returns (
            address vault,
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
        bytes32 ckey = clientKey(guardKey(chainId_, feed_), vault_);
        GuardClient storage c = guardClients[ckey];
        return (
            c.vault,
            c.asset,
            c.destChainId,
            c.warnBps,
            c.midBps,
            c.hardBps,
            c.targetBps,
            c.bandBps,
            c.maxStaleSec,
            c.cooldown
        );
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
    ///      Guard vertical: a feed event runs the per-client ladder (one
    ///      batched callback per event, whatever the client count); a
    ///      factory event arms a client (reactive onboarding); every
    ///      other event runs the staleness patrol, then the generic path.
    function react(LogRecord calldata log_) external override onlySystem {
        _checkGasEdge();
        bytes32 key = keccak256(abi.encodePacked(log_.chainId, log_.contractAddress, log_.blockNumber, log_.topic0));
        if (processed[key]) {
            return;
        }
        processed[key] = true;

        if (log_.topic0 == ANSWER_UPDATED_TOPIC) {
            GuardFeed storage f = guardFeeds[guardKey(log_.chainId, log_.contractAddress)];
            if (f.active) {
                _feedEvaluate(f, log_);
                return;
            }
        }
        if (log_.topic0 == GUARD_SAFE_CREATED_TOPIC) {
            if (guardFactories[log_.chainId] == log_.contractAddress) {
                _onboardClient(log_);
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
    // Guard internals (ADR-GUARD-RULES + multi-client D-2611-3)
    // ------------------------------------------------------------------

    /// @dev AnswerUpdated(int256 current, uint256 roundId, uint256
    ///      updatedAt) — the 3-arg canon. Sanity first (answer > 0),
    ///      then the FEED bookkeeping (freshness, resume), then every
    ///      client's OWN ladder — all fired clients ride ONE batched
    ///      callback (burn independent of the client count).
    function _feedEvaluate(GuardFeed storage f, LogRecord calldata log_) private {
        (int256 current,, uint256 updatedAt) = abi.decode(log_.data, (int256, uint256, uint256));
        if (current <= 0) {
            return; // sanity canon: a bad answer never touches the state
        }
        uint256 price = uint256(current);
        f.lastUpdateTs = updatedAt;

        bool resume = f.paused;
        if (resume) {
            f.paused = false;
        }

        uint256 n = f.clients.length;
        GuardItem[] memory fired = new GuardItem[](n + 1); // + the resume slot
        uint256 k = 0;
        if (resume) {
            fired[k] = GuardItem({vault: address(0), kind: GUARD_RESUME, param: 0, param2: 0, bound: 0});
            k += 1;
        }

        for (uint256 i = 0; i < n; i++) {
            GuardClient storage c = guardClients[f.clients[i]];
            if (!c.active) {
                continue;
            }
            if (price > c.hwm) {
                c.hwm = price; // the client's OWN high since arming
            }
            uint256 anchor = c.hwm > c.entryRef ? c.hwm : c.entryRef;
            uint8 rung = _rungOf(c, anchor, price);

            if (rung > c.rung) {
                fired[k] = _fireDeepening(c, f.feed, log_.chainId, price, anchor, rung);
                k += 1;
            } else if (rung == 0 && c.rung > 0) {
                if (uint64(block.timestamp) >= c.lastFiredAt + c.cooldown) {
                    fired[k] = _fireRebuy(c, f.feed, log_.chainId, price, anchor);
                    k += 1;
                }
            }
        }

        if (k == 0) {
            return;
        }
        GuardItem[] memory items = new GuardItem[](k);
        for (uint256 i = 0; i < k; i++) {
            items[i] = fired[i];
        }
        _fireBatch(f.feed, f.asset, f.destChainId, log_.blockNumber, items);
    }

    /// @dev Deepening (or first crossing): fires regardless of the
    ///      cooldown — worse news does not wait (ADR-GUARD-RULES §4).
    ///      Own frame: keeps the evaluate loop thin.
    function _fireDeepening(
        GuardClient storage c,
        address feed_,
        uint256 chainId_,
        uint256 price,
        uint256 anchor,
        uint8 rung
    ) private returns (GuardItem memory item) {
        uint8 kind = GUARD_EXIT;
        uint256 param = 10_000;
        uint256 param2 = 0;
        uint256 bound;
        if (rung == 1) {
            kind = GUARD_TRIM;
            param = c.targetBps;
            param2 = c.bandBps;
            bound = _pct(anchor, 10_000 - c.warnBps);
        } else if (rung == 2) {
            param = 5_000;
            bound = _pct(anchor, 10_000 - c.midBps);
        } else {
            bound = _pct(anchor, 10_000 - c.hardBps);
        }
        emit GuardFired(kind, feed_, chainId_, price, anchor, rung);
        c.rung = rung;
        c.lastFiredAt = uint64(block.timestamp);
        return GuardItem({vault: c.vault, kind: kind, param: param, param2: param2, bound: bound});
    }

    /// @dev Full recovery above warn: the rebuy gate (per-client
    ///      cooldown-gated flap guard). The vault no-ops inside the
    ///      band, so the trim-rebuy cycle is bounded by the band.
    function _fireRebuy(GuardClient storage c, address feed_, uint256 chainId_, uint256 price, uint256 anchor)
        private
        returns (GuardItem memory item)
    {
        emit GuardFired(GUARD_REBUY, feed_, chainId_, price, anchor, 0);
        c.rung = 0;
        c.lastFiredAt = uint64(block.timestamp);
        return GuardItem({vault: c.vault, kind: GUARD_REBUY, param: c.targetBps, param2: c.bandBps, bound: 0});
    }

    /// @dev Reactive onboarding: the factory's GuardSafeCreated event,
    ///      decoded and armed. The destination chain IS the factory's
    ///      chain (the vault lives there). A malformed event dies
    ///      loudly (BadGuardParams) — the processed mark is already
    ///      written, so a retry needs the next event.
    function _onboardClient(LogRecord calldata log_) private {
        address vault = address(uint160(log_.topic2));
        address asset = address(uint160(log_.topic3));
        (
            address feed,
            uint8 level,
            uint256 entryRef,
            uint64 warnBps,
            uint64 midBps,
            uint64 hardBps,
            uint64 targetBps,
            uint64 bandBps,
            uint64 cooldown,
            uint64 maxStaleSec
        ) = abi.decode(log_.data, (address, uint8, uint256, uint64, uint64, uint64, uint64, uint64, uint64, uint64));
        level; // informational (the presets live in the factory); kept in
        // the event for the landing's causal feed
        GuardPolicy memory p;
        p.chainId = log_.chainId;
        p.feed = feed;
        p.asset = asset;
        p.vault = vault;
        p.destChainId = log_.chainId;
        p.entryRef = entryRef;
        p.warnBps = warnBps;
        p.midBps = midBps;
        p.hardBps = hardBps;
        p.targetBps = targetBps;
        p.bandBps = bandBps;
        p.maxStaleSec = maxStaleSec;
        p.cooldown = cooldown;
        _armClient(p);
    }

    /// @dev Staleness patrol: runs on any non-feed event (the cron
    ///      ladder of the destination networks). One PAUSE per stale
    ///      episode, feed-level; the threshold is the STRICTEST of the
    ///      armed clients' maxStaleSec (any client demanding freshness
    ///      pauses the feed). The fresh AnswerUpdated resumes.
    function _checkGuardStaleness() private {
        uint256 n = guardFeedList.length;
        if (n == 0) {
            return;
        }
        for (uint256 i = 0; i < n; i++) {
            GuardFeed storage f = guardFeeds[guardFeedList[i]];
            if (!f.active || f.paused || f.lastUpdateTs == 0) {
                continue;
            }
            uint256 maxStale = type(uint64).max;
            for (uint256 j = 0; j < f.clients.length; j++) {
                GuardClient storage c = guardClients[f.clients[j]];
                if (c.active && c.maxStaleSec < maxStale) {
                    maxStale = c.maxStaleSec;
                }
            }
            if (maxStale == type(uint64).max) {
                continue; // no armed clients
            }
            uint256 age = block.timestamp - f.lastUpdateTs;
            if (age > maxStale) {
                f.paused = true;
                emit GuardStale(f.feed, f.lastUpdateTs, age);
                GuardItem[] memory items = new GuardItem[](1);
                items[0] = GuardItem({vault: address(0), kind: GUARD_PAUSE, param: 0, param2: 0, bound: 0});
                _fireBatch(f.feed, f.asset, f.destChainId, block.number, items);
            }
        }
    }

    function _rungOf(GuardClient storage c, uint256 anchor, uint256 price) private view returns (uint8) {
        // anchor ≥ price always (hwm was just updated), so no underflow
        uint256 dd = (anchor - price) * 10_000 / anchor;
        if (dd >= c.hardBps) return 3;
        if (dd >= c.midBps) return 2;
        if (dd >= c.warnBps) return 1;
        return 0;
    }

    function _pct(uint256 value, uint256 bps) private pure returns (uint256) {
        return value * bps / 10_000;
    }

    /// @dev One batched callback per event. The wire format is FLAT:
    ///      the sender placeholder is the FIRST 32-byte slot of the
    ///      encoded args — exactly where the network's first-payload-
    ///      slot substitution writes the callback sender (W2.2 canon;
    ///      a wrapper tuple would prepend an offset word and corrupt
    ///      the substitution — caught by the red first-slot test).
    function _fireBatch(
        address feed_,
        address asset_,
        uint256 destChainId_,
        uint256 originBlockNumber_,
        GuardItem[] memory items_
    ) private {
        address executor = executors[destChainId_];
        if (executor == address(0)) {
            return; // not wired — silent (the state machine already advanced)
        }
        bytes memory payload = abi.encodeWithSignature(
            "guardAction(address,address,address,uint256,(address,uint8,uint256,uint256,uint256)[])",
            address(0), // the sender placeholder, substituted at delivery
            feed_,
            asset_,
            originBlockNumber_,
            items_
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId_, recipient: executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }
}
