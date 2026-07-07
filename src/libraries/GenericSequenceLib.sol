// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Op} from "../types/SwapTypes.sol";

/// @title GenericSequenceLib
/// @notice DELEGATECALL library holding the GENERIC_SEQUENCE op executor,
/// split out of `LiquidationExecutor` to stay under the EIP-170 runtime
/// code-size limit. It runs in the executor's storage/balance context
/// (delegatecall), so `address(this)` is the executor and the token balances
/// read here are the executor's. Only DIRECT-CALL routing ops are supported —
/// ops target allowlisted routers/aggregators (Uni V3 SwapRouter, Curve /
/// Balancer routers) whose calldata is built offchain. The caller
/// (`LiquidationExecutor._runGenericSequence`) pre-validates that every
/// `op.target` is allowlisted before delegating here.
///
/// Errors are duplicated from `LiquidationExecutor` so the DELEGATECALL revert
/// selectors match — the same intentional pattern the sister swap libraries
/// use.
library GenericSequenceLib {
    using SafeERC20 for IERC20;

    error EmptyOps();
    error TooManyOps();
    error InvalidPlan();
    error CalldataPatchOOB();
    error OpCallFailed(uint256 opIndex);
    error OpOutputNotReceived(uint256 opIndex);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error CollateralOverspent(uint256 spent, uint256 allowed);

    /// GENERIC_SEQUENCE op flags — direct-call routing only.
    uint32 internal constant FLAG_USE_FULL_BALANCE = 1 << 0; // inject balanceOf(srcToken) at fromAmountPos
    uint32 internal constant FLAG_USE_PREV_RETURN = 1 << 1; // inject previous op output at fromAmountPos
    uint32 internal constant FLAG_KNOWN_MASK = FLAG_USE_FULL_BALANCE | FLAG_USE_PREV_RETURN;
    uint16 internal constant MAX_OPS = 32; // gas-grief bound on sequence length

    /// @notice Execute a flat `Op[]` sequence with per-srcToken containment.
    /// @dev MUST be invoked via DELEGATECALL (as `GenericSequenceLib.run(...)`)
    /// so it shares the executor's storage and balances. Targets are assumed
    /// pre-validated as allowlisted by the caller.
    function run(
        Op[] memory ops,
        address loanToken,
        uint256 flashRepayAmount,
        address collateralAsset,
        uint256 collateralDelta
    ) external {
        uint256 n = ops.length;
        if (n == 0) revert EmptyOps();
        if (n > MAX_OPS) revert TooManyOps();

        uint256 loanBefore = IERC20(loanToken).balanceOf(address(this));

        // Per-srcToken containment. Snapshot every DISTINCT token any op will
        // spend so the post-check can bound each token's net spend to what THIS
        // tx produced — collateralDelta for the collateral asset, ZERO for
        // everything else. This keeps a compromised operator from routing out a
        // standing/pre-existing balance of ANY token (accumulated profit
        // awaiting owner rescue, aToken residue, donations).
        address[] memory snapTok = new address[](n);
        uint256[] memory snapBal = new uint256[](n);
        uint256 nSnap = 0;
        for (uint256 i = 0; i < n; ++i) {
            address t = ops[i].srcToken;
            if (t == address(0)) continue;
            bool seen = false;
            for (uint256 j = 0; j < nSnap; ++j) {
                if (snapTok[j] == t) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                snapTok[nSnap] = t;
                snapBal[nSnap] = IERC20(t).balanceOf(address(this));
                ++nSnap;
            }
        }

        uint256 prevReturn = 0;

        for (uint256 i = 0; i < n; ++i) {
            Op memory op = ops[i];
            // No native value is ever needed to swap tokens; forbid it so an op
            // cannot push the executor's ETH to an arbitrary target.
            if (op.value != 0) revert InvalidPlan();
            // Every op must declare the token it spends, so the per-srcToken cap
            // snapshots it.
            if (op.srcToken == address(0)) revert InvalidPlan();
            // Only the direct-call routing flags are supported; any other bit is
            // rejected so a stale plan can never silently mis-execute.
            if (op.flags & ~FLAG_KNOWN_MASK != 0) revert InvalidPlan();

            // Resolve the input amount. FULL_BALANCE is restricted to the
            // collateral asset (capped at collateralDelta); other inputs come
            // from the previous op's output (chained) or an explicit literal.
            // The per-srcToken cap below is the real backstop.
            uint256 amount = op.amountIn;
            if (op.flags & FLAG_USE_FULL_BALANCE != 0) {
                if (collateralAsset == address(0) || op.srcToken != collateralAsset) revert InvalidPlan();
                uint256 bal = IERC20(collateralAsset).balanceOf(address(this));
                amount = bal < collateralDelta ? bal : collateralDelta;
            } else if (op.flags & FLAG_USE_PREV_RETURN != 0) {
                amount = prevReturn;
            }

            uint256 outBefore = op.outToken == address(0) ? 0 : IERC20(op.outToken).balanceOf(address(this));

            // Direct call into an allowlisted router/aggregator whose calldata
            // was built offchain. Patch runtime values into the pre-built
            // calldata (bounds-checked), approve exact input, call, then reset.
            bytes memory data = op.callData;
            if (op.fromAmountPos != 0) {
                _patchWord(data, op.fromAmountPos, amount);
            }
            if (op.returnAmountPos != 0) {
                _patchWord(data, op.returnAmountPos, prevReturn);
            }
            if (amount != 0) {
                IERC20(op.srcToken).forceApprove(op.target, amount);
            }

            (bool ok, bytes memory ret) = op.target.call(data); // op.value == 0 (checked above)
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 0x20), mload(ret))
                    }
                }
                revert OpCallFailed(i);
            }

            IERC20(op.srcToken).forceApprove(op.target, 0);

            // Output MUST accrue to the executor — pins the swap recipient to
            // this contract. An op whose raw calldata routed output elsewhere
            // produces a zero delta and is rejected. Saturating delta matches
            // the codebase idiom (clean revert instead of a Panic underflow).
            uint256 outBal = op.outToken == address(0) ? 0 : IERC20(op.outToken).balanceOf(address(this));
            uint256 outDelta = outBal > outBefore ? outBal - outBefore : 0;
            if (outDelta == 0) revert OpOutputNotReceived(i);
            prevReturn = outDelta;
        }

        // Repay leg gate (mirrors the split/mixed-split repay assertion).
        uint256 loanAfter = IERC20(loanToken).balanceOf(address(this));
        uint256 repayDelta = loanAfter > loanBefore ? loanAfter - loanBefore : 0;
        if (repayDelta < flashRepayAmount) revert InsufficientRepayOutput(repayDelta, flashRepayAmount);

        // Per-srcToken containment cap: no token may be net-spent past what this
        // tx produced (collateralDelta for the collateral asset, 0 otherwise).
        for (uint256 k = 0; k < nSnap; ++k) {
            uint256 allowed = snapTok[k] == collateralAsset ? collateralDelta : 0;
            uint256 balAfter = IERC20(snapTok[k]).balanceOf(address(this));
            uint256 spent = snapBal[k] > balAfter ? snapBal[k] - balAfter : 0;
            if (spent > allowed) revert CollateralOverspent(spent, allowed);
        }
    }

    /// @dev Write a 32-byte `value` into `data` at byte offset `pos`, reverting
    /// if the write would read/overwrite out of bounds.
    function _patchWord(bytes memory data, uint256 pos, uint256 value) private pure {
        if (pos + 32 > data.length) revert CalldataPatchOOB();
        assembly {
            mstore(add(add(data, 0x20), pos), value)
        }
    }
}
