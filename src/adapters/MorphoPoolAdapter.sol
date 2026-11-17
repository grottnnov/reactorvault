// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPoolAdapter} from "../IPoolAdapter.sol";
import {IWETH9} from "./AavePoolAdapter.sol";

/// @dev Minimal Morpho Blue slice (self-contained repo canon).
interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    function createMarket(MarketParams memory marketParams) external;
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external;
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    function market(bytes32 id) external view returns (Market memory);
    function position(bytes32 id, address user) external view returns (Position memory);
}

interface IIrm {
    /// @dev The stateful borrowRate is onlyMorpho-guarded; the view twin
    ///      is public — same math, same state (AdaptiveCurveIrm v1.0.0).
    function borrowRateView(IMorpho.MarketParams memory marketParams, IMorpho.Market memory market)
        external
        view
        returns (uint256);
}

/// @title MorphoPoolAdapter — native ETH ⇄ Morpho Blue supply on one market
/// @notice The safe settles strictly: withdraw returns EXACTLY the
///         requested ETH to the caller (Morpho withdraws by assets and
///         reverts on insufficient market liquidity — the operator lever
///         repays before the rate drops, so a rate-driven exit always
///         finds liquidity). `principal` is the settlement basis; accrued
///         interest is swept by the owner hatch (only after a full recall).
/// @dev Incident #19: supply/withdraw are vault-only — the money-holder
///      checks the right itself (Uniswap v4 onlyPoolManager / Yearn
///      onlyVault pattern; ToB: missing caller checks = failure #1).
contract MorphoPoolAdapter is IPoolAdapter {
    uint256 private constant WAD = 1e18;
    uint256 private constant VIRTUAL_ASSETS = 1; // Morpho SharesMathLib
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice The only address allowed to supply/withdraw (the safe).
    address public immutable assetVault;
    IMorpho public immutable morpho;
    address public immutable loanToken;
    address public immutable collateralToken;
    address public immutable marketOracle;
    address public immutable marketIrm;
    uint256 public immutable marketLltv;
    bytes32 public immutable marketId;
    IIrm public immutable irm;
    IWETH9 public immutable weth;
    address public immutable owner;

    uint256 public principal;

    error AbovePrincipal();
    error SettleMismatch();
    error TransferFailed();
    error NotOwner();
    error NotVault();
    error ZeroAddress();
    error PrincipalOutstanding();

    constructor(address assetVault_, address morpho_, IMorpho.MarketParams memory marketParams_, address irm_) {
        if (assetVault_ == address(0)) revert ZeroAddress();
        assetVault = assetVault_;
        morpho = IMorpho(morpho_);
        loanToken = marketParams_.loanToken;
        collateralToken = marketParams_.collateralToken;
        marketOracle = marketParams_.oracle;
        marketIrm = marketParams_.irm;
        marketLltv = marketParams_.lltv;
        marketId = keccak256(abi.encode(marketParams_)); // MarketParamsLib.id()
        irm = IIrm(irm_);
        weth = IWETH9(marketParams_.loanToken);
        owner = msg.sender;
    }

    /// @notice The market parameters, reassembled.
    function marketParams() public view returns (IMorpho.MarketParams memory) {
        return IMorpho.MarketParams(loanToken, collateralToken, marketOracle, marketIrm, marketLltv);
    }

    function _mp() internal view returns (IMorpho.MarketParams memory) {
        return IMorpho.MarketParams(loanToken, collateralToken, marketOracle, marketIrm, marketLltv);
    }

    modifier onlyVault() {
        if (msg.sender != assetVault) revert NotVault();
        _;
    }

    function supply() external payable override onlyVault {
        weth.deposit{value: msg.value}();
        weth.approve(address(morpho), msg.value);
        (uint256 assetsOut,) = morpho.supply(_mp(), msg.value, 0, address(this), "");
        if (assetsOut != msg.value) revert SettleMismatch();
        principal += msg.value;
    }

    function withdraw(uint256 ethAmount) external override onlyVault {
        if (ethAmount > principal) revert AbovePrincipal();
        principal -= ethAmount;
        (uint256 assetsOut,) = morpho.withdraw(_mp(), ethAmount, 0, address(this), address(this));
        if (assetsOut != ethAmount) revert SettleMismatch();
        weth.withdraw(ethAmount);
        (bool ok,) = msg.sender.call{value: ethAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Settlement basis (what the safe may recall).
    function totalSupplied() external view override returns (uint256) {
        return principal;
    }

    /// @notice The true market position incl. interest: supply shares
    ///         quoted in assets with Morpho's virtual-share math.
    ///         Magnitudes are bounded (wei-scale shares × assets), plain
    ///         checked math reverts loudly instead of wrapping.
    function truePosition() external view returns (uint256) {
        IMorpho.Position memory p = morpho.position(marketId, address(this));
        IMorpho.Market memory m = morpho.market(marketId);
        return uint256(p.supplyShares) * (uint256(m.totalSupplyAssets) + VIRTUAL_ASSETS)
            / (uint256(m.totalSupplyShares) + VIRTUAL_SHARES);
    }

    /// @notice Annual supply rate, WAD: borrowRate × utilization × (1 −
    ///         fee), per-second rate × seconds/year. Bounded magnitudes
    ///         (per-second WAD × year ≈ 1e26) — checked math is safe.
    function supplyRatePerYear() external view override returns (uint256) {
        IMorpho.Market memory m = morpho.market(marketId);
        if (m.totalSupplyAssets == 0 || m.totalBorrowAssets == 0) return 0;
        uint256 borrowRate = irm.borrowRateView(_mp(), m); // per second, WAD
        uint256 utilization = uint256(m.totalBorrowAssets) * WAD / uint256(m.totalSupplyAssets);
        uint256 supplyPerSecond = borrowRate * utilization / WAD;
        if (m.fee > 0) supplyPerSecond = supplyPerSecond * (WAD - m.fee) / WAD;
        return supplyPerSecond * SECONDS_PER_YEAR;
    }

    /// @notice Owner hatch: withdraw the whole position (principal +
    ///         interest) — allowed only after the safe has fully recalled,
    ///         so the settlement basis can never go hollow.
    function sweepAll(address to) external {
        if (msg.sender != owner) revert NotOwner();
        if (principal != 0) revert PrincipalOutstanding();
        IMorpho.Position memory p = morpho.position(marketId, address(this));
        if (p.supplyShares > 0) {
            morpho.withdraw(_mp(), 0, p.supplyShares, address(this), address(this));
            weth.withdraw(weth.balanceOf(address(this)));
            (bool ok,) = to.call{value: address(this).balance}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @dev WETH9 unwraps via a plain ETH transfer.
    receive() external payable {}
}
