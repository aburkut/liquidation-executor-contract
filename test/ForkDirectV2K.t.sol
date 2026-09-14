// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// Replays the exact `execute` calldata that reverted `UniswapV2: K` in the
/// builders' simulations, against the REAL deployed executor at the real
/// block.
///
/// MEASURED 2026-09-14: with `ARB_DIRECT_V2_SWAPS=1`, every `hashflow>v2`
/// ring closing through the WETH/FLOKI pair died `UniswapV2: K` — 52 of 54
/// post-mortem sims. The same route landed 8 times the previous day through
/// the ROUTER path. Three sims kept: 547fed5a (block 25971664), c1e0917f
/// (25971659), d9cbacb9 (25971649), all `to` 0x4d3abd5d, gas ~684k.
///
/// The plan, decoded from that calldata word by word:
///   op target   0xca7c2771…  WETH/FLOKI pair, Uniswap V2 factory
///   op flags    0x82 = FLAG_USE_PREV_RETURN | FLAG_V2_DIRECT
///   srcToken    FLOKI -> outToken WETH
///   callData    64 bytes: zeroForOne = false, feeNumerator = 997
///               (rewritten to 9970 on replay — see `_plan`)
/// Direction and fee are both CORRECT for this pair, so neither explains the
/// revert.
contract ForkDirectV2KTest is Test {
    address constant EXEC = 0x4d3AbD5dC3ae7863470bB9e70949e2AC45d68731;
    address constant LIB = 0x1941Ab29d7281Ce222401F92f0DB539f18019f45;
    address constant OPERATOR = 0xf4Bb8842dd662c8edDed051e66376937E308B905;
    address constant PAIR = 0xca7c2771D248dCBe09EABE0CE57A62e18dA178c0;
    address constant FLOKI = 0xcf0C122c6b73ff809C693DB761e7BaeBe62b6a2E;

    uint256 constant FORK_BLOCK = 25_971_663;
    uint256 constant BID_WEI = 5000;

    modifier forkOnly() {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    /// The recorded plan carries `feeNumerator = 997` — the scale the bot used
    /// when it built this bundle, and the scale the DEPLOYED library still
    /// reads. This branch moves `DirectSwapLib` to TEN-THOUSANDTHS, where 997
    /// would mean a 99.9% fee, so the replay has to choose which scale it is
    /// speaking:
    ///
    ///   * against the deployed code  -> leave 997 (thousandths)
    ///   * against this branch's code -> rewrite to 9970
    ///
    /// Rewriting unconditionally makes the deployed-code test revert
    /// `DirectSwapInvalid` at the `feeNumerator > 1000` guard — an early exit
    /// at ~277k gas instead of the ~711k it takes to reach the pair — so it
    /// would still be red, just for the wrong reason. The word's position is
    /// asserted rather than assumed.
    function _plan(bool tenThousandths) internal view returns (bytes memory) {
        bytes memory cd = vm.envOr("K_CALLDATA", bytes(""));
        require(cd.length > 4, "K_CALLDATA not set");
        // selector (4) + word 52 -> byte offset 4 + 52*32, last two bytes.
        uint256 hi = 4 + 52 * 32 + 30;
        require(uint8(cd[hi]) == 0x03 && uint8(cd[hi + 1]) == 0xe5, "fee word moved");
        if (tenThousandths) {
            cd[hi] = bytes1(uint8(9970 >> 8));
            cd[hi + 1] = bytes1(uint8(9970 & 0xff));
        }
        return cd;
    }

    function _run(bool tenThousandths) internal returns (bool ok, bytes memory ret) {
        vm.deal(OPERATOR, 1 ether);
        vm.prank(OPERATOR);
        (ok, ret) = EXEC.call{value: BID_WEI}(_plan(tenThousandths));
    }

    /// Does the revert reproduce against the code that is actually on chain?
    function test_fork_deployed_reverts_with_K() public forkOnly {
        // Deployed code still reads thousandths: replay the plan verbatim.
        (bool ok, bytes memory ret) = _run(false);
        emit log_named_bytes("revert", ret);
        assertFalse(ok, "expected the deployed executor to revert");
        assertTrue(_isK(ret), "expected UniswapV2: K");
    }

    /// THE FIX. Etch the branch build of the library over the deployed one
    /// and run the same plan again.
    ///
    /// CONTROL, recorded before the fix was applied: this same test, etching
    /// the then-current `main` build, reverted `UniswapV2: K` byte for byte
    /// like the deployed code above (run 2026-09-14, both payloads identical:
    /// 0x08c379a0…556e697377617056323a204b). So the etch harness reproduces
    /// the deployed behaviour faithfully, and the change below is the fix,
    /// not the harness.
    ///
    /// The plan still does not execute, and it SHOULD NOT: the pair now
    /// accepts the swap, and the cycle is then refused by our OWN flash-repay
    /// gate because it came back 0.249869766973738772 WETH against the
    /// 0.25 WETH principal — 5.21 bps short, about $0.33. That is the
    /// contract declining a losing cycle, which is the behaviour we want.
    /// Asserting success here would mean demanding profit from a plan that
    /// had none.
    function test_fork_the_pair_accepts_the_swap_after_the_fix() public forkOnly {
        vm.etch(LIB, vm.getDeployedCode("GenericSequenceLib.sol:GenericSequenceLib"));
        // This branch reads ten-thousandths: the fee word is rescaled to match.
        (bool ok, bytes memory ret) = _run(true);
        emit log_named_bytes("ret", ret);
        assertFalse(_isK(ret), "the pair must no longer reject on K");
        assertFalse(ok, "this particular cycle is unprofitable and must be refused");
        // `InsufficientRepayOutput(uint256 got, uint256 needed)` — selector
        // taken from the compiled ABI, not guessed.
        assertEq(bytes4(ret), bytes4(0x75ce3dc6), "expected the flash-repay gate");
        (uint256 got, uint256 needed) = abi.decode(_args(ret), (uint256, uint256));
        assertEq(needed, 0.25 ether, "the flash principal");
        assertEq(got, 249_869_766_973_738_772, "what the cycle returned");
        assertLt(got, needed);
    }

    /// Strip the 4-byte selector so the two arguments can be decoded.
    function _args(bytes memory ret) private pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; ++i) {
            out[i - 4] = ret[i];
        }
    }

    /// The pair's reserves versus its balances at the fork block: no unsynced
    /// surplus, so "a donation inflated what we measured" is not the cause.
    function test_fork_pair_has_no_unsynced_surplus() public forkOnly {
        (bool ok, bytes memory r) = PAIR.staticcall(abi.encodeWithSignature("getReserves()"));
        assertTrue(ok, "getReserves");
        (uint112 r0, uint112 r1,) = abi.decode(r, (uint112, uint112, uint32));
        (bool ok2, bytes memory b) = FLOKI.staticcall(abi.encodeWithSignature("balanceOf(address)", PAIR));
        assertTrue(ok2, "balanceOf");
        assertEq(abi.decode(b, (uint256)), uint256(r1), "FLOKI balance == reserve1");
        assertGt(uint256(r0), 0);
    }

    function _isK(bytes memory ret) private pure returns (bool) {
        // Error(string) selector + "UniswapV2: K" somewhere in the payload.
        bytes memory needle = bytes("UniswapV2: K");
        if (ret.length < needle.length) return false;
        for (uint256 i = 0; i + needle.length <= ret.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (ret[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
