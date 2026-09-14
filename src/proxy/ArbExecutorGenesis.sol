// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ArbExecutorStorage} from "../storage/ArbExecutorStorage.sol";

/// The immutables an arb implementation exposes; Genesis seeds from them so the
/// allowlist cannot drift from the code it sits behind.
interface IArbExecutorImmutables {
    function balancerVault() external view returns (address);
    function morphoBlue() external view returns (address);
    function paraswapAugustusV6() external view returns (address);
    function uniV2Router() external view returns (address);
    function uniV3Router() external view returns (address);
    function FLASH_PROVIDER_BALANCER() external view returns (uint8);
    function FLASH_PROVIDER_MORPHO() external view returns (uint8);
}

/// @title One-shot first implementation of an arb executor proxy
/// @notice `ExecutorProxy` is constructed pointing here with a call to
/// `initialize`. Running inside the proxy's constructor, `initialize` seeds the
/// proxy's storage — what `ArbExecutor`'s constructor and `ArbExecutorSeeded`
/// used to write — and, as its last step, points the proxy at the real
/// implementation. The proxy never serves a call while on Genesis.
/// @dev Errors and events repeat the executor's signatures, so selectors and
/// topics match what the executor and its tests already use.
contract ArbExecutorGenesis is ArbExecutorStorage {
    error ZeroAddress();
    error NoOperators();

    event OperatorUpdated(address indexed operator, bool allowed);
    event V4HookBlockedUpdated(address indexed hook, bool blocked);

    /// This contract's own storage is never used.
    constructor() Ownable(address(0xdEaD)) {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address[] memory operators_,
        address[] memory allowedTargets_,
        address[] memory blockedV4Hooks_,
        address implementation
    ) external initializer {
        if (owner_ == address(0)) revert OwnableInvalidOwner(address(0));
        if (operators_.length == 0) revert NoOperators();
        _transferOwnership(owner_);

        for (uint256 i = 0; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
            operators[operators_[i]] = true;
            emit OperatorUpdated(operators_[i], true);
        }

        IArbExecutorImmutables impl = IArbExecutorImmutables(implementation);
        address balancerVault_ = impl.balancerVault();
        allowedFlashProviders[impl.FLASH_PROVIDER_BALANCER()] = balancerVault_;
        allowedFlashProviders[impl.FLASH_PROVIDER_MORPHO()] = impl.morphoBlue();
        // Balancer Vault doubles as a swap venue in cross-venue routing, so a
        // generic `Op` may target it. Morpho Blue is deliberately NOT a target:
        // the flash-repay path reaches it only through `allowedFlashProviders`,
        // and allowlisting it would expose its whole surface as an `Op` target.
        allowedTargets[balancerVault_] = true;
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

        ERC1967Utils.upgradeToAndCall(implementation, "");
    }
}
