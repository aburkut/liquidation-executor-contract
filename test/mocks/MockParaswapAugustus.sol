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

    // FixedStruct optimized selectors (struct inlined in head).
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
    // DynamicStruct selectors (struct in tail with head offset).
    bytes4 private constant _SWAP_EXACT_IN_UNI_V2 = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,uint256[]),uint256,bytes)"
        )
    );
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V2 = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,uint256[]),uint256,bytes)"
        )
    );

    /// @dev Decodes three calldata families that share the same first 7 fixed
    /// fields (srcToken, destToken, fromAmount, toAmount, quotedAmount, metadata,
    /// recipient). Discriminating by selector lets the mock follow the same dispatch
    /// path the real Augustus V6 uses:
    ///   • generic: skip 32-byte executor head word
    ///   • FixedStruct (UniV3): struct inlined right after selector
    ///   • DynamicStruct (UniV2): struct in the tail; head[0] is the offset
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
            assembly {
                srcToken := calldataload(4)
                dstToken := calldataload(36)
                amountIn := calldataload(68)
            }
        } else if (selector == _SWAP_EXACT_IN_UNI_V2 || selector == _SWAP_EXACT_OUT_UNI_V2) {
            assembly {
                let structOffset := calldataload(4)
                let s := add(4, structOffset)
                srcToken := calldataload(s)
                dstToken := calldataload(add(s, 32))
                amountIn := calldataload(add(s, 64))
            }
        } else {
            // Generic: skip executor head word.
            assembly {
                srcToken := calldataload(36)
                dstToken := calldataload(68)
                amountIn := calldataload(100)
            }
        }

        uint256 actualIn = partialFillPct > 0 ? amountIn * partialFillPct / 100 : amountIn;
        IERC20(srcToken).safeTransferFrom(msg.sender, address(this), actualIn);
        uint256 amountOut = actualIn * rate / 1e18;
        IERC20(dstToken).safeTransfer(msg.sender, amountOut);
    }

    receive() external payable {}
}
