// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";

/// @title V10 Deploy
/// @notice Deploys `LiquidationExecutor` V10 against canonical mainnet
/// protocol addresses. Forge auto-deploys + links the six shared
/// external libraries (`SwapValidationLib`, `CoinbasePaymentLib`,
/// `UniswapLib`, `CurveV1Lib`, `BalancerV2Lib`, `SwapLegExecutorLib`)
/// on first use.
///
/// ArbExecutor is intentionally NOT deployed here — it ships in a
/// separate run when bot-side arb integration is ready.
///
/// Usage:
///   PRIVATE_KEY=<owner> forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $ETHEREUM_RPC_URL --broadcast --legacy
///
/// Executor address + auto-deployed library addresses land in
/// `broadcast/Deploy.s.sol/1/run-latest.json`.
contract Deploy is Script {
    // ─── Canonical mainnet addresses ────────────────────────────────
    address constant OWNER = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    address constant OPERATOR = 0x1e9e18152552609175826f3ee6F8bFD639532E37;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    // ─── Additional allowedTargets (LiquidationExecutor only) ───────
    address constant BEBOP_SETTLEMENT = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;
    address constant AAVE_V2_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address constant UNI_V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// GENERIC_SEQUENCE direct-call target: the V3 SwapRouter the bot's
    /// sequence generator emits ops against (deploy plan §2.3).
    address constant UNI_V3_SWAP_ROUTER_01 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function run() external returns (address liqExecutor) {
        // V10+ liquidation allowlist seed: Bebop settlement + Aave V2
        // lending pool + Uni V4 PoolManager + V3 SwapRouter (the
        // GENERIC_SEQUENCE generator's direct-call target). Morpho is
        // constructor-pinned (not in `allowed[]`).
        address[] memory liqAllowed = new address[](4);
        liqAllowed[0] = BEBOP_SETTLEMENT;
        liqAllowed[1] = AAVE_V2_POOL;
        liqAllowed[2] = UNI_V4_POOL_MANAGER;
        liqAllowed[3] = UNI_V3_SWAP_ROUTER_01;

        vm.startBroadcast();

        liqExecutor = address(
            new LiquidationExecutor(
                OWNER,
                OPERATOR,
                WETH,
                AAVE_V3_POOL,
                BALANCER_VAULT,
                MORPHO_BLUE,
                PARASWAP_AUGUSTUS,
                UNI_V2_ROUTER,
                UNI_V3_ROUTER,
                liqAllowed
            )
        );

        vm.stopBroadcast();

        // Post-deploy read-back assertions (deploy plan §1.2): the
        // constructor takes 9 same-type `address` params, each only
        // != 0 checked — a positional swap deploys a mis-wired,
        // non-reverting contract. Verify every role landed where
        // intended before trusting the deployment.
        LiquidationExecutor ex = LiquidationExecutor(payable(liqExecutor));
        require(ex.owner() == OWNER, "readback: owner");
        require(ex.operator() == OPERATOR, "readback: operator");
        require(ex.weth() == WETH, "readback: weth");
        require(ex.aavePool() == AAVE_V3_POOL, "readback: aavePool");
        require(ex.morphoBlue() == MORPHO_BLUE, "readback: morphoBlue");
        require(ex.paraswapAugustusV6() == PARASWAP_AUGUSTUS, "readback: paraswap");
        require(ex.uniV2Router() == UNI_V2_ROUTER, "readback: uniV2Router");
        require(ex.uniV3Router() == UNI_V3_ROUTER, "readback: uniV3Router");
        require(ex.allowedTargets(BEBOP_SETTLEMENT), "readback: bebop allowed");
        require(ex.allowedTargets(AAVE_V2_POOL), "readback: aaveV2 allowed");
        require(ex.allowedTargets(UNI_V4_POOL_MANAGER), "readback: v4pm allowed");
        require(ex.allowedTargets(UNI_V3_SWAP_ROUTER_01), "readback: v3router01 allowed");

        console2.log("LiquidationExecutor V10:", liqExecutor);
    }
}
