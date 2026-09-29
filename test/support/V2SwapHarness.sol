// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DirectSwapLib} from "../../src/libraries/DirectSwapLib.sol";
import {IUniV2PairMinimal} from "../../src/interfaces/IDirectPools.sol";

/// Runs one direct V2 swap three ways against the SAME pair state: the code in
/// `DirectSwapLib` today, and the two orderings it replaced.
///
///   swapCurrent                 DirectSwapLib.swapV2 as compiled: transfer,
///                               then reserves AND balance (#45), fee in
///                               ten-thousandths (#46).
///   swapReservesBeforeTransfer  #41 (7d5d5ec), on chain 2026-09-13..15 in
///                               library 0x1941Ab29 behind executor 0x4d3AbD5d:
///                               reserves read BEFORE the transfer, input
///                               measured after it.
///   swapPricedOnAmount          83d080b, on chain until 2026-09-12: output
///                               from `amount` and pre-transfer reserves, no
///                               measurement at all.
///
/// Both historical bodies are copied verbatim except for the fee scale, which
/// is rewritten to ten-thousandths so that ORDER is the only difference from
/// `swapCurrent`. The fee scale was its own fix (#46) and is not under test.
///
/// Each call returns the output it asked the pair for and the gas it burned
/// between entry and return (library code, the token transfer, the pair).
contract V2SwapHarness {
    using SafeERC20 for IERC20;

    error HarnessInvalid();

    function swapCurrent(address pair, address tokenIn, uint256 amount, bytes calldata data)
        external
        returns (uint256 out, uint256 gasUsed)
    {
        uint256 g = gasleft();
        out = DirectSwapLib.swapV2(pair, tokenIn, amount, data);
        gasUsed = g - gasleft();
    }

    function swapReservesBeforeTransfer(address pair, address tokenIn, uint256 amount, bytes calldata data)
        external
        returns (uint256 out, uint256 gasUsed)
    {
        uint256 g = gasleft();
        (bool zeroForOne, uint16 feeNumerator) = _params(amount, data);
        (uint256 reserveIn, uint256 reserveOut) = _reserves(pair, zeroForOne);
        IERC20(tokenIn).safeTransfer(pair, amount);
        uint256 received = IERC20(tokenIn).balanceOf(pair) - reserveIn;
        out = _amountOut(received, feeNumerator, reserveIn, reserveOut);
        _swap(pair, zeroForOne, out);
        gasUsed = g - gasleft();
    }

    function swapPricedOnAmount(address pair, address tokenIn, uint256 amount, bytes calldata data)
        external
        returns (uint256 out, uint256 gasUsed)
    {
        uint256 g = gasleft();
        (bool zeroForOne, uint16 feeNumerator) = _params(amount, data);
        (uint256 reserveIn, uint256 reserveOut) = _reserves(pair, zeroForOne);
        out = _amountOut(amount, feeNumerator, reserveIn, reserveOut);
        IERC20(tokenIn).safeTransfer(pair, amount);
        _swap(pair, zeroForOne, out);
        gasUsed = g - gasleft();
    }

    function _params(uint256 amount, bytes calldata data) private pure returns (bool zeroForOne, uint16 fee) {
        if (amount == 0 || data.length != 64) revert HarnessInvalid();
        (zeroForOne, fee) = abi.decode(data, (bool, uint16));
        if (fee == 0 || fee > 10_000) revert HarnessInvalid();
    }

    function _reserves(address pair, bool zeroForOne) private view returns (uint256 reserveIn, uint256 reserveOut) {
        (uint112 r0, uint112 r1,) = IUniV2PairMinimal(pair).getReserves();
        (reserveIn, reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert HarnessInvalid();
    }

    function _amountOut(uint256 amountIn, uint16 fee, uint256 reserveIn, uint256 reserveOut)
        private
        pure
        returns (uint256 out)
    {
        if (amountIn == 0) revert HarnessInvalid();
        uint256 inWithFee = amountIn * fee;
        out = (inWithFee * reserveOut) / (reserveIn * 10_000 + inWithFee);
        if (out == 0) revert HarnessInvalid();
    }

    function _swap(address pair, bool zeroForOne, uint256 out) private {
        if (zeroForOne) {
            IUniV2PairMinimal(pair).swap(0, out, address(this), "");
        } else {
            IUniV2PairMinimal(pair).swap(out, 0, address(this), "");
        }
    }
}
