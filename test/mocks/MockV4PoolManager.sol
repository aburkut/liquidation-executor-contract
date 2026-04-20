// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IPoolManager.sol";

/// @dev Deterministic rate-based mock of Uniswap V4 PoolManager for unit tests.
/// Supports exactly the surface the executor touches: unlock → swap → sync →
/// settle → take. Returns a BalanceDelta packed as v4-core does and holds
/// output tokens itself (funded by the test setUp). Optional knobs for
/// controlled failure scenarios:
///   * `setRate(rate)` — swap output multiplier (1e18 = 1:1)
///   * `setRevertOnUnlock(true)` — force unlock to revert
///   * `setZeroOut(true)` — have swap return 0 output (for delta-shape tests)
contract MockV4PoolManager is IPoolManager {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 == 1:1
    bool public revertOnUnlock;
    bool public zeroOut;

    address private _syncedCurrency;
    mapping(address => uint256) private _pendingCredit; // input currency owed by caller

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
        require(params.amountSpecified < 0, "MockV4PM: exact-input only");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = zeroOut ? 0 : amountIn * rate / 1e18;

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
        require(received >= owed, "MockV4PM: unsettled");
        _pendingCredit[currency] = 0;
        _syncedCurrency = address(0);
        return owed;
    }

    function take(address currency, address to, uint256 amount) external {
        IERC20(currency).safeTransfer(to, amount);
    }
}
