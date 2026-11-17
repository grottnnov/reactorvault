// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Минимальный Morpho Blue-срез (как в MorphoPoolAdapter, канон репо).
interface IMorphoUsdc {
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
    function market(bytes32 id) external view returns (Market memory);
    function position(bytes32 id, address user) external view returns (Position memory);
}

interface IIrmUsdc {
    function borrowRateView(IMorphoUsdc.MarketParams memory marketParams, IMorphoUsdc.Market memory market)
        external
        view
        returns (uint256);
}

interface IERC20M {
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title MorphoUsdcAdapter — USDC ⇄ Morpho Blue supply (mainnet-ветка).
/// @notice Рынок задаётся ПОЛНЫМИ параметрами в конструкторе (сверка
///         marketId 1:1 с реальным рынком — на деплое); сейф пушит токен,
///         withdraw возвращает ровно amount отправителю (msg.sender =
///         сейф). Гвард только-сейф (инцидент #19), ETH не принимается.
contract MorphoUsdcAdapter {
    uint256 private constant WAD = 1e18;

    /// @notice Единственный адрес, имеющий право supply/withdraw.
    address public immutable assetVault;
    IMorphoUsdc public immutable morpho;
    address public immutable loanToken;
    address public immutable collateralToken;
    address public immutable marketOracle;
    address public immutable marketIrm;
    uint256 public immutable marketLltv;
    bytes32 public immutable marketId;
    IIrmUsdc public immutable irm;

    uint256 public principal;

    error AbovePrincipal();
    error SettleMismatch();
    error NotVault();

    constructor(
        address assetVault_,
        address morpho_,
        IMorphoUsdc.MarketParams memory mp_,
        address irm_,
        bytes32 marketId_
    ) {
        assetVault = assetVault_;
        morpho = IMorphoUsdc(morpho_);
        loanToken = mp_.loanToken;
        collateralToken = mp_.collateralToken;
        marketOracle = mp_.oracle;
        marketIrm = mp_.irm;
        marketLltv = mp_.lltv;
        irm = IIrmUsdc(irm_);
        marketId = marketId_; // сверка с keccak(abi.encode(mp_)) — на деплое
    }

    function marketParams() public view returns (IMorphoUsdc.MarketParams memory) {
        return IMorphoUsdc.MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: marketOracle,
            irm: marketIrm,
            lltv: marketLltv
        });
    }

    function supply(uint256 amount) external {
        if (msg.sender != assetVault) revert NotVault();
        IERC20M(loanToken).approve(address(morpho), amount);
        (uint256 assetsOut,) = morpho.supply(marketParams(), amount, 0, address(this), "");
        if (assetsOut != amount) revert SettleMismatch();
        principal += amount;
    }

    function withdraw(uint256 amount) external returns (bool) {
        if (msg.sender != assetVault) revert NotVault();
        if (amount > principal) revert AbovePrincipal();
        // Живой урок форка 17.11: полный отзыв «по активам» невозможен —
        // Morpho округляет шары ВВЕРХ (нужно S+1 против наминченных S,
        // паника 0x11). Поэтому: полный выход — по ШАРАМ позиции,
        // частичный — по активам. Обе ветки возвращают amount ± пылевой
        // допуск сейфа (RECALL_DUST).
        IMorphoUsdc.Market memory m = morpho.market(marketId);
        uint256 shares = morpho.position(marketId, address(this)).supplyShares;
        uint256 assets = (shares * uint256(m.totalSupplyAssets)) / uint256(m.totalSupplyShares);
        uint256 assetsOut;
        if (amount >= assets) {
            // полный выход: по шарам — ровно вся позиция
            (assetsOut,) = morpho.withdraw(marketParams(), 0, shares, address(this), address(this));
            principal = 0;
        } else {
            (assetsOut,) = morpho.withdraw(marketParams(), amount, 0, address(this), address(this));
            principal -= amount;
        }
        require(IERC20M(loanToken).balanceOf(address(this)) >= assetsOut, "settle: token not in");
        (bool ok, bytes memory ret) =
            address(loanToken).call(abi.encodeWithSignature("transfer(address,uint256)", assetVault, assetsOut));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "settle: send failed");
        return true;
    }

    function totalSupplied() external view returns (uint256) {
        return principal;
    }

    /// @notice Годовая ставка предложения: borrowRate × utilization × (1−fee).
    function supplyRatePerYear() external view returns (uint256) {
        IMorphoUsdc.Market memory m = morpho.market(marketId);
        if (m.totalBorrowAssets == 0 || m.totalSupplyAssets == 0) return 0;
        uint256 borrowRate = irm.borrowRateView(marketParams(), m);
        uint256 utilization = (uint256(m.totalBorrowAssets) * WAD) / uint256(m.totalSupplyAssets);
        uint256 feeFactor = WAD - m.fee;
        return (borrowRate * utilization * feeFactor) / (WAD * WAD);
    }
}
