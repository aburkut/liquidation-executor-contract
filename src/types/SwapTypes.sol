// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketParams} from "../interfaces/IMorphoBlue.sol";

/// @title Shared swap-leg types
/// @notice File-scope enum + struct definitions imported by every
/// swap-related library and by both executor contracts
/// (`LiquidationExecutor`, `ArbExecutor`). File scope (not wrapped in
/// a library) so consumers can name them directly:
///
///   import {SwapMode, SwapLeg} from "../types/SwapTypes.sol";
///   function dispatch(SwapLeg memory leg) { ... leg.mode == SwapMode.UNI_V3 ... }
///
/// FROZEN INTERFACE: changing field order, types, or enum positions
/// silently corrupts every ABI-decode that passes through DELEGATECALL
/// (libraries' memory layout has to match callers exactly). Adding a
/// new SwapMode means appending at the END of the enum, never
/// reordering. Treat as load-bearing.

/// @dev Dispatch enum read by the per-mode router. SELL/BUY pairs
/// (e.g. UNI_V3 + UNI_V3_BUY) share the same on-chain swap path; the
/// BUY variant flips the per-library code to `exactOutput*` style and
/// remaps `amountIn` → `amountInMax` / `minAmountOut` → exact-out
/// target.
enum SwapMode {
    PARASWAP_SINGLE, // 0
    BEBOP_MULTI, // 1
    UNI_V2, // 2
    UNI_V3, // 3
    UNI_V4, // 4
    NO_SWAP, // 5 — same-token branch; no DEX consulted
    UNI_V3_BUY, // 6
    UNI_V2_BUY, // 7
    UNI_V4_BUY, // 8
    CURVE_V1, // 9
    CURVE_V1_BUY, // 10
    BAL_V2, // 11
    BAL_V2_BUY, // 12
    CURVE_V1_MH, // 13 — Curve RouterNG.exchange(address[11], uint256[5][5], …) multihop SELL
    CURVE_V1_MH_BUY, // 14 — multihop BUY (same router selector; min_dy interpreted as exact-out)
    BAL_V2_MH, // 15 — Balancer Vault.batchSwap(SwapKind.GIVEN_IN, …) multihop SELL
    BAL_V2_MH_BUY // 16 — Balancer Vault.batchSwap(SwapKind.GIVEN_OUT, …) multihop BUY
}

/// @dev Single swap leg descriptor.
///
/// Per-mode field usage (only the listed fields are read for that
/// mode; the rest stay default-zero / empty):
///   * PARASWAP_SINGLE → `paraswapCalldata`, `amountIn` inside calldata
///   * BEBOP_MULTI     → `bebopTarget`, `bebopCalldata`, `amountIn`
///   * UNI_V2{,_BUY}   → `v2Path` (≥ 2 entries: src…repay)
///   * UNI_V3{,_BUY}   → `v3Fee` (∈ {100, 500, 3000, 10000}) for
///                       single-hop; `v4SwapData` non-empty for
///                       multihop (path bytes)
///   * UNI_V4{,_BUY}   → `v4PoolManager`, `v4SwapData` (160 bytes
///                       single-hop, larger for multihop V4Hop[])
///   * CURVE_V1{,_BUY} → `bebopTarget` = pool, `bebopCalldata` =
///                       abi.encode(int128 i, int128 j, bool useUnderlying)
///   * BAL_V2{,_BUY}   → `bebopTarget` = Vault, `bebopCalldata` =
///                       abi.encode(bytes32 poolId, bytes userData)
///   * CURVE_V1_MH{,_BUY} →
///                       `bebopTarget` = Curve RouterNG (canonical), `bebopCalldata` =
///                       abi.encode(address[11] path, uint256[5][5] swapParams,
///                                  address[5] pools)
///   * BAL_V2_MH{,_BUY}  →
///                       `bebopTarget` = Vault, `bebopCalldata` =
///                       abi.encode(IBalancerVault.BatchSwapStep[] swaps,
///                                  address[] assets, int256[] limits)
///   * NO_SWAP         → every field above MUST be zero/empty; src==repay
struct SwapLeg {
    SwapMode mode;
    address srcToken;
    uint256 amountIn;
    bool useFullBalance;
    uint256 deadline;
    // Paraswap (PARASWAP_SINGLE only — leg1 only)
    bytes paraswapCalldata;
    // Bebop (BEBOP_MULTI only — leg1 only)
    address bebopTarget;
    bytes bebopCalldata;
    // Uniswap V2 (UNI_V2{,_BUY} only)
    address[] v2Path;
    // Uniswap V3 (UNI_V3{,_BUY} only)
    uint24 v3Fee;
    // Uniswap V4 (UNI_V4{,_BUY} only)
    address v4PoolManager;
    bytes v4SwapData;
    // Per-leg output binding.
    // For leg1 in a one-leg plan: == outer plan.loanToken.
    // For leg1 in a two-leg plan: == leg2.srcToken (intermediate).
    // For leg2 always:            == outer plan.loanToken.
    address repayToken;
    uint256 minAmountOut;
}

/// @dev One generic DEX call in a GENERIC_SEQUENCE (direct-call routing).
/// `callData` is built offchain; the executor patches runtime amounts into it
/// before the call. Shared by `LiquidationExecutor` and `GenericSequenceLib`.
struct Op {
    address target; // DEX router/aggregator (must be in `allowedTargets`)
    uint256 value; // MUST be 0 — native ETH forwarding is forbidden (audit)
    uint256 amountIn; // explicit input amount when neither FULL_BALANCE nor PREV_RETURN set
    uint16 fromAmountPos; // byte offset in callData to inject the input amount; 0 = none
    uint16 returnAmountPos; // byte offset to inject the previous op's output; 0 = none
    uint32 flags; // see GenericSequenceLib FLAG_*
    address srcToken; // token spent by this op (approved to target)
    address outToken; // token received (its balance delta = this op's output)
    bytes callData; // selector + args, pre-built offchain
}

// ─── Liquidation action types ────────────────────────────────────────
// Moved out of LiquidationExecutor (file scope) so the pure plan
// validator can live in `SwapValidationLib` and keep the executor under
// the EIP-170 runtime-size limit. Layout is byte-identical to the prior
// contract-scoped definitions — the off-chain encoder is unaffected.

/// @dev One protocol action in a Plan (liquidation or internal).
struct Action {
    uint8 protocolId;
    bytes data;
}

/// @dev Aave V3 target action (actionType == 4 == liquidation only).
struct AaveV3Action {
    uint8 actionType; // 4 = liquidation (only supported type)
    address asset;
    uint256 amount;
    uint256 interestRateMode;
    address onBehalfOf;
    // Liquidation fields (actionType == 4 only)
    address collateralAsset;
    address debtAsset;
    address user;
    uint256 debtToCover;
    bool receiveAToken;
    address aTokenAddress;
}

/// @dev Aave V2 liquidation action. receiveAToken=true is unsupported.
struct AaveV2Liquidation {
    address collateralAsset;
    address debtAsset;
    address user;
    uint256 debtToCover;
    bool receiveAToken; // must be false — validated in validateActions
}

/// @dev Morpho Blue liquidation action (seized-assets mode only).
struct MorphoLiquidation {
    MarketParams marketParams;
    address borrower;
    uint256 seizedAssets;
    uint256 repaidShares;
    /// @dev Max loan-token amount to approve for repayment (loan-token units).
    /// Must be >= actual assetsRepaid returned by Morpho.
    uint256 maxRepayAssets;
}
