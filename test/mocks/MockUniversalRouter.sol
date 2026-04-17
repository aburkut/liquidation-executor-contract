// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Universal Router — deterministic rate-based swap for testing.
/// Input schema: inputs[0] = abi.encode(address tokenIn, uint256 amountIn, address tokenOut).
/// amountIn is at ABI word 1 (byte offset 32) — matching the executor's leg2 patching position.
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

        (address tokenIn, uint256 amountIn, address tokenOut) = abi.decode(inputs[0], (address, uint256, address));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = amountIn * rate / 1e18;
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
