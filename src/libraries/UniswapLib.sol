// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniV2Router} from "../interfaces/IUniV2Router.sol";
import {IUniV3SwapRouter} from "../interfaces/IUniV3SwapRouter.sol";
import {IPoolManager, PoolKey, SwapParams} from "../interfaces/IPoolManager.sol";
import {SwapMode, SwapLeg} from "../types/SwapTypes.sol";

/// @title UniswapLib
/// @notice External library housing ALL Uniswap leg execution logic
/// (V2, V3, V4 single-hop and multihop). Called via DELEGATECALL from
/// `LiquidationExecutor` — execution runs in the caller's storage /
/// balance / msg.sender context. Moving the bodies out of the main
/// contract recovers ~1.5KB+ of runtime bytecode versus inlining and
/// keeps the EIP-170 budget free for plan-validation, flashloan
/// orchestration, and the V4 unlock-callback wiring.
///
/// Coverage:
///   * UNI_V2  / UNI_V2_BUY                 (single-hop & multihop)
///   * UNI_V3  / UNI_V3_BUY                 (single-hop & multihop via path bytes)
///   * UNI_V4  / UNI_V4_BUY  single-hop     (`runV4UnlockSwap`)
///   * UNI_V4  / UNI_V4_BUY  multihop       (`runV4UnlockMultihop`)
///
/// Paraswap orchestration stays in `SwapLegExecutorLib` (sister
/// library) — it has no relationship to Uniswap and a different
/// validation surface (selector classifier + decoder).
///
/// STRUCT DISCIPLINE: `SwapLeg` is imported from `../types/SwapTypes.sol`
/// (V10+ refactor). Treat that file as the frozen interface — every
/// library and contract that touches a leg under DELEGATECALL reads
/// fields by position from the same definition.
///
/// SECURITY DISCIPLINE: V4 entrypoints (`runV4UnlockSwap`,
/// `runV4UnlockMultihop`) are invoked only inside
/// `LiquidationExecutor.unlockCallback`. The caller MUST:
///   (a) verify the PoolManager identity (msg.sender == pinned PM),
///   (b) clear the `_activeV4TokenIn` storage pin BEFORE invocation,
///   (c) re-check every hook in the path against `allowedV4Hooks`.
/// The library has no view of those slots; passing wrong tokenIn or
/// an un-allowlisted hook would silently route to a different pool.
library UniswapLib {
    using SafeERC20 for IERC20;

    // ─── V4 sqrt-price-limit constants (mirror LiquidationExecutor) ──
    // Reference: v4-core TickMath.MIN_SQRT_PRICE / MAX_SQRT_PRICE.
    //   MIN_SQRT_PRICE = 4_295_128_739
    //   MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342
    // V4 PoolManager reverts `PriceLimitOutOfBounds` when
    //   zeroForOne  && sqrtPriceLimitX96 <= MIN_SQRT_PRICE, or
    //   !zeroForOne && sqrtPriceLimitX96 >= MAX_SQRT_PRICE.
    // Our sentinels must therefore be MIN+1 and MAX-1.
    uint160 internal constant V4_MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant V4_MAX_SQRT_PRICE_LIMIT =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    // SwapMode + SwapLeg now sourced from `../types/SwapTypes.sol`.
    // assertNoSwapLegZeroed moved to SwapValidationLib (V10+ refactor).

    // ─── Errors (must match LiquidationExecutor signatures by name) ──
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error ZeroSwapInput();
    error ZeroSwapOutput();
    error InvalidV2Path();
    error InvalidPlan();
    error V4UnexpectedDelta();

    // ─── Events (match LiquidationExecutor signatures; emitted under DELEGATECALL) ──
    event UniV2SwapExecuted(address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut);
    event UniV3SwapExecuted(
        address indexed srcToken, address indexed dstToken, uint24 fee, uint256 amountIn, uint256 amountOut
    );
    event UniV4SwapExecuted(
        address indexed srcToken, address indexed dstToken, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    // =================================================================
    //                          UNISWAP V2
    // =================================================================

    /// @dev Single entrypoint for both UNI_V2 (SELL via
    /// `swapExactTokensForTokens`) and UNI_V2_BUY (BUY via
    /// `swapTokensForExactTokens`). Multihop is supported "for free"
    /// because the V2 router accepts any `path.length >= 2`.
    function executeUniV2Leg(SwapLeg memory leg, uint256 amountIn, address router) external {
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 srcBefore = IERC20(leg.srcToken).balanceOf(address(this));
        uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));

        IERC20(leg.srcToken).forceApprove(router, amountIn);

        uint256 actualIn;
        if (leg.mode == SwapMode.UNI_V2_BUY) {
            // BUY: caller specifies EXACT amountOut (= minAmountOut)
            // and MAX input (= amountIn). Router consumes only what's
            // needed to satisfy amountOut along v2Path.
            if (leg.minAmountOut == 0) revert ZeroSwapOutput();
            IUniV2Router(router)
                .swapTokensForExactTokens(leg.minAmountOut, amountIn, leg.v2Path, address(this), leg.deadline);
            actualIn = srcBefore - IERC20(leg.srcToken).balanceOf(address(this));
        } else {
            IUniV2Router(router)
                .swapExactTokensForTokens(amountIn, leg.minAmountOut, leg.v2Path, address(this), leg.deadline);
            actualIn = amountIn;
        }
        IERC20(leg.srcToken).forceApprove(router, 0);

        uint256 received = IERC20(leg.repayToken).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        emit UniV2SwapExecuted(leg.srcToken, leg.repayToken, actualIn, received);
    }

    // =================================================================
    //                          UNISWAP V3
    // =================================================================

    /// @dev Single entrypoint for all four V3 shapes:
    ///   * single-hop SELL  (UNI_V3,     v4SwapData empty)   → exactInputSingle
    ///   * single-hop BUY   (UNI_V3_BUY, v4SwapData empty)   → exactOutputSingle
    ///   * multihop  SELL   (UNI_V3,     v4SwapData = path)  → exactInput
    ///   * multihop  BUY    (UNI_V3_BUY, v4SwapData = path)  → exactOutput
    /// Multihop is signalled by `leg.v4SwapData.length > 0`; the bytes
    /// are forwarded to the router as the standard V3 path encoding
    /// (`token || fee || token || ...`). For BUY the path MUST be
    /// reversed (tokenOut-first, tokenIn-last) per V3 router contract.
    /// Endpoint sanity (path[0] vs path[last] vs leg.srcToken /
    /// leg.repayToken) is enforced inline; intermediate-fee validity
    /// is enforced naturally by the router (a bad fee field finds no
    /// pool and reverts the swap call).
    function executeUniV3Leg(SwapLeg memory leg, uint256 amountIn, address router) external {
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));

        IERC20(leg.srcToken).forceApprove(router, amountIn);

        bool isMultihop = leg.v4SwapData.length > 0;
        if (isMultihop) {
            (address pathFirst, address pathLast) = _v3PathEndpoints(leg.v4SwapData);
            address expectedFirst = leg.mode == SwapMode.UNI_V3_BUY ? leg.repayToken : leg.srcToken;
            address expectedLast = leg.mode == SwapMode.UNI_V3_BUY ? leg.srcToken : leg.repayToken;
            if (pathFirst != expectedFirst || pathLast != expectedLast) revert InvalidV2Path();
        }

        uint256 actualIn;
        if (leg.mode == SwapMode.UNI_V3_BUY) {
            if (leg.minAmountOut == 0) revert ZeroSwapOutput();
            if (isMultihop) {
                actualIn = IUniV3SwapRouter(router)
                    .exactOutput(
                        IUniV3SwapRouter.ExactOutputParams({
                        path: leg.v4SwapData,
                        recipient: address(this),
                        amountOut: leg.minAmountOut,
                        amountInMaximum: amountIn
                    })
                    );
            } else {
                actualIn = IUniV3SwapRouter(router)
                    .exactOutputSingle(
                        IUniV3SwapRouter.ExactOutputSingleParams({
                        tokenIn: leg.srcToken,
                        tokenOut: leg.repayToken,
                        fee: leg.v3Fee,
                        recipient: address(this),
                        amountOut: leg.minAmountOut,
                        amountInMaximum: amountIn,
                        sqrtPriceLimitX96: 0
                    })
                    );
            }
        } else {
            if (isMultihop) {
                IUniV3SwapRouter(router)
                    .exactInput(
                        IUniV3SwapRouter.ExactInputParams({
                        path: leg.v4SwapData,
                        recipient: address(this),
                        amountIn: amountIn,
                        amountOutMinimum: leg.minAmountOut
                    })
                    );
            } else {
                IUniV3SwapRouter(router)
                    .exactInputSingle(
                        IUniV3SwapRouter.ExactInputSingleParams({
                        tokenIn: leg.srcToken,
                        tokenOut: leg.repayToken,
                        fee: leg.v3Fee,
                        recipient: address(this),
                        amountIn: amountIn,
                        amountOutMinimum: leg.minAmountOut,
                        sqrtPriceLimitX96: 0
                    })
                    );
            }
            actualIn = amountIn;
        }
        IERC20(leg.srcToken).forceApprove(router, 0);

        uint256 received = IERC20(leg.repayToken).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        emit UniV3SwapExecuted(leg.srcToken, leg.repayToken, leg.v3Fee, actualIn, received);
    }

    /// @dev Read first and last 20 bytes of a V3 path-bytes blob as
    /// addresses. The path is `token (20) || fee (3) || token (20) || ...`,
    /// so the endpoint addresses sit at fixed offsets regardless of
    /// the number of intermediate hops.
    function _v3PathEndpoints(bytes memory path) private pure returns (address first, address last) {
        // A valid Uniswap V3 path is (token 20 + fee 3 + token 20) = 43 bytes
        // minimum (single hop). The prior `>= 40` cutoff allowed degenerate
        // lengths 40-42 where the first-20-byte and last-20-byte loads sit
        // adjacent or overlap. Tightened to 43 so the lib's precondition
        // matches the actual V3-path invariant — defense-in-depth even
        // though the only existing caller is pre-gated by `_validateLeg`'s
        // `length < 66` check.
        require(path.length >= 43, "V3Path: too short");
        uint256 len = path.length;
        assembly {
            // Memory layout: path[0..32]=length prefix, path[32..32+len]=data.
            // First 20 bytes (= first address) sit at the start of the data
            // region, in the high 20 bytes of the first word — shr(96, ...)
            // aligns them as a 160-bit address.
            first := shr(96, mload(add(path, 32)))
            // Last 20 bytes (= last address) sit at the END of the data
            // region. To load 32 bytes ENDING at the path's last byte,
            // start the mload at offset (path + 32 + len - 32) = (path + len).
            last := and(mload(add(path, len)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    // =================================================================
    //                       UNISWAP V4 (single-hop)
    // =================================================================

    /// @dev Single-hop V4 swap inside `unlockCallback`. Caller has
    /// already validated PM identity, cleared the tokenIn pin, and
    /// re-checked the hook against allowedV4Hooks. BalanceDelta
    /// invariant `tokenInDelta < 0 && tokenOutDelta > 0` holds for
    /// both SELL and BUY (sign of `amountSpec` only flips the pool's
    /// quote semantics, not the delta direction).
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

    // =================================================================
    //                       UNISWAP V4 (multihop)
    // =================================================================

    /// @dev V4 multihop hop descriptor. Each hop is the next pool to
    /// swap through; `tokenOut` is the token credited from this hop
    /// (and consumed as input by the NEXT hop, except the final one
    /// which leaves the executor as the leg's output).
    struct V4Hop {
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        address hook;
    }

    /// @dev Decode + structurally validate a V4 multihop `v4SwapData`
    /// blob pre-flashloan AND apply the caller's hook-allowlist via a
    /// function-pointer callback. The whole loop body — including
    /// the per-hop hook check — runs inside the lib, off the main
    /// contract's EIP-170 budget. Caller passes `hookAllowed` as
    /// `this.isV4HookAllowed` (an external view returning `bool`);
    /// the lib invokes it once per hop. Each call is a CALL back into
    /// the executor (since `this.fn` semantics is external CALL even
    /// inside DELEGATECALL'd lib code) — gas overhead is ~600-2600
    /// for first hit, ~100 for warm slots. Reverts on:
    ///   * hops.length < 2                       → InvalidPlan
    ///   * tokenOut == address(0) (native ETH)   → V4UnexpectedDelta
    ///   * curIn == tokenOut (loop/no-op hop)    → InvalidPlan
    ///   * fee == 0 or tickSpacing <= 0           → InvalidPlan
    ///   * fee & 0x800000 (dynamic-fee bit)       → InvalidPlan
    ///   * final tokenOut != expectedFinalOut     → InvalidPlan
    ///   * !hookAllowed(h.hook) for non-zero hook → InvalidPlan
    /// @dev Single-hop V4 leg structural validation. Decodes the 5-tuple
    /// `v4SwapData` and asserts: non-native tokens, tokenIn==srcToken,
    /// tokenOut==repayToken, distinct tokens, fee != 0, tickSpacing > 0,
    /// dynamic-fee bit clear. Returns the hook address for the caller's
    /// `allowedV4Hooks` re-check (lib has no view of that storage).
    /// Hosted in lib to keep the byte-heavy decode + check chain off
    /// the main contract's EIP-170 budget. Reverts use `InvalidPlan` /
    /// `V4UnexpectedDelta` (lib namespace) — granular V4 errors removed
    /// from the main contract; tests target `InvalidPlan` selector.
    function decodeAndValidateV4SingleHopShape(bytes memory data, address srcToken, address repayToken)
        external
        pure
        returns (address hook)
    {
        (address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address h) =
            abi.decode(data, (address, address, uint24, int24, address));
        if (
            tokenIn == address(0) || tokenOut == address(0) || tokenIn != srcToken || tokenOut != repayToken
                || tokenIn == tokenOut || fee == 0 || tickSpacing <= 0 || fee & 0x800000 != 0
        ) revert InvalidPlan();
        return h;
    }

    function decodeAndValidateV4MultihopShape(
        bytes memory data,
        address srcToken,
        address expectedFinalOut,
        function(address) external view returns (bool) hookAllowed
    ) external view {
        V4Hop[] memory hopArr = abi.decode(data, (V4Hop[]));
        uint256 nHops = hopArr.length;
        if (nHops < 2) revert InvalidPlan();
        // Reject non-simple paths: every hop's tokenOut must be unique
        // and must NOT equal srcToken. The prior validator only blocked
        // immediate self-loops (curIn == h.tokenOut). Multi-hop paths
        // that revisit srcToken mid-route (e.g. A→B→A→C) or revisit any
        // earlier hop's output (A→B→C→B→D) passed the old check but
        // create implicit aliasing in PoolManager's credit ledger that
        // downstream `consumed > amountIn` reverts catch only for the
        // BUY direction. Defense-in-depth: surface non-simple paths at
        // validation time so SELL has a symmetric reject path too.
        address curIn = srcToken;
        for (uint256 i = 0; i < nHops; i++) {
            V4Hop memory h = hopArr[i];
            if (h.tokenOut == address(0)) revert V4UnexpectedDelta();
            if (curIn == h.tokenOut) revert InvalidPlan();
            if (h.tokenOut == srcToken) revert InvalidPlan();
            // Ensure no earlier hop already produced this tokenOut.
            for (uint256 j = 0; j < i; j++) {
                if (hopArr[j].tokenOut == h.tokenOut) revert InvalidPlan();
            }
            if (h.fee == 0 || h.tickSpacing <= 0) revert InvalidPlan();
            if (h.fee & 0x800000 != 0) revert InvalidPlan();
            if (h.hook != address(0) && !hookAllowed(h.hook)) revert InvalidPlan();
            curIn = h.tokenOut;
        }
        if (curIn != expectedFinalOut) revert InvalidPlan();
    }

    /// @dev Multihop V4 swap inside `unlockCallback`. Walks the hops
    /// in order (SELL: forward, output of hop k feeds hop k+1 as
    /// exact-input; BUY: backward, input demand of hop k+1 becomes
    /// hop k's exact-output target). At the end, only the leg's
    /// tokenIn is settled and only the final hop's tokenOut is taken;
    /// intermediate tokens net to zero through PoolManager's internal
    /// credit accounting.
    ///
    /// Caller (`unlockCallback`) MUST:
    ///   (a) clear `_activeV4TokenIn` BEFORE invoking this function;
    ///   (b) re-check EVERY hop's `hook` against `allowedV4Hooks`
    ///       AFTER decoding the payload (the lib does not have view
    ///       of the allowlist).
    ///
    /// Invariants enforced per hop: `tokenInDelta_k < 0` AND
    /// `tokenOutDelta_k > 0`. Any other shape (zero output, partial
    /// settlement, positive input) reverts via `V4UnexpectedDelta`.
    function runV4UnlockMultihop(IPoolManager pm, address tokenIn, bytes calldata data) external {
        (bytes memory hopsBlob, int256 amountSpec) = abi.decode(data, (bytes, int256));
        V4Hop[] memory hops = abi.decode(hopsBlob, (V4Hop[]));
        uint256 nHops = hops.length;
        if (nHops < 2) revert InvalidPlan();
        // BUY = positive amountSpec (exact-output target); SELL = negative.
        bool isBuy = amountSpec > 0;

        // The chain of token addresses the swap walks through:
        //   tokens[0] = leg.srcToken (= tokenIn)
        //   tokens[k] = hops[k-1].tokenOut    (1 <= k <= nHops)
        // tokens[nHops] is the leg's repayToken (final output).
        // Building the array up-front simplifies index math when we
        // walk hops backward for BUY.
        address[] memory tokens = new address[](nHops + 1);
        tokens[0] = tokenIn;
        for (uint256 i = 0; i < nHops; i++) {
            tokens[i + 1] = hops[i].tokenOut;
        }

        // SELL (amountSpec < 0): walk hops forward. Hop 0 takes
        //   amountSpec (= -amountIn) as exact-input. Hop k>=1 takes
        //   prev hop's gainedOut as -exact-input (i.e. amountSpec_k
        //   = -prevGainedOut). After all hops complete, `owedIn`
        //   accumulates from hop 0 (= original amountIn) and
        //   `finalGainedOut` is the leg's output.
        // BUY  (amountSpec > 0): walk hops BACKWARD. The LAST hop
        //   takes amountSpec (= +amountOut) as exact-output. Hop k
        //   (k < nHops-1) takes next hop's required-input as
        //   +exact-output (so its output equals next hop's input
        //   demand). After all hops, `owedIn` equals hop-0's
        //   required input and `finalGainedOut` equals the original
        //   amountOut target.
        uint256 owedIn;
        uint256 finalGainedOut;
        if (!isBuy) {
            int256 currentSpec = amountSpec; // negative
            for (uint256 i = 0; i < nHops; i++) {
                (uint256 hopOwedIn, uint256 hopGainedOut) = _doV4Hop(pm, tokens[i], tokens[i + 1], hops[i], currentSpec);
                if (i == 0) owedIn = hopOwedIn;
                if (i == nHops - 1) finalGainedOut = hopGainedOut;
                // Next hop consumes this hop's output as exact-input.
                currentSpec = -int256(hopGainedOut);
            }
        } else {
            int256 currentSpec = amountSpec; // positive
            // Walk backward; first iteration handles the LAST hop.
            for (uint256 j = 0; j < nHops; j++) {
                uint256 i = nHops - 1 - j;
                (uint256 hopOwedIn, uint256 hopGainedOut) = _doV4Hop(pm, tokens[i], tokens[i + 1], hops[i], currentSpec);
                if (i == nHops - 1) finalGainedOut = hopGainedOut;
                if (i == 0) owedIn = hopOwedIn;
                // Previous hop must DELIVER hopOwedIn as its output.
                currentSpec = int256(hopOwedIn);
            }
        }

        // Settle the leg's input and take the leg's output. Intermediate
        // tokens net out via PoolManager's per-currency credit ledger.
        pm.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(address(pm), owedIn);
        pm.settle();
        pm.take(tokens[nHops], address(this), finalGainedOut);
    }

    /// @dev Run one V4 swap inside the multihop loop. Returns
    /// `(owedIn, gainedOut)` for THIS hop (PoolManager credit/debit
    /// ledger updates; nothing transferred yet).
    function _doV4Hop(IPoolManager pm, address tokenIn, address tokenOut, V4Hop memory hop, int256 amountSpec)
        private
        returns (uint256 owedIn, uint256 gainedOut)
    {
        bool zeroForOne = tokenIn < tokenOut;
        PoolKey memory key = PoolKey({
            currency0: zeroForOne ? tokenIn : tokenOut,
            currency1: zeroForOne ? tokenOut : tokenIn,
            fee: hop.fee,
            tickSpacing: hop.tickSpacing,
            hooks: hop.hook
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

        owedIn = uint256(int256(-tokenInDelta));
        gainedOut = uint256(int256(tokenOutDelta));
    }
}
