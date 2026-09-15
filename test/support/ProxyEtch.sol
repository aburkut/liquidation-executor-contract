// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ArbExecutor} from "../../src/ArbExecutor.sol";
import {ExecutorDeploy} from "./ExecutorDeploy.sol";

/// Fork-gate helper: turn a LIVE arb executor into a proxy in place.
///
/// The live contract's storage already has the proxy's layout (the storage
/// bases were extracted without moving a slot — `script/check_layout.sh`), so
/// proxy code at the same address with the ERC-1967 slot pointing at a fresh
/// implementation reproduces the address after the migration: the same owner,
/// operators, allowlists and balances, and the same address that signed RFQ
/// quotes and the 1inch access token are bound to.
library ProxyEtch {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// A new implementation built with the live contract's own immutables.
    function arbImplementationLike(address live) internal returns (ArbExecutor) {
        ArbExecutor l = ArbExecutor(payable(live));
        return new ArbExecutor(
            l.weth(), l.balancerVault(), l.morphoBlue(), l.paraswapAugustusV6(), l.uniV2Router(), l.uniV3Router()
        );
    }

    /// `ExecutorProxy` runtime whose immutable admin is a throwaway ProxyAdmin.
    /// Building it calls `implementation` (Genesis reads its immutables).
    function arbProxyRuntime(address implementation) internal returns (bytes memory) {
        ArbExecutor model = ExecutorDeploy.arbProxy(implementation, address(0xA11CE), address(0xB0B), new address[](0));
        return address(model).code;
    }

    /// Put `ExecutorProxy` runtime at `live`, delegating to `implementation`.
    function etchArbProxy(address live, address implementation) internal {
        VM.etch(live, arbProxyRuntime(implementation));
        VM.store(live, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
    }
}
