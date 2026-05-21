// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Balancer V2 Vault — `batchSwap` only. Companion to
/// `MockBalancerV2Vault2` (which exposes the single-`swap` entry).
/// Same deterministic-rate model as the Curve RouterNG mock: every
/// step applies `rate / 1e18` to the input. Pool IDs in `BatchSwapStep`
/// are ignored — the mock walks `assets[]` strictly.
///
/// SELL (`GIVEN_IN`):
///   * `swaps[0].amount` carries the total input.
///   * Every subsequent step has `amount = 0` — Vault chains output→input.
///   * Mock pulls full input from `funds.sender` and mints final output
///     to `funds.recipient`.
///
/// BUY (`GIVEN_OUT`):
///   * `swaps[last].amount` carries the exact output target.
///   * Earlier steps have `amount = 0` — Vault back-solves required input.
///   * Mock back-solves the required `amounts[0]` from `rate^N`, pulls
///     that much, mints the exact output. Reverts if needed > `limits[0]`.
contract MockBalancerV2VaultBatch {
    using SafeERC20 for IERC20;

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    uint256 public rate; // 1e18 == 1:1 per step
    bool public revertNext;

    uint256 public batchSwapCalls;
    SwapKind public lastKind;
    address public lastSrcAsset;
    address public lastDstAsset;
    uint256 public lastConsumed;
    uint256 public lastDelivered;
    uint8 public lastStepCount;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setRevertNext(bool _r) external {
        revertNext = _r;
    }

    function batchSwap(
        SwapKind kind,
        BatchSwapStep[] memory swaps,
        address[] memory assets,
        FundManagement memory funds,
        int256[] memory limits,
        uint256 /* deadline */
    ) external payable returns (int256[] memory assetDeltas) {
        if (revertNext) {
            revertNext = false;
            revert("MockBalancerV2VaultBatch: forced revert");
        }

        require(swaps.length > 0, "MockBalancerV2VaultBatch: empty swaps");
        require(assets.length >= 2, "MockBalancerV2VaultBatch: too few assets");
        require(assets.length == limits.length, "MockBalancerV2VaultBatch: limits mismatch");

        // For simplicity the mock assumes a STRAIGHT chain — every step
        // routes from `assetInIndex = stepNo` to `assetOutIndex = stepNo + 1`.
        // Real Vault.batchSwap accepts arbitrary DAG topologies but for
        // the unit-test surface a straight chain is sufficient and
        // mirrors what the bot encoder will produce.
        for (uint256 s = 0; s < swaps.length; ++s) {
            require(swaps[s].assetInIndex == s, "MockBalancerV2VaultBatch: step in idx mismatch");
            require(swaps[s].assetOutIndex == s + 1, "MockBalancerV2VaultBatch: step out idx mismatch");
        }
        require(assets.length == swaps.length + 1, "MockBalancerV2VaultBatch: assets length mismatch");

        address srcAsset = assets[0];
        address dstAsset = assets[assets.length - 1];
        uint256 stepCount = swaps.length;

        uint256 consumed;
        uint256 delivered;
        if (kind == SwapKind.GIVEN_IN) {
            require(swaps[0].amount > 0, "MockBalancerV2VaultBatch: zero given_in head");
            consumed = swaps[0].amount;
            uint256 acc = consumed;
            for (uint256 s = 0; s < stepCount; ++s) {
                acc = (acc * rate) / 1e18;
            }
            delivered = acc;
            // Vault enforces `limits[dstIdx] >= -delta = +delivered`
            // (delta is positive on the destination side when GIVEN_IN
            // is favourable). We model the canonical "min out" form:
            // `limits[last] >= int256(min_out)` by interpreting the
            // last `int256` as the minimum acceptable output.
            int256 minOut = limits[assets.length - 1];
            require(minOut >= 0, "MockBalancerV2VaultBatch: minOut neg");
            require(delivered >= uint256(minOut), "MockBalancerV2VaultBatch: delivered < limit");
        } else {
            // GIVEN_OUT: last step's `amount` is the target output.
            uint256 lastAmount = swaps[stepCount - 1].amount;
            require(lastAmount > 0, "MockBalancerV2VaultBatch: zero given_out tail");
            delivered = lastAmount;
            // Reverse-apply the rate: required input = delivered / rate^N (ceil).
            // For the mock we use simple division — fractional cases
            // are exercised separately.
            uint256 acc = delivered;
            for (uint256 s = 0; s < stepCount; ++s) {
                // Ceil-divide so the resulting input would actually
                // produce `>= delivered` in a real Vault call.
                acc = (acc * 1e18 + rate - 1) / rate;
            }
            consumed = acc;
            // Vault enforces `limits[srcIdx] >= -consumed` i.e. consumed <= -limit[0].
            // We model it as `consumed <= uint256(-limits[0])`.
            int256 maxIn = -limits[0];
            require(maxIn >= 0, "MockBalancerV2VaultBatch: limits[0] non-negative");
            require(consumed <= uint256(maxIn), "MockBalancerV2VaultBatch: consumed > limit");
        }

        IERC20(srcAsset).safeTransferFrom(funds.sender, address(this), consumed);
        IERC20(dstAsset).safeTransfer(funds.recipient, delivered);

        batchSwapCalls += 1;
        lastKind = kind;
        lastSrcAsset = srcAsset;
        lastDstAsset = dstAsset;
        lastConsumed = consumed;
        lastDelivered = delivered;
        lastStepCount = uint8(stepCount);

        // Return per-asset deltas matching Vault behaviour. Sign: positive
        // on the source side (we paid in), negative on the dest side
        // (Vault paid out).
        assetDeltas = new int256[](assets.length);
        assetDeltas[0] = int256(consumed);
        assetDeltas[assets.length - 1] = -int256(delivered);
        return assetDeltas;
    }
}
