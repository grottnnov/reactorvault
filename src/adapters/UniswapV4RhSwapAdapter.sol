// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISwapAdapter} from "../ISwapAdapter.sol";

/// @dev Minimal Robinhood-Chain v4 PoolManager slice (self-contained
///      repo canon: no external deps for what five calls need). The RH
///      deployment is a monorepo-era v4 fork whose live interface was
///      read from the verified source 26.11 (Blockscout, partial
///      match): settle() takes NO currency argument (the last synced
///      currency is settled), swap's slippage bound is the sqrt price
///      limit, take pays any recipient.
interface IPoolManagerRh {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified; // negative = exact input
        uint160 sqrtPriceLimitX96;
    }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/// @dev Minimal Robinhood-Chain V4Quoter slice. The quote functions
///      are NOT view on purpose: the quoter simulates the swap inside
///      poolManager.unlock and delivers the result through a caught
///      revert — both steps need transient storage (tstore), which a
///      staticcall forbids. Measured live 26.11: eth_call returns an
///      empty revert; a CALL returns the quote (1 TSLA -> 380.55 USDG
///      on the pinned pool).
interface IV4QuoterRh {
    struct QuoteExactSingleParams {
        IPoolManagerRh.PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IERC20Rh {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title UniswapV4RhSwapAdapter — the guard safe's Robinhood-Chain exchange plugin
/// @notice Sells the stock token into the stable (and buys back) through
///         the Uniswap v4 PoolManager DIRECTLY, bypassing the forked
///         Universal Router entirely: the router fork adds an
///         undocumented minHopPriceX36 word to every v4 swap input
///         (stock SDK calldata reverts), while the PoolManager itself
///         speaks the plain monorepo-era v4 ABI. One hookless pool per
///         pair, chosen by measurement (script/rh-pool-discovery.sh);
///         a pool migration = redeploy + owner rewires the safe's slot.
///         Quotes come from the deployed V4Quoter: they shape only the
///         slippage bound — an understated quote weakens minOut, an
///         accepted demo-scale tradeoff recorded in the ADR (a feed
///         cross-check is the main-deploy hardening candidate).
/// @dev Money path: the adapter holds nothing between transactions.
///      Inside unlockCallback (poolManager-only, the incident-#19
///      canon: the guard lives where the money moves) the fill is
///      checked against minOut BEFORE any settlement — a bad fill
///      reverts the whole unlock (a paid revert is better than a
///      silent bad fill: the executor retries on the next event).
///      Settlement is strict: pay the exact delta owed, take the exact
///      delta earned, take() pays the ORIGINAL caller (the safe) —
///      one transfer fewer, and capital never rests here.
contract UniswapV4RhSwapAdapter is ISwapAdapter {
    /// @notice The Robinhood Chain v4 singleton.
    address public immutable poolManager;
    /// @notice The deployed V4Quoter used for quotes.
    address public immutable quoter;
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hooks;

    /// @dev TickMath bounds (monorepo-era v4): full-range price limits,
    ///      the same "no limit" sentinel the quoter itself uses.
    uint160 private constant MIN_SQRT_LIMIT = 4295128740 + 1;
    uint160 private constant MAX_SQRT_LIMIT = 1461446703485210103287273052203988822378723970341 - 1;

    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    error ZeroAddress();
    error CurrenciesOutOfOrder();
    error BadPair();
    error ZeroAmount();
    error AmountTooBig();
    error TransferFailed();
    error NotPoolManager();
    error NotSelf();
    error TooLittleOut(uint256 amountOut, uint256 minOut);
    error SettleMismatch(uint256 paid, uint256 owed);
    error SettleFailed();

    constructor(address poolManager_, address quoter_, IPoolManagerRh.PoolKey memory key) {
        if (poolManager_ == address(0) || quoter_ == address(0)) revert ZeroAddress();
        if (key.currency0 == address(0) || key.currency1 == address(0) || key.currency0 >= key.currency1) {
            revert CurrenciesOutOfOrder();
        }
        poolManager = poolManager_;
        quoter = quoter_;
        currency0 = key.currency0;
        currency1 = key.currency1;
        fee = key.fee;
        tickSpacing = key.tickSpacing;
        hooks = key.hooks;
    }

    /// @inheritdoc ISwapAdapter
    /// @dev NOT view: the Robinhood V4Quoter quotes through a caught
    ///      revert inside poolManager.unlock, and both steps write
    ///      transient storage — staticcall-readonly contexts die with
    ///      an empty revert (measured 26.11). A tx CALL context works.
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut) {
        bool zeroForOne = _pairDirection(tokenIn, tokenOut);
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > type(uint128).max) revert AmountTooBig();
        (uint256 out,) = IV4QuoterRh(quoter)
            .quoteExactInputSingle(
                IV4QuoterRh.QuoteExactSingleParams({
                    poolKey: _poolKey(), zeroForOne: zeroForOne, exactAmount: uint128(amountIn), hookData: ""
                })
            );
        return out;
    }

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        bool zeroForOne = _pairDirection(tokenIn, tokenOut);
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > type(uint128).max) revert AmountTooBig();
        if (!IERC20Rh(tokenIn).transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        bytes memory payload = abi.encode(zeroForOne, uint128(amountIn), minOut, msg.sender);
        bytes memory ret = IPoolManagerRh(poolManager).unlock(abi.encodeCall(this._swapCallback, (payload)));
        (amountOut) = abi.decode(ret, (uint256));
        // defense in depth: the fill was already bound inside the callback
        if (amountOut < minOut) revert TooLittleOut(amountOut, minOut);
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice The unlock callback: the PoolManager calls exactly this
    ///         (IUnlockCallback), and only it. The payload travels as a
    ///         self-call (the deployed V4Quoter's own pattern): the
    ///         data handed to unlock() IS an encoded _swapCallback
    ///         call, executed here against ourselves.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert NotPoolManager();
        (bool ok, bytes memory ret) = address(this).call(data);
        if (!ok) {
            // bubble the inner revert reason (minOut bound, settle
            // mismatch, ...) unchanged
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        // ret is the raw return of _swapCallback: abi.encode(uint256)
        // — one word, no extra wrapping
        return ret;
    }

    /// @dev The real callback body, reachable only through
    ///      unlockCallback's self-call. Swap, bind the fill, pay the
    ///      input, take the output for the original caller — nothing
    ///      may remain half-done (a revert here unwinds the whole
    ///      unlock, transfer included).
    function _swapCallback(bytes calldata data) external returns (uint256) {
        if (msg.sender != address(this)) revert NotSelf();
        (bool zeroForOne, uint128 amountIn, uint256 minOut, address recipient) =
            abi.decode(data, (bool, uint128, uint256, address));
        address inCurrency = zeroForOne ? currency0 : currency1;
        address outCurrency = zeroForOne ? currency1 : currency0;

        int256 rawDelta = IPoolManagerRh(poolManager)
            .swap(
                _poolKey(),
                IPoolManagerRh.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(uint256(amountIn)),
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_LIMIT : MAX_SQRT_LIMIT
                }),
                ""
            );
        // packed BalanceDelta: amount0 = HIGH 128 bits, amount1 = LOW
        // (verified on the live swap return: zeroForOne -> -amountIn in
        // the high half, +amountOut in the low half)
        int128 inputDelta = int128(zeroForOne ? rawDelta >> 128 : rawDelta); // negative for exact-in
        int128 outputDelta = int128(zeroForOne ? rawDelta : rawDelta >> 128); // positive for exact-in
        uint256 amountOut = uint128(outputDelta);
        uint256 owed = uint128(-inputDelta);
        if (amountOut < minOut) revert TooLittleOut(amountOut, minOut);
        if (owed != amountIn) revert SettleMismatch(owed, amountIn);

        // pay: sync -> transfer -> settle (settle() applies to the last synced currency)
        IPoolManagerRh(poolManager).sync(inCurrency);
        if (!IERC20Rh(inCurrency).transfer(poolManager, owed)) revert TransferFailed();
        if (IPoolManagerRh(poolManager).settle() != owed) revert SettleFailed();

        // take: the manager pays the ORIGINAL caller directly (the safe)
        IPoolManagerRh(poolManager).take(outCurrency, recipient, amountOut);

        return amountOut;
    }

    /// @dev Reverts unless the pair matches the pool's currencies; returns
    ///      the swap direction (true = currency0 in).
    function _pairDirection(address tokenIn, address tokenOut) private view returns (bool) {
        if (tokenIn == currency0 && tokenOut == currency1) return true;
        if (tokenIn == currency1 && tokenOut == currency0) return false;
        revert BadPair();
    }

    function _poolKey() private view returns (IPoolManagerRh.PoolKey memory) {
        return IPoolManagerRh.PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks
        });
    }
}
