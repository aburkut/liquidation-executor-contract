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
    )
        external
    {
        // Transfer loan amount to receiver
        IERC20(asset).safeTransfer(receiverAddress, amount);

        // Callback
        bool success = IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(
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
    )
        external
        returns (uint256)
    {
        require(!repayReverts, "MockAavePool: repay reverts");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function supply(
        address asset,
        uint256 amount,
        address, /* onBehalfOf */
        uint16 /* referralCode */
    )
        external
    {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    bool public liquidationReverts;
    uint256 public liquidationCollateralReward;
    address public aToken;

    function setLiquidationReverts(bool _reverts) external {
        liquidationReverts = _reverts;
    }

    function setLiquidationCollateralReward(uint256 _reward) external {
        liquidationCollateralReward = _reward;
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
        require(!liquidationReverts, "MockAavePool: liquidation reverts");
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);
        if (receiveAToken && aToken != address(0)) {
            IERC20(aToken).safeTransfer(msg.sender, liquidationCollateralReward);
        } else {
            IERC20(collateralAsset).safeTransfer(msg.sender, liquidationCollateralReward);
        }
    }

    // Maps collateralAsset → aToken for getReserveData verification
    mapping(address => address) public reserveATokens;

    function setReserveAToken(address asset, address _aToken) external {
        reserveATokens[asset] = _aToken;
    }

    /// @dev Implements getReserveData — returns 480 bytes with aTokenAddress at offset 256.
    /// Uses assembly fallback matching selector 0x35ea6a75 to avoid stack-too-deep.
    fallback() external {
        bytes4 sig;
        assembly { sig := calldataload(0) }
        if (sig == bytes4(0x35ea6a75)) {
            // getReserveData(address asset)
            address asset;
            assembly { asset := calldataload(4) }
            address aAddr = reserveATokens[asset];
            assembly {
                let ptr := mload(0x40)
                // Zero 480 bytes
                calldatacopy(ptr, calldatasize(), 480)
                // Set 9th slot to aAddr
                mstore(add(ptr, 256), aAddr)
                return(ptr, 480)
            }
        }
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return uint128(flashFee);
    }
}
