// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Curve RouterNG (mainnet `0x16C6521D…5353`). Implements
/// `exchange(address[11], uint256[5][5], uint256, uint256, address[5], address)`
/// and chains up to 5 hops at a single deterministic rate per hop
/// (`rate=1e18` → 1:1 in / out). The mock ignores `swapParams` (i, j,
/// swap_type, pool_type, n_coins) — it only walks `path[]` to recover
/// the source / intermediate / destination tokens.
///
/// Behaviour:
///   * Pulls `amount` of `path[0]` from the caller (`msg.sender`).
///   * For every populated hop, applies the rate and conceptually
///     transforms the intermediate token. The mock simply mints the
///     output token at the rate; intermediate tokens are NOT held in
///     real pools (test simplification).
///   * Transfers the final output to `recipient`.
///
/// Test knobs:
///   * `setRate(uint256)` — single rate applied uniformly to every hop.
///   * `setRevertNext(bool)` — one-shot revert.
///   * `setVoidReturn(bool)` — return zero bytes instead of declared
///     uint256 (older Router builds had a void return). The library
///     uses balance-delta accounting so a void return must be tolerated.
///   * `lastExchangeCallCount` / `lastFirstToken` / `lastFinalToken`
///     — assertion hooks for the most recent invocation.
contract MockCurveRouterNG {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 == 1:1 per hop
    bool public revertNext;
    bool public voidReturn;

    uint256 public exchangeCalls;
    address public lastFirstToken;
    address public lastFinalToken;
    uint256 public lastAmountIn;
    uint256 public lastAmountOut;
    address public lastRecipient;

    /// @dev How many populated hops Router observed on the most recent
    /// call. `path[0]` plus every successive non-zero token slot at an
    /// even index counts as one endpoint; `hops = (filledEndpoints - 1)`.
    uint8 public lastHopCount;

    constructor(uint256 _rate) {
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

    /// @dev RouterNG `exchange`. Selector = `0x1a4d01d2`.
    function exchange(
        address[11] memory _route,
        uint256[5][5] memory, /* _swap_params */
        uint256 _amount,
        uint256 _expected,
        address[5] memory, /* _pools */
        address _receiver
    ) external returns (uint256 amountOut) {
        if (revertNext) {
            revertNext = false;
            revert("MockCurveRouterNG: forced revert");
        }

        require(_route[0] != address(0), "MockCurveRouterNG: src=0");

        // Locate the final destination token — the highest even-index
        // slot whose entry is non-zero. The path layout is
        // [tok0, pool0, tok1, pool1, …, tok5] so even indices 0,2,4,6,8,10
        // are tokens and odd indices are pools.
        address dst;
        uint8 hopCount;
        for (uint256 idx = 10; idx > 0; idx -= 2) {
            if (_route[idx] != address(0)) {
                dst = _route[idx];
                hopCount = uint8(idx / 2);
                break;
            }
        }
        require(dst != address(0), "MockCurveRouterNG: dst=0");
        require(hopCount > 0, "MockCurveRouterNG: zero hops");

        // Per-hop application of the single rate. N hops compound the
        // same multiplier — `out = in * rate^N / 1e18^N`. We compute
        // this as repeated multiplication to keep the mock auditable.
        uint256 acc = _amount;
        for (uint8 h = 0; h < hopCount; ++h) {
            acc = (acc * rate) / 1e18;
        }
        amountOut = acc;
        require(amountOut >= _expected, "MockCurveRouterNG: amountOut < expected");

        IERC20(_route[0]).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(dst).safeTransfer(_receiver, amountOut);

        exchangeCalls += 1;
        lastFirstToken = _route[0];
        lastFinalToken = dst;
        lastAmountIn = _amount;
        lastAmountOut = amountOut;
        lastRecipient = _receiver;
        lastHopCount = hopCount;

        if (voidReturn) {
            assembly {
                return(0, 0)
            }
        }
        return amountOut;
    }
}
