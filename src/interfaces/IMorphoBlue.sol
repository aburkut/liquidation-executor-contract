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

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalfOf, address receiver)
        external;

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalfOf, bytes memory data)
        external;

    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256 assetsSeized, uint256 assetsRepaid);

    /// @notice Morpho Blue flashloan: lends `assets` of `token` to msg.sender, then pulls them
    /// back via safeTransferFrom after the `onMorphoFlashLoan(assets, data)` callback. Fee is zero.
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/// @notice Callback interface implemented by flashloan recipients of Morpho Blue.
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
