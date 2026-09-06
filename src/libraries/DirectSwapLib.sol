// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniV3PoolMinimal, IUniV2PairMinimal} from "../interfaces/IDirectPools.sol";

/// @title DirectSwapLib
/// @notice Swap against a Uniswap V2 pair or a V3-style pool DIRECTLY, with no
/// router in between.
///
/// Traced on our landed arbs (2026-09-06): a V3 leg through SwapRouter paid
/// ~7.4k for the router frame plus ~15k for the router's own callback (which
/// does a `transferFrom` out of our allowance) — 10-20k per leg that the
/// competitor's executor, which calls pools itself, never pays. A V2 leg
/// through Router02 paid ~10k of router on top of the pair. Going direct
/// also revives every V3 fork whose pools speak the canonical callback but
/// whose pool addresses the Uniswap router cannot derive (Sushi V3): the
/// router computes the pool from ITS factory, we just call the pool.
///
/// SECURITY — the pool is operator-supplied and NOT allowlisted:
///   * V3: the pool asks for its input through `uniswapV3SwapCallback`. We
///     pay only while ARMED for exactly that pool (transient words set
///     around the `swap` call), only `msg.sender == pool`, only once per
///     arming (the pool word is claimed on entry), only the token armed, and
///     never more than the op's `amount`. A hostile "pool" therefore gets at
///     most the op's input and the op then fails the output-delta check that
///     every generic op is subject to — the same exposure as an allowlisted
///     router routing into a hostile pool, which the containment cap already
///     bounds.
///   * V2: we transfer exactly `amount` to the pair and ask for the output
///     the reserve formula yields; a hostile pair can keep the input and the
///     output-delta check reverts the op.
///   Both paths spend nothing but the op's own `amount` of `srcToken`.
library DirectSwapLib {
    using SafeERC20 for IERC20;

    error DirectSwapInvalid();
    error DirectSwapCallbackUnarmed();
    error DirectSwapCallbackOverpull(uint256 owed, uint256 max);

    /// @dev TRANSIENT words arming the V3 callback: the pool we are inside,
    /// the token it may pull, and the most it may pull. Shared convention
    /// with the executors (which expose the callback and delegate here);
    /// numbers continue the executors' transient map (0 bid, 1 plan hash,
    /// 2 phase, 11/12 V4 arming).
    uint256 private constant V3_POOL_TSLOT = 13;
    uint256 private constant V3_TOKENIN_TSLOT = 14;
    uint256 private constant V3_MAX_TSLOT = 15;
    /// @dev The executors' phase word: the callback also requires an
    /// `execute` to be in flight.
    uint256 private constant PHASE_TSLOT = 2;

    // Uniswap V3 TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO.
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// @notice Exact-input swap against a V3-style pool. `data` =
    /// `abi.encode(bool zeroForOne, uint160 sqrtPriceLimitX96)`; a zero
    /// limit means "no limit" (the tick-math bound for the direction).
    /// Output lands on `address(this)`; the caller checks the delta.
    function swapV3(address pool, address tokenIn, uint256 amount, bytes memory data) internal {
        if (amount == 0 || amount > uint256(type(int256).max) || data.length != 64) revert DirectSwapInvalid();
        (bool zeroForOne, uint160 limit) = abi.decode(data, (bool, uint160));
        if (limit == 0) limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;

        assembly ("memory-safe") {
            tstore(V3_POOL_TSLOT, pool)
            tstore(V3_TOKENIN_TSLOT, tokenIn)
            tstore(V3_MAX_TSLOT, amount)
        }
        IUniV3PoolMinimal(pool).swap(address(this), zeroForOne, int256(amount), limit, "");
        assembly ("memory-safe") {
            tstore(V3_POOL_TSLOT, 0)
            tstore(V3_TOKENIN_TSLOT, 0)
            tstore(V3_MAX_TSLOT, 0)
        }
    }

    /// @notice Body of `uniswapV3SwapCallback` / `pancakeV3SwapCallback`:
    /// pay the armed pool what it is owed, once, never more than armed.
    function payV3Callback(int256 amount0Delta, int256 amount1Delta) internal {
        address pool;
        address tokenIn;
        uint256 maxOwed;
        bool phase;
        assembly ("memory-safe") {
            pool := tload(V3_POOL_TSLOT)
            tokenIn := tload(V3_TOKENIN_TSLOT)
            maxOwed := tload(V3_MAX_TSLOT)
            phase := tload(PHASE_TSLOT)
            // CLAIM — a second callback from the same swap finds no pool.
            tstore(V3_POOL_TSLOT, 0)
        }
        if (!phase || pool == address(0) || msg.sender != pool) revert DirectSwapCallbackUnarmed();
        // Exactly one delta is positive for a real swap: that is what we owe.
        uint256 owed;
        if (amount0Delta > 0) {
            owed = uint256(amount0Delta);
            if (amount1Delta > 0) revert DirectSwapInvalid();
        } else if (amount1Delta > 0) {
            owed = uint256(amount1Delta);
        }
        if (owed == 0) revert DirectSwapInvalid();
        if (owed > maxOwed) revert DirectSwapCallbackOverpull(owed, maxOwed);
        IERC20(tokenIn).safeTransfer(pool, owed);
    }

    /// @notice Exact-input swap against a V2-style pair. `data` =
    /// `abi.encode(bool zeroForOne, uint16 feeNumerator)` where the numerator
    /// is the surviving share of the input out of 1000 — the same
    /// `fee_numerator` the bot's V2 fork table quotes with (997 for Uniswap /
    /// Sushi, 998 for Pancake V2), so quote and execution agree to the wei.
    /// The output is what the constant-product formula yields for the pair's
    /// current reserves; the input is sent to the pair first, as the pair
    /// expects.
    function swapV2(address pair, address tokenIn, uint256 amount, bytes memory data) internal {
        if (amount == 0 || data.length != 64) revert DirectSwapInvalid();
        (bool zeroForOne, uint16 feeNumerator) = abi.decode(data, (bool, uint16));
        if (feeNumerator == 0 || feeNumerator > 1000) revert DirectSwapInvalid();

        (uint112 r0, uint112 r1,) = IUniV2PairMinimal(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert DirectSwapInvalid();
        uint256 inWithFee = amount * feeNumerator;
        uint256 out = (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee);
        if (out == 0) revert DirectSwapInvalid();

        IERC20(tokenIn).safeTransfer(pair, amount);
        if (zeroForOne) {
            IUniV2PairMinimal(pair).swap(0, out, address(this), "");
        } else {
            IUniV2PairMinimal(pair).swap(out, 0, address(this), "");
        }
    }
}
