// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";

/// Test-only: the executor's per-transaction state (plan hash, phase, V4
/// arming words) lives in TRANSIENT storage, which `vm.store`/`vm.load`
/// cannot reach. A forge test is one transaction, so transient words set
/// through these helpers are still there when the test then calls the real
/// callbacks directly — the same "prime the mid-unlock state" the tests
/// used to do with `vm.store` on persistent slots.
contract LiquidationExecutorHarness is LiquidationExecutor {
    uint256 private constant T_PLAN_HASH = 1;
    uint256 private constant T_PHASE = 2;
    uint256 private constant T_V4_PM = 11;
    uint256 private constant T_V4_TOKENIN = 12;

    constructor(
        address owner_,
        address operator_,
        address weth_,
        address aavePool_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    )
        LiquidationExecutor(
            owner_,
            operator_,
            weth_,
            aavePool_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            allowedTargets_
        )
    {}

    function tSetPlan(bytes32 planHash, bool phaseActive) external {
        assembly {
            tstore(T_PLAN_HASH, planHash)
            tstore(T_PHASE, phaseActive)
        }
    }

    /// Prime the V4 arming words as `_executeUniV4Leg` would mid-unlock.
    function tArmV4(address pm, address tokenIn, bool armed, bool phaseActive) external {
        uint256 word = uint256(uint160(tokenIn)) | (armed ? (uint256(1) << 160) : 0);
        assembly {
            tstore(T_V4_PM, pm)
            tstore(T_V4_TOKENIN, word)
            tstore(T_PHASE, phaseActive)
        }
    }

    function tV4Pm() external view returns (bytes32 w) {
        assembly {
            w := tload(T_V4_PM)
        }
    }

    function tV4TokenIn() external view returns (bytes32 w) {
        assembly {
            w := tload(T_V4_TOKENIN)
        }
    }
}
