// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockAaveV2LendingPool {
    using SafeERC20 for IERC20;

    bool public liquidationReverts;
    uint256 public collateralReward; // how much collateral to send back
    address public aToken;

    constructor(uint256 _collateralReward) {
        collateralReward = _collateralReward;
    }

    function setLiquidationReverts(bool _reverts) external {
        liquidationReverts = _reverts;
    }

    function setCollateralReward(uint256 _reward) external {
        collateralReward = _reward;
    }

    function setAToken(address _aToken) external {
        aToken = _aToken;
    }

    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address, /* user */
        uint256 debtToCover,
        bool receiveAToken
    ) external {
        require(!liquidationReverts, "MockAaveV2: liquidation reverts");
        // Pull debt tokens from caller
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);
        // Send collateral reward back
        if (receiveAToken && aToken != address(0)) {
            IERC20(aToken).safeTransfer(msg.sender, collateralReward);
        } else {
            IERC20(collateralAsset).safeTransfer(msg.sender, collateralReward);
        }
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }
}
