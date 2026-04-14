// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketParams, IMorphoFlashLoanCallback} from "../../src/interfaces/IMorphoBlue.sol";

contract MockMorphoBlue {
    using SafeERC20 for IERC20;

    bool public repayReverts;
    bool public liquidationReverts;
    uint256 public liquidationCollateralReward;
    bool public liquidationCollateralRewardSet;
    uint256 public liquidationDebtAmount;
    /// @dev When true, the mock skips the safeTransferFrom pull, simulating a
    /// caller that fails to leave enough balance to satisfy repayment.
    bool public flashLoanSkipsPull;

    function setRepayReverts(bool _reverts) external {
        repayReverts = _reverts;
    }

    function setLiquidationReverts(bool _reverts) external {
        liquidationReverts = _reverts;
    }

    function setLiquidationCollateralReward(uint256 _reward) external {
        liquidationCollateralReward = _reward;
        liquidationCollateralRewardSet = true;
    }

    function setLiquidationDebtAmount(uint256 _amount) external {
        liquidationDebtAmount = _amount;
    }

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256, /* shares */
        address, /* onBehalfOf */
        bytes memory /* data */
    )
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        require(!repayReverts, "MockMorphoBlue: repay reverts");
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, 0);
    }

    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address, /* onBehalfOf */
        address receiver
    )
        external
    {
        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address, /* onBehalfOf */
        bytes memory /* data */
    )
        external
    {
        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function setFlashLoanSkipsPull(bool _skip) external {
        flashLoanSkipsPull = _skip;
    }

    /// @notice Mirrors Morpho Blue: send `assets` of `token` to caller, invoke callback,
    /// then pull repayment via safeTransferFrom. Fee = 0.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        if (!flashLoanSkipsPull) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
        }
    }

    function liquidate(
        MarketParams memory marketParams,
        address, /* borrower */
        uint256 seizedAssets,
        uint256, /* repaidShares */
        bytes memory /* data */
    )
        external
        returns (uint256, uint256)
    {
        require(!liquidationReverts, "MockMorphoBlue: liquidation reverts");
        uint256 collateral = liquidationCollateralRewardSet ? liquidationCollateralReward : seizedAssets;
        uint256 debt = liquidationDebtAmount > 0 ? liquidationDebtAmount : seizedAssets;
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), debt);
        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, collateral);
        return (collateral, debt);
    }
}
