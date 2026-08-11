// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Shared test double for direct-call `Op` sequences: pulls `amountIn`
/// of `tokenIn` from the caller (must be pre-approved by the executor's
/// `GenericSequenceLib` dispatch) and mints `amountOut` of `tokenOut` back
/// to the caller — a deterministic stand-in for a real swap router.
/// Originally defined inline in `ArbGenericSequence.t.sol` (Task 2);
/// extracted here so both the library-level harness test and the
/// full-executor e2e test (`ArbExecutor.t.sol`, Task 5) share one
/// definition.
contract MockRouter {
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
}
