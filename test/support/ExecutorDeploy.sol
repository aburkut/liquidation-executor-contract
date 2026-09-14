// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArbExecutor} from "../../src/ArbExecutor.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";
import {ArbExecutorGenesis} from "../../src/proxy/ArbExecutorGenesis.sol";
import {LiquidationExecutorGenesis} from "../../src/proxy/LiquidationExecutorGenesis.sol";
import {ExecutorProxy} from "../../src/proxy/ExecutorProxy.sol";
import {LiquidationExecutorHarness} from "./LiquidationExecutorHarness.sol";

/// Test-only: deploy executors the way production does — implementation,
/// Genesis, proxy — behind the argument lists the old constructors took, so
/// every existing test runs through the proxy without rewriting its call site.
/// The ProxyAdmin owner is the executor owner, as on mainnet.
///
/// A test that expects an implementation-constructor revert must NOT use these
/// helpers: `vm.expectRevert` covers a single revert and lets execution
/// continue, and each helper creates three contracts, so the next create
/// reverts unexpectedly. Construct the implementation directly instead, as the
/// constructor-revert tests in `test/Executor.t.sol` do.
library ExecutorDeploy {
    function arb(
        address owner_,
        address operator_,
        address weth_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    ) internal returns (ArbExecutor) {
        ArbExecutor impl = new ArbExecutor(
            owner_,
            operator_,
            weth_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            new address[](0)
        );
        return arbProxy(address(impl), owner_, operator_, allowedTargets_);
    }

    function arbProxy(address implementation, address owner_, address operator_, address[] memory allowedTargets_)
        internal
        returns (ArbExecutor)
    {
        bytes memory init = abi.encodeCall(
            ArbExecutorGenesis.initialize, (owner_, _one(operator_), allowedTargets_, new address[](0), implementation)
        );
        return ArbExecutor(payable(address(new ExecutorProxy(address(new ArbExecutorGenesis()), owner_, init))));
    }

    function liquidation(
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
    ) internal returns (LiquidationExecutor) {
        LiquidationExecutor impl = new LiquidationExecutor(
            owner_,
            operator_,
            weth_,
            aavePool_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            new address[](0)
        );
        return LiquidationExecutor(
            payable(liquidationProxy(address(impl), owner_, operator_, balancerVault_, allowedTargets_))
        );
    }

    function liquidationHarness(
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
    ) internal returns (LiquidationExecutorHarness) {
        LiquidationExecutorHarness impl = new LiquidationExecutorHarness(
            owner_,
            operator_,
            weth_,
            aavePool_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            new address[](0)
        );
        return LiquidationExecutorHarness(
            payable(liquidationProxy(address(impl), owner_, operator_, balancerVault_, allowedTargets_))
        );
    }

    function liquidationProxy(
        address implementation,
        address owner_,
        address operator_,
        address balancerVault_,
        address[] memory allowedTargets_
    ) internal returns (address) {
        bytes memory init = abi.encodeCall(
            LiquidationExecutorGenesis.initialize,
            (owner_, _one(operator_), allowedTargets_, new address[](0), balancerVault_, address(0), implementation)
        );
        return address(new ExecutorProxy(address(new LiquidationExecutorGenesis()), owner_, init));
    }

    function _one(address a) private pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }
}
