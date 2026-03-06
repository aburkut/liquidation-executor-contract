// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockParaswapAugustus {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 = 1:1
    bool public swapReverts;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setSwapReverts(bool _reverts) external {
        swapReverts = _reverts;
    }

    /// @dev Generic fallback that decodes (srcToken, dstToken, amountIn) from Paraswap
    /// GenericData layout: selector(4) + executor(32) + srcToken(32) + destToken(32) + fromAmount(32) ...
    fallback() external payable {
        require(!swapReverts, "MockParaswapAugustus: swap reverts");

        // Decode srcToken, dstToken, fromAmount from GenericData after selector + executor
        require(msg.data.length >= 132, "MockParaswapAugustus: bad calldata");
        address srcToken;
        address dstToken;
        uint256 amountIn;
        assembly {
            srcToken := calldataload(36) // GenericData.srcToken
            dstToken := calldataload(68) // GenericData.destToken
            amountIn := calldataload(100) // GenericData.fromAmount
        }

        IERC20(srcToken).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = amountIn * rate / 1e18;
        IERC20(dstToken).safeTransfer(msg.sender, amountOut);
    }

    receive() external payable {}
}
