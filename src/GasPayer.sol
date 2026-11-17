// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @title GasPayer v2 — the cashier (ADR-v2)
/// @notice Housekeeping service: refills the Executor's ETH tank from
///         the client's reserve (by transfer — no swap needed, the
///         reserve is native ETH). Tariff: need × margin, no price
///         feeds (dropped from the MVP). A ward of the depot: free eyes
///         on its own lREACT tank in every react() + a LowGas cry
///         (threshold at half the patrol floor — a safety net).
///         P2 fix: the reserve mirror listens to the EMITTER GasVault (the battery)
///         (GasReserveUpdated), not the executor.
///         Idempotency: a processed-set of (chainId, blockNumber, topic0).
contract GasPayer is AbstractReactive {
    /// @notice Цепь-назначения колбеков долива — параметр деплоя
    ///         (универсальность цепей, 17.11); на тестнете = 11155111.
    uint256 public immutable destChainId;
    uint64 public constant ACTION_GAS_LIMIT = 1_000_000;

    /// @notice Партнёры сменяемы owner'ом (ADR-EXPANSION: гварды —
    ///         намертво, партнёры — ремонтные люки). Миграция эмиттера
    ///         резерва переставляет подписку: отписка старого + подписка
    ///         нового в одном вызове.
    address public executor;
    address public vault; // emitter of GasReserveUpdated (the battery)
    uint256 public immutable ethLowTopic;
    uint256 public immutable reserveTopic;

    event PartnerRewired(string indexed role, address indexed from, address to);

    /// @notice Tariff and cycle limits: the tank need (wei) plus a
    ///         marginNum/100 share routed into the vault treasury; a cap
    ///         per single refill; a cooldown against hammering.
    uint256 public marginNum = 110;
    uint256 public refillCapWei = 1 ether;
    uint256 public minRefillWei = 0.005 ether;
    uint64 public cycleCooldown = 1 hours;
    uint64 public lastRefillAt;

    /// @notice Mirror of the client's reserve (wei) — GasReserveUpdated
    ///         from GasVault (the battery).
    uint256 public reserveWei;
    bool public reserveSeen;

    /// @notice Eyes on its own tank (P-canon "real numbers at the
    ///         source"): eff = reserves(this) − debts(this) on SYSTEM;
    ///         the cry is a public order, edge-triggered with re-arming.
    uint256 public ownFloorWei = 0.05 ether;
    uint256 public ownTargetWei = 0.3 ether;
    bool public ownAlertArmed = true;

    /// @dev Idempotency: key (chainId, blockNumber, topic0).
    mapping(bytes32 => bool) public processed;

    address public owner;

    event EthTankOrdered(uint256 needWei, uint256 marginWei);
    event NoReserve();
    event LowGas(uint256 balance, uint256 target);
    event RateIgnored();

    error NotOwner();
    error ZeroAddress();
    error BadParams();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 destChainId_, address executor_, address vault_, uint256 ethLowTopic_, uint256 reserveTopic_) {
        destChainId = destChainId_;
        if (executor_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        executor = executor_;
        vault = vault_;
        ethLowTopic = ethLowTopic_;
        reserveTopic = reserveTopic_;
    }

    /// @notice Смена исполнителя (адресат колбека долива) — без передеплоя.
    ///         Подписка на крик ExecutorLowEth переезжает вместе с ним:
    ///         отписка старого + подписка нового одним вызовом (CEI: поле
    ///         и событие до внешних вызовов SYSTEM), иначе после
    ///         передеплоя исполнителя кассир слушал бы мёртвый адрес.
    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert ZeroAddress();
        emit PartnerRewired("executor", executor, executor_);
        address old = executor;
        executor = executor_;
        SYSTEM.unsubscribe(destChainId, old, ethLowTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destChainId, executor_, ethLowTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Смена эмиттера резерва (батареи): подписка переезжает —
    ///         отписка старого эмиттера и подписка нового одним вызовом.
    ///         CEI: поле и событие до внешних вызовов SYSTEM.
    function setReserveEmitter(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        emit PartnerRewired("reserveEmitter", vault, vault_);
        address old = vault;
        vault = vault_;
        SYSTEM.unsubscribe(destChainId, old, reserveTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destChainId, vault_, reserveTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function init() external onlyOwner {
        // P2 fix: the emitter of GasReserveUpdated is GasVault, not the executor
        SYSTEM.subscribe(destChainId, vault, reserveTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destChainId, executor, ethLowTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setTariff(uint256 marginNum_, uint256 capWei_, uint256 minWei_, uint64 cooldown_) external onlyOwner {
        if (marginNum_ < 100) revert BadParams();
        marginNum = marginNum_;
        refillCapWei = capWei_;
        minRefillWei = minWei_;
        cycleCooldown = cooldown_;
    }

    function setOwnTank(uint256 floorWei_, uint256 targetWei_) external onlyOwner {
        if (targetWei_ <= floorWei_) revert BadParams();
        ownFloorWei = floorWei_;
        ownTargetWei = targetWei_;
        ownAlertArmed = true;
    }

    function react(LogRecord calldata log_) external override onlySystem {
        // Idempotency: a repeated or out-of-order delivery of the same event
        // (UF §14: duplicates are the norm) must not order a second callback.
        bytes32 key = keccak256(abi.encodePacked(log_.chainId, log_.blockNumber, log_.topic0));
        bool processedAlready = processed[key];
        if (!processedAlready) {
            processed[key] = true;
        }

        _checkOwnTank();

        uint256 t0 = log_.topic0;
        if (t0 == reserveTopic) {
            uint256 weiAmount = abi.decode(log_.data, (uint256));
            reserveWei = weiAmount;
            reserveSeen = true;
        } else if (t0 == ethLowTopic) {
            if (processedAlready) {
                return;
            }
            (uint256 balance, uint256 threshold) = abi.decode(log_.data, (uint256, uint256));
            _orderRefuel(balance, threshold);
        }
    }

    /// @dev Tank need → order to the executor: need into the tank +
    ///      margin into the vault treasury; clamped by the cap and by
    ///      the reserve mirror.
    function _orderRefuel(uint256 balance, uint256 threshold) private {
        if (block.timestamp <= lastRefillAt + cycleCooldown) {
            return;
        }
        uint256 need = threshold > balance ? threshold - balance : 0;
        if (need > refillCapWei) {
            need = refillCapWei;
        }
        if (need == 0) {
            return;
        }
        uint256 margin = need * (marginNum - 100) / 100;
        // Clamp by the reserve mirror: the client only pays with what
        // they have deposited
        if (reserveSeen && need + margin > reserveWei) {
            uint256 total = reserveWei;
            need = total * 100 / marginNum;
            margin = total - need;
        }
        if (need < minRefillWei) {
            emit NoReserve();
            return;
        }
        lastRefillAt = uint64(block.timestamp);
        emit EthTankOrdered(need, margin);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: executor,
                gasLimit: ACTION_GAS_LIMIT,
                payload: abi.encodeWithSignature("refuelEthTank(address,uint256,uint256)", address(0), need, margin)
            })
        );
    }

    /// @dev Eyes in place: real SYSTEM numbers in every react() — free
    ///      (staticcall). The cry is a public order for the depot (fast
    ///      safety net) and for future fillers (W4).
    function _checkOwnTank() private {
        if (ownFloorWei == 0) {
            return;
        }
        uint256 eff = _ownEffective();
        if (!ownAlertArmed) {
            if (eff >= ownTargetWei) {
                ownAlertArmed = true;
            }
        }
        if (ownAlertArmed && eff < ownFloorWei) {
            ownAlertArmed = false;
            emit LowGas(eff, ownTargetWei);
        }
    }

    function _ownEffective() private view returns (uint256) {
        (bool okR, bytes memory rR) =
            address(SYSTEM).staticcall(abi.encodeWithSignature("reserves(address)", address(this)));
        (bool okD, bytes memory rD) =
            address(SYSTEM).staticcall(abi.encodeWithSignature("debts(address)", address(this)));
        uint256 res = (okR && rR.length >= 32) ? abi.decode(rR, (uint256)) : 0;
        uint256 debt = (okD && rD.length >= 32) ? abi.decode(rD, (uint256)) : 0;
        return res > debt ? res - debt : 0;
    }
}
