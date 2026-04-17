// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Universal Router — deterministic rate-based swap for testing.
/// First input entry encodes (address tokenIn, address tokenOut, uint256 amountIn).
/// Transfers amountIn of tokenIn from msg.sender, sends amountIn * rate / 1e18 of tokenOut.
contract MockUniversalRouter {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 = 1:1
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

    function execute(bytes calldata, bytes[] calldata inputs, uint256) external payable {
        require(!swapReverts, "MockUniversalRouter: swap reverts");
        require(inputs.length > 0, "MockUniversalRouter: no inputs");

        // Decode first input: (address tokenIn, address tokenOut, uint256 amountIn)
        (address tokenIn, address tokenOut, uint256 amountIn) = abi.decode(inputs[0], (address, address, uint256));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = amountIn * rate / 1e18;
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
