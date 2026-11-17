// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Минимальный ERC-20-срез (канон репо: без внешних зависимостей;
///      настоящий USDC в этот срез укладывается, включая bool-возвраты).
interface IERC20Asset {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title Erc20AssetVault — сейф ERC-20 актива (ветка USDC).
/// @notice ADR-EXPANSION: «новый актив = новый экземпляр, а не перепись
///         старого». ETH-сейф живёт своей жизнью; этот принимает USDC
///         через transferFrom, казначейская доля копится ВНУТРИ (в USDC,
///         люк вывода — веха G15), рабочий капитал пушится в адаптеры
///         пулов и возвращается строгими расчётами. Инвариант:
///         tokenBalance + totalInPools + treasuryWithdrawn ≡ totalDeposited
///         (казна не вычитается — она остаётся в балансе сейфа).
///         P5: withdrawAll — MVP-скаффолдинг (per-user учёт — G15).
///         P10: noDelegateCall на каждой точке входа. Эфир не принимается:
///         контракт не payable.
contract Erc20AssetVault {
    IERC20Asset public immutable token;
    address public owner;
    address public executor;

    /// @notice Казначейская доля каждого депозита, bps (≤ 10_000).
    uint32 public treasuryBps;

    uint256 public totalDeposited;
    /// @notice Забронированная казна (в токене, лежит в балансе сейфа).
    uint256 public treasuryTaken;

    address[] public poolAdapters;
    mapping(address => bool) public isPoolAdapter;
    mapping(address => uint256) public inPoolOf;

    /// @dev P10: immutable pin реального кода.
    address private immutable _original;

    /// @dev CEI-гвард расчётов: внешние вызовы адаптеров идут до
    ///      записи состояния — реентрансия из адаптера запрещена
    ///      (Slither reentrancy-balance High, 17.11; злой адаптер —
    ///      владелец реестра, но глубина всё равно заперта).
    bool private _recalling;

    event Deposited(address indexed user, uint256 amount, uint256 toTreasury);
    event Withdrawn(address indexed user, uint256 amount);
    event PoolAdapterAuthorized(address indexed adapter);
    event ExecutorAuthorized(address indexed executor);
    event DeployedToPool(address indexed adapter, uint256 amount);
    event RecalledFromPool(address indexed adapter, uint256 amount);

    error NotOwner();
    error NotExecutor();
    error ZeroAddress();
    error ZeroAmount();
    error BadParams();
    error TransferFailed();
    error DelegateCallNotAllowed();
    error AdapterUnknown();
    error AdapterAlreadyKnown();
    error InsufficientFree();
    error InsufficientInPool();
    error SettleMismatch();
    error Reentrancy();

    modifier notRecalling() {
        if (_recalling) revert Reentrancy();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    modifier noDelegateCall() {
        if (address(this) != _original) revert DelegateCallNotAllowed();
        _;
    }

    constructor(IERC20Asset token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        owner = msg.sender;
        _original = address(this);
    }

    function setTreasuryBps(uint32 bps_) external onlyOwner noDelegateCall {
        if (bps_ > 10_000) revert BadParams();
        treasuryBps = bps_;
    }

    function authorizeExecutor(address executor_) external onlyOwner noDelegateCall {
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        emit ExecutorAuthorized(executor_);
    }

    function authorizePoolAdapter(address adapter_) external onlyOwner noDelegateCall {
        if (adapter_ == address(0)) revert ZeroAddress();
        if (isPoolAdapter[adapter_]) revert AdapterAlreadyKnown();
        isPoolAdapter[adapter_] = true;
        poolAdapters.push(adapter_);
        emit PoolAdapterAuthorized(adapter_);
    }

    /// @notice Количество авторизованных адаптеров (для итерации
    ///         исполнителем мульти-активного реестра).
    function poolAdapterCount() external view returns (uint256) {
        return poolAdapters.length;
    }

    /// @notice Депозит: юзер даёт approve, сейф забирает токен.
    ///         Казна бронируется тут же и остаётся в сейфе.
    function deposit(uint256 amount_) external noDelegateCall notRecalling {
        if (amount_ == 0) revert ZeroAmount();
        uint256 toTreasury = amount_ * treasuryBps / 10_000;
        totalDeposited += amount_;
        if (toTreasury > 0) {
            treasuryTaken += toTreasury;
        }
        emit Deposited(msg.sender, amount_, toTreasury);
        _safeTransferFrom(msg.sender, address(this), amount_);
    }

    /// @notice Свободный рабочий капитал: баланс минус забронированная
    ///         казна — казна недоступна пулам (главная разница с ETH-сейфом,
    ///         где казна сразу уезжает в батарею).
    function rebalanceTarget() external view returns (uint256 amount) {
        uint256 bal = token.balanceOf(address(this));
        amount = bal > treasuryTaken ? bal - treasuryTaken : 0;
    }

    /// @notice Пуш-модель: сейф сам передаёт токен адаптеру (никаких
    ///         approve-сарайников). Эффекты до внешнего вызова.
    function deployToPool(address adapter_, uint256 amount_) external onlyExecutor noDelegateCall notRecalling {
        if (!isPoolAdapter[adapter_]) revert AdapterUnknown();
        if (amount_ == 0) revert ZeroAmount();
        uint256 bal = token.balanceOf(address(this));
        uint256 free = bal > treasuryTaken ? bal - treasuryTaken : 0;
        if (amount_ > free) revert InsufficientFree();
        inPoolOf[adapter_] += amount_;
        emit DeployedToPool(adapter_, amount_);
        _safeTransfer(adapter_, amount_);
    }

    /// @notice Строгий расчёт с пылевым допуском: пулы с процентным
    ///         индексом (Aave liquidityIndex, Morpho shares) округляют
    ///         зачисление вниз — отзыв ровно principal невозможен.
    ///         Допуск 0.01 USDC покрывает округление с запасом ×1000
    ///         (замер форка 17.11: разрыв ~11 единиц на 100 USDC при
    ///         индексе 1.19); учёт списывает ФАКТИЧЕСКИ вернутое.
    uint256 public constant RECALL_DUST = 10_000;

    /// @notice Строгой фиксации отзыв: адаптер обязан вернуть amount
    ///         ± RECALL_DUST токена в рамках вызова — иначе весь отзыв
    ///         откатывается.
    function recallFromPool(address adapter_, uint256 amount_) external noDelegateCall {
        if (!isPoolAdapter[adapter_]) revert AdapterUnknown();
        if (amount_ == 0) revert ZeroAmount();
        if (amount_ > inPoolOf[adapter_]) revert InsufficientInPool();
        emit RecalledFromPool(adapter_, amount_);
        uint256 before = token.balanceOf(address(this));
        _recalling = true;
        (bool ok,) = adapter_.call(abi.encodeWithSignature("withdraw(uint256)", amount_));
        _recalling = false;
        if (!ok) revert TransferFailed();
        uint256 back = token.balanceOf(address(this)) - before;
        uint256 diff = back > amount_ ? back - amount_ : amount_ - back;
        if (diff > RECALL_DUST) revert SettleMismatch();
        inPoolOf[adapter_] -= back;
    }

    /// @notice Σ по авторизованным адаптерам.
    function totalInPools() public view returns (uint256 total) {
        uint256 len = poolAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += inPoolOf[poolAdapters[i]];
        }
    }

    /// @notice MVP-скаффолдинг: полный возврат владельцу (сначала отзыв
    ///         всех пулов). Казна уходит вместе с рабочим капиталом.
    function withdrawAll() external onlyOwner noDelegateCall notRecalling {
        uint256 len = poolAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            address adapter = poolAdapters[i];
            if (inPoolOf[adapter] > 0) {
                _recall(adapter, inPoolOf[adapter]);
            }
        }
        uint256 amount = token.balanceOf(address(this));
        totalDeposited = 0;
        treasuryTaken = 0;
        _safeTransfer(owner, amount);
        emit Withdrawn(owner, amount);
    }

    function _recall(address adapter_, uint256 amount_) private {
        emit RecalledFromPool(adapter_, amount_);
        uint256 before = token.balanceOf(address(this));
        _recalling = true;
        (bool ok,) = adapter_.call(abi.encodeWithSignature("withdraw(uint256)", amount_));
        _recalling = false;
        if (!ok) revert TransferFailed();
        uint256 back = token.balanceOf(address(this)) - before;
        uint256 diff = back > amount_ ? back - amount_ : amount_ - back;
        if (diff > RECALL_DUST) revert SettleMismatch();
        inPoolOf[adapter_] -= back;
    }

    /// @dev Безопасные вызовы токена: пузырь реверта + проверка возврата
    ///      для нестандартных (USDC возвращает bool).
    function _safeTransfer(address to, uint256 value) private {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        _check(ok, ret);
    }

    function _safeTransferFrom(address from, address to, uint256 value) private {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, value));
        _check(ok, ret);
    }

    function _check(bool ok, bytes memory ret) private pure {
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            revert TransferFailed();
        }
        if (ret.length > 0 && !abi.decode(ret, (bool))) revert TransferFailed();
    }
}
