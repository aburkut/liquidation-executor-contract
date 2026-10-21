// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";

/// Test-only: the executor's per-transaction state (plan hash, phase, V4
/// arming words) lives in TRANSIENT storage, which `vm.store`/`vm.load`
/// cannot reach. A forge test is one transaction, so transient words set
/// through these helpers are still there when the test then calls the real
/// callbacks directly — the same "prime the mid-unlock state" the tests
/// used to do with `vm.store` on persistent slots.
///
/// The harness adds only a raw transient read and write: it is the executor
/// plus these two functions, and the executor sits close to EIP-170, so
/// every byte added here is a byte the harness goes over it with
/// (`forge build --sizes` fails the build on ANY contract over the limit).
/// The named helpers the tests call live in `HarnessTransient` below and
/// compile into the tests instead.
contract LiquidationExecutorHarness is LiquidationExecutor {
    constructor(
        address weth_,
        address aavePool_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_
    ) LiquidationExecutor(weth_, aavePool_, morpho_, paraswapAugustus_, uniV2Router_, uniV3Router_) {}

    function tStore(uint256 slot, bytes32 value) external {
        assembly {
            tstore(slot, value)
        }
    }

    function tLoad(uint256 slot) external view returns (bytes32 value) {
        assembly {
            value := tload(slot)
        }
    }
}

/// The executor's transient slots, primed and read through the harness.
/// Attach with `using HarnessTransient for LiquidationExecutorHarness;`.
library HarnessTransient {
    uint256 private constant T_PLAN_HASH = 1;
    uint256 private constant T_PHASE = 2;
    uint256 private constant T_V4_PM = 11;
    uint256 private constant T_V4_TOKENIN = 12;

    function tSetPlan(LiquidationExecutorHarness h, bytes32 planHash, bool phaseActive) internal {
        h.tStore(T_PLAN_HASH, planHash);
        h.tStore(T_PHASE, bytes32(uint256(phaseActive ? 1 : 0)));
    }

    /// Prime the V4 arming words as `_executeUniV4Leg` would mid-unlock.
    function tArmV4(LiquidationExecutorHarness h, address pm, address tokenIn, bool armed, bool phaseActive) internal {
        uint256 word = uint256(uint160(tokenIn)) | (armed ? (uint256(1) << 160) : 0);
        h.tStore(T_V4_PM, bytes32(uint256(uint160(pm))));
        h.tStore(T_V4_TOKENIN, bytes32(word));
        h.tStore(T_PHASE, bytes32(uint256(phaseActive ? 1 : 0)));
    }

    function tV4Pm(LiquidationExecutorHarness h) internal view returns (bytes32) {
        return h.tLoad(T_V4_PM);
    }

    function tV4TokenIn(LiquidationExecutorHarness h) internal view returns (bytes32) {
        return h.tLoad(T_V4_TOKENIN);
    }
}
