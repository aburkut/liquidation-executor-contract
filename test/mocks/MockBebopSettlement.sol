// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Bebop settlement contract for testing multi-output swaps.
/// Pulls input token from caller, sends configured output tokens back.
contract MockBebopSettlement {
    using SafeERC20 for IERC20;

    address public inputToken;
    uint256 public inputAmount;
    address public outputToken1;
    uint256 public outputAmount1;
    address public outputToken2;
    uint256 public outputAmount2;
    bool public shouldRevert;

    function configure(
        address _inputToken,
        uint256 _inputAmount,
        address _outputToken1,
        uint256 _outputAmount1,
        address _outputToken2,
        uint256 _outputAmount2
    ) external {
        inputToken = _inputToken;
        inputAmount = _inputAmount;
        outputToken1 = _outputToken1;
        outputAmount1 = _outputAmount1;
        outputToken2 = _outputToken2;
        outputAmount2 = _outputAmount2;
    }

    function setReverts(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    fallback() external {
        require(!shouldRevert, "MockBebop: reverts");

        if (inputToken != address(0) && inputAmount > 0) {
            IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        }

        if (outputToken1 != address(0) && outputAmount1 > 0) {
            IERC20(outputToken1).safeTransfer(msg.sender, outputAmount1);
        }
        if (outputToken2 != address(0) && outputAmount2 > 0) {
            IERC20(outputToken2).safeTransfer(msg.sender, outputAmount2);
        }
    }

    receive() external payable {}
}
