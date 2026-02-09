// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlashLoanRecipient} from "../../src/interfaces/IBalancerVault.sol";

contract MockBalancerVault {
    using SafeERC20 for IERC20;

    uint256 public flashFee;

    constructor(uint256 _flashFee) {
        flashFee = _flashFee;
    }

    function setFlashFee(uint256 _fee) external {
        flashFee = _fee;
    }

    function flashLoan(
        address recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external {
        uint256[] memory feeAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            feeAmounts[i] = flashFee;
            tokens[i].safeTransfer(recipient, amounts[i]);
        }

        IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, amounts, feeAmounts, userData);

        // Balancer expects funds returned by end of callback
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 expected = amounts[i] + feeAmounts[i];
            uint256 bal = tokens[i].balanceOf(address(this));
            require(bal >= expected, "MockBalancerVault: insufficient repayment");
        }
    }
}
