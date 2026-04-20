// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Uniswap V3 SwapRouter02 — exact-input single-hop entry point only.
/// Canonical mainnet router: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45.
/// SwapRouter02 omits the `deadline` struct field (cf. original SwapRouter);
/// the executor enforces its own plan-level deadline prior to invocation.
interface IUniV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
