// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SwapLeg} from "../types/SwapTypes.sol";

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
///     "external swap target"). V10+: no per-pool allowlist —
///     `executeLeg` checks `pool.code.length > 0` as a basic sanity
///     gate; the bot is the trusted source of pool addresses. Earlier
///     versions gated on `allowedExtSwapTargets[pool]` (owner-curated)
///     but the executor holds zero balance between txs so the only
///     attack window was selector-collision via `allowedTargets`,
///     which is empirically empty for `exchange(int128,int128,...)`.
///   * Approval pattern: `forceApprove(pool, dx)` → `exchange(...)` →
///     `forceApprove(pool, 0)`. Tether-style approvals supported.
///   * Output delta floor: `received >= leg.minAmountOut`. Curve's
///     own `min_dy` (passed as the 4th arg) provides defense in depth.
///
/// STRUCT DISCIPLINE: `SwapLeg` imported from `../types/SwapTypes.sol`
/// — same struct used by every executor and per-mode library, no
/// re-declaration or cast required.
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
    error InvalidPoolTarget();
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
    /// @param leg     SwapLeg (shared definition in SwapTypes.sol).
    /// @param amountIn Caller-resolved input amount (full-balance helper applied upstream).
    function executeLeg(SwapLeg memory leg, uint256 amountIn) external {
        if (amountIn == 0) revert ZeroSwapInput();
        if (leg.minAmountOut == 0) revert ZeroSwapOutput();

        address pool = leg.bebopTarget;
        if (pool == address(0)) revert InvalidPoolTarget();
        if (pool.code.length == 0) revert InvalidPoolTarget();

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

    // ─── Multihop entrypoint ─────────────────────────────────────────
    /// @dev Native multihop via Curve RouterNG (mainnet `0x16C6521D…5353`).
    /// The Router contract's `exchange(address[11], uint256[5][5], uint256,
    /// uint256, address[5], address)` walks up to 5 pools in one call,
    /// passing each hop's input through to the next pool's output.
    ///
    /// SwapLeg encoding (re-uses `bebopTarget` + `bebopCalldata`):
    ///   * `bebopTarget`   = canonical RouterNG address. Caller (the
    ///     bot) supplies this; we accept any non-zero contract address
    ///     because per-pool security lives in `path[0]` / `path[10]`
    ///     matching `leg.srcToken` / `leg.repayToken` post-swap delta.
    ///   * `bebopCalldata` = abi.encode(
    ///         address[11] path,           // [token0, pool0, token1, …, pool4, token5]
    ///         uint256[5][5] swapParams,   // per-hop [i, j, swap_type, pool_type, n_coins]
    ///         address[5] pools            // optional metapool factory addresses
    ///     )
    ///
    /// Path positions follow Curve's convention: even indices are
    /// tokens (0,2,4,6,8,10), odd are pools (1,3,5,7,9). Unused trailing
    /// hops MUST be filled with `address(0)`.
    ///
    /// Output is verified by post-balance delta against `leg.minAmountOut`
    /// (Router's own `_expected` is passed through too, defense-in-depth).
    function executeLegMultihop(SwapLeg memory leg, uint256 amountIn) external {
        if (amountIn == 0) revert ZeroSwapInput();
        if (leg.minAmountOut == 0) revert ZeroSwapOutput();

        address router = leg.bebopTarget;
        if (router == address(0)) revert InvalidPoolTarget();
        if (router.code.length == 0) revert InvalidPoolTarget();

        if (leg.bebopCalldata.length == 0) revert InvalidPlan();
        (address[11] memory path, uint256[5][5] memory swapParams, address[5] memory pools) =
            abi.decode(leg.bebopCalldata, (address[11], uint256[5][5], address[5]));

        // Endpoint sanity: first path entry must equal srcToken; the
        // last NON-ZERO entry must equal repayToken. Walk the path
        // backwards to locate the actual final token (operator may have
        // padded with zeros for shorter routes).
        if (path[0] != leg.srcToken) revert InvalidPlan();
        address pathLast;
        for (uint256 k = 10; k > 0; --k) {
            if (path[k] != address(0)) {
                pathLast = path[k];
                break;
            }
        }
        if (pathLast != leg.repayToken) revert InvalidPlan();

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));

        IERC20(leg.srcToken).forceApprove(router, amountIn);

        // Router exchange selector: keccak256("exchange(address[11],uint256[5][5],uint256,uint256,address[5],address)")[0:4]
        // = 0xc872a3c5. Hand-encoded so we don't pay for a sol! interface.
        bytes memory callData =
            abi.encodeWithSelector(0xc872a3c5, path, swapParams, amountIn, leg.minAmountOut, pools, address(this));
        (bool ok,) = router.call(callData);
        IERC20(leg.srcToken).forceApprove(router, 0);
        if (!ok) revert CurveSwapFailed();

        uint256 received = IERC20(leg.repayToken).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        // Pool slot in the event = the router address. The path itself
        // tells off-chain consumers which actual pools were touched.
        emit CurveV1SwapExecuted(router, leg.srcToken, leg.repayToken, amountIn, received);
    }
}
