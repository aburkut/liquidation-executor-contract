// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {LiquidationExecutorSeeded} from "../src/deploy/SeededExecutors.sol";

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
    /// GENERIC_SEQUENCE knapsack Curve slices call the RouterNG — the one
    /// allowlistable front for every Curve pool (pools are dynamic and
    /// allowedTargets is required for ALL ops).
    address constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;

    // ─── Everything the owner added to the LIVE liquidator after deploy ───
    // Read from the contract's own events on 0x7800c252… (blocks
    // 25730434..25919383 via scripts/executor_config_events.py in the bot
    // repo, 2026-09-06), so a redeploy through the seeded constructor needs
    // NO Safe transaction afterwards. The live liquidator NEVER had its Aave
    // V2 lending pool set (no ConfigUpdated("aaveV2Pool") event), so it stays
    // unset here too — pass AAVE_V2_POOL to `aaveV2LendingPool_` below only if
    // V2 liquidations are actually wanted.
    address constant SUSHI_V2_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address constant PANCAKE_V2_ROUTER = 0xEfF92A263d31888d860bD50809A8D171709b7b1c;
    address constant SHIBASWAP_ROUTER = 0x03f7724180AA6b939894B5Ca4314783B0b36b329;
    address constant ONEINCH_LOP = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant HASHFLOW_ROUTER = 0x55084eE0fEf03f14a305cd24286359A35D735151;
    address constant EKUBO_ROUTER = 0xd26f20001a72a18C002b00e6710000d68700ce00;
    address constant SWAAP_ROUTER = 0xd315a9C38eC871068FEC378E4Ce78AF528C76293;
    address constant LAUNCH_HOOK = 0xAFeD2c6e0d906520ca17143a8918Ce6d54b128Cc;
    address constant LBP_MIGRATION_HOOK = 0xd53006d1e3110fD319a79AEEc4c527a0d265E080;
    address constant OPERATOR_2 = 0x25f4c6C1e5Cc564071A1DC1768a1f1ff0BA9d5a1;
    address constant OPERATOR_3 = 0xf4Bb8842dd662c8edDed051e66376937E308B905;

    function run() external returns (address liqExecutor) {
        // V10+ liquidation allowlist seed: Bebop settlement + Aave V2
        // lending pool + Uni V4 PoolManager + the GENERIC_SEQUENCE
        // direct-call routers (V3 SwapRouter01, V2 Router02, Curve
        // RouterNG, Balancer Vault) the knapsack split generator emits
        // ops against. Morpho is constructor-pinned (not in `allowed[]`).
        address[] memory liqAllowed = new address[](14);
        liqAllowed[0] = BEBOP_SETTLEMENT;
        liqAllowed[1] = AAVE_V2_POOL;
        liqAllowed[2] = UNI_V4_POOL_MANAGER;
        liqAllowed[3] = UNI_V3_SWAP_ROUTER_01;
        liqAllowed[4] = UNI_V2_ROUTER;
        liqAllowed[5] = CURVE_ROUTER_NG;
        liqAllowed[6] = BALANCER_VAULT;
        // Added on the live contract after deploy (see above).
        liqAllowed[7] = SUSHI_V2_ROUTER;
        liqAllowed[8] = PANCAKE_V2_ROUTER;
        liqAllowed[9] = SHIBASWAP_ROUTER;
        liqAllowed[10] = ONEINCH_LOP;
        liqAllowed[11] = HASHFLOW_ROUTER;
        liqAllowed[12] = EKUBO_ROUTER;
        liqAllowed[13] = SWAAP_ROUTER;

        address[] memory operators = new address[](2);
        operators[0] = OPERATOR_2;
        operators[1] = OPERATOR_3;
        // V4 hooks are accepted by default now (blocklist, not allowlist);
        // nothing to seed. The two hooks that used to be allowed here are
        // kept as constants only for the read-back below.
        address[] memory hooks = new address[](0);

        vm.startBroadcast();

        liqExecutor = address(
            new LiquidationExecutorSeeded(
                OWNER,
                OPERATOR,
                WETH,
                AAVE_V3_POOL,
                BALANCER_VAULT,
                MORPHO_BLUE,
                PARASWAP_AUGUSTUS,
                UNI_V2_ROUTER,
                UNI_V3_ROUTER,
                liqAllowed,
                operators,
                hooks,
                // The live liquidator never set its Aave V2 lending pool
                // (no event); leave it unset. Pass AAVE_V2_POOL to enable V2.
                address(0)
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
        require(ex.operators(OPERATOR), "readback: operator");
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
        require(ex.allowedTargets(UNI_V2_ROUTER), "readback: v2router allowed");
        require(ex.allowedTargets(CURVE_ROUTER_NG), "readback: curve routerNG allowed");
        require(ex.allowedTargets(BALANCER_VAULT), "readback: bal vault allowed");
        // Seeded post-deploy state (what the live contract accumulated).
        require(ex.allowedTargets(ONEINCH_LOP), "readback: 1inch LOP allowed");
        require(ex.allowedTargets(HASHFLOW_ROUTER), "readback: hashflow allowed");
        require(ex.allowedTargets(EKUBO_ROUTER), "readback: ekubo allowed");
        require(ex.allowedTargets(SWAAP_ROUTER), "readback: swaap allowed");
        require(ex.allowedTargets(SUSHI_V2_ROUTER), "readback: sushi v2 allowed");
        require(ex.allowedTargets(PANCAKE_V2_ROUTER), "readback: pancake v2 allowed");
        require(ex.allowedTargets(SHIBASWAP_ROUTER), "readback: shibaswap allowed");
        require(ex.operators(OPERATOR_2) && ex.operators(OPERATOR_3), "readback: extra operators");
        require(!ex.blockedV4Hooks(LAUNCH_HOOK) && !ex.blockedV4Hooks(LBP_MIGRATION_HOOK), "readback: v4 hooks open");

        console2.log("LiquidationExecutor V10:", liqExecutor);
    }
}
