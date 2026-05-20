// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SwapMode, SwapLeg} from "../types/SwapTypes.sol";

/// @title SwapValidationLib
/// @notice Per-mode pre-flashloan validation of `SwapLeg`. Single
/// source of truth for the field-shape checks every executor (current
/// `LiquidationExecutor`, future `ArbExecutor`) runs before
/// dispatching a leg.
///
/// SCOPE — non-V4 modes only:
///   * UNI_V4 / UNI_V4_BUY validation consults `allowedV4Hooks` storage
///     (per-hook allowlist read), which a pure library cannot reach.
///     Callers MUST short-circuit V4 to their own `_validateV4Leg`
///     BEFORE invoking `validateNonV4Leg`. The lib reverts
///     `InvalidSwapMode` if a V4 leg slips through — defense in depth.
///
/// Called via DELEGATECALL — error selectors and revert reasons match
/// the caller's contract surface exactly (Solidity error selectors are
/// derived from the signature, not the declaring contract, so duplicate
/// declarations across this lib and the executor produce the same
/// 4-byte selector that tests can pin against).
library SwapValidationLib {
    // ─── Errors (same selectors as LiquidationExecutor by signature) ─
    error ZeroAddress();
    error SwapDeadlineExpired(uint256 deadline, uint256 currentTimestamp);
    error InvalidPlan();
    error LegUseFullBalanceNotAllowed(uint8 mode);
    error InvalidParaswapCalldata();
    error ZeroAmountIn();
    error InvalidBebopTarget();
    error InvalidBebopCalldata();
    error InvalidV2Path();
    error InvalidV3Fee(uint24 fee);
    error InvalidSwapMode();

    /// @dev Pre-flashloan validation for every SwapMode except V4.
    ///
    /// Mode normalisation: BUY-side variants (UNI_V3_BUY, UNI_V2_BUY,
    /// CURVE_V1_BUY, BAL_V2_BUY) share their field-shape rules with
    /// the corresponding SELL mode. Normalising once at the top saves
    /// branching against duplicated selectors.
    ///
    /// V4 is rejected with `InvalidSwapMode` — callers must dispatch
    /// V4 separately because hook allowlist enforcement is storage-
    /// dependent and lib-local code cannot read it.
    function validateNonV4Leg(SwapLeg memory leg) external view {
        if (leg.srcToken == address(0)) revert ZeroAddress();
        if (leg.repayToken == address(0)) revert ZeroAddress();

        SwapMode m = leg.mode;
        if (m == SwapMode.UNI_V3_BUY) m = SwapMode.UNI_V3;
        if (m == SwapMode.UNI_V2_BUY) m = SwapMode.UNI_V2;
        if (m == SwapMode.CURVE_V1_BUY) m = SwapMode.CURVE_V1;
        if (m == SwapMode.BAL_V2_BUY) m = SwapMode.BAL_V2;
        // V4 BUY remains its own enum value here — falls through to
        // the `InvalidSwapMode` revert below as a defense-in-depth
        // assertion that the caller dispatched V4 elsewhere.

        // NO_SWAP: same-token path; every DEX-related field MUST be
        // zero/empty. Defense-in-depth against future consumers reading
        // these fields without re-checking the mode.
        if (m == SwapMode.NO_SWAP) {
            assertNoSwapLegZeroedInternal(leg);
            return;
        }

        if (block.timestamp > leg.deadline) revert SwapDeadlineExpired(leg.deadline, block.timestamp);
        if (leg.srcToken == leg.repayToken) revert InvalidPlan();

        // Paraswap/Bebop: reject useFullBalance (amountIn is inside calldata).
        if ((m == SwapMode.PARASWAP_SINGLE || m == SwapMode.BEBOP_MULTI) && leg.useFullBalance) {
            revert LegUseFullBalanceNotAllowed(uint8(m));
        }

        if (m == SwapMode.PARASWAP_SINGLE) {
            if (leg.paraswapCalldata.length < 4) revert InvalidParaswapCalldata();
            if (leg.amountIn == 0) revert ZeroAmountIn();
            // V10 audit LEAD (not enforced): every other mode requires
            // `leg.minAmountOut > 0`. Paraswap historically relies on
            // the calldata-embedded Augustus floor instead; SwapLegExecutorLib
            // checks `amountOut < minAmountOut` (calldata floor) AND
            // `amountOut < leg.minAmountOut` (struct floor). When the
            // struct floor is 0 the second check is a no-op. Bot-side
            // is expected to populate `leg.minAmountOut` after the
            // Paraswap-bot-pipeline change ships; enforcement deferred
            // until then to avoid breaking historical SwapLeg fixtures.
        } else if (m == SwapMode.BEBOP_MULTI) {
            if (leg.bebopTarget == address(0)) revert InvalidBebopTarget();
            if (leg.bebopCalldata.length < 4) revert InvalidBebopCalldata();
            if (leg.amountIn == 0) revert ZeroAmountIn();
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.UNI_V2) {
            uint256 pLen = leg.v2Path.length;
            if (pLen < 2) revert InvalidV2Path();
            if (leg.v2Path[0] != leg.srcToken) revert InvalidV2Path();
            if (leg.v2Path[pLen - 1] != leg.repayToken) revert InvalidV2Path();
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.UNI_V3) {
            // Both UNI_V3 (SELL) and UNI_V3_BUY (mode normalised above)
            // land here. Single-hop vs multihop is signalled by
            // `leg.v4SwapData.length`:
            //   * empty  → single-hop, validate `v3Fee` against the
            //              canonical Uniswap V3 fee tier set
            //   * non-empty → multihop, fees are inside the path bytes;
            //              skip v3Fee here. Path-shape sanity (length,
            //              endpoint tokens) is enforced by the lib at
            //              dispatch — bad fees inside the path get
            //              naturally caught when the router fails to
            //              find a pool. BUY-specific invariants
            //              (amountInMax > 0, amountOut > 0) are
            //              re-checked by the library at dispatch.
            if (leg.v4SwapData.length == 0) {
                uint24 f = leg.v3Fee;
                if (f != 100 && f != 500 && f != 3000 && f != 10000) revert InvalidV3Fee(f);
            } else {
                // Multihop: cheap length sanity (>= 66, (len - 20) % 23 == 0).
                // Lib re-checks endpoints; we keep this here so a malformed
                // length fails fast pre-flashloan.
                if (leg.v4SwapData.length < 66 || (leg.v4SwapData.length - 20) % 23 != 0) {
                    revert InvalidPlan();
                }
            }
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.CURVE_V1) {
            // Curve V1 SELL/BUY. Pool address comes from `bebopTarget`
            // (re-used as the generic "external swap target"). Encoded
            // ext-data carries (int128 i, int128 j, bool useUnderlying)
            // — abi.encode minimum size = 3 * 32 = 96 bytes.
            //
            // amountIn is intentionally NOT validated here — leg2 with
            // useFullBalance=true (sequential + split plans) carries a
            // zero amountIn that's filled in at runtime from the
            // measured leg1 leftover. The library re-asserts
            // amountIn > 0 at dispatch (`ZeroSwapInput`).
            if (leg.bebopTarget == address(0)) revert InvalidPlan();
            if (leg.bebopCalldata.length < 96) revert InvalidPlan();
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.BAL_V2) {
            // Balancer V2 SELL/BUY. Vault address from `bebopTarget`;
            // poolId + userData packed in `bebopCalldata` as
            // abi.encode(bytes32, bytes) — minimum encoding includes
            // the 32-byte poolId plus a 64-byte dynamic-bytes tail
            // (offset + length, even when userData is empty) = 96 bytes.
            //
            // amountIn validation: same reasoning as CURVE_V1 — deferred
            // to lib's runtime `ZeroSwapInput` check so useFullBalance=true
            // leg2 plans (where amountIn = 0 on-wire) are accepted.
            if (leg.bebopTarget == address(0)) revert InvalidPlan();
            if (leg.bebopCalldata.length < 96) revert InvalidPlan();
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else {
            // V4 (SELL or BUY) or anything else — caller must dispatch.
            revert InvalidSwapMode();
        }
    }

    /// @dev Defensive zero-check for NO_SWAP legs. NO_SWAP doesn't
    /// consult any DEX, so every DEX-related field must be zero/empty.
    /// Currently NO consumer reads these for NO_SWAP, but a regression
    /// in any future code path would silently inherit an attacker-
    /// controlled payload. Asserting upstream makes the contract
    /// regression-proof.
    ///
    /// External entry point so callers (e.g. LiquidationExecutor's
    /// pre-flashloan validator pass for NO_SWAP same-token plans) can
    /// call it directly without the `validateNonV4Leg` mode dispatch.
    function assertNoSwapLegZeroed(SwapLeg memory leg) external pure {
        assertNoSwapLegZeroedInternal(leg);
    }

    /// @dev Internal helper so the public `validateNonV4Leg`
    /// (delegate-calling itself for the NO_SWAP branch) does not pay
    /// the per-leg DELEGATECALL overhead twice.
    function assertNoSwapLegZeroedInternal(SwapLeg memory leg) private pure {
        // NO_SWAP is the same-token branch — srcToken MUST equal repayToken.
        if (leg.srcToken != leg.repayToken) revert InvalidPlan();
        if (
            leg.useFullBalance || leg.deadline != 0 || leg.amountIn != 0 || leg.minAmountOut != 0
                || leg.paraswapCalldata.length != 0 || leg.bebopTarget != address(0) || leg.bebopCalldata.length != 0
                || leg.v2Path.length != 0 || leg.v3Fee != 0 || leg.v4PoolManager != address(0)
                || leg.v4SwapData.length != 0
        ) revert InvalidPlan();
    }
}
