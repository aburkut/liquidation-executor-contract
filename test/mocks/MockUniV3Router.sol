// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniV3SwapRouter} from "../../src/interfaces/IUniV3SwapRouter.sol";

/// @dev Mock Uniswap V3 SwapRouter02 — deterministic rate-based exactInputSingle.
/// Pulls `amountIn` of `tokenIn` from msg.sender, sends `amountIn * rate / 1e18`
/// of `tokenOut`. The `fee` argument is accepted but not used — slippage is
/// driven via `setRate`, pool-missing via `setPoolMissing`.
contract MockUniV3Router {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 == 1:1
    bool public swapReverts;
    bool public poolMissing;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setSwapReverts(bool _reverts) external {
        swapReverts = _reverts;
    }

    function setPoolMissing(bool _missing) external {
        poolMissing = _missing;
    }

    function exactInputSingle(IUniV3SwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(!swapReverts, "MockUniV3Router: swap reverts");
        require(!poolMissing, "MockUniV3Router: pool missing");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * rate / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockUniV3Router: insufficient output");

        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
    }

    /// @dev BUY-side: caller wants EXACT `amountOut`. Mock derives
    /// required input from the same constant `rate` used by
    /// `exactInputSingle`:
    ///   actualIn = amountOut * 1e18 / rate (round up to mirror
    ///              chain protocol-favored rounding).
    /// Reverts if `actualIn > amountInMaximum`. Pulls only `actualIn`
    /// from the caller and refunds nothing (deterministic mock — no
    /// "approve more than spent" logic, the executor-side approval
    /// reset still works because forceApprove(...,0) zeroes whatever
    /// was set).
    function exactOutputSingle(IUniV3SwapRouter.ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn)
    {
        require(!swapReverts, "MockUniV3Router: swap reverts");
        require(!poolMissing, "MockUniV3Router: pool missing");
        require(rate > 0, "MockUniV3Router: zero rate");

        // Ceiling division so the mock never silently under-pulls when
        // amountOut * 1e18 isn't divisible by rate (matches chain
        // protocol-favored rounding for exactOutput).
        uint256 num = params.amountOut * 1e18;
        amountIn = num / rate;
        if (amountIn * rate < num) {
            amountIn += 1;
        }
        require(amountIn <= params.amountInMaximum, "MockUniV3Router: amountIn exceeds max");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, params.amountOut);
    }

    /// @dev Multihop SELL — applies SWAP_RATE to the endpoints
    /// (path[0] → path[last]) so unit tests can re-use the same
    /// expected-output formula as the single-hop variant. Intermediate
    /// hops are bookkeeping-only (mirrors V2's mock multihop semantics).
    function exactInput(IUniV3SwapRouter.ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(!swapReverts, "MockUniV3Router: swap reverts");
        require(!poolMissing, "MockUniV3Router: pool missing");
        require(params.path.length >= 66, "MockUniV3Router: path too short");
        require((params.path.length - 20) % 23 == 0, "MockUniV3Router: bad path length");

        address tokenIn = address(bytes20(params.path[0:20]));
        address tokenOut = address(bytes20(params.path[params.path.length - 20:params.path.length]));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * rate / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockUniV3Router: insufficient output");
        IERC20(tokenOut).safeTransfer(params.recipient, amountOut);
    }

    /// @dev Multihop BUY — path is REVERSED on V3 (tokenOut first,
    /// tokenIn last). Same SWAP_RATE inverse as `exactOutputSingle`
    /// applied to endpoints. Pulls only `amountIn` from caller.
    function exactOutput(IUniV3SwapRouter.ExactOutputParams calldata params)
        external
        payable
        returns (uint256 amountIn)
    {
        require(!swapReverts, "MockUniV3Router: swap reverts");
        require(!poolMissing, "MockUniV3Router: pool missing");
        require(rate > 0, "MockUniV3Router: zero rate");
        require(params.path.length >= 66, "MockUniV3Router: path too short");
        require((params.path.length - 20) % 23 == 0, "MockUniV3Router: bad path length");

        // BUY path is REVERSED: first 20 bytes = tokenOut, last 20 bytes = tokenIn.
        address tokenOut = address(bytes20(params.path[0:20]));
        address tokenIn = address(bytes20(params.path[params.path.length - 20:params.path.length]));

        uint256 num = params.amountOut * 1e18;
        amountIn = num / rate;
        if (amountIn * rate < num) {
            amountIn += 1;
        }
        require(amountIn <= params.amountInMaximum, "MockUniV3Router: amountIn exceeds max");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(params.recipient, params.amountOut);
    }
}
