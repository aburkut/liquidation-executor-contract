// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArbExecutor} from "../ArbExecutor.sol";
import {LiquidationExecutor} from "../LiquidationExecutor.sol";

/// @title Seeded executors — everything the owner would otherwise set after
/// deploy, set in the constructor.
///
/// The base constructors seed one operator and the target allowlist; extra
/// operators, the V4 hook allowlist and (for the liquidator) the Aave V2
/// lending pool were always separate owner calls. The liquidator's owner is a
/// Safe, so every such call is a multisig transaction, and until the last one
/// lands the contract exists but cannot do what the previous one could.
///
/// These wrappers add nothing to the runtime bytecode (the extra code is
/// constructor-only, which EIP-170 does not count) and write the base
/// mappings directly — they are `public` state of the base — emitting the
/// same events the setters emit, so the on-chain history reads the same. The
/// deploy scripts instantiate these; the base contracts stay as they are for
/// the tests.
contract ArbExecutorSeeded is ArbExecutor {
    constructor(
        address owner_,
        address operator_,
        address weth_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_,
        address[] memory operators_,
        address[] memory v4Hooks_
    )
        ArbExecutor(
            owner_,
            operator_,
            weth_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            allowedTargets_
        )
    {
        for (uint256 i = 0; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
            operators[operators_[i]] = true;
            emit OperatorUpdated(operators_[i], true);
        }
        for (uint256 i = 0; i < v4Hooks_.length; ++i) {
            if (v4Hooks_[i] == address(0)) revert ZeroAddress();
            allowedV4Hooks[v4Hooks_[i]] = true;
            emit V4HookAllowedUpdated(v4Hooks_[i], true);
        }
    }
}

contract LiquidationExecutorSeeded is LiquidationExecutor {
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
        address[] memory allowedTargets_,
        address[] memory operators_,
        address[] memory v4Hooks_,
        address aaveV2LendingPool_
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
    {
        for (uint256 i = 0; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
            operators[operators_[i]] = true;
            emit OperatorUpdated(operators_[i], true);
        }
        for (uint256 i = 0; i < v4Hooks_.length; ++i) {
            if (v4Hooks_[i] == address(0)) revert ZeroAddress();
            allowedV4Hooks[v4Hooks_[i]] = true;
            emit V4HookAllowedUpdated(v4Hooks_[i], true);
        }
        if (aaveV2LendingPool_ != address(0)) {
            // Same rule as `setAaveV2LendingPool`: the pool must be an
            // allowlisted target (pass it in `allowedTargets_`).
            if (!allowedTargets[aaveV2LendingPool_]) revert TargetNotAllowed();
            aaveV2LendingPool = aaveV2LendingPool_;
            emit ConfigUpdated("aaveV2Pool", address(0), aaveV2LendingPool_);
        }
    }
}
