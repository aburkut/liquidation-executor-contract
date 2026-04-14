// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockParaswapAugustus {
    using SafeERC20 for IERC20;

    uint256 public rate; // 1e18 = 1:1
    bool public swapReverts;
    uint256 public partialFillPct; // 0 = use full amountIn, else = consume (amountIn * pct / 100)

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setSwapReverts(bool _reverts) external {
        swapReverts = _reverts;
    }

    /// @dev Set partial fill: consume only (amountIn * pct / 100) of declared input. 0 = full fill.
    function setPartialFillPct(uint256 pct) external {
        partialFillPct = pct;
    }

    // Optimized UniV3 selectors — see ParaswapSelectorKind in LiquidationExecutor.
    bytes4 private constant _SWAP_EXACT_IN_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,uint256),uint256,bytes)"
        )
    );
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,uint256),uint256,bytes)"
        )
    );

    /// @dev Decodes both the generic GenericData layout and the optimized UniswapV3
    /// struct layout. Generic places src/dst/amount after a 32-byte `executor` head
    /// word; optimized inlines the struct directly. Discriminating by selector keeps
    /// the mock representative of the real Augustus dispatch behavior.
    fallback() external payable {
        require(!swapReverts, "MockParaswapAugustus: swap reverts");
        require(msg.data.length >= 132, "MockParaswapAugustus: bad calldata");

        bytes4 selector;
        assembly {
            selector := calldataload(0)
        }

        address srcToken;
        address dstToken;
        uint256 amountIn;
        if (selector == _SWAP_EXACT_IN_UNI_V3 || selector == _SWAP_EXACT_OUT_UNI_V3) {
            // Optimized: struct inlined right after selector, no executor head word.
            assembly {
                srcToken := calldataload(4) // data.srcToken
                dstToken := calldataload(36) // data.destToken
                amountIn := calldataload(68) // data.fromAmount
            }
        } else {
            // Generic: skip executor head word.
            assembly {
                srcToken := calldataload(36) // GenericData.srcToken
                dstToken := calldataload(68) // GenericData.destToken
                amountIn := calldataload(100) // GenericData.fromAmount
            }
        }

        uint256 actualIn = partialFillPct > 0 ? amountIn * partialFillPct / 100 : amountIn;
        IERC20(srcToken).safeTransferFrom(msg.sender, address(this), actualIn);
        uint256 amountOut = actualIn * rate / 1e18;
        IERC20(dstToken).safeTransfer(msg.sender, amountOut);
    }

    receive() external payable {}
}
