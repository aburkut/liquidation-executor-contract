// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Aave V3 Pool interface — liquidation and utility methods only.
/// flashLoanSimple / FLASHLOAN_PREMIUM_TOTAL / IFlashLoanSimpleReceiver removed:
/// Aave V3 is no longer used as a flashloan source (Balancer + Morpho only).
interface IAaveV3Pool {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @dev Returns reserve data. We only use the aTokenAddress (9th field).
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );
}
