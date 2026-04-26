// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IPoolManager.sol";

/// @dev Adversarial PoolManager mock for security regression tests.
/// Two attack modes (configurable independently):
///   1. tokenIn substitution — when calling back unlockCallback, swap the
///      tokenIn/tokenOut/amountIn fields with operator-supplied bytes
///      (Lead #2). Without re-assertion in unlockCallback the executor
///      will swap a different token than the leg validated.
///   2. nested unlock re-entry — during the legitimate swap call the
///      mock invokes executor.unlockCallback() a second time with
///      attacker-controlled data (Lead #3). Without depth tracking the
///      contract performs a second swap consuming arbitrary tokens.
///
/// Holds output tokens for the legitimate swap path (set by setRate).
contract MaliciousV4PoolManager is IPoolManager {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 == 1:1
    bool public substituteEnabled;
    bytes public substituteData;
    bool public reentryEnabled;
    bytes public reentryData;

    address private _syncedCurrency;
    mapping(address => uint256) private _pendingCredit;
    bool private _reenteredOnce; // guard so re-entry test fires exactly once

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setSubstituteCallback(bytes calldata data) external {
        substituteEnabled = true;
        substituteData = data;
    }

    function setReentryAttack(bytes calldata data) external {
        reentryEnabled = true;
        reentryData = data;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (substituteEnabled) {
            return IUnlockCallback(msg.sender).unlockCallback(substituteData);
        }
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256 swapDelta) {
        require(params.amountSpecified < 0, "MaliciousV4PM: exact-input only");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = amountIn * rate / 1e18;

        // Re-entry attack: ONCE per test (avoid infinite recursion), call
        // back into unlockCallback BEFORE returning the swapDelta. The
        // outer caller (executor) is mid-swap and the contract's
        // _activeV4PoolManager is still pinned to us, so msg.sender check
        // passes and an unguarded contract performs a nested swap.
        if (reentryEnabled && !_reenteredOnce) {
            _reenteredOnce = true;
            IUnlockCallback(msg.sender).unlockCallback(reentryData);
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
        _pendingCredit[tokenIn] = amountIn;
    }

    function sync(address currency) external {
        _syncedCurrency = currency;
    }

    function settle() external payable returns (uint256 paid) {
        address currency = _syncedCurrency;
        uint256 owed = _pendingCredit[currency];
        uint256 received = IERC20(currency).balanceOf(address(this));
        require(received >= owed, "MaliciousV4PM: unsettled");
        _pendingCredit[currency] = 0;
        _syncedCurrency = address(0);
        return owed;
    }

    function take(address currency, address to, uint256 amount) external {
        IERC20(currency).safeTransfer(to, amount);
    }
}
