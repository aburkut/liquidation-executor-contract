// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock dispatching the 8 Augustus V6.2 swap entrypoints accepted by
/// LiquidationExecutor (Generic In/Out, UniV2 In/Out, UniV3 In/Out, CurveV1 In,
/// CurveV2 In). Each accepted selector decodes srcToken/dstToken/fromAmount at
/// the real V6.2 calldata positions (see AugustusV6Types.sol) and performs a
/// rate-based transfer. BalancerV2 direct (0xd85ca173 / 0xd6ed22e6) and the
/// RFQ batch fill (0xda35bb0d) are not handled — those flows revert in the
/// executor before reaching the mock and so should never be invoked here.
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

    // ─── Augustus V6.2 selectors (verified against Sourcify metadata for
    // 0x6A000F20005980200259B80c5102003040001068) ────────────────────────
    bytes4 private constant _SWAP_EXACT_AMOUNT_IN = bytes4(
        keccak256(
            "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    ); // 0xe3ead59e
    bytes4 private constant _SWAP_EXACT_AMOUNT_OUT = bytes4(
        keccak256(
            "swapExactAmountOut(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    ); // 0x7f457675
    bytes4 private constant _SWAP_EXACT_IN_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0x876a02f6
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0x5e94e28d
    bytes4 private constant _SWAP_EXACT_IN_UNI_V2 = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0xe8bb3b6c
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V2 = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0xa76f4eb6
    bytes4 private constant _SWAP_EXACT_IN_CURVE_V1 = bytes4(
        keccak256(
            "swapExactAmountInOnCurveV1((uint256,uint256,address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes)"
        )
    ); // 0x1a01c532
    bytes4 private constant _SWAP_EXACT_IN_CURVE_V2 = bytes4(
        keccak256(
            "swapExactAmountInOnCurveV2((uint256,uint256,uint256,address,address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes)"
        )
    ); // 0xe37ed256
    bytes4 private constant _SWAP_EXACT_IN_BALANCER_V2 = bytes4(
        keccak256("swapExactAmountInOnBalancerV2((uint256,uint256,uint256,bytes32,uint256),uint256,bytes,bytes)")
    ); // 0xd85ca173
    bytes4 private constant _SWAP_EXACT_OUT_BALANCER_V2 = bytes4(
        keccak256("swapExactAmountOutOnBalancerV2((uint256,uint256,uint256,bytes32,uint256),uint256,bytes,bytes)")
    ); // 0xd6ed22e6

    /// @dev Dispatches every accepted Augustus V6.2 selector, decoding
    /// (srcToken, dstToken, fromAmount) at the real calldata positions for
    /// each layout family:
    ///   • Generic (executor + GenericData): srcToken = calldata[36], dstToken
    ///     = calldata[68], fromAmount = calldata[100].
    ///   • UniV2/V3 (tail-encoded UniV2Data/UniV3Data, head[0] = offset to
    ///     struct): struct[0] = srcToken, struct[32] = dstToken,
    ///     struct[64] = fromAmount.
    ///   • CurveV1 (inline 9-field CurveV1Data): srcToken = calldata[4 + 64],
    ///     dstToken = calldata[4 + 96], fromAmount = calldata[4 + 128].
    ///   • CurveV2 (inline 11-field CurveV2Data): srcToken = calldata[4 + 128],
    ///     dstToken = calldata[4 + 160], fromAmount = calldata[4 + 192].
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
        if (
            selector == _SWAP_EXACT_IN_UNI_V3 || selector == _SWAP_EXACT_OUT_UNI_V3 || selector == _SWAP_EXACT_IN_UNI_V2
                || selector == _SWAP_EXACT_OUT_UNI_V2
        ) {
            // Tail-encoded UniV2/V3: head[0] = offset to struct (relative to args base).
            assembly {
                let structOffset := calldataload(4)
                let s := add(4, structOffset)
                srcToken := calldataload(s)
                dstToken := calldataload(add(s, 32))
                amountIn := calldataload(add(s, 64))
            }
        } else if (selector == _SWAP_EXACT_IN_CURVE_V1) {
            // Inline 9-field CurveV1Data: src@[64], dst@[96], fromAmount@[128].
            assembly {
                srcToken := calldataload(add(4, 64))
                dstToken := calldataload(add(4, 96))
                amountIn := calldataload(add(4, 128))
            }
        } else if (selector == _SWAP_EXACT_IN_CURVE_V2) {
            // Inline 11-field CurveV2Data: src@[128], dst@[160], fromAmount@[192].
            assembly {
                srcToken := calldataload(add(4, 128))
                dstToken := calldataload(add(4, 160))
                amountIn := calldataload(add(4, 192))
            }
        } else if (selector == _SWAP_EXACT_IN_BALANCER_V2 || selector == _SWAP_EXACT_OUT_BALANCER_V2) {
            // BalancerV2 inline struct (5 fields): fromAmount at [0], toAmount at [32].
            // srcToken/dstToken live in `bytes data` blob. Parse via batchSwap assets array.
            assembly {
                amountIn := calldataload(4) // fromAmount = struct field 0
                // offset_to_data at args[224]
                let dataOff := calldataload(add(4, 224))
                // data content starts at 4 + dataOff + 32 (skip length word)
                let d := add(4, add(dataOff, 32))
                // For batchSwap: assetsOffset at content[68]
                let assetsOff := calldataload(add(d, 68))
                // first asset at content[4 + assetsOff + 32]
                srcToken := calldataload(add(d, add(4, add(assetsOff, 32))))
                // count at content[4 + assetsOff]
                let cnt := calldataload(add(d, add(4, assetsOff)))
                dstToken := calldataload(add(d, add(4, add(assetsOff, mul(cnt, 32)))))
            }
        } else if (selector == _SWAP_EXACT_AMOUNT_IN || selector == _SWAP_EXACT_AMOUNT_OUT) {
            // Generic: skip executor head word, then GenericData inlined.
            assembly {
                srcToken := calldataload(36)
                dstToken := calldataload(68)
                amountIn := calldataload(100)
            }
        } else {
            revert("MockParaswapAugustus: unknown selector");
        }

        uint256 actualIn = partialFillPct > 0 ? amountIn * partialFillPct / 100 : amountIn;
        IERC20(srcToken).safeTransferFrom(msg.sender, address(this), actualIn);
        uint256 amountOut = actualIn * rate / 1e18;
        IERC20(dstToken).safeTransfer(msg.sender, amountOut);
    }

    receive() external payable {}
}
