// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IVaultCore {
    function rebalanceTarget() external view returns (uint256);
    function consumeGasReserve(uint256 weiAmount) external;
    function releaseReserveTo(address to, uint256 weiAmount) external;
}

/// @title VaultCore v2 — an ETH safe with two pockets (ADR-v2)
/// @notice Native-ETH deposit; pocket 1 is the client's gas reserve,
///         pocket 2 is the treasury share (the ETH fund: bps of every
///         deposit + margin on gas spending). Invariant:
///         free + gasReserve + treasury ≡ totalDeposited ≡
///         address(this).balance (inPools arrives in W2).
///         P10 (Uniswap canon): noDelegateCall on every entry point.
///         P5 debt: withdrawAll is MVP scaffolding; per-user accounting
///         is W3 (G15).
contract VaultCore is IVaultCore {
    address public owner;
    address public executor;

    /// @notice Pocket 1: the client's reserve for paying their gas (wei).
    uint256 public gasReserve;
    uint32 public gasReserveBps;
    uint256 public gasReserveCap;

    /// @notice Pocket 2: the treasury share — the ETH fund (wei); the
    ///         auto-faucet uses it to buy lREACT for the depot.
    uint256 public treasury;
    uint32 public treasuryBps;

    /// @notice Everything ever deposited; the invariant anchor against
    ///         the contract balance.
    uint256 public totalDeposited;

    /// @dev P10: immutable pins the address of the real code; under a
    ///      delegatecall address(this) is foreign — entry denied.
    address private immutable _original;

    event Deposited(address indexed user, uint256 amount, uint256 toReserve, uint256 toTreasury);
    event GasReserveUpdated(uint256 weiAmount);
    event GasReserveConsumed(uint256 weiAmount);
    event TreasuryUpdated(uint256 weiAmount);
    event TreasuryWithdrawn(address indexed to, uint256 weiAmount);
    event ExecutorAuthorized(address indexed executor);
    event Withdrawn(address indexed user, uint256 amount);

    error NotOwner();
    error NotExecutor();
    error ZeroAmount();
    error InsufficientReserve();
    error InsufficientTreasury();
    error CapBelowReserve();
    error BadParams();
    error DelegateCallNotAllowed();
    error DonationsNotAllowed();
    error TransferFailed();

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

    /// @notice Deposit split shares: reserve (client gas, capped) and
    ///         treasury (the ETH fund). The cap may not be tightened
    ///         below the actual reserve (invariant-fuzzer lesson,
    ///         CapBelowReserve).
    function setParams(uint32 reserveBps_, uint32 treasuryBps_, uint256 capWei_) external onlyOwner noDelegateCall {
        if (capWei_ < gasReserve) revert CapBelowReserve();
        if (uint256(reserveBps_) + uint256(treasuryBps_) > 10_000) revert BadParams();
        gasReserveBps = reserveBps_;
        treasuryBps = treasuryBps_;
        gasReserveCap = capWei_;
    }

    /// @notice Native-ETH deposit. Automatic split: into the reserve
    ///         (bps, ≤ cap) and the treasury (bps); the rest is free
    ///         (the client's working capital).
    function deposit() external payable noDelegateCall {
        if (msg.value == 0) revert ZeroAmount();
        uint256 toReserve = msg.value * gasReserveBps / 10_000;
        uint256 capRoom = gasReserveCap > gasReserve ? gasReserveCap - gasReserve : 0;
        if (toReserve > capRoom) {
            toReserve = capRoom;
        }
        uint256 toTreasury = msg.value * treasuryBps / 10_000;
        totalDeposited += msg.value;
        if (toReserve > 0) {
            gasReserve += toReserve;
            emit GasReserveUpdated(gasReserve);
        }
        if (toTreasury > 0) {
            treasury += toTreasury;
            emit TreasuryUpdated(treasury);
        }
        emit Deposited(msg.sender, msg.value, toReserve, toTreasury);
    }

    /// @notice Gas spending (the cashier, callback from Lasna): client
    ///         reserve → treasury. ETH never leaves the safe; the
    ///         auto-faucet withdraws it later (withdrawTreasury) in
    ///         portions to buy lREACT.
    function consumeGasReserve(uint256 weiAmount) external onlyExecutor noDelegateCall {
        if (weiAmount > gasReserve) revert InsufficientReserve();
        gasReserve -= weiAmount;
        treasury += weiAmount;
        emit GasReserveConsumed(weiAmount);
        emit GasReserveUpdated(gasReserve);
        emit TreasuryUpdated(treasury);
    }

    /// @notice Release from the client's reserve (wei) to a recipient —
    ///         the Executor's ETH tank (a plain transfer; no swap needed:
    ///         the reserve is ETH).
    function releaseReserveTo(address to, uint256 weiAmount) external onlyExecutor noDelegateCall {
        if (weiAmount > gasReserve) revert InsufficientReserve();
        gasReserve -= weiAmount;
        totalDeposited -= weiAmount;
        emit GasReserveConsumed(weiAmount);
        emit GasReserveUpdated(gasReserve);
        (bool ok,) = to.call{value: weiAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Treasury → recipient (the converter / auto-faucet, owner hand).
    function withdrawTreasury(address to, uint256 weiAmount) external onlyOwner noDelegateCall {
        if (weiAmount == 0) revert ZeroAmount();
        if (weiAmount > treasury) revert InsufficientTreasury();
        treasury -= weiAmount;
        totalDeposited -= weiAmount;
        emit TreasuryWithdrawn(to, weiAmount);
        emit TreasuryUpdated(treasury);
        (bool ok,) = to.call{value: weiAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice MVP scaffolding: a full sweep to the owner. Known debt:
    ///         per-user balances do not exist yet (G15/W3); must not
    ///         survive the arrival of third-party deposits.
    function withdrawAll() external onlyOwner noDelegateCall {
        uint256 amount = address(this).balance;
        totalDeposited = 0;
        if (gasReserve != 0) {
            gasReserve = 0;
            emit GasReserveUpdated(0);
        }
        if (treasury != 0) {
            treasury = 0;
            emit TreasuryUpdated(0);
        }
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(owner, amount);
    }

    /// @notice Working capital (free): balance minus both pockets.
    function rebalanceTarget() external view override returns (uint256 amount) {
        amount = address(this).balance - gasReserve - treasury;
    }

    function authorizeExecutor(address executor_) external onlyOwner noDelegateCall {
        executor = executor_;
        emit ExecutorAuthorized(executor_);
    }

    /// @dev Direct transfers are denied (donation policy — G15: account
    ///      for them or guard; the guard was chosen: explicitness beats
    ///      silent drift).
    receive() external payable {
        revert DonationsNotAllowed();
    }
}
