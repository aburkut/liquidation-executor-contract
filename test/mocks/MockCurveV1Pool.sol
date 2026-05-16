// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Curve StableSwap V1 pool. Implements both
/// `exchange(int128,int128,uint256,uint256)` and
/// `exchange_underlying(int128,int128,uint256,uint256)` with a single
/// deterministic rate (rate=1e18 → 1:1). The two-coin variant covers
/// the bulk of our MVP set (USDS/USDT, sUSDe/USDT, 3pool, etc).
///
/// Coin-index mapping is fixed at deploy: coins[0] and coins[1]. The
/// `useUnderlying` selector ignores wrapping (tests just use direct
/// tokens). `setRevertNext()` arms a one-shot revert to test failure
/// paths.
contract MockCurveV1Pool {
    using SafeERC20 for IERC20;

    address[] public coins;
    uint256 public rate; // 1e18 == 1:1
    bool public revertNext;

    constructor(address coin0, address coin1, uint256 _rate) {
        coins.push(coin0);
        coins.push(coin1);
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setRevertNext(bool _r) external {
        revertNext = _r;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        return _exchange(i, j, dx, min_dy);
    }

    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        return _exchange(i, j, dx, min_dy);
    }

    function _exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) internal returns (uint256 dy) {
        if (revertNext) {
            revertNext = false;
            revert("MockCurveV1Pool: forced revert");
        }
        require(i != j, "i==j");
        require(uint256(uint128(i)) < coins.length, "bad i");
        require(uint256(uint128(j)) < coins.length, "bad j");

        IERC20(coins[uint256(uint128(i))]).safeTransferFrom(msg.sender, address(this), dx);
        dy = dx * rate / 1e18;
        require(dy >= min_dy, "MockCurveV1Pool: dy < min_dy");
        IERC20(coins[uint256(uint128(j))]).safeTransfer(msg.sender, dy);
        return dy;
    }
}
