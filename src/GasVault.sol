// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IGasVault {
    function consumeGasReserve(uint256 weiAmount) external;
    function releaseReserveTo(address to, uint256 weiAmount) external;
    function treasuryIn() external payable;
}

/// @title GasVault — the battery (ADR-EXPANSION §2)
/// @notice The ONE gas pocket of the system, shared by every AssetVault
///         and every chain: pocket 1 — the client's fuel reserve (ETH),
///         pocket 2 — the treasury (the ETH fund: margin on gas spending
///         + bps routed from asset deposits). The Executor's ETH tank
///         and the auto-faucet both draw from here. Invariant:
///         gasReserve + treasury ≡ address(this).balance. Pattern: the
///         ERC-4337 single user deposit — one gas pocket pays for all
///         operations, regardless of asset or chain. Events keep the
///         v2 names/topics (GasReserveUpdated) so the cashier's
///         subscription stays compatible.
contract GasVault is IGasVault {
    address public owner;
    address public executor;

    /// @notice Pocket 1: the client's reserve for paying their gas (wei).
    uint256 public gasReserve;

    /// @notice Pocket 2: the treasury share — the ETH fund (wei); the
    ///         auto-faucet uses it to buy lREACT for the depot.
    uint256 public treasury;

    /// @dev P10: immutable pins the address of the real code; under a
    ///      delegatecall address(this) is foreign — entry denied.
    address private immutable _original;

    event FuelDeposited(address indexed user, uint256 amount);
    event GasReserveUpdated(uint256 weiAmount);
    event GasReserveConsumed(uint256 weiAmount);
    event TreasuryUpdated(uint256 weiAmount);
    event TreasuryWithdrawn(address indexed to, uint256 weiAmount);
    event Withdrawn(address indexed user, uint256 amount);
    event ExecutorAuthorized(address indexed executor);

    error NotOwner();
    error NotExecutor();
    error ZeroAmount();
    error InsufficientReserve();
    error InsufficientTreasury();
    error TransferFailed();
    error DelegateCallNotAllowed();
    error DonationsNotAllowed();

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

    function authorizeExecutor(address executor_) external onlyOwner noDelegateCall {
        executor = executor_;
        emit ExecutorAuthorized(executor_);
    }

    /// @notice Client fuel top-up — one pocket for all assets and
    ///         chains (the user "fills up" once, not per-asset).
    function depositFuel() external payable noDelegateCall {
        if (msg.value == 0) revert ZeroAmount();
        gasReserve += msg.value;
        emit FuelDeposited(msg.sender, msg.value);
        emit GasReserveUpdated(gasReserve);
    }

    /// @notice Gas spending (the cashier, callback from Lasna): client
    ///         reserve → treasury. ETH never leaves the battery; the
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
        emit GasReserveConsumed(weiAmount);
        emit GasReserveUpdated(gasReserve);
        (bool ok,) = to.call{value: weiAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Treasury intake: bps routed from AssetVault deposits and
    ///         deliberate partner transfers. An explicit entry, not a
    ///         donation (the invariant stays provable).
    function treasuryIn() external payable override {
        treasury += msg.value;
        emit TreasuryUpdated(treasury);
    }

    /// @notice Treasury → recipient (the converter / auto-faucet, owner hand).
    function withdrawTreasury(address to, uint256 weiAmount) external onlyOwner noDelegateCall {
        if (weiAmount == 0) revert ZeroAmount();
        if (weiAmount > treasury) revert InsufficientTreasury();
        treasury -= weiAmount;
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
        gasReserve = 0;
        treasury = 0;
        emit GasReserveUpdated(0);
        emit TreasuryUpdated(0);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(owner, amount);
    }

    /// @dev Direct transfers are denied (donation policy — G15: the
    ///      invariant must not drift; use depositFuel/treasuryIn).
    receive() external payable {
        revert DonationsNotAllowed();
    }
}
