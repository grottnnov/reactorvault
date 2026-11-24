// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAssetVault} from "./AssetVault.sol";
import {IGasVault} from "./GasVault.sol";
import {IPoolAdapter} from "./IPoolAdapter.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @title Executor v3 — carries out instructions from the brain
///        (ADR-GAS-ARCHITECTURE: pay-on-delivery)
/// @notice The single valid callback sender is the brain (RulesEngine):
///         rebalance. Service fees are billed to the safe the work was
///         done for (accrued on the safe, settled at its cash events)
///         and the tank self-sustains: everything above the tank target
///         is swept into the fund as margin. Capital work goes through
///         the AssetVault, fuel margins through the GasVault fund.
///         Per-chain instances on expansion (same code, new deploy).
/// @dev A vault slice for the multi-asset executor: both branches (ETH
///      AssetVault and Erc20AssetVault) satisfy this interface.
interface IExecutorVault {
    function rebalanceTarget() external view returns (uint256);
    function deployToPool(address adapter, uint256 amount) external;
    function recallFromPool(address adapter, uint256 amount) external;
    function inPoolOf(address adapter) external view returns (uint256);
    function poolAdapterCount() external view returns (uint256);
    function poolAdapters(uint256 i) external view returns (address);
}

contract Executor is AbstractCallback {
    /// @notice Partners are replaceable by the owner; the sender guards
    ///         (brain/cashier) are immutable on purpose.
    ///         v3: a REGISTRY of safes — the constructor's safe is first
    ///         in the list, addVault/removeVault manage the rest (multi-asset).
    IExecutorVault[] public vaults;
    mapping(address => bool) public isVault;
    IGasVault public gasVault;

    /// @notice ETH tank: below the threshold → ExecutorLowEth event —
    ///         a loud alarm (pay-on-delivery: the tank self-sustains on
    ///         billed fees + deploy-time seed; a cry means tariffs need
    ///         recalibration, not a manual refill path).
    uint256 public ethLowThreshold = 0.005 ether;

    /// @notice Pay-on-delivery (ADR-GAS): the service fee billed to a
    ///         safe per served action (gas-unit based, owner-calibrated
    ///         from live measurements; every change announced).
    uint256 public feePerActionWei = 0.002 ether;

    /// @notice The tank target: everything above it is swept into the
    ///         fund (GasVault) as margin at the end of each action.
    uint256 public tankTargetWei = 0.02 ether;

    /// @notice Minimum APY gap (WAD/yr) to move capital between pools;
    ///         below it the placement stays (gate against rate flapping).
    uint256 public minSpreadWad = 0.01e18;

    uint256 public rebalanceCount;
    uint256 public feesBilled;

    event Rebalanced(address indexed sender, uint256 originBlockNumber, uint256 amount);
    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    event ExecutorLowEth(uint256 balance, uint256 threshold);
    event VaultsRewired(address indexed assetVault, address indexed gasVault);
    event VaultUnpaid(address indexed vault);
    event MarginSwept(uint256 weiAmount);
    event FeeTariffSet(uint256 feePerActionWei, uint256 tankTargetWei);

    error NotOwner();
    error ZeroAddress();
    error BadMargin();

    address private owner;

    /// @dev P10: immutable address against delegatecall.
    address private immutable _original;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier noDelegateCall() {
        if (address(this) != _original) revert DelegateCallNotAllowed();
        _;
    }

    error DelegateCallNotAllowed();

    constructor(address rulesEngine_, IPayable callbackProxy_, IExecutorVault assetVault_, IGasVault gasVault_)
        AbstractCallback(callbackProxy_, rulesEngine_)
    {
        owner = msg.sender;
        vaults.push(assetVault_);
        isVault[address(assetVault_)] = true;
        emit VaultAdded(address(assetVault_));
        gasVault = gasVault_;
        _original = address(this);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice Multi-asset: add a safe (with its own pool adapters).
    function addVault(IExecutorVault vault_) external onlyOwner noDelegateCall {
        if (address(vault_) == address(0)) revert ZeroAddress();
        if (isVault[address(vault_)]) revert ZeroAddress(); // already present
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

    /// @notice Battery replacement (gas is shared per chain).
    function setGasVault(IGasVault gasVault_) external onlyOwner noDelegateCall {
        if (address(gasVault_) == address(0)) revert ZeroAddress();
        gasVault = gasVault_;
        emit VaultsRewired(address(0), address(gasVault_));
    }

    /// @notice Tariffs are money: every retune is announced on-chain.
    event EthLowThresholdSet(uint256 threshold);
    event MinSpreadSet(uint256 minSpreadWad);

    function setEthLowThreshold(uint256 threshold_) external onlyOwner noDelegateCall {
        ethLowThreshold = threshold_;
        emit EthLowThresholdSet(threshold_);
    }

    function setMinSpread(uint256 minSpreadWad_) external onlyOwner noDelegateCall {
        minSpreadWad = minSpreadWad_;
        emit MinSpreadSet(minSpreadWad_);
    }

    /// @notice Pay-on-delivery tariff (ADR-GAS): fee per served action
    ///         and the tank target above which margins are swept.
    function setFeeTariff(uint256 feePerActionWei_, uint256 tankTargetWei_) external noDelegateCall onlyOwner {
        feePerActionWei = feePerActionWei_;
        tankTargetWei = tankTargetWei_;
        emit FeeTariffSet(feePerActionWei_, tankTargetWei_);
    }

    /// @notice Rebalance: local decision at execution time. Rates are
    ///         compared via adapter views on THIS chain (fresher than
    ///         any event-carried data); idle free capital is placed
    ///         unconditionally, a move between pools only above
    ///         minSpreadWad. Capital transits THROUGH the safe
    ///         (recall → deploy); the executor never holds it.
    function rebalance(address sender_, uint256 originBlockNumber_)
        external
        noDelegateCall
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        uint256 moved = _placeCapital();
        rebalanceCount += 1;
        emit Rebalanced(sender_, originBlockNumber_, moved);
        // Pay-on-delivery (ADR-GAS): the work is done — bill the served
        // safes, keep the tank at target, sweep the margin into the fund.
        _billVaults();
        _sweepMargin();
        _checkEth(); // a loud alarm when the tank is low (recalibrate)
    }

    /// @dev Multi-asset: every safe is rebalanced independently — the
    ///      best/worst pool is computed by ITS own adapters.
    function _placeCapital() private returns (uint256 moved) {
        uint256 len = vaults.length;
        for (uint256 v = 0; v < len; v++) {
            IExecutorVault vault = vaults[v];
            uint256 n = vault.poolAdapterCount();
            if (n < 2) {
                if (n == 1) {
                    // a single pool: simply place the free capital
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
                    // a tie — the early pool stays (tie→poolA)
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

    /// @notice Pay-on-delivery billing: every served safe is charged
    ///         the action fee (accrued on the safe — never a transfer
    ///         here, a fully staked safe cannot fail to pay). A vault
    ///         that refuses (cap, unknown selector) is skipped loudly
    ///         and never blocks the others.
    function _billVaults() private {
        if (feePerActionWei == 0) {
            return;
        }
        uint256 len = vaults.length;
        for (uint256 v = 0; v < len; v++) {
            (bool ok,) = address(vaults[v]).call(abi.encodeWithSignature("chargeFee(uint256)", feePerActionWei));
            if (ok) {
                feesBilled += feePerActionWei;
            } else {
                emit VaultUnpaid(address(vaults[v]));
            }
        }
    }

    /// @dev The tank self-sustains: everything above the target is
    ///      margin — it leaves for the fund (the REACT half is fed from
    ///      there by the auto-faucet chain).
    function _sweepMargin() private {
        uint256 bal = address(this).balance;
        if (bal > tankTargetWei) {
            uint256 sweep = bal - tankTargetWei;
            emit MarginSwept(sweep); // P9: the event precedes the external call
            gasVault.treasuryIn{value: sweep}();
        }
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
