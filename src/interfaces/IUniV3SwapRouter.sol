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

    /// @dev BUY-side single-hop. Router pulls AT MOST `amountInMaximum`
    /// of `tokenIn` from msg.sender, transfers EXACTLY `amountOut` of
    /// `tokenOut` to `recipient`, and refunds any unused input. Reverts
    /// if the pool can't deliver `amountOut` within `amountInMaximum`.
    /// Returns the actual input consumed.
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    /// @dev Multihop SELL — path is ABI-encoded as
    /// `tokenIn (20 bytes) || fee0 (3 bytes) || token1 (20 bytes) ||
    ///  fee1 (3 bytes) || ... || tokenOut (20 bytes)`.
    /// Total length = 20 + 23 * (numHops); single-hop is 43 bytes,
    /// two-hop is 66 bytes, three-hop is 89 bytes, etc. Router walks
    /// the path token-by-token charging msg.sender amountIn and
    /// crediting `recipient` the final hop's output.
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /// @dev Multihop BUY — path is REVERSED relative to ExactInput:
    /// `tokenOut (20 bytes) || feeLast (3 bytes) || tokenPrev (20 bytes)
    ///  || ... || tokenIn (20 bytes)`. Router pulls AT MOST
    /// `amountInMaximum` of the LAST token (== tokenIn) and credits
    /// `recipient` exactly `amountOut` of the FIRST token (== tokenOut).
    /// Refunds any unused input.
    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
