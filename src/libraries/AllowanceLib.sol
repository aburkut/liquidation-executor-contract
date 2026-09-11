// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AllowanceLib
/// @notice A BOUNDED allowance: the spender may pull what this leg declared,
/// and not a wei more.
///
/// Every leg used to run `forceApprove(spender, amountIn) -> swap ->
/// forceApprove(spender, 0)`. An exact-in swap pulls the whole allowance, so
/// the next leg on the same (token, spender) writes the slot from zero again:
/// one SSTORE from zero (20k) plus the call, about 24.4k per leg, and once
/// more for the flash repayment. Traced on our landed arbs (2026-09-06) that
/// was 49k of a 363k two-leg cycle and 98k of a 462k three-leg one.
///
/// This library first tried to reclaim that by granting `type(uint256).max`
/// once and leaving it standing. AUDITED 2026-09-08: six independent passes
/// each landed on the same hole, with a working exploit.
///
///   * `BalancerV2Lib.executeLeg`, `BalancerV2Lib.executeLegBatchSwap` and
///     `CurveV1Lib.executeLegMultihop` pass `leg.bebopTarget` here. That field
///     is OPERATOR-supplied and checked only for `!= 0` and `code.length > 0`;
///     no allowlist is consulted on any of the three paths. One otherwise
///     valid liquidation therefore left an UNLIMITED allowance standing to an
///     address the operator picked, which survives the transaction, survives
///     `pause()`, survives `setOperator(op, false)` and survives
///     `setAllowedTarget(t, false)` — every documented kill-switch — and is
///     drained later with a plain `transferFrom`.
///   * A standing allowance to an owner-curated but multicall-capable router
///     also defeats the containment cap in `GenericSequenceLib._finishOps`,
///     which buckets only tokens some op DECLARED as `srcToken`. A later plan
///     can route out a token it never names, with no cap at all.
///
/// Neither is reachable without the standing grant, so the grant is what goes.
/// An allowance bounded by `amount` cannot outlive what the plan declared, and
/// the containment argument in `LiquidationExecutor.operators` — an operator
/// key may SPEND under the caps and never move standing funds — holds again.
/// The 24.4k per leg is the price of that sentence being true; the rest of the
/// gas work in this branch (packed plans, immutables, transient state, direct
/// pool swaps) is untouched.
///
/// `clear` is the other half for OPERATOR-supplied spenders: a swap that pulls
/// less than it declared would otherwise leave a live remainder to an address
/// nobody curated.
library AllowanceLib {
    using SafeERC20 for IERC20;

    /// @dev Let `spender` pull at most `amount` of `token` from this contract.
    ///
    /// Exactly `amount`, never more: an allowance larger than the leg declared
    /// is spendable after the leg, and after the transaction. `forceApprove`
    /// zeroes first, so Tether-style tokens that refuse a non-zero to non-zero
    /// change are handled.
    function ensure(address token, address spender, uint256 amount) internal {
        IERC20(token).forceApprove(spender, amount);
    }

    /// @dev Take back whatever `spender` did not pull.
    ///
    /// Called after the external swap on every OPERATOR-supplied spender. A
    /// leg that consumes its whole allowance leaves nothing behind and this is
    /// a no-op write; a leg that consumes less would otherwise leave a live
    /// remainder to an address that was never curated.
    function clear(address token, address spender) internal {
        IERC20(token).forceApprove(spender, 0);
    }
}
