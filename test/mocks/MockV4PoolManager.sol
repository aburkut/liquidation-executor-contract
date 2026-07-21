// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IPoolManager.sol";

/// @dev Deterministic rate-based mock of Uniswap V4 PoolManager for unit
/// tests. Supports the swap+sync+settle+take surface the executor touches,
/// for SINGLE-HOP and MULTIHOP flows. Internal accounting uses a signed
/// delta map per currency so multiple `swap()` calls within one
/// `unlock()` can chain — output of hop k credits the same currency
/// that hop k+1 then consumes.
///
/// Knobs:
///   * `setRate(rate)` — swap output multiplier (1e18 = 1:1)
///   * `setRevertOnUnlock(true)` — force unlock to revert
///   * `setZeroOut(true)` — have swap return 0 output
contract MockV4PoolManager is IPoolManager {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 == 1:1
    bool public revertOnUnlock;
    bool public zeroOut;

    /// @dev Exact-in input inflation, in bps of the requested input. 10000 =
    /// honest (settle exactly the specified input). >10000 models an
    /// adversarial/buggy pool that reports a LARGER tokenInDelta than the
    /// exact-in amount, forcing the executor to settle more than it asked —
    /// used to exercise the generic-op per-op input ceiling (V4InputOverspent).
    uint256 public inputInflateBps = 10_000;

    function setInputInflateBps(uint256 bps) external {
        inputInflateBps = bps;
    }

    /// @dev Native-ETH value received across all `settle{value: ...}()`
    /// calls in this test — lets tests assert the exact wei forwarded for
    /// a native-tokenIn V4 leg (currency `address(0)` in the delta map).
    uint256 public settledValue;

    address private _syncedCurrency;
    /// @dev Signed net-delta per currency, accumulated within one unlock.
    /// Negative = caller owes us (settle deducts). Positive = we owe
    /// caller (take deducts). Cleared back to zero by settle/take.
    mapping(address => int256) private _delta;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setRevertOnUnlock(bool _r) external {
        revertOnUnlock = _r;
    }

    function setZeroOut(bool _z) external {
        zeroOut = _z;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        require(!revertOnUnlock, "MockV4PM: unlock reverts");
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256 swapDelta) {
        require(params.amountSpecified != 0, "MockV4PM: amountSpec=0");
        uint256 amountIn;
        uint256 amountOut;
        if (params.amountSpecified < 0) {
            // Exact-input (SELL): caller fixes input, output = input * rate.
            amountIn = uint256(-params.amountSpecified);
            // Adversarial over-pull: report a larger tokenInDelta than asked.
            if (inputInflateBps != 10_000) {
                amountIn = amountIn * inputInflateBps / 10_000;
            }
            amountOut = zeroOut ? 0 : amountIn * rate / 1e18;
        } else {
            // Exact-output (BUY): caller fixes output, input = output / rate.
            amountOut = zeroOut ? 0 : uint256(params.amountSpecified);
            amountIn = amountOut == 0 ? 0 : amountOut * 1e18 / rate;
        }

        int128 tokenInD = -int128(int256(amountIn));
        int128 tokenOutD = int128(int256(amountOut));

        int128 amount0;
        int128 amount1;
        if (params.zeroForOne) {
            amount0 = tokenInD;
            amount1 = tokenOutD;
        } else {
            amount0 = tokenOutD;
            amount1 = tokenInD;
        }

        swapDelta = int256((uint256(uint128(amount0)) << 128) | uint128(amount1));

        address tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
        address tokenOut = params.zeroForOne ? key.currency1 : key.currency0;
        // Accumulate signed deltas — supports multihop chaining where
        // hop k's tokenOut credit feeds hop k+1's tokenIn debit, netting
        // intermediate currencies to zero by the end of the unlock.
        _delta[tokenIn] -= int256(amountIn);
        _delta[tokenOut] += int256(amountOut);
    }

    function sync(address currency) external {
        _syncedCurrency = currency;
    }

    function settle() external payable returns (uint256 paid) {
        if (msg.value > 0) {
            // Native-ETH settlement: no `sync` precedes this (native has no
            // ERC20 balance to diff against) — currency is always
            // `address(0)` in the delta map, matching `runV4UnlockSwap`'s
            // native branch (which skips sync/approve entirely).
            address currency = address(0);
            int256 d = _delta[currency];
            require(d <= 0, "MockV4PM: nothing owed native");
            uint256 owed = uint256(-d);
            require(msg.value >= owed, "MockV4PM: unsettled native");
            _delta[currency] = 0;
            settledValue += msg.value;
            return owed;
        }
        address syncedCurrency = _syncedCurrency;
        int256 d2 = _delta[syncedCurrency];
        require(d2 <= 0, "MockV4PM: nothing owed for sync'd currency");
        uint256 owed2 = uint256(-d2);
        uint256 received = IERC20(syncedCurrency).balanceOf(address(this));
        require(received >= owed2, "MockV4PM: unsettled");
        _delta[syncedCurrency] = 0;
        _syncedCurrency = address(0);
        return owed2;
    }

    function take(address currency, address to, uint256 amount) external {
        int256 d = _delta[currency];
        require(d >= int256(amount), "MockV4PM: insufficient credit");
        _delta[currency] = d - int256(amount);
        IERC20(currency).safeTransfer(to, amount);
    }
}
