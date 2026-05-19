// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SwapMode, SwapLeg} from "../types/SwapTypes.sol";

/// @dev Subset of Balancer V2 Vault — single-swap entrypoint only.
/// `IAsset` in Balancer == address with native-ETH sentinel; we never
/// route ETH so it's typed as `address` here. Decimals/struct layout
/// match the Vault contract verbatim.
interface IBalancerV2Vault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(SingleSwap memory singleSwap, FundManagement memory funds, uint256 limit, uint256 deadline)
        external
        payable
        returns (uint256 amountCalculated);
}

/// @title BalancerV2Lib
/// @notice External library housing Balancer V2 single-swap leg execution
/// against the Balancer Vault. Supports both SELL (SwapKind.GIVEN_IN)
/// and BUY (SwapKind.GIVEN_OUT) natively — Balancer is one of the few
/// external DEXes that exposes exact-out as a first-class primitive.
///
/// Called via DELEGATECALL from `LiquidationExecutor._dispatchLeg`.
///
/// SCOPE:
///   * Single-swap only (no `batchSwap` / multihop in this lib). Multi-
///     pool routes can chain two single-swap legs via the existing
///     two-leg plan shape if needed.
///   * WeightedPool, StablePool, ComposableStablePool, MetaStablePool —
///     routed through the same `Vault.swap` entrypoint; pool type is
///     opaque to the caller (Vault dispatches via poolId → pool addr).
///   * Phantom-BPT pools (ComposableStablePool) are supported by the
///     Vault as long as the caller's assetIn/assetOut are real underlying
///     tokens. The bot is responsible for picking non-BPT endpoints.
///
/// BUY-SIDE MODEL:
///   `kind = GIVEN_OUT`, `amount = targetOut (= leg.minAmountOut)`,
///   `limit = maxIn (= leg.amountIn)`. The Vault consumes ≤ `limit`
///   from us and credits `targetOut` to us. Approval is sized to
///   `leg.amountIn` (the max). Post-swap we re-zero the approval and
///   verify post-balance ≥ targetOut as defense-in-depth.
///
/// SELL-SIDE MODEL:
///   `kind = GIVEN_IN`, `amount = amountIn`, `limit = leg.minAmountOut`
///   (= min acceptable output).
///
/// SECURITY:
///   * Vault address from `leg.bebopTarget` (re-purposed as external
///     swap target). V10+: no per-pool allowlist —`executeLeg` does
///     `vault != 0` and `vault.code.length > 0` sanity gates; the bot
///     is the trusted source of the Vault address. The single canonical
///     Balancer V2 Vault `0xBA12222222228d8Ba445958a75a0704d566BF2C8`
///     is the only one a real plan should ever reference.
///   * `forceApprove(vault, amountIn) → swap → forceApprove(vault, 0)`.
///   * Output delta floor: `received >= leg.minAmountOut`.
///
/// STRUCT DISCIPLINE: `SwapLeg` imported from `../types/SwapTypes.sol`
/// — same struct used by every executor and per-mode library, no
/// re-declaration or cast required.
///
/// EXT-DATA ENCODING (re-uses the `bebopCalldata` byte field):
///   `bebopCalldata = abi.encode(bytes32 poolId, bytes userData)`
///
/// `userData` is almost always empty for SingleSwap; the Vault accepts
/// it as opaque pool-specific calldata (used by certain pool types
/// e.g. ManagedPool for join-on-swap). Keeping it future-proofs the
/// encoding without a contract upgrade.
library BalancerV2Lib {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error InvalidVaultTarget();
    error ZeroSwapInput();
    error ZeroSwapOutput();
    error InvalidPlan();

    // ─── Event ───────────────────────────────────────────────────────
    /// @dev Mirror of LiquidationExecutor's `BalancerV2SwapExecuted` so
    /// the emit fires from the executor's address with the canonical
    /// topic hash. `poolId` is indexed for filtering by venue.
    event BalancerV2SwapExecuted(
        bytes32 indexed poolId,
        address indexed srcToken,
        address indexed dstToken,
        uint256 amountIn,
        uint256 amountOut,
        uint8 kind
    );

    /// @dev Single entrypoint for BAL_V2 (SELL) and BAL_V2_BUY. The
    /// caller's `mode` field selects SwapKind.
    ///
    /// @param leg       SwapLeg (shared definition in SwapTypes.sol).
    /// @param amountIn  Caller-resolved input amount (full-balance applied upstream).
    function executeLeg(SwapLeg memory leg, uint256 amountIn) external {
        if (amountIn == 0) revert ZeroSwapInput();
        if (leg.minAmountOut == 0) revert ZeroSwapOutput();

        address vault = leg.bebopTarget;
        if (vault == address(0)) revert InvalidVaultTarget();
        if (vault.code.length == 0) revert InvalidVaultTarget();

        // Decode ext-data: (poolId, userData)
        if (leg.bebopCalldata.length == 0) revert InvalidPlan();
        (bytes32 poolId, bytes memory userData) = abi.decode(leg.bebopCalldata, (bytes32, bytes));

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);
        uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));

        IERC20(leg.srcToken).forceApprove(vault, amountIn);

        bool isBuy = leg.mode == SwapMode.BAL_V2_BUY;
        IBalancerV2Vault.SwapKind kind =
            isBuy ? IBalancerV2Vault.SwapKind.GIVEN_OUT : IBalancerV2Vault.SwapKind.GIVEN_IN;
        uint256 swapAmount = isBuy ? leg.minAmountOut : amountIn;
        uint256 swapLimit = isBuy ? amountIn : leg.minAmountOut;

        IBalancerV2Vault.SingleSwap memory single = IBalancerV2Vault.SingleSwap({
            poolId: poolId,
            kind: kind,
            assetIn: leg.srcToken,
            assetOut: leg.repayToken,
            amount: swapAmount,
            userData: userData
        });
        IBalancerV2Vault.FundManagement memory funds = IBalancerV2Vault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        IBalancerV2Vault(vault).swap(single, funds, swapLimit, leg.deadline);
        IERC20(leg.srcToken).forceApprove(vault, 0);

        uint256 received = IERC20(leg.repayToken).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        emit BalancerV2SwapExecuted(poolId, leg.srcToken, leg.repayToken, amountIn, received, uint8(kind));
    }
}
