// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";

/// @notice Allowlists the 10 curated Curve StableSwap V1 pools from
/// the bot's `dex/curve_v1/top_pools_mainnet.json` registry into the
/// executor's `allowedExtSwapTargets` map. Pool addresses must match
/// the JSON 1:1 — any drift breaks routing in Phase 7d+ when the
/// picker emits Curve plans.
///
/// Usage (owner key in `PRIVATE_KEY`):
///   EXECUTOR_ADDRESS=0x5b1E... \
///     forge script script/AllowCurvePools.s.sol:AllowCurvePools \
///     --rpc-url $RPC_URL --broadcast --legacy
///
/// Each `setExtSwapTarget` is a separate tx (the function is
/// `onlyOwner`; bundling via Multicall3 would change `msg.sender`).
/// The script emits 10 sequential broadcasts under one nonce window.
contract AllowCurvePools is Script {
    function run() external {
        address executor = vm.envAddress("EXECUTOR_ADDRESS");

        // Pool list — keep in sync with
        // liquidation-bot/src/dex/curve_v1/top_pools_mainnet.json.
        address[10] memory pools = [
            0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7, // 3pool DAI/USDC/USDT
            0xDcEF968d416a41Cdac0ED8702fAC8128A64241A2, // FRAX/USDC
            0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E, // USDC/crvUSD
            0x390f3595bCa2Df7d23783dFd126427CCeb997BF4, // USDT/crvUSD
            0x34D655069F4cAc1547E4C8cA284FfFF5ad4A8db0, // TUSD/crvUSD
            0x383E6b4437b59fff47B619CBA855CA29342A8559, // PYUSD/USDC
            0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72, // USDe/USDC
            0xDC24316b9AE028F1497c275EB9192a3Ea0f67022, // stETH/ETH
            0xa1F8A6807c402E4A15ef4EBa36528A3FED24E577, // frxETH/ETH
            0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A // WETH/cbETH
        ];

        LiquidationExecutor exec = LiquidationExecutor(payable(executor));

        vm.startBroadcast();
        for (uint256 i = 0; i < pools.length; i++) {
            // Idempotent: setting an already-allowed target re-emits
            // the event but is otherwise a no-op storage write.
            exec.setExtSwapTarget(pools[i], true);
            console2.log("allowed", pools[i]);
        }
        vm.stopBroadcast();
    }
}
