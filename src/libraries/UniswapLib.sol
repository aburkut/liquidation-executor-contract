// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager, PoolKey, SwapParams} from "../interfaces/IPoolManager.sol";

/// @title UniswapLib
/// @notice External library housing Uniswap V4 swap-and-settle logic.
/// Called via DELEGATECALL from `LiquidationExecutor.unlockCallback` —
/// runs in the caller's storage / balance / msg.sender context. Moving
/// the swap-execution body out of the main contract recovers ~250 bytes
/// of runtime bytecode without changing any externally-observable
/// behaviour (event signatures, error selectors, calldata layout, and
/// PoolManager interaction order are all preserved).
///
/// V2 / V3 leg dispatch lives in `SwapLegExecutorLib` (sister library);
/// keeping the V4 helpers in their own module keeps the V4-specific
/// imports (`IPoolManager`, `PoolKey`, `SwapParams`) localised here and
/// leaves room to add V4 BUY-side / multihop variants without bloating
/// the main contract again.
///
/// SECURITY DISCIPLINE: the caller (`unlockCallback`) MUST validate the
/// PoolManager identity AND clear the `_activeV4TokenIn` storage pin
/// BEFORE invoking this library — the lib has no view of those slots
/// and trusts the caller to enforce the re-entry / pinned-PM guard.
/// Passing the wrong tokenIn here would silently route the swap to a
/// different pool (PoolManager substitutes nothing — the caller does).
library UniswapLib {
    using SafeERC20 for IERC20;

    // ─── V4 sqrt-price-limit constants (mirror LiquidationExecutor) ──
    uint160 internal constant V4_MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant V4_MAX_SQRT_PRICE_LIMIT =
        1_461_446_703_529_909_599_001_367_844_790_673_715_015_930_149_261;

    // ─── Errors (must match LiquidationExecutor signatures by name) ──
    error V4UnexpectedDelta();

    // ─── Events (match LiquidationExecutor signatures; emitted under DELEGATECALL) ──
    event UniV4SwapExecuted(
        address indexed srcToken, address indexed dstToken, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    /// @dev Decode the 5-tuple payload that `LiquidationExecutor.
    /// _executeUniV4Leg` packs into `pm.unlock(...)`'s `data` argument.
    /// Layout: `(tokenOut, fee, tickSpacing, hook, amountSpec)` —
    /// tokenIn is INTENTIONALLY pinned in storage by the caller so the
    /// PoolManager cannot substitute it via callback. `amountSpec`
    /// carries the V4 sign convention directly: negative = exact-input
    /// (SELL), positive = exact-output (BUY). The library does not
    /// branch on the sign — the BalanceDelta invariant
    /// `tokenInDelta < 0 && tokenOutDelta > 0` is identical for both
    /// directions, and the caller (LiquidationExecutor) is responsible
    /// for any mode-specific post-unlock checks (e.g. enforcing
    /// `consumed <= amountInMax` for BUY).
    function decodeV4UnlockData(bytes calldata data)
        external
        pure
        returns (address tokenOut, uint24 fee, int24 tickSpacing, address hook, int256 amountSpec)
    {
        return abi.decode(data, (address, uint24, int24, address, int256));
    }

    /// @dev The inner swap+settle body that runs inside
    /// `LiquidationExecutor.unlockCallback` after the caller has
    /// (a) verified the PoolManager identity, (b) re-checked the hook
    /// against `allowedV4Hooks`, and (c) cleared `_activeV4TokenIn`.
    ///
    /// Keeps the single-hop invariants enforced by the pre-extraction
    /// inline body:
    ///   * `tokenInDelta < 0` (we owe input)
    ///   * `tokenOutDelta > 0` (we receive output)
    /// Any other shape (zero-output, positive input, partial settle)
    /// fails closed via `V4UnexpectedDelta`. `amountSpec` is forwarded
    /// to V4's `SwapParams.amountSpecified` verbatim; sign selects
    /// exact-input vs exact-output at the pool level.
    function runV4UnlockSwap(
        IPoolManager pm,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hook,
        int256 amountSpec
    ) external {
        bool zeroForOne = tokenIn < tokenOut;
        PoolKey memory key = PoolKey({
            currency0: zeroForOne ? tokenIn : tokenOut,
            currency1: zeroForOne ? tokenOut : tokenIn,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hook
        });

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpec,
            sqrtPriceLimitX96: zeroForOne ? V4_MIN_SQRT_PRICE_LIMIT : V4_MAX_SQRT_PRICE_LIMIT
        });

        int256 swapDelta = pm.swap(key, params, "");
        int128 amount0 = int128(swapDelta >> 128);
        int128 amount1 = int128(swapDelta);

        int128 tokenInDelta = zeroForOne ? amount0 : amount1;
        int128 tokenOutDelta = zeroForOne ? amount1 : amount0;

        if (tokenInDelta >= 0 || tokenOutDelta <= 0) revert V4UnexpectedDelta();

        uint256 owedIn = uint256(int256(-tokenInDelta));
        uint256 gainedOut = uint256(int256(tokenOutDelta));

        pm.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(address(pm), owedIn);
        pm.settle();
        pm.take(tokenOut, address(this), gainedOut);
    }
}
