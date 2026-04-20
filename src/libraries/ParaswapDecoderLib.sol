// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ParaswapDecoderLib
/// @notice External library housing the Paraswap Augustus V6.2 selector
/// classifier, decoders, and combined decode+validate entry point. Moving
/// these out of LiquidationExecutor keeps the executor's runtime bytecode
/// under EIP-170 (24,576 bytes). Callers use DELEGATECALL (auto-inserted by
/// the Solidity compiler for external library functions).
///
/// SAFETY: every read against a user-controlled offset is bounds-checked.
/// `cd` is ABI-encoded calldata including its 32-byte length prefix — the
/// offset base `p := cd + 36` skips the length prefix (32) and the 4-byte
/// selector.
library ParaswapDecoderLib {
    error InvalidParaswapCalldata();
    error InvalidParaswapSelector(bytes4 selector);
    error SwapRecipientInvalid(address recipient);
    error ZeroSrcOrDstToken();

    // ─── Augustus V6.2 selector constants ─────────────────────────────
    bytes4 private constant _SWAP_EXACT_AMOUNT_IN = 0xe3ead59e;
    bytes4 private constant _SWAP_EXACT_AMOUNT_OUT = 0x7f457675;
    bytes4 private constant _SWAP_EXACT_IN_UNI_V3 = 0x876a02f6;
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V3 = 0x5e94e28d;
    bytes4 private constant _SWAP_EXACT_IN_UNI_V2 = 0xe8bb3b6c;
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V2 = 0xa76f4eb6;
    bytes4 private constant _SWAP_EXACT_IN_CURVE_V1 = 0x1a01c532;
    bytes4 private constant _SWAP_EXACT_IN_CURVE_V2 = 0xe37ed256;
    bytes4 private constant _SWAP_EXACT_IN_BALANCER_V2 = 0xd85ca173;
    bytes4 private constant _SWAP_EXACT_OUT_BALANCER_V2 = 0xd6ed22e6;
    bytes4 private constant _SWAP_RFQ_BATCH_FILL = 0xda35bb0d;

    // Kind encoding (private, not exposed externally): 0..9 = accepted
    // families (lower bit 0 = ExactIn, lower bit 1 = ExactOut / reject).
    // 10 = RFQ (reject), 11 = Unsupported (reject). Using a uint8 keeps the
    // external ABI tuple-shape small.
    uint8 private constant KIND_EXACT_IN_GENERIC = 0;
    uint8 private constant KIND_EXACT_OUT_GENERIC = 1;
    uint8 private constant KIND_UNI_V2_EXACT_IN = 2;
    uint8 private constant KIND_UNI_V2_EXACT_OUT = 3;
    uint8 private constant KIND_UNI_V3_EXACT_IN = 4;
    uint8 private constant KIND_UNI_V3_EXACT_OUT = 5;
    uint8 private constant KIND_CURVE_V1_EXACT_IN = 6;
    uint8 private constant KIND_CURVE_V2_EXACT_IN = 7;
    uint8 private constant KIND_BALANCER_V2_EXACT_IN = 8;
    uint8 private constant KIND_BALANCER_V2_EXACT_OUT = 9;
    uint8 private constant KIND_RFQ = 10;
    uint8 private constant KIND_UNSUPPORTED = 11;

    /// @notice Single entry that classifies, decodes, and applies universal
    /// validation. `caller` is the expected beneficiary — pass `address(this)`
    /// from the main contract (under DELEGATECALL, that resolves to the
    /// executor). Returns `isExactIn` so the caller can choose strict (`==`)
    /// vs. lenient (`<=`) amount-in comparison.
    /// @dev Reverts on: calldata too short, unsupported/RFQ selector,
    /// malformed decoder input, bad beneficiary, zero src/dst tokens.
    function decodeAndValidate(bytes memory cd, address caller)
        external
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, bool isExactIn)
    {
        if (cd.length < 4) revert InvalidParaswapCalldata();
        bytes4 selector;
        assembly {
            selector := mload(add(cd, 32))
        }
        uint8 kind = _classify(selector);
        if (kind == KIND_UNSUPPORTED || kind == KIND_RFQ) revert InvalidParaswapSelector(selector);

        isExactIn = kind == KIND_EXACT_IN_GENERIC || kind == KIND_UNI_V2_EXACT_IN || kind == KIND_UNI_V3_EXACT_IN
            || kind == KIND_CURVE_V1_EXACT_IN || kind == KIND_CURVE_V2_EXACT_IN || kind == KIND_BALANCER_V2_EXACT_IN;

        address beneficiary;
        if (kind <= KIND_EXACT_OUT_GENERIC) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeGeneric(cd);
        } else if (kind <= KIND_UNI_V3_EXACT_OUT) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeTailUniV2V3(cd);
        } else if (kind == KIND_CURVE_V1_EXACT_IN) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeInlineCurveV1(cd);
        } else if (kind == KIND_CURVE_V2_EXACT_IN) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeInlineCurveV2(cd);
        } else {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeBalancerV2(cd);
        }

        if (beneficiary != caller && beneficiary != address(0)) revert SwapRecipientInvalid(beneficiary);
        if (srcToken == address(0) || dstToken == address(0)) revert ZeroSrcOrDstToken();
    }

    // ─── Private decoders ─────────────────────────────────────────────

    function _classify(bytes4 s) private pure returns (uint8) {
        if (s == _SWAP_EXACT_AMOUNT_IN) return KIND_EXACT_IN_GENERIC;
        if (s == _SWAP_EXACT_AMOUNT_OUT) return KIND_EXACT_OUT_GENERIC;
        if (s == _SWAP_EXACT_IN_UNI_V3) return KIND_UNI_V3_EXACT_IN;
        if (s == _SWAP_EXACT_OUT_UNI_V3) return KIND_UNI_V3_EXACT_OUT;
        if (s == _SWAP_EXACT_IN_UNI_V2) return KIND_UNI_V2_EXACT_IN;
        if (s == _SWAP_EXACT_OUT_UNI_V2) return KIND_UNI_V2_EXACT_OUT;
        if (s == _SWAP_EXACT_IN_CURVE_V1) return KIND_CURVE_V1_EXACT_IN;
        if (s == _SWAP_EXACT_IN_CURVE_V2) return KIND_CURVE_V2_EXACT_IN;
        if (s == _SWAP_EXACT_IN_BALANCER_V2) return KIND_BALANCER_V2_EXACT_IN;
        if (s == _SWAP_EXACT_OUT_BALANCER_V2) return KIND_BALANCER_V2_EXACT_OUT;
        if (s == _SWAP_RFQ_BATCH_FILL) return KIND_RFQ;
        return KIND_UNSUPPORTED;
    }

    function _decodeGeneric(bytes memory cd)
        private
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        if (cd.length < 260) {
            revert InvalidParaswapCalldata();
        }
        assembly {
            let p := add(cd, 36)
            srcToken := and(mload(add(p, 32)), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(p, 64)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(p, 96))
            minAmountOut := mload(add(p, 128))
            beneficiary := and(mload(add(p, 224)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _decodeTailUniV2V3(bytes memory cd)
        private
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        if (cd.length < 356) {
            revert InvalidParaswapCalldata();
        }
        uint256 structOffset;
        assembly {
            structOffset := mload(add(cd, 36))
        }
        if (structOffset % 32 != 0 || structOffset < 96 || 4 + structOffset + 256 > cd.length) {
            revert InvalidParaswapCalldata();
        }
        assembly {
            let s := add(add(cd, 36), structOffset)
            srcToken := and(mload(s), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(s, 32)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(s, 64))
            minAmountOut := mload(add(s, 96))
            beneficiary := and(mload(add(s, 192)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _decodeInlineCurveV1(bytes memory cd)
        private
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        if (cd.length < 292) {
            revert InvalidParaswapCalldata();
        }
        assembly {
            let p := add(cd, 36)
            srcToken := and(mload(add(p, 64)), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(p, 96)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(p, 128))
            minAmountOut := mload(add(p, 160))
            beneficiary := and(mload(add(p, 256)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _decodeInlineCurveV2(bytes memory cd)
        private
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        if (cd.length < 356) {
            revert InvalidParaswapCalldata();
        }
        assembly {
            let p := add(cd, 36)
            srcToken := and(mload(add(p, 128)), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(p, 160)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(p, 192))
            minAmountOut := mload(add(p, 224))
            beneficiary := and(mload(add(p, 320)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _decodeBalancerV2(bytes memory cd)
        private
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        uint256 L = cd.length;
        if (L < 296) revert InvalidParaswapCalldata();

        uint256 dataOff;
        assembly {
            let mask := 0xffffffffffffffffffffffffffffffffffffffff
            let p := add(cd, 36)
            fromAmount := mload(p)
            minAmountOut := mload(add(p, 32))
            beneficiary := and(mload(add(p, 128)), mask)
            dataOff := mload(add(p, 224))
        }
        if (dataOff + 36 > L) revert InvalidParaswapCalldata();

        uint256 dataLen;
        assembly {
            let p := add(cd, 36)
            dataLen := mload(add(p, dataOff))
        }
        if (dataLen + dataOff + 36 > L || dataLen < 4) revert InvalidParaswapCalldata();

        uint256 vSel;
        assembly {
            let p := add(cd, 36)
            let d := add(p, add(dataOff, 32))
            vSel := shr(224, mload(d))
        }

        if (vSel == 0x52bbbe29) {
            if (dataLen < 356) revert InvalidParaswapCalldata();
            assembly {
                let mask := 0xffffffffffffffffffffffffffffffffffffffff
                let p := add(cd, 36)
                let d := add(p, add(dataOff, 32))
                srcToken := and(mload(add(d, 292)), mask)
                dstToken := and(mload(add(d, 324)), mask)
            }
        } else if (vSel == 0x945bcec9) {
            if (dataLen < 100) revert InvalidParaswapCalldata();
            uint256 assetsOff;
            uint256 kind;
            assembly {
                let p := add(cd, 36)
                let d := add(p, add(dataOff, 32))
                kind := mload(add(d, 4))
                assetsOff := mload(add(d, 68))
            }
            if (assetsOff + 36 > dataLen) revert InvalidParaswapCalldata();

            uint256 cnt;
            assembly {
                let p := add(cd, 36)
                let d := add(p, add(dataOff, 32))
                cnt := mload(add(d, add(4, assetsOff)))
            }
            if (cnt == 0 || cnt > type(uint256).max / 32 || 4 + assetsOff + cnt * 32 + 32 > dataLen) {
                revert InvalidParaswapCalldata();
            }

            assembly {
                let mask := 0xffffffffffffffffffffffffffffffffffffffff
                let p := add(cd, 36)
                let d := add(p, add(dataOff, 32))
                let first := and(mload(add(d, add(4, add(assetsOff, 32)))), mask)
                let last := and(mload(add(d, add(4, add(assetsOff, mul(cnt, 32))))), mask)
                switch eq(kind, 1)
                case 1 {
                    srcToken := last
                    dstToken := first
                }
                default {
                    srcToken := first
                    dstToken := last
                }
            }
        } else {
            revert InvalidParaswapCalldata();
        }
    }
}
