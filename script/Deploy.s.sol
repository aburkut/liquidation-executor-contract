// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";

/// @title V10 Deploy
/// @notice Deploys the V10 family — `LiquidationExecutor` (current
/// liquidation pipeline) and `ArbExecutor` (atomic DEX arbitrage) —
/// against the canonical mainnet protocol addresses. Forge auto-
/// deploys + links the six shared external libraries
/// (`SwapValidationLib`, `CoinbasePaymentLib`, `UniswapLib`,
/// `CurveV1Lib`, `BalancerV2Lib`, `SwapLegExecutorLib`) on first use
/// and reuses the same deployment when ArbExecutor is constructed
/// later in the run, so both contracts share library bytecode.
///
/// Usage:
///   PRIVATE_KEY=<owner> forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $ETHEREUM_RPC_URL --broadcast --verify
///
/// Both executor addresses + the auto-deployed library addresses
/// land in `broadcast/Deploy.s.sol/1/run-latest.json`.
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

    function run() external returns (address liqExecutor, address arbExecutor) {
        // V10+ liquidation allowlist seed: Bebop settlement +
        // Aave V2 lending pool + Uni V4 PoolManager. Morpho is
        // constructor-pinned (not in `allowed[]`).
        address[] memory liqAllowed = new address[](3);
        liqAllowed[0] = BEBOP_SETTLEMENT;
        liqAllowed[1] = AAVE_V2_POOL;
        liqAllowed[2] = UNI_V4_POOL_MANAGER;

        // ArbExecutor seed: just Bebop. Curve / Balancer pool
        // addresses are NOT allowlisted — V10 dropped that mechanism
        // (see `allowedExtSwapTargets` removal commit). The routers,
        // Balancer Vault, Morpho, and Paraswap are constructor-seeded
        // into `allowedTargets` automatically inside ArbExecutor's
        // constructor; no additional entries are required for the
        // baseline arb routes (V2/V3/Curve/Balancer/Paraswap/Bebop).
        address[] memory arbAllowed = new address[](1);
        arbAllowed[0] = BEBOP_SETTLEMENT;

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

        arbExecutor = address(
            new ArbExecutor(
                OWNER,
                OPERATOR,
                WETH,
                BALANCER_VAULT,
                MORPHO_BLUE,
                PARASWAP_AUGUSTUS,
                UNI_V2_ROUTER,
                UNI_V3_ROUTER,
                arbAllowed
            )
        );

        vm.stopBroadcast();

        console2.log("LiquidationExecutor V10:", liqExecutor);
        console2.log("ArbExecutor V1:        ", arbExecutor);
    }
}
