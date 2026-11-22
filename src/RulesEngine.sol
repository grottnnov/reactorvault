// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @title RulesEngine — the brain (ADR-v2 + ADR-EXPANSION)
/// @notice Product logic ONLY: "if X → ACT" rules, callbacks into the
///         Executor. A rule is keyed by (origin chainId, topic0) so the
///         same event signature from two chains (Chainlink feeds on
///         Sepolia vs Robinhood, Aave events on Sepolia vs Base Sepolia)
///         stays two independent rules. The callback destination chain
///         is configured data, not a code constant — a per-chain
///         Executor instance is the expansion path (ADR-EXPANSION §3).
///         Cash-handling lives in the cashier (GasPayer), not here (P3
///         canon: mechanics ≠ product). Free eyes on its own lREACT
///         tank in every react() + a LowGas cry. Idempotency: a
///         processed-set of (chainId, blockNumber, topic0). P10:
///         noDelegateCall on owner entry points.
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
    ///      one (chainId, blockNumber, topic0) → one rule firing.
    mapping(bytes32 => bool) public processed;

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

    function react(LogRecord calldata log_) external override onlySystem {
        _checkGasEdge();
        bytes32 key = keccak256(abi.encodePacked(log_.chainId, log_.blockNumber, log_.topic0));
        if (processed[key]) {
            return;
        }
        processed[key] = true;
        Rule storage rule = rules[ruleKey(log_.chainId, log_.topic0)];
        if (!rule.active) {
            return;
        }
        if (uint64(block.timestamp) < rule.lastFiredAt + rule.cooldown) {
            return;
        }
        rule.lastFiredAt = uint64(block.timestamp);
        address executor = executors[rule.destChainId];
        if (executor == address(0)) {
            return; // destination chain not wired — the rule stays silent
        }
        firedCount += 1;
        emit RuleFired(log_.topic0, log_.chainId, log_.blockNumber);
        bytes memory payload = abi.encodeWithSignature("rebalance(address,uint256)", address(0), log_.blockNumber);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: rule.destChainId, recipient: executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }
}
