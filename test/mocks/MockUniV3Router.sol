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
}
