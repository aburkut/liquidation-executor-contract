// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {ArbExecutorGenesis} from "../src/proxy/ArbExecutorGenesis.sol";
import {ExecutorProxy} from "../src/proxy/ExecutorProxy.sol";
import {FluidPools} from "./FluidPools.sol";

/// @title ArbExecutor deploy
/// @notice Deploys `ArbExecutor` behind an `ExecutorProxy`, fully configured:
/// implementation → `ArbExecutorGenesis` → proxy, whose constructor runs
/// Genesis `initialize` and hands the proxy to the implementation. Nothing
/// needs to be called afterwards — no `setAllowedTarget`, no `setOperator`.
/// Every target the bot can emit an `Op` against is seeded by Genesis into
/// proxy storage, and the run asserts each one back before returning, so a
/// partially-seeded deploy fails here instead of at the first arb.
///
/// Why that matters: an admin transaction after deploy is a second window in
/// which the contract exists but cannot trade, and a second chance to forget
/// something. The whole allowlist is therefore written at deploy, by Genesis.
///
/// FLUID is the reason this list is long. Fluid has no router — every pool is
/// its own contract, so each must be allowlisted by address. The 48 pools live
/// in `script/FluidPools.sol`, shared with `Deploy.s.sol` so both executors
/// seed the same set, and every one is read back below. New Fluid pools appear
/// over time and WILL need an admin call, which is a deliberate, visible
/// follow-up rather than a silent gap.
///
/// PANCAKE is included. Its router was not in the bot's config, so an earlier
/// draft of this script left the venue out entirely — but the address is
/// derivable rather than unknowable, and leaving a venue we already quote
/// unroutable is a worse default than looking it up.
///
/// Usage (the `arb` profile compiles for runtime gas, not size — ArbExecutor
/// has 12 KB of EIP-170 headroom; see foundry.toml):
///   FOUNDRY_PROFILE=arb PRIVATE_KEY=<deployer key> forge script script/DeployArb.s.sol:DeployArb \
///     --rpc-url $ETHEREUM_RPC_URL --broadcast --legacy
/// The key only pays for the deploy; the executor and its ProxyAdmin belong to
/// the Safe `OWNER`.
///
/// Dry-run on a local fork started with `anvil --fork-url <rpc> --chain-id 31337`:
/// a fork keeps chain id 1 otherwise, and `--broadcast` overwrites the tracked
/// broadcast/<script>/1/run-latest.json records (docs/PROXY_OPERATIONS.md).
contract DeployArb is Script {
    // ─── Ownership / operation ──────────────────────────────────────
    address constant OWNER = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    /// The bot's live signer — same key that runs LiquidationExecutor.
    address constant OPERATOR = 0x1e9e18152552609175826f3ee6F8bFD639532E37;

    // ─── Implementation immutables (implementation constructor) ─────
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    // ─── Additional swap targets ────────────────────────────────────
    /// V4 swaps go through the singleton PoolManager…
    address constant UNI_V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// …and the Universal Router for the router-mediated V4 path.
    address constant V4_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    /// One allowlistable front for every Curve pool (pools are dynamic).
    address constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;
    /// Signed RFQ fills settle here.
    address constant BEBOP_SETTLEMENT = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;
    /// The V3 SwapRouter the sequence generator emits `exactInputSingle` against.
    address constant UNI_V3_SWAP_ROUTER_01 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    /// PancakeSwap V3's SwapRouter. Verified on-chain rather than recalled: it
    /// returns Pancake's own pool deployer and factory, and its bytecode
    /// carries selector 0x414bf389 — the deadline-carrying `exactInputSingle`,
    /// so the bot encodes it exactly like Uniswap V3.
    address constant PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    // ─── Everything the owner added to the LIVE executor after its deploy ───
    // Read back from the contract's own events (AllowedTargetUpdated,
    // V4HookAllowedUpdated, OperatorUpdated on 0xfC127EB8…, blocks
    // 25734276..25919383 via scripts/executor_config_events.py in the bot
    // repo) on 2026-09-06, so a redeploy needs NO admin call afterwards.
    /// V2 fork routers (bot: dex/uniswap_v2_quoter/forks.rs).
    address constant SUSHI_V2_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address constant PANCAKE_V2_ROUTER = 0xEfF92A263d31888d860bD50809A8D171709b7b1c;
    address constant SHIBASWAP_ROUTER = 0x03f7724180AA6b939894B5Ca4314783B0b36b329;
    /// 1inch Limit Order Protocol v4 (fillOrderArgs).
    address constant ONEINCH_LOP = 0x111111125421cA6dc452d289314280a0f8842A65;
    /// Hashflow router (bot: execution/hashflow.rs).
    address constant HASHFLOW_ROUTER = 0x55084eE0fEf03f14a305cd24286359A35D735151;
    /// Ekubo router (bot: dex/ekubo/encoder.rs).
    address constant EKUBO_ROUTER = 0xd26f20001a72a18C002b00e6710000d68700ce00;
    /// Swaap router (memory: project_swaap_book_measured).
    address constant SWAAP_ROUTER = 0xd315a9C38eC871068FEC378E4Ce78AF528C76293;
    address constant PROPAMM_ROUTER = 0x4DdF368080CD7946db5b459aD591c350158175e1;
    /// V4 hooks the bot is allowed to swap through (bot: dex/uniswap_v4_quoter/hook_fee.rs).
    address constant LAUNCH_HOOK = 0xAFeD2c6e0d906520ca17143a8918Ce6d54b128Cc;
    address constant LBP_MIGRATION_HOOK = 0xd53006d1e3110fD319a79AEEc4c527a0d265E080;
    /// The two extra operator keys (independent nonce streams).
    address constant OPERATOR_2 = 0x25f4c6C1e5Cc564071A1DC1768a1f1ff0BA9d5a1;
    address constant OPERATOR_3 = 0xf4Bb8842dd662c8edDed051e66376937E308B905;

    function run() external returns (address arbExecutor) {
        address[] memory fluid = FluidPools.all();

        // Non-Fluid targets. Balancer Vault, Paraswap, the V2 router and the
        // V3 router are seeded by Genesis from the implementation's
        // immutables, so they are absent here and asserted below all the same.
        address[] memory extra = new address[](14);
        extra[6] = SUSHI_V2_ROUTER;
        extra[7] = PANCAKE_V2_ROUTER;
        extra[8] = SHIBASWAP_ROUTER;
        extra[9] = ONEINCH_LOP;
        extra[10] = HASHFLOW_ROUTER;
        extra[11] = EKUBO_ROUTER;
        extra[12] = SWAAP_ROUTER;
        // Titan's PropAMM router: one address reaches all seven proprietary
        // AMMs, and the owner allowlisted it on the LIVE executors on
        // 2026-09-10 after three hours of measurement (a pAMM beats our best
        // V3 pool by a median 5 bps at the same block). A fresh deploy without
        // it silently undoes that.
        extra[13] = PROPAMM_ROUTER;
        // NOT WETH. It sat here so `FLAG_NATIVE_IN` could reach
        // `WETH9.deposit()` and close a native cycle -- and an allowlisted
        // TOKEN is an open call surface: an op naming `srcToken = address(0)`
        // and carrying `WETH.transfer(attacker, ...)` passed the target walk
        // and was never capped, because the containment snapshot is built from
        // the ops' own `srcToken` fields and so never contained WETH. The
        // inventory path in this branch is what would have given that a
        // standing balance to take. `FLAG_WETH_WRAP` now does the deposit
        // through a pinned interface, so nothing needs WETH to be a target.
        extra[0] = UNI_V4_POOL_MANAGER;
        extra[1] = V4_UNIVERSAL_ROUTER;
        extra[2] = CURVE_ROUTER_NG;
        extra[3] = BEBOP_SETTLEMENT;
        extra[4] = UNI_V3_SWAP_ROUTER_01;
        extra[5] = PANCAKE_V3_SWAP_ROUTER;

        address[] memory allowed = new address[](extra.length + FluidPools.COUNT);
        for (uint256 i = 0; i < extra.length; ++i) {
            allowed[i] = extra[i];
        }
        for (uint256 i = 0; i < FluidPools.COUNT; ++i) {
            allowed[extra.length + i] = fluid[i];
        }

        // Broadcast with the key from the environment, which is what the usage
        // note above already promised. A bare `vm.startBroadcast()` ignores
        // PRIVATE_KEY and falls back to Foundry's default sender, so the
        // documented invocation simulated fine and then refused to broadcast.
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address[] memory operators = new address[](3);
        operators[0] = OPERATOR;
        operators[1] = OPERATOR_2;
        operators[2] = OPERATOR_3;
        // V4 hooks are accepted by default now (blocklist, not allowlist);
        // nothing to seed. The two hooks that used to be allowed here are
        // kept as constants only for the read-back below.
        address[] memory hooks = new address[](0);
        ArbExecutor impl =
            new ArbExecutor(WETH, BALANCER_VAULT, MORPHO_BLUE, PARASWAP_AUGUSTUS, UNI_V2_ROUTER, UNI_V3_ROUTER);
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        ExecutorProxy proxy = new ExecutorProxy(
            address(genesis),
            OWNER,
            abi.encodeCall(ArbExecutorGenesis.initialize, (OWNER, operators, allowed, hooks, address(impl)))
        );
        vm.stopBroadcast();
        ArbExecutor exec = ArbExecutor(payable(address(proxy)));

        // ─── Readback: prove nothing is left to configure ────────────
        // Every venue the bot can route through must answer true HERE. If one
        // does not, the deploy is wrong and we find out now rather than when a
        // live arb reverts on an unallowlisted target.
        for (uint256 i = 0; i < allowed.length; ++i) {
            require(exec.allowedTargets(allowed[i]), "readback: allowed target");
        }
        require(exec.allowedTargets(PROPAMM_ROUTER), "readback: propamm router");
        // The one target that must answer FALSE. An allowlisted token is a
        // call surface, and `FLAG_WETH_WRAP` removed the only reason WETH was
        // ever on the list.
        require(!exec.allowedTargets(WETH), "readback: WETH must NOT be a target");
        require(exec.allowedTargets(BALANCER_VAULT), "readback: balancer vault");
        require(exec.allowedTargets(PARASWAP_AUGUSTUS), "readback: paraswap");
        require(exec.allowedTargets(UNI_V2_ROUTER), "readback: v2 router");
        require(exec.allowedTargets(UNI_V3_ROUTER), "readback: v3 router");
        require(exec.operators(OPERATOR), "readback: operator armed");
        require(exec.operators(OPERATOR_2) && exec.operators(OPERATOR_3), "readback: extra operators armed");
        require(
            !exec.blockedV4Hooks(LAUNCH_HOOK) && !exec.blockedV4Hooks(LBP_MIGRATION_HOOK), "readback: v4 hooks open"
        );
        require(
            address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.IMPLEMENTATION_SLOT)))) == address(impl),
            "readback: implementation"
        );
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        require(admin.owner() == OWNER, "readback: ProxyAdmin owner");
        require(exec.weth() == WETH, "readback: weth");
        require(exec.balancerVault() == BALANCER_VAULT, "readback: balancer vault immutable");
        require(exec.morphoBlue() == MORPHO_BLUE, "readback: morpho immutable");
        require(exec.paraswapAugustusV6() == PARASWAP_AUGUSTUS, "readback: paraswap immutable");
        require(exec.uniV2Router() == UNI_V2_ROUTER, "readback: v2 router immutable");
        require(exec.uniV3Router() == UNI_V3_ROUTER, "readback: v3 router immutable");
        require(exec.allowedFlashProviders(2) == BALANCER_VAULT, "readback: balancer flash provider");
        require(exec.allowedFlashProviders(3) == MORPHO_BLUE, "readback: morpho flash provider");
        require(!exec.allowedTargets(MORPHO_BLUE), "readback: Morpho must NOT be a target");
        require(exec.owner() == OWNER, "readback: owner");

        console2.log("ArbExecutor proxy (permanent address):", address(exec));
        console2.log("implementation:", address(impl));
        console2.log("ProxyAdmin (upgrade target for the Safe):", address(admin));
        console2.log("allowlisted targets:", allowed.length + 4);
        return address(exec);
    }
}
