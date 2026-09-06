// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AllowanceLib
/// @notice A STANDING allowance for an owner-curated spender.
///
/// Every leg used to run `forceApprove(spender, amountIn) → swap →
/// forceApprove(spender, 0)`. An exact-in swap pulls the whole allowance, so
/// the next leg on the same (token, spender) writes the slot from zero again:
/// one SSTORE from zero (20k) plus the call, about 24.4k per leg, and once
/// more for the flash repayment. Traced on our landed arbs (2026-09-06) that
/// was 49k of a 363k two-leg cycle and 98k of a 462k three-leg one — a fifth
/// of the transaction spent re-granting what the previous transaction had
/// already granted. The competitor's executor grants once and never resets.
///
/// This helper grants `type(uint256).max` the first time a (token, spender)
/// pair is short and leaves it standing. Tokens that decrement an unlimited
/// allowance (non-OpenZeppelin style) drain it slowly and get topped up when
/// it runs short; Tether-style tokens that refuse a non-zero → non-zero
/// change are handled by `forceApprove`, which resets to zero first.
///
/// SECURITY: a standing allowance lets the spender pull this contract's
/// balance BETWEEN transactions, so it is only ever granted to spenders the
/// OWNER curated — immutable routers, pinned flash providers, allowlisted
/// settlement contracts — all of which pull from `msg.sender` inside a call
/// this contract itself makes and never on their own. An OPERATOR-supplied
/// spender (a Curve pool address in the leg) keeps the exact approve/reset
/// pattern, because the containment argument for those rests on the
/// allowance being capped at `amountIn` (see the note above
/// `LiquidationExecutor.operators`).
library AllowanceLib {
    using SafeERC20 for IERC20;

    /// @dev Make sure `spender` may pull at least `amount` of `token` from
    /// this contract; grants an unlimited standing allowance when it may not.
    function ensure(address token, address spender, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), spender) < amount) {
            IERC20(token).forceApprove(spender, type(uint256).max);
        }
    }
}
