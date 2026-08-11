// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Bebop settlement contract for testing multi-output swaps.
/// Pulls input token from caller, sends configured output tokens back.
contract MockBebopSettlement {
    using SafeERC20 for IERC20;

    address public inputToken;
    uint256 public inputAmount;
    address public outputToken1;
    uint256 public outputAmount1;
    address public outputToken2;
    uint256 public outputAmount2;
    bool public shouldRevert;

    function configure(
        address _inputToken,
        uint256 _inputAmount,
        address _outputToken1,
        uint256 _outputAmount1,
        address _outputToken2,
        uint256 _outputAmount2
    ) external {
        inputToken = _inputToken;
        inputAmount = _inputAmount;
        outputToken1 = _outputToken1;
        outputAmount1 = _outputAmount1;
        outputToken2 = _outputToken2;
        outputAmount2 = _outputAmount2;
    }

    function setReverts(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    fallback() external {
        require(!shouldRevert, "MockBebop: reverts");

        if (inputToken != address(0) && inputAmount > 0) {
            IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        }

        if (outputToken1 != address(0) && outputAmount1 > 0) {
            IERC20(outputToken1).safeTransfer(msg.sender, outputAmount1);
        }
        if (outputToken2 != address(0) && outputAmount2 > 0) {
            IERC20(outputToken2).safeTransfer(msg.sender, outputAmount2);
        }
    }

    receive() external payable {}
}

/// @dev Bebop settlement that honours a partial fill, the way the real one
/// does: the taker amount is read from a word inside the calldata rather than
/// from the signed order, and the output is pro-rated to it.
///
/// The plain `MockBebopSettlement` above ignores calldata entirely, so it
/// cannot tell a patched order from an unpatched one — which is exactly the
/// bug this exists to catch.
contract MockBebopPartialFillSettlement {
    using SafeERC20 for IERC20;

    address public immutable sellToken;
    address public immutable buyToken;
    /// Amount the order was signed for, and what it pays at that size.
    uint256 public immutable signedSell;
    uint256 public immutable signedBuy;
    /// Word index (after the selector) carrying the taker's chosen amount.
    uint256 public immutable fillWord;

    constructor(address sell_, address buy_, uint256 signedSell_, uint256 signedBuy_, uint256 fillWord_) {
        sellToken = sell_;
        buyToken = buy_;
        signedSell = signedSell_;
        signedBuy = signedBuy_;
        fillWord = fillWord_;
    }

    fallback() external {
        uint256 at = 4 + fillWord * 32;
        require(msg.data.length >= at + 32, "MockBebop: short calldata");
        uint256 requested;
        assembly {
            requested := calldataload(at)
        }
        // Zero means "fill the whole signed order" — the real contract's
        // convention, and the value a quote arrives with.
        uint256 fill = requested == 0 ? signedSell : requested;
        require(fill <= signedSell, "MockBebop: over-fill");

        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), fill);
        IERC20(buyToken).safeTransfer(msg.sender, (signedBuy * fill) / signedSell);
    }
}
