// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @dev Lasna faucet (a testnet stand-in for buying REACT). The prod
///      signature is verified by a live call at deploy time; the mainnet
///      path (Uniswap + bridge) is a separate adapter, ISwapAdapter-style.
interface IFuelSource {
    function request(address recipient) external payable;
}

/// @dev FuelBuyer — order recipient on Sepolia. Live delivery (probe
///      canon, 08.11): the callback arrives FROM THE PROXY (msg.sender)
///      and the network replaces the first payload slot with the source
///      address — the converter. Library guards: onlyServiceProvider
///      (proxy) + onlyCallbackSender (converter, immutable). The
///      converter↔buyer circular dependency is broken by precompute
///      (the converter learns the buyer address at construction, the
///      buyer learns the future converter address).
contract FuelBuyer is AbstractCallback {
    address public owner;
    IFuelSource public faucet;

    /// @notice Получатель топлива сменяем owner'ом (ADR-EXPANSION);
    ///         гвард отправителя (конвертер) — immutable намеренно.
    address public fund; // lREACT recipient (the depot, Lasna)

    uint256 public buyAmountWei = 0.02 ether;
    uint256 public buysCount;
    uint256 public totalSpentWei;

    event FuelBought(uint256 ethSpent, address indexed fund);
    event FaucetSet(address faucet);
    event FundRewired(address indexed from, address to);

    error NotOwner();
    error ZeroAddress();
    error BuyFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPayable callbackProxy_, address converter_, address fund_)
        AbstractCallback(callbackProxy_, converter_)
    {
        if (fund_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        fund = fund_;
    }

    function setFaucet(IFuelSource faucet_) external onlyOwner {
        if (address(faucet_) == address(0)) revert ZeroAddress();
        faucet = faucet_;
        emit FaucetSet(address(faucet_));
    }

    /// @notice Смена получателя топлива (склада) — без передеплоя.
    function setFund(address fund_) external onlyOwner {
        if (fund_ == address(0)) revert ZeroAddress();
        emit FundRewired(fund, fund_);
        fund = fund_;
    }

    function setBuyAmount(uint256 wei_) external onlyOwner {
        buyAmountWei = wei_;
    }

    /// @notice Purchase order: ETH goes to the faucet (from the balance
    ///         topped up by the vault's withdrawTreasury), lREACT lands
    ///         on the depot (fund). Called by the converter's callback;
    ///         sender_ is the network-injected converter address (a
    ///         library guard); originBlockNumber_ is the second slot,
    ///         untouched by the network (the converter's audit trail).
    function buyFuel(address sender_, uint256 originBlockNumber_)
        external
        payable
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        uint256 spent = address(this).balance < buyAmountWei ? address(this).balance : buyAmountWei;
        if (spent == 0) {
            revert BuyFailed();
        }
        buysCount += 1;
        totalSpentWei += spent;
        faucet.request{value: spent}(fund);
        emit FuelBought(spent, fund);
        originBlockNumber_; // the converter's audit-trail parameter
    }

    /// @dev Top up the purchase fund (from the vault treasury). Donations
    ///      above that go into the cause too (unlike the vault, this is
    ///      a fuel tank — accounting is aggregate via totalSpentWei).
    receive() external payable override {}

    /// @notice Settles callback-proxy debt from the buyer's own balance
    ///         (incident #15 class, morning check 13.11: debt > 0 is a
    ///         silent delivery pause; top-ups do NOT clear it). Anyone
    ///         may call — the payment only ever covers our own debt.
    function coverDebt() external {
        _coverDebt();
    }
}

/// @title FuelConverter — the auto-faucet (ADR-v2): a reactive listener
///        for the depot's horizon. HorizonAlert (level ≥ 1, days < 30) →
///        order FuelBuyer.buyFuel on Sepolia. Retries happen on the next
///        escalation (the depot re-emits HorizonAlert on every patrol
///        tick while the level holds; converter idempotency is
///        per-block).
contract FuelConverter is AbstractReactive {
    /// @dev The depot and its HorizonAlert live on Lasna — subscribe in
    ///      the SOURCE chain (5318007), not the destination one (a live
    ///      trap caught before the W2 deploy).
    uint256 public constant SRC_CHAIN_ID = 5318007;
    uint256 public constant DEST_CHAIN_ID = 11155111;
    uint64 public constant ACTION_GAS_LIMIT = 300_000;

    /// @notice Партнёры сменяемы owner'ом (ADR-EXPANSION): смена склада
    ///         переставляет подписку на его HorizonAlert в одном вызове.
    address public fund; // the depot (Lasna): emitter of HorizonAlert
    address public buyer; // FuelBuyer (Sepolia)

    event PartnersRewired(address indexed fund, address indexed buyer);

    /// @notice topic0 of HorizonAlert(uint256,uint256,uint256,uint8)
    uint256 public immutable horizonTopic;

    /// @dev Idempotency: one order per escalation block.
    mapping(uint256 => bool) public orderedAtBlock;
    /// @notice Minimum escalation level to order (1 = <30 days).
    uint8 public triggerLevel = 1;
    uint64 public cooldown = 12 hours;
    uint64 public lastOrderAt;

    address public owner;

    event FuelOrdered(uint256 originBlockNumber, uint8 level);
    error NotOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address fund_, address buyer_, uint256 horizonTopic_) {
        if (fund_ == address(0) || buyer_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        fund = fund_;
        buyer = buyer_;
        horizonTopic = horizonTopic_;
    }

    /// @notice Смена склада: подписка на HorizonAlert переезжает
    ///         (отписка старого эмиттера + подписка нового). CEI: поле
    ///         и событие до внешних вызовов SYSTEM.
    function setFund(address fund_) external onlyOwner {
        if (fund_ == address(0)) revert ZeroAddress();
        emit PartnersRewired(fund_, buyer);
        address old = fund;
        fund = fund_;
        SYSTEM.unsubscribe(SRC_CHAIN_ID, old, horizonTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(SRC_CHAIN_ID, fund_, horizonTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Смена покупщика (адресат колбека покупки) — без передеплоя.
    function setBuyer(address buyer_) external onlyOwner {
        if (buyer_ == address(0)) revert ZeroAddress();
        emit PartnersRewired(fund, buyer_);
        buyer = buyer_;
    }

    function init() external onlyOwner {
        SYSTEM.subscribe(SRC_CHAIN_ID, fund, horizonTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setTrigger(uint8 level_, uint64 cooldown_) external onlyOwner {
        triggerLevel = level_;
        cooldown = cooldown_;
    }

    function react(LogRecord calldata log_) external override onlySystem {
        if (log_.topic0 != horizonTopic) {
            return;
        }
        (,,, uint8 level) = abi.decode(log_.data, (uint256, uint256, uint256, uint8));
        if (level < triggerLevel) {
            return;
        }
        if (orderedAtBlock[log_.blockNumber]) {
            return;
        }
        if (lastOrderAt != 0 && block.timestamp <= lastOrderAt + cooldown) {
            return; // lastOrderAt=0 means "never" — the first order is never blocked
        }
        orderedAtBlock[log_.blockNumber] = true;
        lastOrderAt = uint64(block.timestamp);
        emit FuelOrdered(log_.blockNumber, level);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DEST_CHAIN_ID,
                recipient: buyer,
                gasLimit: ACTION_GAS_LIMIT,
                // The address slot comes first: the network replaces it
                // with the source address (our rvm) — that is the
                // recipient's authorization.
                payload: abi.encodeWithSignature("buyFuel(address,uint256)", address(0), log_.blockNumber)
            })
        );
    }
}
