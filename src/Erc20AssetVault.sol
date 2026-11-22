// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev A minimal ERC-20 slice (repo canon: no external dependencies;
///      real USDC fits into this slice, including bool returns).
interface IERC20Asset {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title Erc20AssetVault — the ERC-20 asset safe (USDC branch).
/// @notice ADR-EXPANSION: "a new asset = a new instance, not a rewrite
///         of the old one". The ETH safe lives its own life; this one
///         takes USDC via transferFrom, the treasury share accrues
///         INSIDE (in USDC, the withdrawal hatch is milestone G15),
///         working capital is pushed into pool adapters and returned
///         by strict settlement. Invariant:
///         tokenBalance + totalInPools + treasuryWithdrawn ≡ totalDeposited
///         (the treasury is not subtracted — it stays in the safe's balance).
///         P5: withdrawAll is MVP scaffolding (per-user accounting — G15).
///         P10: noDelegateCall on every entry point. Ether is not
///         accepted: the contract is not payable.
contract Erc20AssetVault {
    IERC20Asset public immutable token;
    address public owner;
    address public executor;

    /// @notice Treasury share of every deposit, bps (≤ 10_000).
    uint32 public treasuryBps;

    uint256 public totalDeposited;
    /// @notice Reserved treasury (in the token, sits in the safe's balance).
    uint256 public treasuryTaken;

    /// ------------------------------------------------- ERC-4626-lite (17.11)
    /// @notice User share accounting (ADR-MULTI-ASSET-CHAINS): a deposit
    ///         mints shares, a redeem burns them; NAV = free (minus
    ///         treasury) + REAL pool positions (they grow with interest).
    ///         Protection against first-deposit donation inflation: the
    ///         virtual VIRTUAL_UNITS offset in both parts of the ratio
    ///         (Solmate pattern); rounding always in the safe's favor.
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    /// @dev Offset against the first-deposit attack: in an empty safe
    ///      1 unit of the asset ≠ a giant share; a red test is attached.
    uint256 internal constant VIRTUAL_UNITS = 1_000_000;

    event VaultDeposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event VaultRedeem(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    address[] public poolAdapters;
    mapping(address => bool) public isPoolAdapter;
    mapping(address => uint256) public inPoolOf;

    /// @dev P10: an immutable pin of the real code.
    address private immutable _original;

    /// @dev CEI guard of settlement: external adapter calls go before
    ///      the state write — reentrancy from an adapter is forbidden
    ///      (Slither reentrancy-balance High, 17.11; a malicious adapter
    ///      is the registry owner's pick, but the depth is locked anyway).
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
    error InsufficientShares();

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

    /// @notice The number of authorized adapters (for the executor's
    ///         iteration over the multi-asset registry).
    function poolAdapterCount() external view returns (uint256) {
        return poolAdapters.length;
    }

    /// @notice Deposit: the user gives approve, the safe pulls the
    ///         token, mints shares. Treasury: fee-on-mint — the INCOMING
    ///         user pays the fee (shares are minted on assets-minus-treasury;
    ///         old holders do not pay for someone else's entry — the OZ
    ///         fee-vault model).
    function deposit(uint256 amount_) external noDelegateCall notRecalling {
        if (amount_ == 0) revert ZeroAmount();
        uint256 toTreasury = amount_ * treasuryBps / 10_000;
        uint256 working = amount_ - toTreasury;
        uint256 shares = _convertToShares(working);
        if (shares == 0) revert ZeroAmount(); // dust mints no shares
        totalShares += shares;
        shareOf[msg.sender] += shares;
        totalDeposited += working;
        if (toTreasury > 0) {
            treasuryTaken += toTreasury;
        }
        emit VaultDeposit(msg.sender, msg.sender, amount_, shares);
        emit Deposited(msg.sender, amount_, toTreasury);
        _safeTransferFrom(msg.sender, address(this), amount_);
    }

    /// @notice User assets in full: the BY-LEDGER free part (working
    ///         deposits − in pools; the fee-on-mint treasury is NOT in
    ///         the ledger) + real pool positions (with interest). A direct
    ///         token donation to the safe does NOT enter NAV — the
    ///         first-deposit donation attack is dead for large amounts
    ///         too, not only within the offset.
    function totalAssets() public view returns (uint256) {
        uint256 free = totalDeposited - totalInPools();
        uint256 len = poolAdapters.length;
        uint256 invested;
        for (uint256 i = 0; i < len; i++) {
            (bool ok, bytes memory ret) = poolAdapters[i].staticcall(abi.encodeWithSignature("truePosition()"));
            if (ok && ret.length >= 32) {
                invested += abi.decode(ret, (uint256));
            }
        }
        return free + invested;
    }

    /// @dev Free user capital by ledger: working deposits − in pools
    ///      (the treasury and donations sit there physically, but are not the user's).
    function _ledgerFree() internal view returns (uint256) {
        return totalDeposited - totalInPools();
    }

    function _convertToShares(uint256 assets_) internal view returns (uint256) {
        return (assets_ * (totalShares + VIRTUAL_UNITS)) / (totalAssets() + VIRTUAL_UNITS);
    }

    function _convertToAssets(uint256 shares_) internal view returns (uint256) {
        return (shares_ * (totalAssets() + VIRTUAL_UNITS)) / (totalShares + VIRTUAL_UNITS);
    }

    function convertToShares(uint256 assets_) external view returns (uint256) {
        return _convertToShares(assets_);
    }

    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return _convertToAssets(shares_);
    }

    /// @notice User exit: burns shares, recalls from pools itself when
    ///         free capital is short. "An exit that always works".
    function redeem(uint256 shares_) external noDelegateCall notRecalling {
        if (shares_ == 0) revert ZeroAmount();
        if (shareOf[msg.sender] < shares_) revert InsufficientShares();
        uint256 assets = _convertToAssets(shares_);
        uint256 free = _ledgerFree();
        if (free < assets) {
            uint256 need = assets - free;
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
        totalDeposited -= assets; // the withdrawn leaves the ledger — NAV does not inflate
        emit VaultRedeem(msg.sender, msg.sender, msg.sender, assets, shares_);
        _safeTransfer(msg.sender, assets);
    }

    /// @notice Free working capital by ledger: deposits − treasury −
    ///         in pools (the treasury is inaccessible to pools; donations
    ///         are not working capital).
    function rebalanceTarget() external view returns (uint256 amount) {
        amount = _ledgerFree();
    }

    /// @notice Push model: the safe itself transfers the token to the
    ///         adapter (no approve shacks). Effects before the external call.
    function deployToPool(address adapter_, uint256 amount_) external onlyExecutor noDelegateCall notRecalling {
        if (!isPoolAdapter[adapter_]) revert AdapterUnknown();
        if (amount_ == 0) revert ZeroAmount();
        if (amount_ > _ledgerFree()) revert InsufficientFree();
        inPoolOf[adapter_] += amount_;
        emit DeployedToPool(adapter_, amount_);
        _safeTransfer(adapter_, amount_);
    }

    /// @notice Strict settlement with a dust tolerance: pools with an
    ///         interest index (Aave liquidityIndex, Morpho shares) round
    ///         the credit down — recalling exactly the principal is
    ///         impossible. The 0.01 USDC tolerance covers the rounding
    ///         with a ×1000 margin (fork measurement 17.11: a gap of ~11
    ///         units per 100 USDC at index 1.19); accounting debits what
    ///         was ACTUALLY returned.
    uint256 public constant RECALL_DUST = 10_000;

    /// @notice Strict-settlement recall: the adapter must return amount
    ///         ± RECALL_DUST of the token within the call — otherwise
    ///         the whole recall reverts.
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

    /// @notice Σ inPoolOf across authorized adapters.
    function totalInPools() public view returns (uint256 total) {
        uint256 len = poolAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += inPoolOf[poolAdapters[i]];
        }
    }

    /// @notice MVP scaffolding: a full return to the owner (all pools
    ///         recalled first). The treasury leaves together with the
    ///         working capital.
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
        emit Withdrawn(owner, amount); // P9: the event precedes the external call
        _safeTransfer(owner, amount);
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

    /// @dev Safe token calls: revert bubbling + a return check for
    ///      non-standard ones (USDC returns bool).
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
