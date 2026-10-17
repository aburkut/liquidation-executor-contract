// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SwapMode,
    SwapLeg,
    Op,
    Action,
    AaveV3Action,
    AaveV2Liquidation,
    MorphoLiquidation
} from "../types/SwapTypes.sol";
import {GenericSequenceLib} from "./GenericSequenceLib.sol";

/// @title SwapValidationLib
/// @notice Per-mode pre-flashloan validation of `SwapLeg`. Single
/// source of truth for the field-shape checks every executor (current
/// `LiquidationExecutor`, future `ArbExecutor`) runs before
/// dispatching a leg.
///
/// SCOPE — non-V4 modes only:
///   * UNI_V4 / UNI_V4_BUY validation consults `blockedV4Hooks` storage
///     (per-hook blocklist read), which a pure library cannot reach.
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

    // ─── validateGenericOps errors (selectors match LiquidationExecutor) ─
    error EmptyOps();
    error TooManyOps();
    error TargetNotAllowed();

    // ─── validateActions errors (selectors match LiquidationExecutor) ────
    error UnsupportedActionType(uint8 actionType);
    error InvalidCollateralAsset();
    error ReceiveATokenV2Unsupported();
    error MorphoInvalidMarketParams();
    error MorphoShareModeUnsupported();
    error MorphoMixedModeUnsupported();
    error InvalidProtocolId(uint8 id);
    error ZeroActionAmount();
    error DebtAssetMismatch(address expected, address actual);
    error CollateralAssetMismatch(address expected, address actual);
    error ATokenAddressRequired();
    error MixedReceiveAToken();
    error NoLiquidationAction();
    error ActionsSpentStandingLoan(uint256 spent, uint256 loanAmount);

    // ─── Protocol ids (must match LiquidationExecutor) ───────────────────
    uint8 internal constant PROTOCOL_AAVE_V3 = 1;
    uint8 internal constant PROTOCOL_MORPHO_BLUE = 2;
    uint8 internal constant PROTOCOL_AAVE_V2 = 3;

    uint16 private constant MAX_OPS = 32; // gas-grief bound on sequence length

    /// @notice Pure plan-shape validation, moved out of LiquidationExecutor to
    /// keep the executor under the EIP-170 runtime-size limit. Called via
    /// DELEGATECALL, so error selectors surface exactly as the caller's own.
    /// Validates every action's protocol/shape, that all liquidations target
    /// the same `loanToken` debt and a single collateral asset, and the
    /// receiveAToken consistency; returns (collateralAsset, trackingToken).
    function validateActions(Action[] memory actions, address loanToken)
        external
        pure
        returns (address collateralAsset, address trackingToken)
    {
        uint256 liquidationCount;
        bool receiveATokenSet;
        bool receiveAToken;
        address aTokenAddr;

        for (uint256 i = 0; i < actions.length; ++i) {
            uint8 protocolId = actions[i].protocolId;

            bytes memory data = actions[i].data;

            address actionDebt;
            address actionCollateral;
            uint256 actionAmount;
            bool actionReceiveAToken;
            address actionATokenAddress;

            if (protocolId == PROTOCOL_AAVE_V3) {
                AaveV3Action memory a = abi.decode(data, (AaveV3Action));
                if (a.actionType != 4) revert UnsupportedActionType(a.actionType);
                if (a.collateralAsset == address(0)) revert InvalidCollateralAsset();
                actionDebt = a.debtAsset;
                actionCollateral = a.collateralAsset;
                actionAmount = a.debtToCover;
                actionReceiveAToken = a.receiveAToken;
                actionATokenAddress = a.aTokenAddress;
            } else if (protocolId == PROTOCOL_AAVE_V2) {
                AaveV2Liquidation memory a = abi.decode(data, (AaveV2Liquidation));
                if (a.receiveAToken) revert ReceiveATokenV2Unsupported();
                if (a.collateralAsset == address(0)) revert InvalidCollateralAsset();
                actionDebt = a.debtAsset;
                actionCollateral = a.collateralAsset;
                actionAmount = a.debtToCover;
            } else if (protocolId == PROTOCOL_MORPHO_BLUE) {
                MorphoLiquidation memory a = abi.decode(data, (MorphoLiquidation));
                if (a.marketParams.loanToken == address(0)) revert MorphoInvalidMarketParams();
                if (a.marketParams.collateralToken == address(0)) revert MorphoInvalidMarketParams();
                // Only seized-assets mode is supported. Share mode and mixed mode are rejected.
                if (a.seizedAssets == 0) revert MorphoShareModeUnsupported();
                if (a.repaidShares != 0) revert MorphoMixedModeUnsupported();
                if (a.maxRepayAssets == 0) revert InvalidPlan();
                actionDebt = a.marketParams.loanToken;
                actionCollateral = a.marketParams.collateralToken;
                actionAmount = a.seizedAssets;
            } else {
                revert InvalidProtocolId(protocolId);
            }

            if (actionAmount == 0) revert ZeroActionAmount();
            if (actionDebt != loanToken) revert DebtAssetMismatch(loanToken, actionDebt);

            if (actionCollateral != address(0)) {
                if (collateralAsset == address(0)) {
                    collateralAsset = actionCollateral;
                } else {
                    if (actionCollateral != collateralAsset) {
                        revert CollateralAssetMismatch(collateralAsset, actionCollateral);
                    }
                }
            }

            // receiveAToken consistency check (Aave V3 only — V2 receiveAToken=true is blocked above)
            if (protocolId == PROTOCOL_AAVE_V3) {
                if (!receiveATokenSet) {
                    receiveAToken = actionReceiveAToken;
                    receiveATokenSet = true;
                    if (receiveAToken) {
                        if (actionATokenAddress == address(0)) revert ATokenAddressRequired();
                        aTokenAddr = actionATokenAddress;
                    }
                } else {
                    if (actionReceiveAToken != receiveAToken) revert MixedReceiveAToken();
                    if (receiveAToken && actionATokenAddress != aTokenAddr) {
                        revert CollateralAssetMismatch(aTokenAddr, actionATokenAddress);
                    }
                }
            }

            liquidationCount++;
        }

        if (liquidationCount == 0) revert NoLiquidationAction();

        // Set trackingToken: aToken when receiveAToken=true, underlying otherwise
        trackingToken = (receiveAToken && aTokenAddr != address(0)) ? aTokenAddr : collateralAsset;
    }

    /// @notice The generic-sequence op walk, run once before the flash loan.
    /// Moved out of LiquidationExecutor for the EIP-170 budget, unchanged in
    /// order and in error selectors, plus the Balancer vault as a swap venue
    /// (`_isOwnVaultSwap`). It is the authoritative target gate:
    /// GenericSequenceLib runs the ops via DELEGATECALL and cannot re-read
    /// `allowedTargets`, so it trusts this check.
    /// @param vault the executor's Balancer flash provider, also a target
    /// @param balancerFlash the plan borrows from that vault
    function validateGenericOps(
        Op[] memory ops,
        mapping(address => bool) storage allowedTargets,
        address aavePool,
        address morphoBlue,
        address aaveV2LendingPool,
        address vault,
        bool balancerFlash
    ) external view {
        uint256 nOps = ops.length;
        if (nOps == 0) revert EmptyOps();
        if (nOps > MAX_OPS) revert TooManyOps();
        for (uint256 i = 0; i < nOps; ++i) {
            Op memory op = ops[i];
            // WETH-unwrap ops carry no external `target` — they only invoke
            // `IWETH(weth).withdraw` on the contract-pinned `weth` inside the
            // lib (which enforces `srcToken == weth` and the exact-flag
            // shape), so there is nothing to allowlist. Exempt them from the
            // target gate; every other op's target must be allowlisted.
            // EXACT equality, not bit presence. A combined-flag op
            // (FLAG_WETH_UNWRAP | FLAG_V4_UNLOCK, or | FLAG_V3_FLASH)
            // DOES carry an external target, so bit-presence skipped
            // the executor's own allowlist gate — and, sitting above
            // the flash rejection below, the flash gate too. Only a
            // library backstop stood behind them. `ArbExecutor` has
            // always used equality here; the two now agree.
            // Neither an unwrap nor a wrap carries an external target: the
            // library calls the pinned `weth.withdraw` / `weth.deposit`
            // itself. Merged into one condition, and the wrap side uses a
            // masked equality, purely for the EIP-170 budget — the naive
            // form cost 86 bytes and pushed the executor past the
            // project's own headroom guard at 24400.
            //
            // Still EXACT on both sides: `flags & ~PREV == WRAP` accepts
            // the two shapes GenericSequenceLib accepts and rejects
            // WRAP|V4_UNLOCK (the unlock bit survives the mask) and a bare
            // PREV (leaves 0). The unwrap keeps plain equality, as before.
            //
            // #38 taught the library FLAG_WETH_WRAP and left both
            // executors' walks behind it; the arb path hit that in
            // production on 2026-09-11 and this walk carries the identical
            // gap, latent only because the bot emits no wrap here yet.
            //
            // Safe above the dangerous-target check for the same reason
            // the unwrap always was: the library never calls `op.target`
            // for either shape. NOT because the target is address(0) —
            // this walk runs BEFORE the library, so a plan may carry
            // `flags == FLAG_WETH_WRAP` with any target it likes. It
            // simply never gets called.
            uint32 f = op.flags;
            if (
                f == GenericSequenceLib.FLAG_WETH_UNWRAP
                    || f & ~GenericSequenceLib.FLAG_USE_PREV_RETURN == GenericSequenceLib.FLAG_WETH_WRAP
            ) continue;
            // FLASH swaps run the rest of the sequence inside a pool
            // callback; the executor only implements the immediate-pay
            // callbacks (size budget), so a flash op cannot run here.
            if (f & (GenericSequenceLib.FLAG_V3_FLASH | GenericSequenceLib.FLAG_V2_FLASH) != 0) {
                revert InvalidPlan();
            }
            // Being allowlisted is not enough for a target that can move
            // value WITHOUT an allowance, or mint balance the containment
            // cap then reads as income. AUDITED 2026-09-08:
            // LiquidationExecutorGenesis seeds the lending pools and the
            // vault into `allowedTargets` because the liquidation and flash paths
            // re-read that mapping as their own kill-switch — which also
            // handed a generic op their whole function surface, with
            // operator-authored calldata. Two shapes escape the cap
            // outright: `borrow(asset, Y, 2, 0, this)` RAISES the balance
            // the cap measures, so the borrowed principal routes out and
            // the cap sees nothing; and `withdraw(asset, max, attacker)`
            // burns the executor's own aTokens with no allowance and no
            // `srcToken`, so the token is never bucketed at all.
            // `ArbExecutor` refuses to seed Morpho for this reason and
            // says so; this is the same refusal, kept narrow so the
            // liquidation paths still work.
            //
            // ABOVE the direct-pool exemption below, not after it: a
            // direct-pool op names its pool freely, and the check has to
            // see every op.
            //
            // The Balancer vault is a swap venue too, so it passes as
            // exactly one call (`_isOwnVaultSwap`), and never under a
            // Balancer flash, where its lock is held. Refusing it whole cost
            // every split that priced a Balancer pool: the bot builds those
            // under a Morpho flash, and the chain reverted each one here
            // (TargetNotAllowed, measured 2026-10-16 replaying the 15.10
            // liquidations).
            address t = op.target;
            if (
                t == aavePool || t == morphoBlue || t == aaveV2LendingPool
                    || (t == vault && (balancerFlash || !_isOwnVaultSwap(op)))
            ) revert TargetNotAllowed();
            // Direct pool swaps name the pool itself: permissionless and
            // bounded by construction (DirectSwapLib), not allowlisted.
            if (f & (GenericSequenceLib.FLAG_V3_DIRECT | GenericSequenceLib.FLAG_V2_DIRECT) != 0) {
                continue;
            }
            // Every op target must be allowlisted.
            if (!allowedTargets[t]) revert TargetNotAllowed();
        }
    }

    /// @dev The one Balancer-vault call a generic op may make:
    /// `swap(SingleSwap, FundManagement, uint256 limit, uint256 deadline)`,
    /// paid from and to the executor's own external balances. DELEGATECALL,
    /// so `address(this)` is the executor.
    ///
    /// Not the whole vault, because an op's calldata is the operator's and
    /// the vault has calls that move value with no allowance:
    /// `setRelayerApproval(this, x, true)` lets `x` spend for the executor in
    /// every later transaction, `manageUserBalance` moves internal balances,
    /// `flashLoan` lends. A `swap` with `funds` pinned does none of that: the
    /// vault pulls `assetIn` through the allowance GenericSequenceLib grants
    /// for this op and takes back after it, and pays `assetOut` to the
    /// executor, where the library's output check requires it.
    ///
    /// Pinned here:
    ///   * the selector, 0x52bbbe29;
    ///   * `funds` = (this, false, this, false): head words 1..4, calldata
    ///     bytes [36, 164). `SingleSwap` is dynamic and lives in the tail, so
    ///     its offset word cannot move them;
    ///   * no patch slot inside bytes [0, 164): GenericSequenceLib writes 32
    ///     bytes at `fromAmountPos` / `returnAmountPos` AFTER this check, so a
    ///     slot there could rewrite the selector or a `funds` word once
    ///     checked. The bot's amount slot is 356 (`SingleSwap.amount`);
    ///   * nothing in `flags` but an amount source: no direct, V4, native or
    ///     flash shape.
    function _isOwnVaultSwap(Op memory op) private view returns (bool ok) {
        if (
            op.flags
                    & ~(GenericSequenceLib.FLAG_USE_FULL_BALANCE
                        | GenericSequenceLib.FLAG_USE_PREV_RETURN
                        | GenericSequenceLib.FLAG_USE_PRODUCED) != 0
        ) return false;
        if ((op.fromAmountPos != 0 && op.fromAmountPos < 164) || (op.returnAmountPos != 0 && op.returnAmountPos < 164))
        {
            return false;
        }
        bytes memory d = op.callData;
        // p = the selector; word k of the head starts at p + 4 + 32k. Word 0
        // is the SingleSwap offset, words 1..4 are `funds`.
        assembly ("memory-safe") {
            let p := add(d, 0x20)
            ok := and(
                and(gt(mload(d), 163), eq(shr(224, mload(p)), 0x52bbbe29)),
                and(
                    and(eq(mload(add(p, 36)), address()), iszero(mload(add(p, 68)))),
                    and(eq(mload(add(p, 100)), address()), iszero(mload(add(p, 132))))
                )
            )
        }
    }

    /// @notice Invariant: liquidation actions spend at most the flash
    /// principal of `loanToken`, never the executor's standing balance.
    /// Measured (DELEGATECALL, so `this` is the executor): a padded
    /// `debtToCover` that the pool trims to within `loanAmount` passes.
    function assertActionsWithinLoan(address loanToken, uint256 loanBefore, uint256 loanAmount) external view {
        uint256 balance = IERC20(loanToken).balanceOf(address(this));
        if (balance + loanAmount < loanBefore) revert ActionsSpentStandingLoan(loanBefore - balance, loanAmount);
    }

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
        if (m == SwapMode.CURVE_V1_MH_BUY) m = SwapMode.CURVE_V1_MH;
        if (m == SwapMode.BAL_V2_MH_BUY) m = SwapMode.BAL_V2_MH;
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
            // V10 audit fix: every swap mode now requires
            // `leg.minAmountOut > 0`. Paraswap historically deferred to
            // the calldata-embedded Augustus floor only — making the
            // dispatch site's second `amountOut < leg.minAmountOut`
            // check a no-op. Bot-side must populate this field from the
            // Paraswap `/prices` quote (typically `destAmount × 99/100`)
            // before submitting Paraswap-mode plans against V10+
            // executors. Bot integration is tracked separately.
            if (leg.minAmountOut == 0) revert InvalidPlan();
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
        } else if (m == SwapMode.CURVE_V1_MH) {
            // Curve V1 multihop via RouterNG. `bebopTarget` = Router
            // address; `bebopCalldata` = abi.encode(address[11] path,
            // uint256[5][5] swapParams, address[5] pools). Fixed-size
            // arrays encode without offsets/lengths:
            //   11 * 32 (path) + 25 * 32 (swapParams) + 5 * 32 (pools)
            //   = 41 * 32 = 1312 bytes.
            // Library re-decodes and asserts path endpoints match
            // srcToken / repayToken at dispatch.
            if (leg.bebopTarget == address(0)) revert InvalidPlan();
            if (leg.bebopCalldata.length < 1312) revert InvalidPlan();
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.BAL_V2_MH) {
            // Balancer V2 multihop via Vault.batchSwap. `bebopTarget` =
            // Vault address; `bebopCalldata` = abi.encode(
            //   BatchSwapStep[] swaps, address[] assets, int256[] limits).
            // All three are dynamic arrays — minimum non-empty encoding
            // is three offset words (3 * 32 = 96) plus three length
            // words (3 * 32 = 96) = 192 bytes for the headers, plus the
            // contents. Cheapest sanity threshold is therefore 192
            // bytes; library re-decodes and checks asset endpoints +
            // step shape at dispatch.
            if (leg.bebopTarget == address(0)) revert InvalidPlan();
            if (leg.bebopCalldata.length < 192) revert InvalidPlan();
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
