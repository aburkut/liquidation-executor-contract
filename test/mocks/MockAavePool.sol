// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Mock Aave V3 Pool — liquidation + utility methods only.
/// flashLoanSimple removed: Aave V3 is no longer a flashloan source.
contract MockAavePool {
    using SafeERC20 for IERC20;

    bool public repayReverts;
    bool public liquidationReverts;
    uint256 public liquidationCollateralReward;
    address public aToken;

    constructor(uint256) {}

    function setRepayReverts(bool _reverts) external {
        repayReverts = _reverts;
    }

    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address, /* user */
        uint256 debtToCover,
        bool receiveAToken
    ) external {
        require(!liquidationReverts, "MockAavePool: liquidation reverts");
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);
        if (receiveAToken && aToken != address(0)) {
            IERC20(aToken).safeTransfer(msg.sender, liquidationCollateralReward);
        } else {
            IERC20(collateralAsset).safeTransfer(msg.sender, liquidationCollateralReward);
        }
    }

    function setLiquidationReverts(bool _reverts) external {
        liquidationReverts = _reverts;
    }

    function setLiquidationCollateralReward(uint256 _reward) external {
        liquidationCollateralReward = _reward;
    }

    function setAToken(address _aToken) external {
        aToken = _aToken;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    // Maps collateralAsset -> aToken for getReserveData verification
    mapping(address => address) public reserveATokens;

    function setReserveAToken(address asset, address _aToken) external {
        reserveATokens[asset] = _aToken;
    }

    /// @dev Implements getReserveData — returns 480 bytes with aTokenAddress at offset 256.
    fallback() external {
        bytes4 sig;
        assembly {
            sig := calldataload(0)
        }
        if (sig == bytes4(0x35ea6a75)) {
            address asset;
            assembly {
                asset := calldataload(4)
            }
            address aAddr = reserveATokens[asset];
            assembly {
                let ptr := mload(0x40)
                calldatacopy(ptr, calldatasize(), 480)
                mstore(add(ptr, 256), aAddr)
                return(ptr, 480)
            }
        }
    }
}
