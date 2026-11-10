// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IGasVault} from "./GasVault.sol";

interface IAssetVault {
    function rebalanceTarget() external view returns (uint256);
}

/// @title AssetVault — the per-asset safe (ADR-EXPANSION §2)
/// @notice Pure working capital: one instance per asset (ETH today;
///         USDC/USDG/stock tokens after the hackathon — a new deploy,
///         not a rewrite). No gas logic: fuel lives in the GasVault,
///         the treasury share (treasuryBps of a deposit) is routed to
///         the battery at deposit time. Invariant:
///         address(this).balance + treasurySent ≡ totalDeposited
///         (inPools arrives in W2). P9: events before external calls;
///         P10: noDelegateCall on every entry point; P5 debt: withdrawAll
///         is MVP scaffolding, per-user accounting is W3 (G15).
contract AssetVault is IAssetVault {
    address public owner;
    address public executor;
    IGasVault public gasVault;

    /// @notice Treasury share of every deposit, basis points (≤ 10_000).
    uint32 public treasuryBps;

    /// @notice Everything ever deposited (incl. the routed treasury).
    uint256 public totalDeposited;

    /// @notice The treasury share already routed to the battery.
    uint256 public treasurySent;

    /// @dev P10: immutable pins the address of the real code; under a
    ///      delegatecall address(this) is foreign — entry denied.
    address private immutable _original;

    event Deposited(address indexed user, uint256 amount, uint256 toTreasury);
    event TreasurySent(uint256 weiAmount);
    event ExecutorAuthorized(address indexed executor);
    event Withdrawn(address indexed user, uint256 amount);

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error BadParams();
    error GasVaultNotSet();
    error TransferFailed();
    error DelegateCallNotAllowed();
    error DonationsNotAllowed();

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

    /// @notice Deposit: the treasury share (bps) is routed to the
    ///         battery, the rest is working capital. P9: events before
    ///         the external treasuryIn call; a failure reverts the
    ///         whole deposit atomically.
    function deposit() external payable noDelegateCall {
        if (msg.value == 0) revert ZeroAmount();
        uint256 toTreasury = msg.value * treasuryBps / 10_000;
        totalDeposited += msg.value;
        if (toTreasury > 0) {
            treasurySent += toTreasury;
        }
        emit Deposited(msg.sender, msg.value, toTreasury);
        if (toTreasury > 0) {
            if (address(gasVault) == address(0)) revert GasVaultNotSet();
            emit TreasurySent(toTreasury);
            gasVault.treasuryIn{value: toTreasury}();
        }
    }

    /// @notice Working capital (free): the whole balance (W2: minus
    ///         inPools).
    function rebalanceTarget() external view override returns (uint256 amount) {
        amount = address(this).balance;
    }

    /// @notice MVP scaffolding: a full sweep to the owner. Known debt:
    ///         per-user balances do not exist yet (G15/W3); must not
    ///         survive the arrival of third-party deposits.
    function withdrawAll() external onlyOwner noDelegateCall {
        uint256 amount = address(this).balance;
        totalDeposited = 0;
        treasurySent = 0;
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(owner, amount);
    }

    /// @dev Direct transfers are denied (donation policy — G15: the
    ///      invariant must not drift; a deposit is an explicit call).
    receive() external payable {
        revert DonationsNotAllowed();
    }
}
