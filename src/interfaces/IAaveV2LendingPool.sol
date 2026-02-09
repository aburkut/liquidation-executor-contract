// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAaveV2LendingPool {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
}
