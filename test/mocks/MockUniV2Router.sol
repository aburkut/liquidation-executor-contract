// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Uniswap V2 Router02 — deterministic rate-based single-hop swap.
/// Pulls path[0] amountIn from msg.sender, sends path[last] (amountIn * rate / 1e18).
/// Multi-hop (path.length > 2) applies rate once; intermediate hops are ignored
/// because tests exercise endpoints only. Use `setRate` / `setSwapReverts` for
/// revert/slippage scenarios.
contract MockUniV2Router {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 == 1:1
    bool public swapReverts;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setSwapReverts(bool _reverts) external {
        swapReverts = _reverts;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        require(!swapReverts, "MockUniV2Router: swap reverts");
        require(path.length >= 2, "MockUniV2Router: short path");

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = amountIn * rate / 1e18;
        require(amountOut >= amountOutMin, "MockUniV2Router: insufficient output");

        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
        return amounts;
    }

    /// @dev BUY-side mock: caller specifies EXACT amountOut and a MAX
    /// input cap. Mirrors `MockUniV3Router.exactOutputSingle` ceiling
    /// behaviour: required input = ceil(amountOut * 1e18 / rate). Pulls
    /// only that input from the caller (router refunds nothing because
    /// nothing extra was pulled). Reverts when the required input
    /// exceeds `amountInMax`.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        require(!swapReverts, "MockUniV2Router: swap reverts");
        require(path.length >= 2, "MockUniV2Router: short path");
        require(rate > 0, "MockUniV2Router: zero rate");

        // Ceiling division: input that, after rate, produces >= amountOut.
        uint256 required = (amountOut * 1e18 + rate - 1) / rate;
        require(required <= amountInMax, "MockUniV2Router: amountInMax exceeded");

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), required);
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = required;
        amounts[path.length - 1] = amountOut;
        return amounts;
    }
}
