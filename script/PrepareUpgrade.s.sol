// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";

/// Deploy a new implementation for an existing executor proxy, built with the
/// immutables the proxy runs with today, and print the Safe transaction that
/// switches to it. The script never upgrades anything itself: the ProxyAdmin
/// belongs to the Safe.
///
///   arb:          FOUNDRY_PROFILE=arb PROXY=0x… EXECUTOR_KIND=arb PRIVATE_KEY=<deployer key> \
///                   forge script script/PrepareUpgrade.s.sol --rpc-url $RPC --broadcast
///   liquidation:  PROXY=0x… EXECUTOR_KIND=liquidation PRIVATE_KEY=<deployer key> \
///                   forge script script/PrepareUpgrade.s.sol --rpc-url $RPC --broadcast
///
/// Dry-run on a local fork first: `anvil --fork-url <rpc> --chain-id 31337`.
/// Without `--chain-id`, a fork keeps chain id 1 and `forge script --broadcast`
/// overwrites the tracked broadcast/<script>/1/run-latest.json records of the
/// real mainnet deploys.
///
/// Before the Safe signs: run the fork gate (test/fork/ProxyReplay.t.sol and
/// the liquidation fork test) against the new implementation.
contract PrepareUpgrade is Script {
    function run() external returns (address implementation) {
        address proxy = vm.envAddress("PROXY");
        bytes32 kind = keccak256(bytes(vm.envString("EXECUTOR_KIND")));
        address admin = address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));
        address current = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(admin != address(0) && current != address(0), "PROXY is not an ERC-1967 proxy");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        if (kind == keccak256("arb")) {
            ArbExecutor p = ArbExecutor(payable(proxy));
            implementation = address(
                new ArbExecutor(
                    p.weth(),
                    p.balancerVault(),
                    p.morphoBlue(),
                    p.paraswapAugustusV6(),
                    p.uniV2Router(),
                    p.uniV3Router()
                )
            );
        } else if (kind == keccak256("liquidation")) {
            LiquidationExecutor p = LiquidationExecutor(payable(proxy));
            implementation = address(
                new LiquidationExecutor(
                    p.weth(), p.aavePool(), p.morphoBlue(), p.paraswapAugustusV6(), p.uniV2Router(), p.uniV3Router()
                )
            );
        } else {
            revert("EXECUTOR_KIND must be arb or liquidation");
        }
        vm.stopBroadcast();

        console2.log("proxy:", proxy);
        console2.log("ProxyAdmin (Safe transaction target):", admin);
        console2.log("current implementation (rollback target):", current);
        console2.log("new implementation:", implementation);
        console2.log("Safe transaction calldata (value 0):");
        console2.logBytes(
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), implementation, ""))
        );
    }
}
