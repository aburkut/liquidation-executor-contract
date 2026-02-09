// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorphoBlue {
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalfOf,
        address receiver
    ) external;

    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalfOf,
        bytes memory data
    ) external;
}
