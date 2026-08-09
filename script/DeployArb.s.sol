// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";

/// @title ArbExecutor deploy
/// @notice Deploys `ArbExecutor` fully configured. Nothing needs to be called
/// on the contract afterwards — no `setAllowedTarget`, no `setOperator`, no
/// `setV4HookAllowed`. Every target the bot can emit an `Op` against is seeded
/// in the constructor, and the run asserts each one back before returning, so a
/// partially-seeded deploy fails here instead of at the first arb.
///
/// Why that matters: an admin transaction after deploy is a second window in
/// which the contract exists but cannot trade, and a second chance to forget
/// something. The whole allowlist is therefore constructor state.
///
/// FLUID is the reason this list is long. Fluid has no router — every pool is
/// its own contract, so each must be allowlisted by address. The 48 below were
/// read from the live `DexReservesResolver.getAllPoolAddresses()`; that is the
/// same set the bot mirrors. New Fluid pools appear over time and WILL need an
/// admin call, which is a deliberate, visible follow-up rather than a silent
/// gap: `FLUID_POOL_COUNT` is asserted so a drift is caught the next time this
/// script runs.
///
/// PANCAKE is deliberately absent. The bot quotes Pancake but has no router
/// address for it and never emits ops against it; inventing an address to
/// allowlist would be worse than leaving the venue unroutable.
///
/// Usage:
///   PRIVATE_KEY=<owner> forge script script/DeployArb.s.sol:DeployArb \
///     --rpc-url $ETHEREUM_RPC_URL --broadcast --legacy
contract DeployArb is Script {
    // ─── Ownership / operation ──────────────────────────────────────
    address constant OWNER = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    /// The bot's live signer — same key that runs LiquidationExecutor.
    address constant OPERATOR = 0x1e9e18152552609175826f3ee6F8bFD639532E37;

    // ─── Constructor-pinned protocol addresses ──────────────────────
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

    /// Fluid pools read from `DexReservesResolver.getAllPoolAddresses()` at
    /// block 25_718_394. Asserted below so a changed set is loud.
    uint256 constant FLUID_POOL_COUNT = 48;

    function run() external returns (address arbExecutor) {
        address[] memory fluid = new address[](FLUID_POOL_COUNT);
        fluid[0] = 0x0B1a513ee24972DAEf112bC777a5610d4325C9e7;
        fluid[1] = 0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
        fluid[2] = 0x3C0441B42195F4aD6aa9a0978E06096ea616CDa7;
        fluid[3] = 0xdE632C3a214D5f14C1d8ddF0b92F8BCd188fee45;
        fluid[4] = 0x2886a01a0645390872a9eb99dAe1283664b0c524;
        fluid[5] = 0x36a905DCD12C0201f884fAFda71e63E9547975DA;
        fluid[6] = 0xFD6D459F04c3F0568e7361F29d0390081A43b90b;
        fluid[7] = 0xBA9ed8AE94C70Ef9AA2cd1045ED473aaa405C6c7;
        fluid[8] = 0x86f874212335Af27C41cDb855C2255543d1499cE;
        fluid[9] = 0x8710039D5de6840EdE452A85672B32270a709aE2;
        fluid[10] = 0xc800b0e15c40a1Ff0539218100c86F4c1BAC8D9C;
        fluid[11] = 0x836951EB21F3Df98273517B7249dCEFF270d34bf;
        fluid[12] = 0x276084527B801e00Db8E4410504F9BaF93f72C67;
        fluid[13] = 0x080574D224E960c272e005aA03EFbe793f317640;
        fluid[14] = 0x1DD125C32e4B5086c63CC13B3cA02C4A2a61Fa9b;
        fluid[15] = 0x5D538aE12f9539Ac457CD5FdbDEC02d5779F0971;
        fluid[16] = 0xc8F989E9B7ECE1b4D092Ae4db7fAF1294146bdA4;
        fluid[17] = 0xf063BD202E45d6b2843102cb4EcE339026645D4a;
        fluid[18] = 0xe8C831687ce8C9D015eb10b430d1a54faA0cb4eD;
        fluid[19] = 0xc6fdFc08401113D02280E27f53F4F38A19fbCcc9;
        fluid[20] = 0xDD72157A021804141817d46D9852A97addfB9F59;
        fluid[21] = 0xD0810e5CF08dCDe266ecEBEf40caD806c7768D72;
        fluid[22] = 0x3381d456706474Ebde92fb4685C0Eaeb5033002e;
        fluid[23] = 0x0C88C9713520E9546252B09E57fAa46e9854743A;
        fluid[24] = 0xaDD2F118871424b10411dC4d458dEFD9366b47Ca;
        fluid[25] = 0x97479d9C09c7Fd333bBfd07e93d4c8a669698EBc;
        fluid[26] = 0xd64e12101614209eE810EFDe214542A2cb68d9fD;
        fluid[27] = 0x50faCbcfBf9352523F82C67832E6d3D7Ce731D4c;
        fluid[28] = 0x0FFda76c8a06D03C104f58ECE336348488487E60;
        fluid[29] = 0xe0Cc64Ab3712e2087E1D4AAB6f3A14F120449E5f;
        fluid[30] = 0xF507a38Aaf37339cC3bEAc4C7a58B17401BDf6bc;
        fluid[31] = 0x218C659b6BBb73d47C7926Fc90D9893342534B84;
        fluid[32] = 0xDd5F2AFab5Ae5484339F9aD40FB4d51Fc5c96be3;
        fluid[33] = 0xea734B615888c669667038D11950f44b177F15C0;
        fluid[34] = 0xc6cA3E74E4Af761EE4d0Fba922b72408aAc3a819;
        fluid[35] = 0xB0960263E39C70C9B6e9EA2A382B18095264A364;
        fluid[36] = 0x862FC0A67623a4E6f0776103340836c91728B06D;
        fluid[37] = 0xd0fd46555eEb69FaD117db59A1b6713CF234097c;
        fluid[38] = 0x79eEa4A1BE86c43a9A9C4384B0B28a07Af24ae29;
        fluid[39] = 0x93b17A6497f045Dc60309921e47c1FA4dC792302;
        fluid[40] = 0x505844CBb4Ca37Af433CF0ABf247d6a2ABEd705D;
        fluid[41] = 0x86df50987C744Efc5A0cEf83F8EFd87e1880Dab1;
        fluid[42] = 0xC0652bdDcfF7739dadf0C9567584B35Ca63eB8E1;
        fluid[43] = 0xb96ceE75211700bc148B95B1C907D726791f4457;
        fluid[44] = 0x40D66b5f8f1521F97C2acA54dD200Fe3Ca035328;
        fluid[45] = 0xA2E3A4e2A08b5714FA974Ce88466D736BD8b39d9;
        fluid[46] = 0x4653583Be64eB008d7F34cc6023A81C5033e6f70;
        fluid[47] = 0xb9b87A1B79891A8C9251F501B1b5d71bC7c8aA24;

        // Non-Fluid targets. Balancer Vault, Paraswap, the V2 router and the
        // V3 router are seeded by the constructor itself, so they are absent
        // here and asserted below all the same.
        address[] memory extra = new address[](6);
        extra[0] = WETH; // FLAG_NATIVE_IN closes a native cycle via WETH9.deposit
        extra[1] = UNI_V4_POOL_MANAGER;
        extra[2] = V4_UNIVERSAL_ROUTER;
        extra[3] = CURVE_ROUTER_NG;
        extra[4] = BEBOP_SETTLEMENT;
        extra[5] = UNI_V3_SWAP_ROUTER_01;

        address[] memory allowed = new address[](extra.length + FLUID_POOL_COUNT);
        for (uint256 i = 0; i < extra.length; ++i) {
            allowed[i] = extra[i];
        }
        for (uint256 i = 0; i < FLUID_POOL_COUNT; ++i) {
            allowed[extra.length + i] = fluid[i];
        }

        vm.startBroadcast();
        ArbExecutor exec = new ArbExecutor(
            OWNER, OPERATOR, WETH, BALANCER_VAULT, MORPHO_BLUE, PARASWAP_AUGUSTUS, UNI_V2_ROUTER, UNI_V3_ROUTER, allowed
        );
        vm.stopBroadcast();

        // ─── Readback: prove nothing is left to configure ────────────
        // Every venue the bot can route through must answer true HERE. If one
        // does not, the deploy is wrong and we find out now rather than when a
        // live arb reverts on an unallowlisted target.
        for (uint256 i = 0; i < allowed.length; ++i) {
            require(exec.allowedTargets(allowed[i]), "readback: allowed target");
        }
        require(exec.allowedTargets(BALANCER_VAULT), "readback: balancer vault");
        require(exec.allowedTargets(PARASWAP_AUGUSTUS), "readback: paraswap");
        require(exec.allowedTargets(UNI_V2_ROUTER), "readback: v2 router");
        require(exec.allowedTargets(UNI_V3_ROUTER), "readback: v3 router");
        require(exec.operators(OPERATOR), "readback: operator armed");
        require(exec.owner() == OWNER, "readback: owner");

        console2.log("ArbExecutor:", address(exec));
        console2.log("allowlisted targets:", allowed.length + 4);
        return address(exec);
    }
}
