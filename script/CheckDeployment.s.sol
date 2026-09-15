// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/// The getters both executors expose.
interface IExecutorView {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function operators(address operator) external view returns (bool);
    function allowedTargets(address target) external view returns (bool);
    function allowedFlashProviders(uint8 id) external view returns (address);
    function weth() external view returns (address);
    function morphoBlue() external view returns (address);
    function paraswapAugustusV6() external view returns (address);
    function uniV2Router() external view returns (address);
    function uniV3Router() external view returns (address);
}

interface IArbExecutorView is IExecutorView {
    function balancerVault() external view returns (address);
}

interface ILiquidationExecutorView is IExecutorView {
    function aavePool() external view returns (address);
    function aaveV2LendingPool() external view returns (address);
}

/// Read-only check of a MINED executor proxy on a live network. It deploys
/// nothing, signs nothing and needs no key: every check is a storage read or
/// a view call, and any mismatch reverts.
///
///   PROXY=0x… EXECUTOR_KIND=arb forge script script/CheckDeployment.s.sol --rpc-url $RPC
///   PROXY=0x… EXECUTOR_KIND=liquidation forge script script/CheckDeployment.s.sol --rpc-url $RPC
///
/// No `--broadcast`, no `PRIVATE_KEY`. After an upgrade, add
/// `EXPECTED_IMPLEMENTATION=0x…` to require that exact implementation.
///
/// This is spec §3 step 3's gate on the deployed proxies, together with
/// `forge verify-bytecode` on the implementation (docs/PROXY_OPERATIONS.md):
/// verify-bytecode proves the mined code is the build the fork gate tested,
/// and this script proves the proxy around it is wired and owned as intended.
contract CheckDeployment is Script {
    // Must match script/DeployArb.s.sol and script/Deploy.s.sol.
    address constant OWNER = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    address constant OPERATOR = 0x1e9e18152552609175826f3ee6F8bFD639532E37;
    address constant OPERATOR_2 = 0x25f4c6C1e5Cc564071A1DC1768a1f1ff0BA9d5a1;
    address constant OPERATOR_3 = 0xf4Bb8842dd662c8edDed051e66376937E308B905;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /// OpenZeppelin 5.5 `Initializable` namespaced storage. The struct packs
    /// `uint64 _initialized` into the low 8 bytes and `bool _initializing`
    /// into the next byte of this one slot.
    bytes32 constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function run() external view {
        address proxy = vm.envAddress("PROXY");
        bytes32 kind = keccak256(bytes(vm.envString("EXECUTOR_KIND")));
        bool arb = kind == keccak256("arb");
        require(arb || kind == keccak256("liquidation"), "EXECUTOR_KIND must be arb or liquidation");

        // ─── Proxy wiring ────────────────────────────────────────────
        address impl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(impl != address(0), "not an ERC-1967 proxy: implementation slot is zero");
        require(impl.code.length > 0, "implementation slot points at an address without code");
        address expected = vm.envOr("EXPECTED_IMPLEMENTATION", address(0));
        require(expected == address(0) || impl == expected, "implementation is not EXPECTED_IMPLEMENTATION");
        address admin = address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));
        require(admin != address(0), "not an ERC-1967 proxy: admin slot is zero");
        console2.log("ok proxy: implementation", impl);
        console2.log("ok proxy: admin", admin);

        // ─── Ownership ───────────────────────────────────────────────
        IExecutorView exec = IExecutorView(proxy);
        require(ProxyAdmin(admin).owner() == OWNER, "ProxyAdmin owner is not the Safe");
        require(exec.owner() == OWNER, "executor owner is not the Safe");
        console2.log("ok ownership: ProxyAdmin and executor owned by", OWNER);

        // ─── Initialisation is spent ─────────────────────────────────
        uint256 init = uint256(vm.load(proxy, INITIALIZABLE_STORAGE));
        require(uint64(init) == 1, "Initializable._initialized is not 1");
        require(uint8(init >> 64) == 0, "Initializable._initializing is set");
        console2.log("ok initializer: _initialized == 1, not initializing");

        // ─── Immutables ──────────────────────────────────────────────
        require(exec.weth() == WETH, "immutable: weth");
        require(exec.morphoBlue() == MORPHO_BLUE, "immutable: morphoBlue");
        require(exec.paraswapAugustusV6() == PARASWAP_AUGUSTUS, "immutable: paraswapAugustusV6");
        require(exec.uniV2Router() == UNI_V2_ROUTER, "immutable: uniV2Router");
        require(exec.uniV3Router() == UNI_V3_ROUTER, "immutable: uniV3Router");
        if (arb) {
            require(IArbExecutorView(proxy).balancerVault() == BALANCER_VAULT, "immutable: balancerVault");
        } else {
            require(ILiquidationExecutorView(proxy).aavePool() == AAVE_V3_POOL, "immutable: aavePool");
        }
        console2.log("ok immutables: all six match the deploy scripts");

        // ─── Flash providers ─────────────────────────────────────────
        require(exec.allowedFlashProviders(2) == BALANCER_VAULT, "allowedFlashProviders(2) is not the Balancer vault");
        require(exec.allowedFlashProviders(3) == exec.morphoBlue(), "allowedFlashProviders(3) is not morphoBlue()");
        console2.log("ok flash providers: 2 = Balancer vault, 3 = morphoBlue()");

        // ─── Operation ───────────────────────────────────────────────
        require(exec.operators(OPERATOR), "operator OPERATOR not set");
        require(exec.operators(OPERATOR_2), "operator OPERATOR_2 not set");
        require(exec.operators(OPERATOR_3), "operator OPERATOR_3 not set");
        require(!exec.paused(), "executor is paused");
        console2.log("ok operation: three operators set, not paused");

        // ─── Kind-specific allowlist ─────────────────────────────────
        if (arb) {
            require(!exec.allowedTargets(MORPHO_BLUE), "arb: Morpho must NOT be a target");
            require(!exec.allowedTargets(WETH), "arb: WETH must NOT be a target");
            console2.log("ok arb allowlist: Morpho and WETH are not targets");
        } else {
            require(exec.allowedTargets(AAVE_V3_POOL), "liquidation: Aave V3 pool must be a target");
            require(exec.allowedTargets(MORPHO_BLUE), "liquidation: Morpho must be a target");
            require(
                ILiquidationExecutorView(proxy).aaveV2LendingPool() == address(0),
                "liquidation: aaveV2LendingPool must be unset"
            );
            console2.log("ok liquidation allowlist: Aave V3 pool and Morpho are targets, Aave V2 pool unset");
        }

        console2.log(
            arb
                ? "CheckDeployment: all checks passed for arb proxy"
                : "CheckDeployment: all checks passed for liquidation proxy",
            proxy
        );
    }
}
