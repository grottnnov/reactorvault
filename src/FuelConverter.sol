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

    /// @notice ADR-PURCHASE-SAFETY B2: рунбук-стоп — пауза покупок
    ///         без вывода средств (SCSVS G1.7). Стоп-пара: pause() здесь
    ///         + deactivate() конвертера (одна рунбук-операция).
    bool public paused;

    event FuelBought(uint256 ethSpent, address indexed fund);
    event FaucetSet(address faucet);
    event FundRewired(address indexed from, address to);
    event PauseSet(bool paused);

    error NotOwner();
    error ZeroAddress();
    error BuyFailed();
    error Paused();

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

    /// @notice Рунбук-стоп: никаких покупок, пока пауза не снята.
    function pause() external onlyOwner {
        paused = true;
        emit PauseSet(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PauseSet(false);
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
        if (paused) revert Paused();
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

/// @title FuelConverter v3 — the auto-faucet (ADR-v2 + ADR-PURCHASE-SAFETY
///        B2): a reactive listener for the depot's horizon. HorizonAlert
///        (level ≥ 1, days < 30) → order FuelBuyer.buyFuel on Sepolia.
///        v3 adds the rate stop: a second subscription to the depot's
///        Funded (faucet-payer filter) observes every payout; below
///        MIN_PAYOUT_PER_BUY → BadRate + orders frozen until the owner
///        hatch. Retries happen on the next
///        escalation (the depot re-emits HorizonAlert on every patrol
///        tick while the level holds; converter idempotency is
///        per-block).
contract FuelConverter is AbstractReactive {
    /// @dev The depot and its HorizonAlert live on Lasna — subscribe in
    ///      the SOURCE chain (5318007), not the destination one (a live
    ///      trap caught before the W2 deploy).
    /// @notice Цепи — параметры деплоя (универсальность, 17.11):
    ///         тестнет = 5318007/11155111, мейн = 1597/1.
    uint256 public immutable SRC_CHAIN_ID;
    uint256 public immutable DEST_CHAIN_ID;
    /// @dev Gas-стрижка прокси (канон 11.11): до вызова доходит заказ
    ///      минус ~200k удержаний прокси. Живая потребность buyFuel =
    ///      260 850 (замер форком 13.11, инцидент #16: 300k не хватило,
    ///      тихий OOG = диагностическое событие, buys=0 при «успешной»
    ///      доставке). Заказ = потребность × ~2 + прокси-держатели.
    uint64 public constant ACTION_GAS_LIMIT = 600_000;

    /// @notice Партнёры сменяемы owner'ом (ADR-EXPANSION): смена склада
    ///         переставляет подписку на его HorizonAlert в одном вызове.
    address public fund; // the depot (Lasna): emitter of HorizonAlert
    address public buyer; // FuelBuyer (Sepolia)

    event PartnersRewired(address indexed fund, address indexed buyer);

    /// @notice topic0 of HorizonAlert(uint256,uint256,uint256,uint8)
    uint256 public immutable horizonTopic;

    /// @notice ADR-PURCHASE-SAFETY B2 — стоп-курс. Вторая подписка:
    ///          Funded(address indexed from, uint256 amount) склада
    ///          (Lasna); внутри react фильтр «отправитель = кран»
    ///          (topic1 = faucetRvm, живой замер 16.11, блок 8 490 015).
    uint256 public immutable fundedTopic;
    address public immutable faucetRvm;

    /// @notice Минимум выплаты на покупку (lREACT, WAD): фиксированный
    ///          параметр, НЕ автокалибровка (Gelato-норматив). Источник:
    ///          курс 2.0/покупку (замер 16.11), жор 0.6/день; убыточный
    ///          режим крана 1:12.7 = 0.25 — отсекается.
    uint256 public constant MIN_PAYOUT_PER_BUY = 1e18;

    /// @notice Выплата ниже минимума один раз → заказы остановлены до
    ///          разбора человеком (реактивация — owner-люк).
    bool public rateStopped;

    /// @notice Телеметрия для сенсора: бегущее среднее выплаты lREACT
    ///          на покупку (на решение НЕ влияет).
    uint256 public rateEma;
    uint256 public payouts;

    event RateObserved(uint256 payout, uint256 rateEma);
    event BadRate(uint256 payout, uint256 minimum);
    event RateStopCleared();

    /// @dev Idempotency: one order per escalation block.
    mapping(uint256 => bool) public orderedAtBlock;
    /// @notice Minimum escalation level to order (1 = <30 days).
    uint8 public triggerLevel = 1;
    uint64 public cooldown = 12 hours;
    uint64 public lastOrderAt;

    address public owner;

    /// @notice Kill switch for the subscription (incident #16 lesson:
    ///         a replaced converter stays subscribed forever — its
    ///         reserve burns on every alert until it falls silent; an
    ///         owner hatch lets us retire a pair cleanly).
    bool public active = true;

    event FuelOrdered(uint256 originBlockNumber, uint8 level);
    event Deactivated();
    error NotOwner();
    error ZeroAddress();
    error Inactive();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 srcChainId_,
        uint256 destChainId_,
        address fund_,
        address buyer_,
        uint256 horizonTopic_,
        uint256 fundedTopic_,
        address faucetRvm_
    ) {
        if (fund_ == address(0) || buyer_ == address(0) || faucetRvm_ == address(0)) revert ZeroAddress();
        SRC_CHAIN_ID = srcChainId_;
        DEST_CHAIN_ID = destChainId_;
        owner = msg.sender;
        fund = fund_;
        buyer = buyer_;
        horizonTopic = horizonTopic_;
        fundedTopic = fundedTopic_;
        faucetRvm = faucetRvm_;
    }

    /// @notice Смена склада: ОБЕ подписки переезжают (HorizonAlert +
    ///         Funded) — отписка старого эмиттера + подписка нового.
    ///         CEI: поля и события до внешних вызовов SYSTEM.
    function setFund(address fund_) external onlyOwner {
        if (fund_ == address(0)) revert ZeroAddress();
        emit PartnersRewired(fund_, buyer);
        address old = fund;
        fund = fund_;
        _unsubscribeFund(old);
        SYSTEM.subscribe(SRC_CHAIN_ID, fund_, horizonTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(SRC_CHAIN_ID, fund_, fundedTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Смена покупщика (адресат колбека покупки) — без передеплоя.
    function setBuyer(address buyer_) external onlyOwner {
        if (buyer_ == address(0)) revert ZeroAddress();
        emit PartnersRewired(fund, buyer_);
        buyer = buyer_;
    }

    function init() external onlyOwner {
        SYSTEM.subscribe(SRC_CHAIN_ID, fund, horizonTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(SRC_CHAIN_ID, fund, fundedTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setTrigger(uint8 level_, uint64 cooldown_) external onlyOwner {
        triggerLevel = level_;
        cooldown = cooldown_;
    }

    /// @notice Реактивация заказов после BadRate-стопа: только owner,
    ///          только после разбора человеком (ADR: «плохой курс ≠
    ///          транзиент» — авто-retry запрещён).
    function clearRateStop() external onlyOwner {
        rateStopped = false;
        emit RateStopCleared();
    }

    /// @notice Retire the converter: unsubscribe BOTH topics + ignore
    ///         any in-flight deliveries. Reversible only by redeployment.
    function deactivate() external onlyOwner {
        active = false;
        emit Deactivated();
        _unsubscribeFund(fund);
    }

    function _unsubscribeFund(address fund_) private {
        SYSTEM.unsubscribe(SRC_CHAIN_ID, fund_, horizonTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(SRC_CHAIN_ID, fund_, fundedTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function react(LogRecord calldata log_) external override onlySystem {
        if (!active) {
            return;
        }
        if (log_.topic0 == fundedTopic) {
            _observePayout(log_);
            return;
        }
        if (log_.topic0 != horizonTopic) {
            return;
        }
        if (rateStopped) {
            return; // BadRate-стоп: заказы заморожены до clearRateStop()
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

    /// @dev Телеметрия курса: Funded от крана (topic1-фильтр) →
    ///      бегущее среднее; выплата ниже минимума → BadRate + стоп
    ///      заказов (один раз; дальше молчит до люка).
    function _observePayout(LogRecord calldata log_) private {
        if (log_.topic1 != uint256(uint160(faucetRvm))) {
            return; // платит не кран — не наш сигнал
        }
        uint256 payout = abi.decode(log_.data, (uint256));
        payouts += 1;
        rateEma = rateEma == 0 ? payout : (rateEma + payout) / 2;
        emit RateObserved(payout, rateEma);
        if (!rateStopped && payout < MIN_PAYOUT_PER_BUY) {
            rateStopped = true;
            emit BadRate(payout, MIN_PAYOUT_PER_BUY);
        }
    }
}
