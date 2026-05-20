// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";

contract Deploy is Script {
    function run() external returns (address executor) {
        address owner = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
        address operator = 0x1e9e18152552609175826f3ee6F8bFD639532E37;
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
        address balancer = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
        address morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        address paraswap = 0x6A000F20005980200259B80c5102003040001068;
        address uniV2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        address uniV3 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

        // V10+: Morpho moved into the constructor (was element [1] of
        // allowed[] in V9 and post-deploy `configureMorpho`).
        address[] memory allowed = new address[](3);
        allowed[0] = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;
        allowed[1] = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
        allowed[2] = 0x000000000004444c5dc75cB358380D2e3dE08A90;

        vm.startBroadcast();
        executor = address(
            new LiquidationExecutor(owner, operator, weth, aavePool, balancer, morpho, paraswap, uniV2, uniV3, allowed)
        );
        vm.stopBroadcast();
    }
}
