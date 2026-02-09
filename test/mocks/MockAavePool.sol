// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlashLoanSimpleReceiver} from "../../src/interfaces/IAaveV3Pool.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAavePool {
    using SafeERC20 for IERC20;

    uint256 public flashFee; // flat fee amount for testing
    bool public repayReverts;

    constructor(uint256 _flashFee) {
        flashFee = _flashFee;
    }

    function setFlashFee(uint256 _fee) external {
        flashFee = _fee;
    }

    function setRepayReverts(bool _reverts) external {
        repayReverts = _reverts;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    ) external {
        // Transfer loan amount to receiver
        IERC20(asset).safeTransfer(receiverAddress, amount);

        // Callback
        bool success = IFlashLoanSimpleReceiver(receiverAddress).executeOperation(
            asset,
            amount,
            flashFee,
            receiverAddress, // initiator = receiverAddress in this mock
            params
        );
        require(success, "MockAavePool: callback failed");

        // Pull repayment
        IERC20(asset).safeTransferFrom(receiverAddress, address(this), amount + flashFee);
    }

    function repay(
        address asset,
        uint256 amount,
        uint256, /* interestRateMode */
        address /* onBehalfOf */
    ) external returns (uint256) {
        require(!repayReverts, "MockAavePool: repay reverts");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function supply(
        address asset,
        uint256 amount,
        address, /* onBehalfOf */
        uint16 /* referralCode */
    ) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return uint128(flashFee);
    }
}
