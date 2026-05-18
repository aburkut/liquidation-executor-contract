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

    // Per-selector hit counters — let tests assert that the lib routed
    // to the exact selector requested by `useUnderlying`. Without these
    // a useUnderlying=true test would silently pass even if the lib
    // dispatched to `exchange` (since the mock executes both identically).
    uint256 public exchangeCalls;
    uint256 public exchangeUnderlyingCalls;

    // When true, return zero bytes from the call (mimics older Curve
    // pools whose `exchange` signature was `void`). The library MUST
    // tolerate a void return — it relies on the balance delta, not the
    // declared return value.
    bool public voidReturn;

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

    function setVoidReturn(bool _v) external {
        voidReturn = _v;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        exchangeCalls += 1;
        dy = _exchange(i, j, dx, min_dy);
        // Older 3pool/USDC contracts declared `exchange` as `void`
        // (no return). Solidity-generated wrappers happily ignore the
        // declared uint256 return type when zero bytes come back. We
        // truncate the return frame by reverting cleanly via assembly
        // only when `voidReturn` is armed.
        if (voidReturn) {
            assembly {
                return(0, 0)
            }
        }
        return dy;
    }

    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        exchangeUnderlyingCalls += 1;
        dy = _exchange(i, j, dx, min_dy);
        if (voidReturn) {
            assembly {
                return(0, 0)
            }
        }
        return dy;
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
