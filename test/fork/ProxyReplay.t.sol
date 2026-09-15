// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyEtch} from "../support/ProxyEtch.sol";

/// Fork gate: a real production landing, replayed through the proxy.
///
/// tx 0xc444fb52… (block 25_974_940, index 17), route v4>hashflow, sent by
/// operator 0xf4Bb8842 with a 5000-wei bid to the live ArbExecutor 0x4d3AbD5d.
/// Its receipt holds a Uniswap V4 swap (the PoolManager calls the executor's
/// `unlockCallback`) and two WETH `Withdrawal`s to the executor (ETH arriving
/// under WETH9's 2300-gas `transfer`) — the two things a proxy could break.
///
/// The calldata runs twice from the pre-transaction state: once with the new
/// implementation's code etched straight onto the address (bare), once with
/// proxy code there delegating to that implementation. Both must succeed and
/// keep the same balances; the gas difference is the proxy's overhead.
///
/// Run it under the profile that ships ArbExecutor, with its own output dirs:
///   MAINNET_RPC_URL=https://rpc-eth.blockmachine.io FOUNDRY_PROFILE=arb FOUNDRY_OUT=out-arb \
///     FOUNDRY_CACHE_PATH=cache-arb forge test --match-path test/fork/ProxyReplay.t.sol -vv
contract ProxyReplayTest is Test {
    address constant EXEC = 0x4d3AbD5dC3ae7863470bB9e70949e2AC45d68731;
    address constant OPERATOR = 0xf4Bb8842dd662c8edDed051e66376937E308B905;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 constant LANDING_TX = 0xc444fb52c2a1db3bb4df85cf6f73627a6dc0768beb5dffeff81a7f8605cd9889;
    uint256 constant BID_WEI = 5000;
    /// 1% of the bot's `ARB_GAS_UNITS` (500_000, src/arbitrage/detector.rs in
    /// the bot repo). Above it, the bot's gas constants move in the same change.
    uint256 constant MAX_PROXY_OVERHEAD_GAS = 5_000;

    bool internal forked;
    address internal impl;
    bytes internal implRuntime;
    bytes internal proxyRuntime;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, LANDING_TX);
        forked = true;
        // Built here, in setUp's own transaction: see _coolExecutor.
        impl = address(ProxyEtch.arbImplementationLike(EXEC));
        implRuntime = impl.code;
        proxyRuntime = ProxyEtch.arbProxyRuntime(impl);
    }

    /// Mainnet pays cold for what a test tends to warm: the proxy's first
    /// DELEGATECALL to the implementation (2600, not 100) and first SLOAD of
    /// the ERC-1967 slot (2100, not 100).
    /// - The implementation address is cold because setUp — a previous
    ///   transaction — deployed it and captured both runtimes, and nothing in
    ///   the test touches it before the proxy run. `vm.cool(address)` cannot do
    ///   this: on forge 1.6.0-nightly it resets slot warmth, not account warmth
    ///   (measured: a warm CALL still costs warm after `vm.cool`).
    /// - Before EACH run, `vm.cool(EXEC)` marks every executor slot cold and
    ///   `vm.coolSlot` names the implementation slot that `vm.store` warmed.
    /// EXEC itself is warm in both runs (`vm.etch` touches it), as a
    /// transaction's `to` is on mainnet. Both runs get the same cooling, so the
    /// gas difference is what the proxy adds on mainnet.
    function _coolExecutor() internal {
        vm.cool(EXEC);
        vm.coolSlot(EXEC, ERC1967Utils.IMPLEMENTATION_SLOT);
    }

    function _replay() internal returns (bool ok, uint256 gasUsed, uint256 wethKept, uint256 ethKept) {
        bytes memory data = vm.parseBytes(vm.trim(vm.readFile("test/fixtures/landing_c444fb52.hex")));
        vm.deal(OPERATOR, 1 ether);
        vm.prank(OPERATOR, OPERATOR);
        uint256 before = gasleft();
        (ok,) = EXEC.call{value: BID_WEI}(data);
        gasUsed = before - gasleft();
        wethKept = IERC20(WETH).balanceOf(EXEC);
        ethKept = EXEC.balance;
    }

    function test_fork_landing_replays_through_the_proxy() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint256 snap = vm.snapshotState();

        vm.etch(EXEC, implRuntime);
        _coolExecutor();
        (bool okBare, uint256 gasBare, uint256 wethBare, uint256 ethBare) = _replay();
        assertTrue(okBare, "the landing must replay on the bare implementation");

        vm.revertToState(snap);
        vm.etch(EXEC, proxyRuntime);
        vm.store(EXEC, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(impl))));
        _coolExecutor();
        (bool okProxy, uint256 gasProxy, uint256 wethProxy, uint256 ethProxy) = _replay();
        assertTrue(okProxy, "the landing must replay through the proxy");

        assertEq(wethProxy, wethBare, "same WETH kept");
        assertEq(ethProxy, ethBare, "same ETH kept");
        emit log_named_uint("gas bare", gasBare);
        emit log_named_uint("gas proxy", gasProxy);
        emit log_named_uint("proxy overhead", gasProxy - gasBare);
        assertLt(gasProxy - gasBare, MAX_PROXY_OVERHEAD_GAS, "proxy overhead above 1% of ARB_GAS_UNITS");
    }
}
