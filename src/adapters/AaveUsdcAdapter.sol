// SPDX-License-License: MIT
pragma solidity ^0.8.29;

/// @dev A minimal Aave v3 Pool slice for USDC supply (repo canon:
///      self-sufficient interfaces, no external dependencies).
///      Deliberately separate from IAavePool (AavePoolAdapter.sol): the
///      USDC path targets the v3.2 mainnet ABI where ReserveData fields
///      sit in a different order than in the older Sepolia pool — merging
///      the two would silently misdecode (the ABI-mismatch lesson, 17.11).
///      Two vendor ABI generations = two interfaces, a deliberate drift guard.
interface IAavePoolUsdc {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex; // v3.2 mainnet: the 13th field (the Sepolia pool is older)
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

/// @title AaveUsdcAdapter — USDC ⇄ Aave v3 supply (mainnet branch).
/// @notice The safe PUSHES the token (transfer) — the adapter takes it
///         into its balance and places it into the pool; withdraw returns
///         exactly amount to the sender (msg.sender = the safe). Guards:
///         the safe only (incident #19 — the guard lives where the money
///         is), ETH is not accepted.
contract AaveUsdcAdapter {
    /// @notice The single address entitled to supply/withdraw.
    address public immutable assetVault;
    IAavePoolUsdc public immutable aavePool;
    IERC20Usdc public immutable usdc;
    IERC20Usdc public immutable aToken;
    address public immutable owner;

    uint256 public principal;

    error AbovePrincipal();
    error SettleMismatch();
    error SettleSendFailed();
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
        // Index rounding: the credit rounds down → the user's balance
        // may be slightly below principal; recall min(amount, balance).
        IAavePoolUsdc.ReserveData memory rd = aavePool.getReserveData(address(usdc));
        uint256 user = (aToken.scaledBalanceOf(address(this)) * uint256(rd.liquidityIndex)) / 1e27;
        uint256 take = amount < user ? amount : user;
        principal -= take;
        uint256 got = aavePool.withdraw(address(usdc), take, address(this));
        if (got != take) revert SettleMismatch();
        if (!_send(assetVault, take)) revert SettleSendFailed();
        return true;
    }

    function totalSupplied() external view returns (uint256) {
        return principal;
    }

    function truePosition() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice The annual rate (ray → WAD: 1e27 → 1e18).
    function supplyRatePerYear() external view returns (uint256) {
        return uint256(aavePool.getReserveData(address(usdc)).currentLiquidityRate) / 1e9;
    }

    function _send(address to, uint256 value) private returns (bool) {
        (bool ok, bytes memory ret) =
            address(usdc).call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
