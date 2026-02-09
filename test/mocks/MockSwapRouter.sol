// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";

contract MockSwapRouter {
    using SafeERC20 for IERC20;

    // Simple rate: outputAmount = inputAmount * rate / 1e18
    uint256 public rate; // in 18 decimals; 1e18 = 1:1
    address public tokenOut; // the output token to send
    bool public swapReverts;

    constructor(uint256 _rate, address _tokenOut) {
        rate = _rate;
        tokenOut = _tokenOut;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setSwapReverts(bool _reverts) external {
        swapReverts = _reverts;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(!swapReverts, "MockSwapRouter: swap reverts");

        // Pull input tokens
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        // Calculate output
        amountOut = params.amountIn * rate / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: slippage");

        // Send output tokens
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
    }

    function exactInput(ISwapRouter.ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(!swapReverts, "MockSwapRouter: swap reverts");

        // Extract tokenIn from path (first 20 bytes)
        address tokenIn;
        bytes memory path = params.path;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
        }

        // Pull input tokens
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        // Calculate output
        amountOut = params.amountIn * rate / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: slippage");

        // Send output tokens (use stored tokenOut)
        IERC20(tokenOut).safeTransfer(params.recipient, amountOut);
    }
}
