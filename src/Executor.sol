// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAssetVault} from "./AssetVault.sol";
import {IGasVault} from "./GasVault.sol";
import {IPoolAdapter} from "./IPoolAdapter.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @title Executor v2 — carries out instructions from the brain and the
///        cashier (ADR-v2 + ADR-EXPANSION §2)
/// @notice Two valid callback senders: RulesEngine (rebalance) and the
///         GasPayer cashier (refuelEthTank). Capital work goes through
///         the AssetVault, fuel through the GasVault — one battery for
///         every asset and chain. Per-chain instances on expansion
///         (same code, new deploy; ADR-EXPANSION §3).
/// @dev Срез сейфа для мульти-активного исполнителя: обе ветки (ETH
///      AssetVault и Erc20AssetVault) удовлетворяют этому интерфейсу.
interface IExecutorVault {
    function rebalanceTarget() external view returns (uint256);
    function deployToPool(address adapter, uint256 amount) external;
    function recallFromPool(address adapter, uint256 amount) external;
    function inPoolOf(address adapter) external view returns (uint256);
    function poolAdapterCount() external view returns (uint256);
    function poolAdapters(uint256 i) external view returns (address);
}

contract Executor is AbstractCallback {
    /// @notice Партнёры сменяемы owner'ом; гварды отправителей
    ///         (мозг/кассир) — immutable намеренно.
    ///         v3: РЕЕСТР сейфов — конструкторский сейф первый в списке,
    ///         addVault/removeVault управляют остальными (мульти-актив).
    IExecutorVault[] public vaults;
    mapping(address => bool) public isVault;
    IGasVault public gasVault;

    /// @notice ETH tank: below the threshold → ExecutorLowEth event; the
    ///         cashier (Lasna) is subscribed and refills the tank by
    ///         drawing from the client's fuel reserve (GasVault).
    uint256 public ethLowThreshold = 0.005 ether;

    /// @notice Minimum APY gap (WAD/yr) to move capital between pools;
    ///         below it the placement stays (gate against rate flapping).
    uint256 public minSpreadWad = 0.01e18;

    uint256 public rebalanceCount;
    uint256 public totalTankedEth;

    event Rebalanced(address indexed sender, uint256 originBlockNumber, uint256 amount);
    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
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
        IExecutorVault assetVault_,
        IGasVault gasVault_,
        address gasPayerSender_
    ) AbstractCallback(callbackProxy_, rulesEngine_) {
        owner = msg.sender;
        vaults.push(assetVault_);
        isVault[address(assetVault_)] = true;
        emit VaultAdded(address(assetVault_));
        gasVault = gasVault_;
        _GAS_PAYER_SENDER = gasPayerSender_;
        _original = address(this);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice Мульти-актив: добавить сейф (со своими адаптерами пулов).
    function addVault(IExecutorVault vault_) external onlyOwner noDelegateCall {
        if (address(vault_) == address(0)) revert ZeroAddress();
        if (isVault[address(vault_)]) revert ZeroAddress(); // уже есть
        isVault[address(vault_)] = true;
        vaults.push(vault_);
        emit VaultAdded(address(vault_));
    }

    function removeVault(IExecutorVault vault_) external onlyOwner noDelegateCall {
        if (!isVault[address(vault_)]) revert ZeroAddress();
        isVault[address(vault_)] = false;
        uint256 len = vaults.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(vaults[i]) == address(vault_)) {
                vaults[i] = vaults[len - 1];
                vaults.pop();
                break;
            }
        }
        emit VaultRemoved(address(vault_));
    }

    /// @notice Смена батареи (газ — общий на цепь).
    function setGasVault(IGasVault gasVault_) external onlyOwner noDelegateCall {
        if (address(gasVault_) == address(0)) revert ZeroAddress();
        gasVault = gasVault_;
        emit VaultsRewired(address(0), address(gasVault_));
    }

    function setEthLowThreshold(uint256 threshold_) external onlyOwner noDelegateCall {
        ethLowThreshold = threshold_;
    }

    function setMinSpread(uint256 minSpreadWad_) external onlyOwner noDelegateCall {
        minSpreadWad = minSpreadWad_;
    }

    /// @notice Rebalance: local decision at execution time. Rates are
    ///         compared via adapter views on THIS chain (fresher than
    ///         any event-carried data); idle free capital is placed
    ///         unconditionally, a move between pools only above
    ///         minSpreadWad. Capital transits THROUGH the safe
    ///         (recall → deploy); the executor never holds it.
    function rebalance(address sender_, uint256 originBlockNumber_)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        uint256 moved = _placeCapital();
        rebalanceCount += 1;
        emit Rebalanced(sender_, originBlockNumber_, moved);
        // Bootstrap-cry: an empty tank must be able to cry from the
        // rebalance callback itself — refuelEthTank is unreachable while
        // the tank is empty, so without this check the cashier would
        // never learn about the first refill (red №1, 10.11).
        _checkEth();
    }

    /// @dev Мульти-актив: каждый сейф ребалансируется независимо —
    ///      лучший/худший пул считается по ЕГО адаптерам.
    function _placeCapital() private returns (uint256 moved) {
        uint256 len = vaults.length;
        for (uint256 v = 0; v < len; v++) {
            IExecutorVault vault = vaults[v];
            uint256 n = vault.poolAdapterCount();
            if (n < 2) {
                if (n == 1) {
                    // единственный пул: просто размещаем свободное
                    uint256 freeSolo = vault.rebalanceTarget();
                    if (freeSolo > 0) {
                        vault.deployToPool(vault.poolAdapters(0), freeSolo);
                        moved += freeSolo;
                    }
                }
                continue;
            }
            uint256 bestRate;
            address best;
            {
                address first = vault.poolAdapters(0);
                best = first;
                bestRate = IPoolAdapter(first).supplyRatePerYear();
            }
            address worst = best;
            uint256 worstRate = bestRate;
            for (uint256 i = 1; i < n; i++) {
                address a = vault.poolAdapters(i);
                uint256 r = IPoolAdapter(a).supplyRatePerYear();
                if (r > bestRate) {
                    // ничья — остаётся ранний пул (tie→poolA)
                    bestRate = r;
                    best = a;
                }
                if (r < worstRate) {
                    worstRate = r;
                    worst = a;
                }
            }
            uint256 spread = bestRate - worstRate;
            uint256 inWorst = vault.inPoolOf(worst);
            if (inWorst > 0 && spread >= minSpreadWad) {
                vault.recallFromPool(worst, inWorst);
                moved = inWorst;
            }
            uint256 free = vault.rebalanceTarget();
            if (free > 0) {
                vault.deployToPool(best, free);
                moved += free;
            }
        }
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

    /// @notice Pay off the callback-proxy debt from the balance and lift
    ///         the delivery pause. Incident #15 (12.11): a delivery
    ///         attempt at an empty tank leaves a debt; debt > 0 = the
    ///         proxy holds all deliveries (InDebt) and plain top-ups do
    ///         NOT clear it — only this payment does. Anyone may call:
    ///         the funds only ever go to the proxy for our own debt.
    function coverDebt() external {
        _coverDebt();
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
