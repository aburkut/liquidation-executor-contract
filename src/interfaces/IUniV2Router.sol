// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Uniswap V2 Router02 — exact-input + exact-output path swaps.
/// Canonical mainnet router: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D.
interface IUniV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @dev BUY-side: caller specifies EXACT `amountOut` and a MAX
    /// `amountInMax`. Router consumes only the input required to
    /// satisfy `amountOut` along `path`; whatever is unused stays on
    /// the caller's wallet.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
