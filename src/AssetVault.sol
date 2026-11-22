// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IGasVault} from "./GasVault.sol";
import {IPoolAdapter} from "./IPoolAdapter.sol";

interface IAssetVault {
    function rebalanceTarget() external view returns (uint256);
    function deployToPool(address adapter, uint256 amount) external;
    function recallFromPool(address adapter, uint256 amount) external;
    function inPoolOf(address adapter) external view returns (uint256);
}

/// @title AssetVault — the per-asset safe (ADR-EXPANSION §2)
/// @notice Pure working capital: one instance per asset (ETH today;
///         USDC/USDG/stock tokens after the hackathon — a new deploy,
///         not a rewrite). No gas logic: fuel lives in the GasVault,
///         the treasury share (treasuryBps of a deposit) is routed to
///         the battery at deposit time. Invariant:
///         address(this).balance + totalInPools + treasurySent
///         ≡ totalDeposited — capital only ever sits in the safe or in
///         an authorized pool adapter (rebalancing transits THROUGH the
///         safe, ADR-EXPANSION §2; the executor orchestrates, never
///         holds). P9: events before external calls; P10: noDelegateCall
///         on every entry point; P5 debt: withdrawAll is MVP scaffolding,
///         per-user accounting is W3 (G15).
contract AssetVault is IAssetVault {
    address public owner;
    address public executor;
    IGasVault public gasVault;

    /// @notice Treasury share of every deposit, basis points (≤ 10_000).
    uint32 public treasuryBps;

    /// @notice Working deposits ever received (the fee-on-mint treasury
    ///         share leaves for the battery and is not in the users' ledger).
    uint256 public totalDeposited;

    /// @notice The treasury share already routed to the battery.
    uint256 public treasurySent;

    /// ------------------------------------------------- ERC-4626-lite (17.11)
    /// @notice User share accounting (ADR-MULTI-ASSET-CHAINS): a deposit
    ///         mints shares on WORKING capital (minus the treasury), a
    ///         redeem burns them; NAV = ledgerFree + real pool positions.
    ///         Ether donations are impossible by construction (receive
    ///         reverts), the VIRTUAL_UNITS offset holds the empty safe's math.
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    uint256 internal constant VIRTUAL_UNITS = 1e12; // 1 μETH

    event VaultDeposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event VaultRedeem(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Authorized pool adapters and per-adapter deployed capital.
    address[] public poolAdapters;
    mapping(address => bool) public isPoolAdapter;
    mapping(address => uint256) public inPoolOf;

    /// @dev Settlement window flag: native ETH may enter receive()
    ///      ONLY while an adapter withdraw is being settled — every
    ///      other direct transfer stays a reverted donation.
    bool private _recalling;

    /// @dev P10: immutable pins the address of the real code; under a
    ///      delegatecall address(this) is foreign — entry denied.
    address private immutable _original;

    event Deposited(address indexed user, uint256 amount, uint256 toTreasury);
    event TreasurySent(uint256 weiAmount);
    event ExecutorAuthorized(address indexed executor);
    event Withdrawn(address indexed user, uint256 amount);
    event PoolAdapterAuthorized(address indexed adapter);
    event DeployedToPool(address indexed adapter, uint256 amount);
    event RecalledFromPool(address indexed adapter, uint256 amount);

    error NotOwner();
    error NotExecutor();
    error ZeroAddress();
    error ZeroAmount();
    error BadParams();
    error GasVaultNotSet();
    error TransferFailed();
    error DelegateCallNotAllowed();
    error DonationsNotAllowed();
    error AdapterUnknown();
    error AdapterAlreadyKnown();
    error InsufficientFree();
    error InsufficientInPool();
    error SettleMismatch();
    error InsufficientShares();
    error ZeroShares();

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

    constructor() {
        owner = msg.sender;
        _original = address(this);
    }

    function setGasVault(IGasVault gasVault_) external onlyOwner noDelegateCall {
        if (address(gasVault_) == address(0)) revert ZeroAddress();
        gasVault = gasVault_;
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

    /// @notice Authorize a pool adapter (owner's repair hatch, one per
    ///         pool; ADR-EXPANSION: partners swappable, guards fixed).
    function authorizePoolAdapter(address adapter_) external onlyOwner noDelegateCall {
        if (adapter_ == address(0)) revert ZeroAddress();
        if (isPoolAdapter[adapter_]) revert AdapterAlreadyKnown();
        isPoolAdapter[adapter_] = true;
        poolAdapters.push(adapter_);
        emit PoolAdapterAuthorized(adapter_);
    }

    /// @notice Deploy free capital to a pool (executor only). Effects
    ///         before the external call; a reverting supply undoes the
    ///         ledger atomically.
    function deployToPool(address adapter_, uint256 amount_) external override onlyExecutor noDelegateCall {
        if (!isPoolAdapter[adapter_]) revert AdapterUnknown();
        if (amount_ == 0) revert ZeroAmount();
        if (amount_ > totalDeposited - totalInPools()) revert InsufficientFree();
        inPoolOf[adapter_] += amount_;
        emit DeployedToPool(adapter_, amount_);
        IPoolAdapter(adapter_).supply{value: amount_}();
    }

    /// @notice Recall capital from a pool (executor only). Strict
    ///         settlement: the adapter must return exactly amount_ of
    ///         native ETH within the call — anything else reverts the
    ///         whole recall.
    function recallFromPool(address adapter_, uint256 amount_) external override onlyExecutor noDelegateCall {
        _recall(adapter_, amount_);
    }

    function _recall(address adapter_, uint256 amount_) internal {
        if (!isPoolAdapter[adapter_]) revert AdapterUnknown();
        if (amount_ == 0) revert ZeroAmount();
        if (amount_ > inPoolOf[adapter_]) revert InsufficientInPool();
        emit RecalledFromPool(adapter_, amount_);
        uint256 before = address(this).balance;
        _recalling = true;
        IPoolAdapter(adapter_).withdraw(amount_);
        _recalling = false;
        if (address(this).balance - before != amount_) revert SettleMismatch();
        inPoolOf[adapter_] -= amount_;
    }

    /// @notice The number of authorized adapters (the multi-asset
    ///         executor reads the safe's registry).
    function poolAdapterCount() external view returns (uint256) {
        return poolAdapters.length;
    }

    /// @notice Σ inPoolOf across authorized adapters.
    function totalInPools() public view returns (uint256 total) {
        uint256 len = poolAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += inPoolOf[poolAdapters[i]];
        }
    }

    /// @notice Deposit: the treasury share (bps) is routed to the
    ///         battery, the rest is working capital. P9: events before
    ///         the external treasuryIn call; a failure reverts the
    ///         whole deposit atomically.
    function deposit() external payable noDelegateCall {
        if (msg.value == 0) revert ZeroAmount();
        uint256 toTreasury = msg.value * treasuryBps / 10_000;
        uint256 working = msg.value - toTreasury;
        uint256 shares = (working * (totalShares + VIRTUAL_UNITS)) / (totalAssets() + VIRTUAL_UNITS);
        if (shares == 0) revert ZeroShares();
        totalShares += shares;
        shareOf[msg.sender] += shares;
        totalDeposited += working;
        emit VaultDeposit(msg.sender, msg.sender, msg.value, shares);
        emit Deposited(msg.sender, msg.value, toTreasury);
        if (toTreasury > 0) {
            treasurySent += toTreasury;
            if (address(gasVault) == address(0)) revert GasVaultNotSet();
            emit TreasurySent(toTreasury);
            gasVault.treasuryIn{value: toTreasury}();
        }
    }

    /// @notice User assets: ledgerFree + real pool positions.
    function totalAssets() public view returns (uint256) {
        uint256 invested;
        uint256 len = poolAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            (bool ok, bytes memory ret) = poolAdapters[i].staticcall(abi.encodeWithSignature("truePosition()"));
            if (ok && ret.length >= 32) {
                invested += abi.decode(ret, (uint256));
            }
        }
        return totalDeposited - totalInPools() + invested;
    }

    function convertToShares(uint256 assets_) external view returns (uint256) {
        return (assets_ * (totalShares + VIRTUAL_UNITS)) / (totalAssets() + VIRTUAL_UNITS);
    }

    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return (shares_ * (totalAssets() + VIRTUAL_UNITS)) / (totalShares + VIRTUAL_UNITS);
    }

    /// @notice User exit: burns shares, recalls from pools itself when
    ///         free capital is short. "An exit that always works".
    function redeem(uint256 shares_) external noDelegateCall {
        if (shares_ == 0) revert ZeroAmount();
        if (shareOf[msg.sender] < shares_) revert InsufficientShares();
        uint256 assets = (shares_ * (totalAssets() + VIRTUAL_UNITS)) / (totalShares + VIRTUAL_UNITS);
        if (assets > totalDeposited - totalInPools()) {
            uint256 need = assets - (totalDeposited - totalInPools());
            uint256 len = poolAdapters.length;
            for (uint256 i = 0; i < len && need > 0; i++) {
                address adapter = poolAdapters[i];
                uint256 there = inPoolOf[adapter];
                if (there > 0) {
                    uint256 take = there < need ? there : need;
                    _recall(adapter, take);
                    need -= take;
                }
            }
            if (need > 0) revert InsufficientFree();
        }
        totalShares -= shares_;
        shareOf[msg.sender] -= shares_;
        totalDeposited -= assets;
        emit VaultRedeem(msg.sender, msg.sender, msg.sender, assets, shares_);
        (bool ok,) = msg.sender.call{value: assets}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Working capital (free): the safe's balance. Capital
    ///         deployed to pools is tracked in inPoolOf (it lives in
    ///         the adapters, not here).
    function rebalanceTarget() external view override returns (uint256 amount) {
        amount = totalDeposited - totalInPools(); // ledger: no donations by construction
    }

    /// @notice MVP scaffolding: a full sweep to the owner. Recalls
    ///         every pool first (the client's exit always works, at the
    ///         speed of pool liquidity). Known debt: per-user balances
    ///         do not exist yet (G15/W3); must not survive the arrival
    ///         of third-party deposits.
    function withdrawAll() external onlyOwner noDelegateCall {
        uint256 len = poolAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            address adapter = poolAdapters[i];
            if (inPoolOf[adapter] > 0) {
                _recall(adapter, inPoolOf[adapter]);
            }
        }
        uint256 amount = address(this).balance;
        totalDeposited = 0;
        treasurySent = 0;
        emit Withdrawn(owner, amount); // P9: the event precedes the external call
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Direct transfers are denied (donation policy — G15: the
    ///      invariant must not drift; a deposit is an explicit call).
    ///      The single exception is the _recalling window: pool adapters
    ///      pay their withdrawal back to the safe inside the call.
    receive() external payable {
        if (!_recalling) revert DonationsNotAllowed();
    }
}
