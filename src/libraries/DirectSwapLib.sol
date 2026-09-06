// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniV3PoolMinimal, IUniV2PairMinimal} from "../interfaces/IDirectPools.sol";
import {Op} from "../types/SwapTypes.sol";

/// @title DirectSwapLib
/// @notice Swap against a Uniswap V2 pair or a V3-style pool DIRECTLY, with no
/// router in between — and, for the FLASH flags, with the pool's input paid at
/// the END of the sequence out of the cycle's own proceeds.
///
/// Traced on our landed arbs (2026-09-06): a V3 leg through SwapRouter paid
/// ~7.4k for the router frame plus ~15k for the router's own callback (which
/// does a `transferFrom` out of our allowance) — 10-20k per leg that the
/// competitor's executor, which calls pools itself, never pays. A V2 leg
/// through Router02 paid ~10k of router. Going direct also revives every V3
/// fork whose pools speak the canonical callback but whose pool addresses
/// the Uniswap router cannot derive (Sushi V3): the router computes the pool
/// from ITS factory, we just call the pool.
///
/// The competitor funds its cycles with no flash loan and no standing
/// inventory: a V3 pool pays its output first and asks for the input through
/// `uniswapV3SwapCallback`; the rest of the cycle runs INSIDE that callback
/// and the pool is paid last (V2 pairs work the same way through
/// `uniswapV2Call`). `flashV3`/`flashV2` do exactly that: the remaining ops
/// travel in the swap's `data`, the executor's callback verifies them by
/// hash, runs them through `GenericSequenceLib.continueOps`, and settles.
///
/// SECURITY — the pool is operator-supplied and NOT allowlisted:
///   * Immediate path (V3_DIRECT): we pay only while ARMED for exactly that
///     pool (transient words set around the `swap` call), only
///     `msg.sender == pool`, only once per arming (the pool word is claimed on
///     entry), only the token armed, and never more than the op's `amount`.
///   * Continuation path (V3_FLASH / V2_FLASH): the same arming, plus the
///     continuation bytes the pool hands back must hash to what we armed —
///     a pool cannot make us run anything but the plan's own remaining ops.
///     What the callback pays at the end is bounded by the op's `amount`
///     (V3: the pool's positive delta, capped; V2: exactly `amount`).
///   * V2_DIRECT: we transfer exactly `amount` to the pair and ask for the
///     output the reserve formula yields.
///   A hostile "pool" therefore gets at most the op's input, and the op then
///   fails the output-delta / repay checks every sequence is subject to — the
///   same exposure as an allowlisted router routing into a hostile pool,
///   which the containment cap already bounds.
library DirectSwapLib {
    using SafeERC20 for IERC20;

    error DirectSwapInvalid();
    error DirectSwapCallbackUnarmed();
    error DirectSwapCallbackOverpull(uint256 owed, uint256 max);
    error DirectSwapContinuationMismatch();

    /// @dev TRANSIENT words. Shared convention with the executors (which
    /// expose the callbacks and delegate here); numbers continue the
    /// executors' transient map (0 bid, 1 plan hash, 2 phase, 11/12 V4).
    ///   13  the pool/pair we are inside (claimed on callback entry)
    ///   14  the token an IMMEDIATE callback may pull
    ///   15  the most an IMMEDIATE callback may pull
    ///   16  keccak of the continuation bytes a FLASH callback must present
    ///   17  the last op's output of the continuation, read back by the frame
    ///       that started the flash swap
    uint256 private constant POOL_TSLOT = 13;
    uint256 private constant TOKENIN_TSLOT = 14;
    uint256 private constant MAX_TSLOT = 15;
    uint256 private constant CONT_HASH_TSLOT = 16;
    uint256 private constant LAST_RETURN_TSLOT = 17;
    /// @dev The executors' phase word: every callback also requires an
    /// `execute` to be in flight.
    uint256 private constant PHASE_TSLOT = 2;

    // Uniswap V3 TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO.
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    // ─── Immediate-payment direct swaps ──────────────────────────────

    /// @notice Exact-input swap against a V3-style pool, input paid inside the
    /// callback. `data` = `abi.encode(bool zeroForOne, uint160 sqrtPriceLimitX96)`;
    /// a zero limit means "no limit". Output lands on `address(this)`; the
    /// caller checks the delta.
    function swapV3(address pool, address tokenIn, uint256 amount, bytes memory data)
        internal
        returns (uint256 received)
    {
        (bool zeroForOne, uint160 limit) = _v3Params(amount, data);
        assembly ("memory-safe") {
            tstore(POOL_TSLOT, pool)
            tstore(TOKENIN_TSLOT, tokenIn)
            tstore(MAX_TSLOT, amount)
        }
        (int256 d0, int256 d1) = IUniV3PoolMinimal(pool).swap(address(this), zeroForOne, int256(amount), limit, "");
        _disarm();
        received = receivedV3(d0, d1);
    }

    /// @notice Body of an IMMEDIATE `uniswapV3SwapCallback` (empty data): pay
    /// the armed pool what it is owed, once, never more than armed.
    function payV3Callback(int256 amount0Delta, int256 amount1Delta) internal {
        address pool;
        address tokenIn;
        uint256 maxOwed;
        bool phase;
        assembly ("memory-safe") {
            pool := tload(POOL_TSLOT)
            tokenIn := tload(TOKENIN_TSLOT)
            maxOwed := tload(MAX_TSLOT)
            phase := tload(PHASE_TSLOT)
            // CLAIM — a second callback from the same swap finds no pool.
            tstore(POOL_TSLOT, 0)
        }
        if (!phase || pool == address(0) || msg.sender != pool) revert DirectSwapCallbackUnarmed();
        uint256 owed = _owed(amount0Delta, amount1Delta);
        if (owed > maxOwed) revert DirectSwapCallbackOverpull(owed, maxOwed);
        IERC20(tokenIn).safeTransfer(pool, owed);
    }

    /// @notice Exact-input swap against a V2-style pair, input sent first.
    /// `data` = `abi.encode(bool zeroForOne, uint16 feeNumerator)` where the
    /// numerator is the surviving share of the input out of 1000 — the same
    /// `fee_numerator` the bot's V2 fork table quotes with (997 Uniswap /
    /// Sushi, 998 Pancake V2), so quote and execution agree to the wei.
    function swapV2(address pair, address tokenIn, uint256 amount, bytes memory data) internal returns (uint256 out) {
        bool zeroForOne;
        (zeroForOne, out) = _v2Out(pair, amount, data);
        IERC20(tokenIn).safeTransfer(pair, amount);
        if (zeroForOne) {
            IUniV2PairMinimal(pair).swap(0, out, address(this), "");
        } else {
            IUniV2PairMinimal(pair).swap(out, 0, address(this), "");
        }
    }

    // ─── Flash swaps: the rest of the sequence runs in the callback ──

    /// @notice V3 flash swap: the pool pays its output first and asks for the
    /// input through the callback, which runs `cont` (the remaining ops,
    /// packed by `GenericSequenceLib`) and pays last. Nothing is borrowed.
    function flashV3(address pool, uint256 amount, bytes memory data, bytes memory cont) internal {
        (bool zeroForOne, uint160 limit) = _v3Params(amount, data);
        _armContinuation(pool, cont);
        IUniV3PoolMinimal(pool).swap(address(this), zeroForOne, int256(amount), limit, cont);
        _disarm();
    }

    /// @notice V2 flash swap: the pair pays the reserve-formula output first
    /// and calls `uniswapV2Call`, which runs `cont` and then sends `amount`.
    function flashV2(address pair, uint256 amount, bytes memory data, bytes memory cont) internal {
        (bool zeroForOne, uint256 out) = _v2Out(pair, amount, data);
        _armContinuation(pair, cont);
        if (zeroForOne) {
            IUniV2PairMinimal(pair).swap(0, out, address(this), cont);
        } else {
            IUniV2PairMinimal(pair).swap(out, 0, address(this), cont);
        }
        _disarm();
    }

    /// @notice Entry of a FLASH callback (non-empty data): the caller must be
    /// the armed pool, an `execute` must be in flight, and `cont` must be the
    /// bytes we armed. Claims the pool word so the same swap cannot call
    /// back twice. Returns what the callback must pay at the end.
    function beginContinuation(bytes calldata cont) internal returns (address tokenIn, uint256 maxOwed) {
        address pool;
        bytes32 expected;
        bool phase;
        assembly ("memory-safe") {
            pool := tload(POOL_TSLOT)
            expected := tload(CONT_HASH_TSLOT)
            phase := tload(PHASE_TSLOT)
            tstore(POOL_TSLOT, 0)
        }
        if (!phase || pool == address(0) || msg.sender != pool) revert DirectSwapCallbackUnarmed();
        if (keccak256(cont) != expected) revert DirectSwapContinuationMismatch();
        (,,,, tokenIn, maxOwed) = abi.decode(cont, (Op[], address, uint256, address, address, uint256));
    }

    /// @notice End of a V3 FLASH callback: pay the positive delta, capped.
    function settleV3(address pool, int256 amount0Delta, int256 amount1Delta, address tokenIn, uint256 maxOwed)
        internal
    {
        uint256 owed = _owed(amount0Delta, amount1Delta);
        if (owed > maxOwed) revert DirectSwapCallbackOverpull(owed, maxOwed);
        IERC20(tokenIn).safeTransfer(pool, owed);
    }

    /// @notice End of a V2 FLASH callback: send exactly the op's input; the
    /// pair's own K check then accepts or reverts.
    function settleV2(address pair, address tokenIn, uint256 amount) internal {
        IERC20(tokenIn).safeTransfer(pair, amount);
    }

    /// @notice The output the callback received, from V3 deltas (the negative
    /// one) — what the continuation's first op may chain off.
    function receivedV3(int256 amount0Delta, int256 amount1Delta) internal pure returns (uint256) {
        if (amount0Delta < 0) return uint256(-amount0Delta);
        if (amount1Delta < 0) return uint256(-amount1Delta);
        revert DirectSwapInvalid();
    }

    /// @dev The continuation stores its last op's output here; the frame that
    /// started the flash swap reads it back after `swap` returns.
    function setLastReturn(uint256 v) internal {
        assembly ("memory-safe") {
            tstore(LAST_RETURN_TSLOT, v)
        }
    }

    function takeLastReturn() internal returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(LAST_RETURN_TSLOT)
            tstore(LAST_RETURN_TSLOT, 0)
        }
    }

    // ─── Internals ───────────────────────────────────────────────────

    function _v3Params(uint256 amount, bytes memory data) private pure returns (bool zeroForOne, uint160 limit) {
        if (amount == 0 || amount > uint256(type(int256).max) || data.length != 64) revert DirectSwapInvalid();
        (zeroForOne, limit) = abi.decode(data, (bool, uint160));
        if (limit == 0) limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    }

    function _v2Out(address pair, uint256 amount, bytes memory data)
        private
        view
        returns (bool zeroForOne, uint256 out)
    {
        if (amount == 0 || data.length != 64) revert DirectSwapInvalid();
        uint16 feeNumerator;
        (zeroForOne, feeNumerator) = abi.decode(data, (bool, uint16));
        if (feeNumerator == 0 || feeNumerator > 1000) revert DirectSwapInvalid();

        (uint112 r0, uint112 r1,) = IUniV2PairMinimal(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert DirectSwapInvalid();
        uint256 inWithFee = amount * feeNumerator;
        out = (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee);
        if (out == 0) revert DirectSwapInvalid();
    }

    function _owed(int256 amount0Delta, int256 amount1Delta) private pure returns (uint256 owed) {
        // Exactly one delta is positive for a real swap: that is what we owe.
        if (amount0Delta > 0) {
            owed = uint256(amount0Delta);
            if (amount1Delta > 0) revert DirectSwapInvalid();
        } else if (amount1Delta > 0) {
            owed = uint256(amount1Delta);
        }
        if (owed == 0) revert DirectSwapInvalid();
    }

    function _armContinuation(address pool, bytes memory cont) private {
        bytes32 h = keccak256(cont);
        assembly ("memory-safe") {
            tstore(POOL_TSLOT, pool)
            tstore(CONT_HASH_TSLOT, h)
            tstore(TOKENIN_TSLOT, 0)
            tstore(MAX_TSLOT, 0)
        }
    }

    function _disarm() private {
        assembly ("memory-safe") {
            tstore(POOL_TSLOT, 0)
            tstore(TOKENIN_TSLOT, 0)
            tstore(MAX_TSLOT, 0)
            tstore(CONT_HASH_TSLOT, 0)
        }
    }
}
