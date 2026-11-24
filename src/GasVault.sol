// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IGasVault {
    function treasuryIn() external payable;
}

/// @title GasVault — the fund (ADR-GAS-ARCHITECTURE, 24.11)
/// @notice The system's ETH-side money: the execution half of the
///         treasury ("collected in whatever asset clients pay"), fed by
///         service-fee margins swept from executors. The REACT half
///         (obligations) lives on the fuel depot and is replenished by
///         the auto-faucet chain: this contract's authorized buyer
///         PULLS its purchase funds directly, capped per purchase and
///         bounded by "the system may spend no more than it has
///         earned" (earned − ownerWithdrawn − buyerSpent ≥ pull).
///         The prepaid client pocket ("gas reserve") and the cashier
///         refuel circuit are deliberately GONE: an action pays for
///         itself (pay-on-delivery, fees accrued on the safe).
///         Invariant: treasury ≡ address(this).balance.
contract GasVault is IGasVault {
    address public owner;
    address public executor; // the margin sweeper (per chain)

    /// @notice The ETH fund (wei): margin on service fees; the buyer
    ///         converts portions of it into reactive fuel.
    uint256 public treasury;

    /// @dev P10: immutable pins the address of the real code; under a
    ///      delegatecall address(this) is foreign — entry denied.
    address private immutable _original;

    /// ------------------------------------------------- pull accounting
    /// @notice Cumulative fee income ever received (treasuryIn total).
    uint256 public earned;

    /// @notice Cumulative owner profit withdrawals.
    uint256 public ownerWithdrawn;

    /// @notice Cumulative buyer fuel purchases pulled from the fund.
    uint256 public buyerSpent;

    /// @notice The authorized fuel buyer (the auto-faucet's Sepolia leg).
    address public buyer;

    /// @notice Cap per single purchase pull (wei) — the faucet buys in
    ///          portions; owner-tunable with an event.
    uint256 public buyCapWei;

    event TreasuryUpdated(uint256 weiAmount);
    event TreasuryWithdrawn(address indexed to, uint256 weiAmount);
    event ExecutorAuthorized(address indexed executor);
    event BuyerAuthorized(address indexed buyer, uint256 capWei);
    event BuyCapSet(uint256 capWei);
    event PurchasePulled(address indexed buyer, uint256 weiAmount);

    error NotOwner();
    error NotExecutor();
    error NotBuyer();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientTreasury();
    error CapExceeded(uint256 asked, uint256 cap);
    error SpentAboveEarned(uint256 spentPlus, uint256 earnedLess);
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

    modifier onlyBuyer() {
        if (msg.sender != buyer) revert NotBuyer();
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
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        emit ExecutorAuthorized(executor_);
    }

    /// @notice Authorize the fuel buyer and its per-purchase cap.
    function authorizeBuyer(address buyer_, uint256 capWei_) external onlyOwner noDelegateCall {
        if (buyer_ == address(0)) revert ZeroAddress();
        buyer = buyer_;
        buyCapWei = capWei_;
        emit BuyerAuthorized(buyer_, capWei_);
    }

    /// @notice The purchase cap is money — announced on change.
    function setBuyCap(uint256 capWei_) external onlyOwner noDelegateCall {
        buyCapWei = capWei_;
        emit BuyCapSet(capWei_);
    }

    /// @notice Margin intake: service-fee margins swept by executors
    ///         and deliberate partner transfers. An explicit entry, not
    ///         a donation (the invariant stays provable).
    function treasuryIn() external payable override {
        treasury += msg.value;
        earned += msg.value;
        emit TreasuryUpdated(treasury);
    }

    /// @notice Treasury → recipient (owner hand: profit extraction).
    function withdrawTreasury(address to, uint256 weiAmount) external onlyOwner noDelegateCall {
        if (weiAmount == 0) revert ZeroAmount();
        if (weiAmount > treasury) revert InsufficientTreasury();
        treasury -= weiAmount;
        ownerWithdrawn += weiAmount;
        emit TreasuryWithdrawn(to, weiAmount);
        emit TreasuryUpdated(treasury);
        (bool ok,) = to.call{value: weiAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice The buyer PULLS its purchase funds itself (the last
    ///         manual operational step dies). Guards: per-purchase cap
    ///         and "the fund spends no more than it has earned"
    ///         (earned − ownerWithdrawn − buyerSpent ≥ weiAmount).
    function pullForPurchase(uint256 weiAmount) external onlyBuyer noDelegateCall {
        if (weiAmount == 0) revert ZeroAmount();
        if (weiAmount > buyCapWei) revert CapExceeded(weiAmount, buyCapWei);
        uint256 earnedLess = earned - ownerWithdrawn - buyerSpent;
        if (weiAmount > earnedLess) {
            revert SpentAboveEarned(buyerSpent + weiAmount, earnedLess);
        }
        treasury -= weiAmount;
        buyerSpent += weiAmount;
        emit PurchasePulled(buyer, weiAmount);
        emit TreasuryUpdated(treasury);
        (bool ok,) = buyer.call{value: weiAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Direct transfers are denied (donation policy: the invariant
    ///      must not drift; use treasuryIn).
    receive() external payable {
        revert DonationsNotAllowed();
    }
}
