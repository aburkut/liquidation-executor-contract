// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ArbExecutor} from "../src/ArbExecutor.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {ArbExecutorGenesis} from "../src/proxy/ArbExecutorGenesis.sol";
import {LiquidationExecutorGenesis} from "../src/proxy/LiquidationExecutorGenesis.sol";
import {ExecutorProxy} from "../src/proxy/ExecutorProxy.sol";
import {ExecutorDeploy} from "./support/ExecutorDeploy.sol";

contract ExecutorProxyTest is Test {
    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address weth = makeAddr("weth");
    address balancer = makeAddr("balancer");
    address morpho = makeAddr("morpho");
    address paraswap = makeAddr("paraswap");
    address v2 = makeAddr("v2");
    address v3 = makeAddr("v3");
    address aave = makeAddr("aave");
    address venue = makeAddr("venue");

    // ─── helpers ──────────────────────────────────────────────────────

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _arbImpl() internal returns (ArbExecutor) {
        return new ArbExecutor(weth, balancer, morpho, paraswap, v2, v3);
    }

    function _liqImpl() internal returns (LiquidationExecutor) {
        return new LiquidationExecutor(weth, aave, morpho, paraswap, v2, v3);
    }

    function _arb() internal returns (ArbExecutor) {
        return ExecutorDeploy.arbProxy(address(_arbImpl()), owner, operator, _one(venue));
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _adminOf(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT)))));
    }

    // ─── arb ──────────────────────────────────────────────────────────

    function test_arbGenesis_seedsTheProxyAndHandsItToTheImplementation() public {
        ArbExecutor exec = _arb();
        assertEq(exec.owner(), owner);
        assertTrue(exec.operators(operator));
        assertTrue(exec.allowedTargets(venue));
        assertTrue(exec.allowedTargets(balancer));
        assertTrue(exec.allowedTargets(paraswap));
        assertTrue(exec.allowedTargets(v2));
        assertTrue(exec.allowedTargets(v3));
        assertFalse(exec.allowedTargets(morpho), "the arb executor never allowlists Morpho as a target");
        assertEq(exec.allowedFlashProviders(2), balancer);
        assertEq(exec.allowedFlashProviders(3), morpho);
        assertEq(exec.weth(), weth, "immutables come from the implementation");
        assertEq(_adminOf(address(exec)).owner(), owner, "ProxyAdmin belongs to the executor owner");
        address impl = _implementationOf(address(exec));
        assertEq(ArbExecutor(payable(impl)).balancerVault(), balancer, "the slot holds the implementation, not Genesis");
    }

    function test_genesis_isOneShot() public {
        ArbExecutor exec = _arb();
        address impl = _implementationOf(address(exec));
        // Through the proxy there is no initializer left: it runs the implementation.
        vm.expectRevert();
        ArbExecutorGenesis(address(exec)).initialize(owner, _one(operator), new address[](0), new address[](0), impl);
        // A Genesis contract used directly is locked.
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        genesis.initialize(owner, _one(operator), new address[](0), new address[](0), impl);
    }

    function test_implementationsAreOwnerlessAndLocked() public {
        ArbExecutor arbImpl = _arbImpl();
        assertEq(arbImpl.owner(), address(0xdEaD), "an implementation's own storage is never used");
        assertFalse(arbImpl.operators(operator));
        assertFalse(arbImpl.allowedTargets(balancer));

        LiquidationExecutor liqImpl = _liqImpl();
        assertEq(liqImpl.owner(), address(0xdEaD));
        assertFalse(liqImpl.operators(operator));
        assertFalse(liqImpl.allowedTargets(aave));
    }

    function test_arbGenesis_refusesAZeroOwner() public {
        ArbExecutor impl = _arbImpl();
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        bytes memory init = abi.encodeCall(
            ArbExecutorGenesis.initialize,
            (address(0), _one(operator), new address[](0), new address[](0), address(impl))
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ExecutorProxy(address(genesis), owner, init);
    }

    function test_arbGenesis_refusesNoOperators() public {
        ArbExecutor impl = _arbImpl();
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        bytes memory init = abi.encodeCall(
            ArbExecutorGenesis.initialize, (owner, new address[](0), new address[](0), new address[](0), address(impl))
        );
        vm.expectRevert(ArbExecutorGenesis.NoOperators.selector);
        new ExecutorProxy(address(genesis), owner, init);
    }

    function test_proxy_acceptsEthWithinTheTransferStipend() public {
        ArbExecutor exec = _arb();
        vm.deal(address(this), 1 ether);
        // `transfer` forwards 2300 gas — exactly what WETH9.withdraw pays with.
        payable(address(exec)).transfer(1 ether);
        assertEq(address(exec).balance, 1 ether);
    }

    function test_onlyTheProxyAdminOwnerUpgrades() public {
        ArbExecutor exec = _arb();
        address before = _implementationOf(address(exec));
        ArbExecutor next = _arbImpl();
        ProxyAdmin admin = _adminOf(address(exec));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(exec)), address(next), "");

        // The owner calling the proxy directly reaches the implementation, which has no upgrade entry point.
        vm.prank(owner);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(exec)).upgradeToAndCall(address(next), "");

        assertEq(_implementationOf(address(exec)), before);
    }

    function test_upgradeKeepsStateAndRollsBack() public {
        ArbExecutor exec = _arb();
        address first = _implementationOf(address(exec));
        ArbExecutor next = _arbImpl();
        ProxyAdmin admin = _adminOf(address(exec));

        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(exec)), address(next), "");
        assertEq(_implementationOf(address(exec)), address(next));
        assertEq(exec.owner(), owner);
        assertTrue(exec.operators(operator));
        assertTrue(exec.allowedTargets(venue));

        address added = makeAddr("added");
        vm.prank(owner);
        exec.setAllowedTarget(added, true);

        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(exec)), first, "");
        assertEq(_implementationOf(address(exec)), first);
        assertTrue(exec.allowedTargets(added), "state written under one implementation survives the rollback");
    }

    function test_proxyAdminCannotReachTheExecutor() public {
        ArbExecutor exec = _arb();
        vm.prank(address(_adminOf(address(exec))));
        vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
        exec.owner();
    }

    // ─── liquidation ──────────────────────────────────────────────────

    function test_liqGenesis_seedsTheProxy() public {
        LiquidationExecutor exec = LiquidationExecutor(
            payable(ExecutorDeploy.liquidationProxy(address(_liqImpl()), owner, operator, balancer, _one(venue)))
        );
        assertEq(exec.owner(), owner);
        assertTrue(exec.operators(operator));
        assertTrue(exec.allowedTargets(venue));
        assertTrue(exec.allowedTargets(aave));
        assertTrue(exec.allowedTargets(balancer));
        assertTrue(exec.allowedTargets(morpho), "the liquidator allowlists Morpho, as it always did");
        assertTrue(exec.allowedTargets(paraswap));
        assertTrue(exec.allowedTargets(v2));
        assertTrue(exec.allowedTargets(v3));
        assertEq(exec.allowedFlashProviders(2), balancer);
        assertEq(exec.allowedFlashProviders(3), morpho);
        assertEq(exec.aaveV2LendingPool(), address(0));
        assertEq(exec.aavePool(), aave);
        assertEq(_adminOf(address(exec)).owner(), owner);
    }

    function test_liqGenesis_setsAnAllowlistedAaveV2Pool() public {
        address v2Pool = makeAddr("aaveV2");
        LiquidationExecutor impl = _liqImpl();
        bytes memory init = abi.encodeCall(
            LiquidationExecutorGenesis.initialize,
            (owner, _one(operator), _one(v2Pool), new address[](0), balancer, v2Pool, address(impl))
        );
        LiquidationExecutor exec = LiquidationExecutor(
            payable(address(new ExecutorProxy(address(new LiquidationExecutorGenesis()), owner, init)))
        );
        assertEq(exec.aaveV2LendingPool(), v2Pool);
    }

    function test_liqGenesis_refusesAnAaveV2PoolThatIsNotATarget() public {
        address v2Pool = makeAddr("aaveV2");
        LiquidationExecutor impl = _liqImpl();
        LiquidationExecutorGenesis genesis = new LiquidationExecutorGenesis();
        bytes memory init = abi.encodeCall(
            LiquidationExecutorGenesis.initialize,
            (owner, _one(operator), new address[](0), new address[](0), balancer, v2Pool, address(impl))
        );
        vm.expectRevert(LiquidationExecutorGenesis.TargetNotAllowed.selector);
        new ExecutorProxy(address(genesis), owner, init);
    }
}
