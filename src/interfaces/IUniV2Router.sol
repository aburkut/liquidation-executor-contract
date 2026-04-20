// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Uniswap V2 Router02 — exact-input path swap entry point only.
/// Canonical mainnet router: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D.
interface IUniV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
