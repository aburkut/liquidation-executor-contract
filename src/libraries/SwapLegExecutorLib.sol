// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniV2Router} from "../interfaces/IUniV2Router.sol";
import {IUniV3SwapRouter} from "../interfaces/IUniV3SwapRouter.sol";
import {ParaswapDecoderLib} from "./ParaswapDecoderLib.sol";

/// @title SwapLegExecutorLib
/// @notice External library housing the per-leg swap executors for
/// Paraswap (single), Uniswap V2 (`swapExactTokensForTokens`), and
/// Uniswap V3 (`exactInputSingle`). Called via DELEGATECALL from
/// `LiquidationExecutor` — execution runs in the caller's storage /
/// balance / msg.sender context, which is necessary because these
/// functions transfer tokens, set approvals, and emit events against
/// the executor's account.
///
/// Moving the bodies out of the main contract recovers ~1KB+ of runtime
/// bytecode versus inlining, the same pattern already used for
/// `ParaswapDecoderLib`. V4 and Bebop stay in the main contract: V4
/// depends on the `_activeV4PoolManager` storage slot + the
/// `IUnlockCallback` entrypoint; Bebop needs `allowedTargets[...]`
/// (operator-supplied target, runtime allowlist check).
///
/// STRUCT DISCIPLINE: `SwapLeg` here MUST stay byte-for-byte identical
/// to the `SwapLeg` declared in `LiquidationExecutor`. Divergence
/// silently corrupts ABI decoding under DELEGATECALL.
///
/// SECURITY NOTE — removed checks: the main contract's pre-library
/// `_executeParaswapCall` used to re-assert `allowedTargets[augustus]`
/// before the external call. `paraswapAugustusV6` is pinned in the
/// constructor and has no setter, and the constructor seeds
/// `allowedTargets[paraswapAugustusV6] = true` with no flip path, so
/// the check is a constant-true at every reachable callsite. The
/// library omits it to shave bytecode without changing behavior. Same
/// rationale holds for `uniV2Router` / `uniV3Router` (both immutable,
/// both auto-allowlisted).
library SwapLegExecutorLib {
    using SafeERC20 for IERC20;

    // ─── SwapLeg struct (MUST match LiquidationExecutor.SwapLeg) ─────
    enum SwapMode {
        PARASWAP_SINGLE,
        BEBOP_MULTI,
        UNI_V2,
        UNI_V3,
        UNI_V4
    }

    struct SwapLeg {
        SwapMode mode;
        address srcToken;
        uint256 amountIn;
        bool useFullBalance;
        uint256 deadline;
        bytes paraswapCalldata;
        address bebopTarget;
        bytes bebopCalldata;
        address[] v2Path;
        uint24 v3Fee;
        address v4PoolManager;
        bytes v4SwapData;
        address repayToken;
        uint256 minAmountOut;
    }

    // ─── Errors (must match LiquidationExecutor signatures by name) ──
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error ZeroSwapInput();
    error ZeroSwapOutput();
    error InvalidV2Path();
    error InvalidV3Fee(uint24 fee);
    error InvalidPlan();
    error ParaswapSwapFailed();
    error ParaswapSrcTokenMismatch(address expected, address actual);
    error ParaswapAmountInMismatch(uint256 expected, uint256 actual);
    error ParaswapDstTokenUnexpected(address dstToken);

    // ─── Events (match LiquidationExecutor signatures; emitted under DELEGATECALL) ──
    event ParaswapSwapExecuted(address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut);
    event UniV2SwapExecuted(address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut);
    event UniV3SwapExecuted(
        address indexed srcToken, address indexed dstToken, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    // ─── Paraswap single leg ─────────────────────────────────────────
    /// @dev Orchestrates decode → approve → call → reset → delta check.
    /// `augustus` is `paraswapAugustusV6` from the main contract; the
    /// caller is responsible for ensuring it is non-zero (constructor-
    /// pinned, so always non-zero in practice).
    function executeParaswapLeg(SwapLeg memory leg, address augustus) external {
        (address srcToken, address dstToken, uint256 declaredIn, uint256 minAmountOut, bool isExactIn) =
            ParaswapDecoderLib.decodeAndValidate(leg.paraswapCalldata, address(this));

        if (srcToken != leg.srcToken) revert ParaswapSrcTokenMismatch(leg.srcToken, srcToken);
        if (dstToken != leg.repayToken) revert ParaswapDstTokenUnexpected(dstToken);

        uint256 srcBefore = IERC20(srcToken).balanceOf(address(this));
        if (srcBefore < declaredIn) revert InsufficientSrcBalance(declaredIn, srcBefore);
        uint256 dstBefore = IERC20(dstToken).balanceOf(address(this));

        IERC20(srcToken).forceApprove(augustus, declaredIn);
        (bool ok,) = augustus.call(leg.paraswapCalldata);
        IERC20(srcToken).forceApprove(augustus, 0);
        if (!ok) revert ParaswapSwapFailed();

        uint256 actualIn;
        {
            uint256 srcAfter = IERC20(srcToken).balanceOf(address(this));
            actualIn = srcBefore > srcAfter ? srcBefore - srcAfter : 0;
        }
        uint256 amountOut;
        {
            uint256 dstAfter = IERC20(dstToken).balanceOf(address(this));
            amountOut = dstAfter - dstBefore;
        }

        if (isExactIn) {
            if (actualIn != leg.amountIn) revert ParaswapAmountInMismatch(leg.amountIn, actualIn);
        } else {
            if (actualIn > leg.amountIn) revert ParaswapAmountInMismatch(leg.amountIn, actualIn);
        }

        if (amountOut == 0) revert ZeroSwapOutput();
        if (amountOut < minAmountOut) revert InsufficientRepayOutput(amountOut, minAmountOut);

        emit ParaswapSwapExecuted(srcToken, dstToken, actualIn, amountOut);
    }

    // ─── Uniswap V2 leg ──────────────────────────────────────────────
    function executeUniV2Leg(SwapLeg memory leg, uint256 amountIn, address router) external {
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));

        IERC20(leg.srcToken).forceApprove(router, amountIn);
        IUniV2Router(router)
            .swapExactTokensForTokens(amountIn, leg.minAmountOut, leg.v2Path, address(this), leg.deadline);
        IERC20(leg.srcToken).forceApprove(router, 0);

        uint256 received = IERC20(leg.repayToken).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        emit UniV2SwapExecuted(leg.srcToken, leg.repayToken, amountIn, received);
    }

    // ─── Uniswap V3 leg ──────────────────────────────────────────────
    function executeUniV3Leg(SwapLeg memory leg, uint256 amountIn, address router) external {
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));

        IERC20(leg.srcToken).forceApprove(router, amountIn);
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
        IERC20(leg.srcToken).forceApprove(router, 0);

        uint256 received = IERC20(leg.repayToken).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        emit UniV3SwapExecuted(leg.srcToken, leg.repayToken, leg.v3Fee, amountIn, received);
    }
}
