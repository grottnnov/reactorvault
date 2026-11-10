// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAssetVault} from "./AssetVault.sol";
import {IGasVault} from "./GasVault.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @title Executor v2 — carries out instructions from the brain and the
///        cashier (ADR-v2 + ADR-EXPANSION §2)
/// @notice Two valid callback senders: RulesEngine (rebalance) and the
///         GasPayer cashier (refuelEthTank). Capital work goes through
///         the AssetVault, fuel through the GasVault — one battery for
///         every asset and chain. Per-chain instances on expansion
///         (same code, new deploy; ADR-EXPANSION §3).
contract Executor is AbstractCallback {
    /// @notice Партнёры сменяемы owner'ом ОДНИМ атомарным сеттером
    ///         (ADR-EXPANSION: сейф и батарея переезжают только парой —
    ///         рассинхрон адресатов исключён конструкцией). Гварды
    ///         отправителей (мозг/кассир) — immutable намеренно.
    IAssetVault public assetVault;
    IGasVault public gasVault;

    address public poolA;
    address public poolB;

    /// @notice ETH tank: below the threshold → ExecutorLowEth event; the
    ///         cashier (Lasna) is subscribed and refills the tank by
    ///         drawing from the client's fuel reserve (GasVault).
    uint256 public ethLowThreshold = 0.005 ether;

    uint256 public rebalanceCount;
    uint256 public totalTankedEth;

    event Rebalanced(address indexed sender, uint256 originBlockNumber, uint256 amount);
    event PoolsSet(address poolA, address poolB);
    event EthTankRefueled(uint256 needWei, uint256 marginWei);
    event ExecutorLowEth(uint256 balance, uint256 threshold);
    event VaultsRewired(address indexed assetVault, address indexed gasVault);

    error NotOwner();
    error ZeroAddress();
    error BadMargin();

    address private owner;

    /// @dev P10: immutable address against delegatecall.
    address private immutable _original;

    /// @notice Second valid callback sender — the GasPayer cashier
    ///         (Lasna): refuelEthTank arrives from it, rebalance — from
    ///         RulesEngine (_CALLBACK_SENDER).
    address public immutable _GAS_PAYER_SENDER;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier noDelegateCall() {
        if (address(this) != _original) revert DelegateCallNotAllowed();
        _;
    }

    error DelegateCallNotAllowed();

    modifier onlyGasPayerSender(address sender_) {
        if (sender_ != _GAS_PAYER_SENDER) {
            revert CallbackNotAuthorized(sender_, _GAS_PAYER_SENDER);
        }
        _;
    }

    constructor(
        address rulesEngine_,
        IPayable callbackProxy_,
        IAssetVault assetVault_,
        IGasVault gasVault_,
        address gasPayerSender_
    ) AbstractCallback(callbackProxy_, rulesEngine_) {
        owner = msg.sender;
        assetVault = assetVault_;
        gasVault = gasVault_;
        _GAS_PAYER_SENDER = gasPayerSender_;
        _original = address(this);
    }

    function setPools(address poolA_, address poolB_) external onlyOwner noDelegateCall {
        if (poolA_ == address(0) || poolB_ == address(0)) revert ZeroAddress();
        poolA = poolA_;
        poolB = poolB_;
        emit PoolsSet(poolA_, poolB_);
    }

    /// @notice Атомарная смена пары сейф+батарея — только вместе
    ///         (zero-address запрещён; смена — событием).
    function setVaults(IAssetVault assetVault_, IGasVault gasVault_) external onlyOwner noDelegateCall {
        if (address(assetVault_) == address(0) || address(gasVault_) == address(0)) revert ZeroAddress();
        assetVault = assetVault_;
        gasVault = gasVault_;
        emit VaultsRewired(address(assetVault_), address(gasVault_));
    }

    function setEthLowThreshold(uint256 threshold_) external onlyOwner noDelegateCall {
        ethLowThreshold = threshold_;
    }

    function rebalance(address sender_, uint256 originBlockNumber_)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        uint256 amount = assetVault.rebalanceTarget();
        rebalanceCount += 1;
        emit Rebalanced(sender_, originBlockNumber_, amount);
        // Bootstrap-cry: an empty tank must be able to cry from the
        // rebalance callback itself — refuelEthTank is unreachable while
        // the tank is empty, so without this check the cashier would
        // never learn about the first refill (red №1, 10.11).
        _checkEth();
    }

    /// @notice Refill the ETH tank from the battery: needWei goes into
    ///         the tank, marginWei into the treasury pocket (the ETH
    ///         fund). The reserve is ETH already: no swap needed (ADR-v2).
    function refuelEthTank(address sender_, uint256 needWei_, uint256 marginWei_)
        external
        noDelegateCall
        onlyServiceProvider
        onlyGasPayerSender(sender_)
    {
        if (marginWei_ > needWei_) revert BadMargin();
        if (marginWei_ > 0) {
            gasVault.consumeGasReserve(marginWei_);
        }
        if (needWei_ > 0) {
            gasVault.releaseReserveTo(address(this), needWei_);
            totalTankedEth += needWei_;
        }
        emit EthTankRefueled(needWei_, marginWei_);
        _checkEth();
    }

    function _checkEth() private {
        uint256 bal = address(this).balance;
        if (bal < ethLowThreshold) {
            emit ExecutorLowEth(bal, ethLowThreshold);
        }
    }

    /// @dev Callback payments and automatic debt covering — AbstractPayer
    ///      mechanics: the proxy calls pay() on delivery, ETH is charged
    ///      to the balance.
    receive() external payable override {}
}
