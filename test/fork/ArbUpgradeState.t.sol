// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ArbExecutor} from "../../src/ArbExecutor.sol";

/// Fork gate: the owner's upgrade transaction (ProxyAdmin.upgradeAndCall with
/// empty data, pranked as the Safe on the fork only) changes nothing on the
/// arb proxy but its ERC-1967 implementation slot.
///
/// Read before and after: the persistent slots of `layout/ArbExecutor.json`
/// (owner, pending owner + paused, and the four mappings at known keys), the
/// ERC-1967 admin slot, OpenZeppelin's Initializable namespace, the proxy's
/// token balances, and the 1inch Resolver Access Token (RES) it holds — bound
/// to the proxy ADDRESS, which an upgrade does not change.
///
///   MAINNET_RPC_URL=https://eth.drpc.org forge test --match-path test/fork/ArbUpgradeState.t.sol -vv
contract ArbUpgradeStateTest is Test {
    address constant PROXY = 0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c;
    address constant SAFE = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    address constant ROLLBACK_IMPL = 0x0835F6b8b06bFeCb9d18b272D723dcaA7f31C83a;
    address constant RES = 0xAcce5500000f71A32B5E5514D1577E14b7aacC4a;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    bytes32 constant INITIALIZABLE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    uint256 constant FORK_BLOCK = 26_131_000;

    // Mapping keys whose entries must survive (operators, targets, providers).
    address[4] internal operators = [
        0x1e9e18152552609175826f3ee6F8bFD639532E37,
        0x25f4c6C1e5Cc564071A1DC1768a1f1ff0BA9d5a1,
        0xf4Bb8842dd662c8edDed051e66376937E308B905,
        0x1B613556C0edBBA04c53e4685dA338ace02896C4
    ];
    address[8] internal targets = [
        0xBA12222222228d8Ba445958a75a0704d566BF2C8, // Balancer vault
        0x6A000F20005980200259B80c5102003040001068, // Paraswap Augustus
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, // Uniswap V2 router
        0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45, // Uniswap V3 router
        0x000000000004444c5dc75cB358380D2e3dE08A90, // V4 PoolManager
        0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb, // Morpho (must stay false)
        WETH, // must stay false
        0x9f846ef584FD44d075B5E8dF00dDB4416da61a80 // Motoswap fee router
    ];

    function _mappingSlot(address key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _snapshot() internal view returns (bytes32[] memory s) {
        s = new bytes32[](4 + operators.length + targets.length + 2);
        uint256 i;
        s[i++] = vm.load(PROXY, bytes32(uint256(0))); // _owner
        s[i++] = vm.load(PROXY, bytes32(uint256(1))); // _pendingOwner | _paused
        s[i++] = vm.load(PROXY, ERC1967Utils.ADMIN_SLOT);
        s[i++] = vm.load(PROXY, INITIALIZABLE);
        for (uint256 k = 0; k < operators.length; ++k) {
            s[i++] = vm.load(PROXY, _mappingSlot(operators[k], 5));
        }
        for (uint256 k = 0; k < targets.length; ++k) {
            s[i++] = vm.load(PROXY, _mappingSlot(targets[k], 3));
        }
        s[i++] = vm.load(PROXY, keccak256(abi.encode(uint256(2), uint256(2)))); // provider 2
        s[i++] = vm.load(PROXY, keccak256(abi.encode(uint256(3), uint256(2)))); // provider 3
    }

    function _balances() internal view returns (uint256 res, uint256 weth, uint256 usdc, uint256 eth) {
        res = IERC20(RES).balanceOf(PROXY);
        weth = IERC20(WETH).balanceOf(PROXY);
        usdc = IERC20(USDC).balanceOf(PROXY);
        eth = PROXY.balance;
    }

    function test_fork_upgrade_changes_only_the_implementation_slot() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        assertEq(
            address(uint160(uint256(vm.load(PROXY, ERC1967Utils.IMPLEMENTATION_SLOT)))),
            ROLLBACK_IMPL,
            "the fork must start on the deployed implementation"
        );
        bytes32[] memory before = _snapshot();
        (uint256 resB, uint256 wethB, uint256 usdcB, uint256 ethB) = _balances();
        assertEq(resB, 1, "the proxy holds the RES token before the upgrade");

        ArbExecutor live = ArbExecutor(payable(PROXY));
        address impl = address(
            new ArbExecutor(
                live.weth(),
                live.balancerVault(),
                live.morphoBlue(),
                live.paraswapAugustusV6(),
                live.uniV2Router(),
                live.uniV3Router()
            )
        );
        address admin = address(uint160(uint256(before[2])));
        vm.prank(SAFE);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(PROXY), impl, "");

        assertEq(
            address(uint160(uint256(vm.load(PROXY, ERC1967Utils.IMPLEMENTATION_SLOT)))),
            impl,
            "the implementation slot points at the new implementation"
        );
        bytes32[] memory afterUp = _snapshot();
        for (uint256 i = 0; i < before.length; ++i) {
            assertEq(afterUp[i], before[i], "a persistent slot changed across the upgrade");
        }
        (uint256 resA, uint256 wethA, uint256 usdcA, uint256 ethA) = _balances();
        assertEq(resA, resB, "RES balance unchanged");
        assertEq(wethA, wethB, "WETH balance unchanged");
        assertEq(usdcA, usdcB, "USDC balance unchanged");
        assertEq(ethA, ethB, "ETH balance unchanged");

        // The getters read the same through the new code, and it answers 2.
        ArbExecutor exec = ArbExecutor(payable(PROXY));
        assertEq(exec.owner(), SAFE, "owner");
        assertFalse(exec.paused(), "not paused");
        assertEq(exec.allowedFlashProviders(2), live.balancerVault(), "provider 2");
        assertEq(exec.allowedFlashProviders(3), live.morphoBlue(), "provider 3");
        assertFalse(exec.allowedTargets(WETH), "WETH is not a target");
        assertFalse(exec.allowedTargets(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb), "Morpho is not a target");
        assertEq(exec.version(), 2, "new implementation");
        assertEq(ProxyAdmin(admin).owner(), SAFE, "ProxyAdmin still owned by the Safe");
    }
}
