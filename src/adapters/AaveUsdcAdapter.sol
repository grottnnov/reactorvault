// SPDX-License-License: MIT
pragma solidity ^0.8.29;

/// @dev Минимальный Aave v3 Pool-срез для USDC-поставки (канон репо:
///      самодостаточные интерфейсы, без внешних зависимостей).
interface IAavePoolUsdc {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex; // v3.2 mainnet: 13-е поле (Sepolia-пул старее)
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

interface IERC20Usdc {
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function scaledBalanceOf(address who) external view returns (uint256);
}

/// @title AaveUsdcAdapter — USDC ⇄ Aave v3 supply (mainnet-ветка).
/// @notice Сейф ПУШАЕТ токен (transfer) — адаптер принимает его в баланс
///         и кладёт в пул; withdraw возвращает ровно amount отправителю
///         (msg.sender = сейф). Гварды: только сейф (инцидент #19 —
///         гвард живёт там, где деньги), ETH не принимается.
contract AaveUsdcAdapter {
    /// @notice Единственный адрес, имеющий право supply/withdraw.
    address public immutable assetVault;
    IAavePoolUsdc public immutable aavePool;
    IERC20Usdc public immutable usdc;
    IERC20Usdc public immutable aToken;
    address public immutable owner;

    uint256 public principal;

    error AbovePrincipal();
    error SettleMismatch();
    error NotOwner();
    error NotVault();

    constructor(address assetVault_, address aavePool_, address usdc_) {
        assetVault = assetVault_;
        aavePool = IAavePoolUsdc(aavePool_);
        usdc = IERC20Usdc(usdc_);
        aToken = IERC20Usdc(IAavePoolUsdc(aavePool_).getReserveData(usdc_).aTokenAddress);
        owner = msg.sender;
    }

    function supply(uint256 amount) external {
        if (msg.sender != assetVault) revert NotVault();
        usdc.approve(address(aavePool), amount);
        aavePool.supply(address(usdc), amount, address(this), 0);
        principal += amount;
    }

    function withdraw(uint256 amount) external returns (bool) {
        if (msg.sender != assetVault) revert NotVault();
        if (amount > principal) revert AbovePrincipal();
        // Индексное округление: зачисление вниз → баланс юзера может
        // быть чуть меньше principal; отзываем min(amount, баланс).
        IAavePoolUsdc.ReserveData memory rd = aavePool.getReserveData(address(usdc));
        uint256 user = (aToken.scaledBalanceOf(address(this)) * uint256(rd.liquidityIndex)) / 1e27;
        uint256 take = amount < user ? amount : user;
        principal -= take;
        uint256 got = aavePool.withdraw(address(usdc), take, address(this));
        if (got != take) revert SettleMismatch();
        require(_send(assetVault, take), "settle: send failed");
        return true;
    }

    function totalSupplied() external view returns (uint256) {
        return principal;
    }

    function truePosition() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Годовая ставка (ray → WAD: 1e27 → 1e18).
    function supplyRatePerYear() external view returns (uint256) {
        return uint256(aavePool.getReserveData(address(usdc)).currentLiquidityRate) / 1e9;
    }

    function _send(address to, uint256 value) private returns (bool) {
        (bool ok, bytes memory ret) =
            address(usdc).call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
