// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ParaswapDecoderLib} from "./ParaswapDecoderLib.sol";
import {SwapLeg} from "../types/SwapTypes.sol";

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
/// STRUCT DISCIPLINE: `SwapLeg` is imported from `../types/SwapTypes.sol`
/// (V10+ refactor) — single source of truth for both this library and
/// its callers.
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

    // SwapLeg sourced from `../types/SwapTypes.sol` (V10+ refactor).
    // Same struct used by every executor and per-mode library, no
    // re-declaration or cast required.

    // ─── Errors (must match LiquidationExecutor signatures by name) ──
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error ZeroSwapOutput();
    error ParaswapSwapFailed();
    error ParaswapSrcTokenMismatch(address expected, address actual);
    error ParaswapAmountInMismatch(uint256 expected, uint256 actual);
    error ParaswapDstTokenUnexpected(address dstToken);
    // Bebop
    error BebopTargetNotContract();
    error BebopSwapFailed();
    /// @dev The quote's `partialFillOffset` does not address a whole word
    /// inside its own calldata. Fail closed rather than write out of bounds.
    error BebopPartialFillOffsetOutOfRange();
    error TargetNotAllowed();

    // ─── Events (match LiquidationExecutor signatures; emitted under DELEGATECALL) ──
    event ParaswapSwapExecuted(address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut);
    event BebopSwapExecuted(
        address indexed target, address indexed srcToken, uint256 amountIn, uint256 repayDelta, uint256 profitDelta
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
        // Two floors: the calldata-embedded `minAmountOut` (Augustus's
        // own slippage check) AND the struct-level `leg.minAmountOut`.
        // Other DEX libraries (Uniswap V2/V3/V4, Curve V1, Balancer V2)
        // enforce `leg.minAmountOut` as the source of truth. Paraswap
        // used to defer entirely to the calldata value, leaving per-leg
        // slippage discipline asymmetric — a permissively-built quote
        // could land with calldata-min = 0 even when the operator
        // intended `leg.minAmountOut` as a hard floor. Now both bind.
        if (amountOut < minAmountOut) revert InsufficientRepayOutput(amountOut, minAmountOut);
        if (amountOut < leg.minAmountOut) revert InsufficientRepayOutput(amountOut, leg.minAmountOut);

        emit ParaswapSwapExecuted(srcToken, dstToken, actualIn, amountOut);
    }

    // ─── Bebop multi leg ─────────────────────────────────────────────
    /// @dev Executes opaque Bebop settlement call.
    ///
    /// Moved from `LiquidationExecutor._executeBebopLeg` (inline) to free
    /// ~150 bytes of main runtime bytecode for Curve V1 + Balancer V2
    /// dispatch branches. Identical control flow; the caller now passes
    /// `allowedTargets[leg.bebopTarget]` as a bool argument since the
    /// storage mapping isn't directly visible from the library (would
    /// require slot-pinning assembly — the bool plumbing is cheaper).
    ///
    /// Security model unchanged: allowlist re-check + exact-approval pair
    /// + output delta floor.
    function executeBebopLeg(SwapLeg memory leg, uint256 repayBefore, bool isTargetAllowed) external {
        address target = leg.bebopTarget;
        if (target.code.length == 0) revert BebopTargetNotContract();
        if (!isTargetAllowed) revert TargetNotAllowed();

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));

        // A signed RFQ order is written for an exact amount, but a
        // liquidation's realised collateral is only known on-chain and moves
        // with the block. When we hold less than the quote was written for,
        // Bebop lets the taker fill part of it by writing the amount at the
        // word its quote names — the alternative is the settlement rejecting
        // the order outright, which is what used to happen.
        uint256 fill = leg.amountIn;
        if (srcBal < fill) {
            if (leg.bebopPartialFillOffset == 0) {
                revert InsufficientSrcBalance(leg.amountIn, srcBal);
            }
            fill = srcBal;
            _writeBebopFill(leg.bebopCalldata, leg.bebopPartialFillOffset, fill);
        }

        IERC20(leg.srcToken).forceApprove(target, fill);
        (bool ok,) = target.call(leg.bebopCalldata);
        IERC20(leg.srcToken).forceApprove(target, 0);

        if (!ok) revert BebopSwapFailed();

        uint256 repayAfter = IERC20(leg.repayToken).balanceOf(address(this));
        uint256 repayDelta = repayAfter > repayBefore ? repayAfter - repayBefore : 0;
        if (repayDelta < leg.minAmountOut) revert InsufficientRepayOutput(repayDelta, leg.minAmountOut);

        emit BebopSwapExecuted(target, leg.srcToken, fill, repayDelta, 0);
    }

    /// @dev Overwrite the taker amount inside a signed Bebop order.
    ///
    /// `wordIndex` counts 32-byte words AFTER the 4-byte selector, which is
    /// how Bebop reports `partialFillOffset`. The bounds check is the whole
    /// safety story here: an offset past the end would otherwise write into
    /// memory beyond the array, and an offset supplied by a malformed quote
    /// must not be able to do that.
    function _writeBebopFill(bytes memory data, uint256 wordIndex, uint256 amount) private pure {
        uint256 at = 4 + wordIndex * 32;
        if (at + 32 > data.length) revert BebopPartialFillOffsetOutOfRange();
        assembly {
            // `data` points at the length word; payload starts one word later.
            mstore(add(add(data, 32), at), amount)
        }
    }
}
