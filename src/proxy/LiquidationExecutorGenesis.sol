// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {LiquidationExecutorStorage} from "../storage/LiquidationExecutorStorage.sol";

/// The immutables a liquidation implementation exposes. It keeps no Balancer
/// immutable, so the vault is an `initialize` parameter.
interface ILiquidationExecutorImmutables {
    function aavePool() external view returns (address);
    function morphoBlue() external view returns (address);
    function paraswapAugustusV6() external view returns (address);
    function uniV2Router() external view returns (address);
    function uniV3Router() external view returns (address);
    function FLASH_PROVIDER_BALANCER() external view returns (uint8);
    function FLASH_PROVIDER_MORPHO() external view returns (uint8);
}

/// @title One-shot first implementation of a liquidation executor proxy
/// @notice Same shape as `ArbExecutorGenesis`: seeds the proxy's storage inside
/// its constructor — what `LiquidationExecutor`'s constructor and
/// `LiquidationExecutorSeeded` used to write — then points it at the real
/// implementation.
contract LiquidationExecutorGenesis is LiquidationExecutorStorage {
    error ZeroAddress();
    error NoOperators();
    error TargetNotAllowed();

    event OperatorUpdated(address indexed operator, bool allowed);
    event V4HookBlockedUpdated(address indexed hook, bool blocked);
    event ConfigUpdated(bytes32 indexed key, address indexed oldValue, address indexed newValue);

    /// This contract's own storage is never used.
    constructor() Ownable(address(0xdEaD)) {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address[] memory operators_,
        address[] memory allowedTargets_,
        address[] memory blockedV4Hooks_,
        address balancerVault_,
        address aaveV2LendingPool_,
        address implementation
    ) external initializer {
        if (owner_ == address(0)) revert OwnableInvalidOwner(address(0));
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (operators_.length == 0) revert NoOperators();
        _transferOwnership(owner_);

        for (uint256 i = 0; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
            operators[operators_[i]] = true;
            emit OperatorUpdated(operators_[i], true);
        }

        ILiquidationExecutorImmutables impl = ILiquidationExecutorImmutables(implementation);
        address morpho = impl.morphoBlue();
        allowedFlashProviders[impl.FLASH_PROVIDER_BALANCER()] = balancerVault_;
        allowedFlashProviders[impl.FLASH_PROVIDER_MORPHO()] = morpho;
        allowedTargets[impl.aavePool()] = true;
        allowedTargets[balancerVault_] = true;
        allowedTargets[morpho] = true;
        allowedTargets[impl.paraswapAugustusV6()] = true;
        allowedTargets[impl.uniV2Router()] = true;
        allowedTargets[impl.uniV3Router()] = true;

        for (uint256 i = 0; i < allowedTargets_.length; ++i) {
            if (allowedTargets_[i] == address(0)) revert ZeroAddress();
            allowedTargets[allowedTargets_[i]] = true;
        }
        for (uint256 i = 0; i < blockedV4Hooks_.length; ++i) {
            if (blockedV4Hooks_[i] == address(0)) revert ZeroAddress();
            blockedV4Hooks[blockedV4Hooks_[i]] = true;
            emit V4HookBlockedUpdated(blockedV4Hooks_[i], true);
        }
        if (aaveV2LendingPool_ != address(0)) {
            // Same rule as `setAaveV2LendingPool`: the pool must be an allowlisted target.
            if (!allowedTargets[aaveV2LendingPool_]) revert TargetNotAllowed();
            aaveV2LendingPool = aaveV2LendingPool_;
            emit ConfigUpdated("aaveV2Pool", address(0), aaveV2LendingPool_);
        }

        ERC1967Utils.upgradeToAndCall(implementation, "");
    }
}
