// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {UniswapLib} from "./UniswapLib.sol";

/// @title CurveV1Lib
/// @notice External library housing Curve StableSwap V1 leg execution
/// (SELL via `exchange` / `exchange_underlying`, BUY via SELL semantics
/// with bot-precomputed `dx` and `min_dy = targetOut`). Called via
/// DELEGATECALL from `LiquidationExecutor._dispatchLeg`.
///
/// SCOPE — StableSwap V1 ONLY:
///   * `exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)` —
///     pools with int128 indices. Covers the bulk of the curated MVP
///     set (3pool / DAI/USDC/USDT, USDS/USDT, sUSDe/USDT family).
///   * `exchange_underlying(int128 i, int128 j, ...)` — lending /
///     metapool wrapper variant. Selected via the `useUnderlying`
///     flag in the encoded ext-data.
/// StableSwap-NG (uint256 indices), Cryptoswap (gamma/D math), and
/// metapool-LP-token routing are explicit non-goals for this lib. A
/// separate `CurveNGLib` / `CryptoswapLib` would house those if added.
///
/// BUY-SIDE MODEL:
///   Curve has no native exact-out. The bot precomputes `dx` such that
///   `get_dy(i, j, dx) >= targetOut`, packs `dx` into `leg.amountIn`
///   and `targetOut` into `leg.minAmountOut`. The library forwards
///   `dx` as `exchange` argument and asserts post-balance >= targetOut.
///   Excess output (if get_dy(dx) > targetOut due to bot rounding)
///   stays on the executor — net profit to the liquidation. Setting
///   `mode = CURVE_V1_BUY` only flips an event-emission label; the
///   on-chain swap is identical.
///
/// SECURITY:
///   * Pool address comes from `leg.bebopTarget` (re-purposed as
///     "external swap target"). Caller MUST validate it against
///     `allowedTargets[...]` BEFORE delegatecalling here.
///   * Approval pattern: `forceApprove(pool, dx)` → `exchange(...)` →
///     `forceApprove(pool, 0)`. Tether-style approvals supported.
///   * Output delta floor: `received >= leg.minAmountOut`. Curve's
///     own `min_dy` (passed as the 4th arg) provides defense in depth.
///
/// STRUCT DISCIPLINE: `UniswapLib.SwapLeg memory` is the canonical
/// argument shape — divergence silently corrupts ABI decoding under
/// DELEGATECALL. See UniswapLib for the field order of record.
///
/// EXT-DATA ENCODING (re-uses the `bebopCalldata` byte field, which
/// is empty for all non-Bebop/non-Curve/non-Balancer modes):
///
///   `bebopCalldata = abi.encode(int128 i, int128 j, bool useUnderlying)`
///
/// Decoding cost is dwarfed by the external swap; the alternative
/// (growing `SwapLeg` with dedicated fields) would cost ~30 bytes of
/// main runtime bytecode per accessor.
library CurveV1Lib {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────
    error CurveSwapFailed();
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error TargetNotAllowed();
    error ZeroSwapInput();
    error ZeroSwapOutput();
    error InvalidPlan();

    // ─── Event ───────────────────────────────────────────────────────
    /// @dev Mirror of LiquidationExecutor's `CurveV1SwapExecuted` so the
    /// emit fires from the executor's address with the canonical topic.
    event CurveV1SwapExecuted(
        address indexed pool, address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut
    );

    // ─── External entrypoint ─────────────────────────────────────────
    /// @dev Single entrypoint for both CURVE_V1 (SELL) and CURVE_V1_BUY.
    /// SELL and BUY produce identical on-chain swaps; the mode only
    /// flips the event label.
    ///
    /// @param leg     SwapLeg (must be ABI-identical to LiquidationExecutor.SwapLeg)
    /// @param amountIn Caller-resolved input amount (full-balance helper applied upstream).
    /// @param isTargetAllowed `allowedTargets[leg.bebopTarget]` read by caller — pool
    ///   address is re-validated against the executor's allowlist BEFORE swap.
    function executeLeg(UniswapLib.SwapLeg memory leg, uint256 amountIn, bool isTargetAllowed) external {
        if (amountIn == 0) revert ZeroSwapInput();
        if (leg.minAmountOut == 0) revert ZeroSwapOutput();

        address pool = leg.bebopTarget;
        if (!isTargetAllowed) revert TargetNotAllowed();
        if (pool.code.length == 0) revert TargetNotAllowed();

        // Decode ext-data: (i, j, useUnderlying)
        if (leg.bebopCalldata.length == 0) revert InvalidPlan();
        (int128 i, int128 j, bool useUnderlying) = abi.decode(leg.bebopCalldata, (int128, int128, bool));

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));

        IERC20(leg.srcToken).forceApprove(pool, amountIn);

        // Curve StableSwap exchange — most pools return uint256, some
        // older variants return void. We don't decode the return value
        // (use the balance delta as authoritative).
        bytes memory callData;
        if (useUnderlying) {
            // exchange_underlying(int128,int128,uint256,uint256)
            callData = abi.encodeWithSelector(0xa6417ed6, i, j, amountIn, leg.minAmountOut);
        } else {
            // exchange(int128,int128,uint256,uint256)
            callData = abi.encodeWithSelector(0x3df02124, i, j, amountIn, leg.minAmountOut);
        }
        (bool ok,) = pool.call(callData);
        IERC20(leg.srcToken).forceApprove(pool, 0);
        if (!ok) revert CurveSwapFailed();

        uint256 received = IERC20(leg.repayToken).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        emit CurveV1SwapExecuted(pool, leg.srcToken, leg.repayToken, amountIn, received);
    }
}
