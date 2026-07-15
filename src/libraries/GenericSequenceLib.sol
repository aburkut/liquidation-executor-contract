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
    /// V4 single-hop exact-out via the PoolManager unlock-callback pattern.
    /// The op's fields are reinterpreted:
    ///   * `target`    = the V4 PoolManager (allowlist-checked by the caller
    ///                   like every op target);
    ///   * `amountIn`  = the EXACT-OUT amount (positive `amountSpec` — the
    ///                   knapsack repay slices are exact-out BUYs);
    ///   * `callData`  = the raw 160-byte single-hop v4SwapData 5-tuple
    ///                   `(tokenIn, tokenOut, fee, tickSpacing, hook)` — NOT
    ///                   selector-prefixed calldata. The lib wraps it into
    ///                   `unlock(abi.encode(inner, int256(amountIn)))` itself,
    ///                   so the unlock-payload shape is correct BY CONSTRUCTION
    ///                   and the executor's `unlockCallback` single-hop branch
    ///                   (with its callback-time hook-allowlist re-check)
    ///                   handles the swap exactly as for structured V4 legs.
    /// Multihop v4SwapData is intentionally NOT accepted here: its hook
    /// allowlist walk lives in the structured-leg pre-flashloan validator,
    /// which generic ops bypass — the strict 160-byte shape keeps the
    /// callback-time hook re-check authoritative.
    uint32 internal constant FLAG_V4_UNLOCK = 1 << 2;
    uint32 internal constant FLAG_KNOWN_MASK = FLAG_USE_FULL_BALANCE | FLAG_USE_PREV_RETURN | FLAG_V4_UNLOCK;
    uint16 internal constant MAX_OPS = 32; // gas-grief bound on sequence length

    /// @dev `LiquidationExecutor` storage slots for the V4 unlock arming
    /// fields. This lib runs via DELEGATECALL, so `sstore` writes the
    /// executor's storage. Slot numbers are pinned against
    /// `forge inspect storageLayout` by `test_v4SlotConstantsMatchLayout`
    /// (same pattern as the replay CLI's allowlist slot constants); any
    /// layout drift fails the suite instead of silently mis-arming.
    /// Slot 10 packs `_activeV4PoolManager` (bytes 0..19) WITH
    /// `_executionPhase` (byte 20) — arming must preserve the high bytes.
    uint256 private constant V4_PM_SLOT = 10;
    uint256 private constant V4_TOKENIN_SLOT = 11;

    /// @dev `IPoolManager.unlock(bytes)` selector, pinned by
    /// `test_v4UnlockSelectorPin` (keccak("unlock(bytes)")[..4]) — the same
    /// hardcoded-selector idiom the Curve RouterNG dispatcher uses.
    bytes4 private constant V4_UNLOCK_SELECTOR = 0x48c89491;

    /// @dev Strict size of a single-hop v4SwapData tuple — 5 × 32-byte words.
    /// Mirrors `LiquidationExecutor.V4_SWAP_DATA_LENGTH`.
    uint256 private constant V4_SWAP_DATA_LENGTH = 160;

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

            if (op.flags & FLAG_V4_UNLOCK != 0) {
                // ── V4 single-hop exact-out via PoolManager unlock ──
                // The executor's `unlockCallback` (audited for structured V4
                // legs) performs the swap; this branch only arms the two
                // storage fields its guards read (`_activeV4PoolManager`,
                // `_activeV4TokenIn`) and wraps the 160-byte tuple into the
                // canonical unlock payload. Token movement happens inside the
                // callback (settle/take) — no allowance is granted, so the
                // approve/reset pair is skipped. The shared outToken delta
                // check below still pins the swap output to the executor, and
                // the per-srcToken containment cap bounds what the op spends.
                if (op.callData.length != V4_SWAP_DATA_LENGTH) revert InvalidPlan();
                // FULL_BALANCE / PREV_RETURN would make `amount` an INPUT
                // amount, but a V4 op's `amount` is the exact-OUT spec —
                // reject the combination instead of mis-signing the swap.
                if (op.flags & (FLAG_USE_FULL_BALANCE | FLAG_USE_PREV_RETURN) != 0) revert InvalidPlan();
                // Positive int256 discriminates exact-out in the callback;
                // bound the cast so the sign can never flip (mirrors
                // `_executeUniV4Leg`).
                if (amount == 0 || amount > uint256(type(int256).max)) revert InvalidPlan();

                // Arm. Slot 10 packs `_executionPhase` in byte 20 — preserve
                // everything above the address.
                uint256 pmSlot = V4_PM_SLOT;
                uint256 tokenInSlot = V4_TOKENIN_SLOT;
                address pm = op.target;
                address tokenIn = op.srcToken;
                assembly {
                    let cur := sload(pmSlot)
                    sstore(pmSlot, or(and(cur, not(0xffffffffffffffffffffffffffffffffffffffff)), pm))
                    sstore(tokenInSlot, tokenIn)
                }

                (bool okV4, bytes memory retV4) =
                    op.target.call(abi.encodeWithSelector(V4_UNLOCK_SELECTOR, abi.encode(op.callData, int256(amount))));

                // Disarm — the callback CLAIMs tokenIn itself, but clear both
                // defensively (an unlock that never reached our callback must
                // not leave the executor armed for a later stray callback).
                assembly {
                    let cur := sload(pmSlot)
                    sstore(pmSlot, and(cur, not(0xffffffffffffffffffffffffffffffffffffffff)))
                    sstore(tokenInSlot, 0)
                }

                if (!okV4) {
                    if (retV4.length > 0) {
                        assembly {
                            revert(add(retV4, 0x20), mload(retV4))
                        }
                    }
                    revert OpCallFailed(i);
                }
            } else {
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
            }

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
