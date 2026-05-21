// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    BAL_V2_BUY // 12
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
