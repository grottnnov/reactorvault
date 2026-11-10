// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPoolAdapter} from "../IPoolAdapter.sol";

/// @dev Minimal Aave v3 Pool slice (self-contained repo canon: no
///      external deps for what three calls need). getReserveData is
///      declared as a struct return so the 13-word tuple decodes into
///      memory instead of blowing the stack.
interface IAavePool {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
    }

    function supply(address asset, uint256 amount, address onBehalf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (ReserveData memory);
}

/// @dev WETH9 slice: wrap/unwrap + ERC20 views the adapter needs.
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address guy) external view returns (uint256);
}

interface IERC20Balance {
    function balanceOf(address who) external view returns (uint256);
}

/// @title AavePoolAdapter — native ETH ⇄ Aave v3 WETH supply
/// @notice The safe settles strictly: withdraw returns EXACTLY the
///         requested ETH to the caller. `principal` is the settlement
///         basis (what the safe deployed); interest accrues on top in
///         the aToken position and is swept by the owner hatch —
///         demo-scale simplification, recorded in the ADR.
contract AavePoolAdapter is IPoolAdapter {
    IAavePool public immutable aavePool;
    IWETH9 public immutable weth;
    IERC20Balance public immutable aToken;
    address public immutable owner;

    uint256 public principal;

    error AbovePrincipal();
    error SettleMismatch();
    error TransferFailed();
    error NotOwner();

    constructor(address aavePool_, address weth_) {
        aavePool = IAavePool(aavePool_);
        weth = IWETH9(weth_);
        aToken = IERC20Balance(_aTokenOf(aavePool_, weth_));
        owner = msg.sender;
    }

    function supply() external payable override {
        weth.deposit{value: msg.value}();
        weth.approve(address(aavePool), msg.value);
        aavePool.supply(address(weth), msg.value, address(this), 0);
        principal += msg.value;
    }

    function withdraw(uint256 ethAmount) external override {
        if (ethAmount > principal) revert AbovePrincipal();
        principal -= ethAmount;
        uint256 got = aavePool.withdraw(address(weth), ethAmount, address(this));
        if (got != ethAmount) revert SettleMismatch();
        weth.withdraw(ethAmount);
        (bool ok,) = msg.sender.call{value: ethAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Settlement basis (what the safe may recall).
    function totalSupplied() external view override returns (uint256) {
        return principal;
    }

    /// @notice The true aToken position: principal + accrued interest.
    function truePosition() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Aave's annual liquidity rate, ray → WAD (1e18 = 100%).
    function supplyRatePerYear() external view override returns (uint256) {
        IAavePool.ReserveData memory rd = aavePool.getReserveData(address(weth));
        return uint256(rd.currentLiquidityRate) / 1e9;
    }

    /// @notice Owner hatch: withdraw accrued interest above the
    ///         principal (unwrapped and forwarded as ETH).
    function sweepExcess(address to) external {
        if (msg.sender != owner) revert NotOwner();
        uint256 excess = aToken.balanceOf(address(this)) - principal;
        if (excess > 0) {
            aavePool.withdraw(address(weth), excess, address(this));
            weth.withdraw(weth.balanceOf(address(this)));
            (bool ok,) = to.call{value: address(this).balance}("");
            if (!ok) revert TransferFailed();
        }
    }

    function _aTokenOf(address pool_, address weth_) private view returns (address) {
        IAavePool.ReserveData memory rd = IAavePool(pool_).getReserveData(weth_);
        return rd.aTokenAddress;
    }

    /// @dev WETH9 unwraps via a plain ETH transfer.
    receive() external payable {}
}
