// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketParams} from "../../src/interfaces/IMorphoBlue.sol";

contract MockMorphoBlue {
    using SafeERC20 for IERC20;

    bool public repayReverts;

    function setRepayReverts(bool _reverts) external {
        repayReverts = _reverts;
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
}
