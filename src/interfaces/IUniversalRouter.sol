// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Uniswap Universal Router interface — execute() entry point only.
/// Commands encode swap type (V2_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, etc.),
/// inputs encode per-command parameters (recipient, amountIn, amountOutMin, path, etc.).
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
