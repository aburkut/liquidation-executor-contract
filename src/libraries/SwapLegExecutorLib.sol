// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ParaswapDecoderLib} from "./ParaswapDecoderLib.sol";
import {UniswapLib} from "./UniswapLib.sol";

/// @title SwapLegExecutorLib
/// @notice External library housing the Paraswap leg orchestrator.
/// Called via DELEGATECALL from `LiquidationExecutor` — execution runs
/// in the caller's storage / balance / msg.sender context, which is
/// necessary because this function transfers tokens, sets approvals,
/// and emits events against the executor's account.
///
/// SCOPE: Paraswap (single-leg via Augustus V6.2). All Uniswap V2/V3/V4
/// leg execution lives in `UniswapLib` (sister library); Bebop stays
/// in the main contract because it needs runtime `allowedTargets[...]`
/// allowlist re-checks against an operator-supplied target.
///
/// STRUCT DISCIPLINE: `SwapLeg` here MUST stay byte-for-byte identical
/// to the `SwapLeg` declared in `LiquidationExecutor`. Divergence
/// silently corrupts ABI decoding under DELEGATECALL.
///
/// SECURITY NOTE — removed allowlist check: the main contract's pre-
/// library `_executeParaswapCall` used to re-assert
/// `allowedTargets[augustus]` before the external call.
/// `paraswapAugustusV6` is pinned in the constructor and has no setter,
/// and the constructor seeds `allowedTargets[paraswapAugustusV6] = true`
/// with no flip path, so the check is a constant-true at every reachable
/// callsite. The library omits it to shave bytecode without changing
/// behavior.
library SwapLegExecutorLib {
    using SafeERC20 for IERC20;

    // ─── SwapLeg struct + SwapMode enum imported from UniswapLib ─────
    // Single source of truth for the struct shape — both the Uniswap
    // and the Paraswap libs accept the SAME `UniswapLib.SwapLeg memory`
    // pointer and the main contract uses ONE cast helper for both.
    // STRUCT DISCIPLINE: the struct in UniswapLib MUST stay byte-for-
    // byte identical to `LiquidationExecutor.SwapLeg`.

    // ─── Errors (must match LiquidationExecutor signatures by name) ──
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error ZeroSwapOutput();
    error ParaswapSwapFailed();
    error ParaswapSrcTokenMismatch(address expected, address actual);
    error ParaswapAmountInMismatch(uint256 expected, uint256 actual);
    error ParaswapDstTokenUnexpected(address dstToken);

    // ─── Events (match LiquidationExecutor signatures; emitted under DELEGATECALL) ──
    event ParaswapSwapExecuted(address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut);

    // ─── Paraswap single leg ─────────────────────────────────────────
    /// @dev Orchestrates decode → approve → call → reset → delta check.
    /// `augustus` is `paraswapAugustusV6` from the main contract; the
    /// caller is responsible for ensuring it is non-zero (constructor-
    /// pinned, so always non-zero in practice).
    function executeParaswapLeg(UniswapLib.SwapLeg memory leg, address augustus) external {
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
}
