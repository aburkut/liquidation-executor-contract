// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {ArbTypes} from "../../src/ArbExecutor.sol";
import {Op} from "../../src/types/SwapTypes.sol";
import {GenericSequenceLib} from "../../src/libraries/GenericSequenceLib.sol";
import {MockUniV3Pool} from "../mocks/MockDirectPools.sol";
import {V2SwapHarness} from "../support/V2SwapHarness.sol";

interface IV2PairView {
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IFlokiTax {
    function getTax(address benefactor, address beneficiary, uint256 amount) external view returns (uint256);
}

/// A direct V2 swap through FLOKI's own WETH pair, on mainnet state, through
/// the executor that is LIVE — no calldata fixture, no etching.
///
/// FLOKI's `_transfer` runs `treasuryHandler.beforeTransferHandler` BEFORE it
/// moves a balance. On a sell into an exchange pool, with any tax on hand, the
/// handler sells that tax into the primary pool (this pair) through Uniswap's
/// router and adds a slice of it as liquidity — a `swap` and a `mint` on the
/// pair we are paying, inside our own `transfer`. Read at the fork block: the
/// handler holds 653 106.57 FLOKI and its primary pool is this pair, so every
/// sell here runs the swap-back first (0.3% tax either way, `getTax`).
///
/// MEASURED 2026-09-14 with `ARB_DIRECT_V2_SWAPS=1`: 52 of 54 `hashflow>v2`
/// sims closing through this pair reverted `UniswapV2: K` on library code that
/// read reserves before the transfer. #45 moved the read after it and has been
/// on chain since the proxy migration of 2026-09-15: the implementation the
/// proxy runs today (0x0835F6b8, upgraded 2026-09-26 from main b48587a) links
/// GenericSequenceLib 0x88ada618, whose runtime is byte-identical to this
/// tree's `arb` build of b48587a once its 20-byte self-address is zeroed
/// (checked 2026-09-29; the hash below pins the deployed bytes). The bot kept
/// `ARB_DIRECT_V2_SWAPS=0` on a doc comment that still described the 09-11
/// code. These tests are the on-chain answer.
///
/// The cycle tests need a first leg that sells FLOKI cheaply — in production
/// a Hashflow quote. A `MockUniV3Pool` "maker" stands in for it: it pays its
/// output first and takes its input through the executor's V3 callback, the
/// same frame a direct V3 hop uses, at a rate set a few percent better than
/// the pair so the cycle clears the inventory gate. The pair, FLOKI, its
/// handler, the router and the executor are all the real ones.
///
///   MAINNET_RPC_URL=https://eth.drpc.org forge test --match-path test/fork/ForkDirectV2PostTransfer.t.sol -vv
/// (an archive RPC; publicnode refuses historical state without a token).
contract ForkDirectV2PostTransferTest is Test {
    uint256 constant FORK_BLOCK = 26_081_000;

    address constant EXEC = 0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c; // ArbExecutor proxy
    address constant IMPL = 0x0835F6b8b06bFeCb9d18b272D723dcaA7f31C83a;
    address constant GSL = 0x88Ada6184aa605B8450062Bb919765E6373fc4C6;
    /// keccak256 of GSL's runtime at the fork block.
    bytes32 constant GSL_CODEHASH = 0xddcd073fe62bf2ba8765b44da47013fed21e9ded1cc00c9ac67adf8f228c9018;
    address constant OPERATOR = 0xf4Bb8842dd662c8edDed051e66376937E308B905;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FLOKI = 0xcf0C122c6b73ff809C693DB761e7BaeBe62b6a2E;
    address constant FLOKI_HANDLER = 0xBc530Bfa3FCA1a731149248AfC7F750c18360de1;
    address constant FLOKI_TAX = 0x834F96fD4fE9147a2a647D957FBbE67FEc62B67b;
    /// Uniswap V2 WETH/FLOKI: token0 WETH, token1 FLOKI.
    address constant PAIR_FLOKI = 0xca7c2771D248dCBe09EABE0CE57A62e18dA178c0;
    /// Uniswap V2 USDC/WETH: token0 USDC, token1 WETH. No hook, no tax.
    address constant PAIR_USDC = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    address constant ROUTER02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    uint16 constant FEE = 9970;
    /// ~0.25 WETH of FLOKI (9 decimals), the size of the 09-14 plans.
    uint256 constant FLOKI_IN = 25_000_000e9;
    uint256 constant WETH_IN = 0.2 ether;

    bytes32 constant SWAP_TOPIC = keccak256("Swap(address,uint256,uint256,uint256,uint256,address)");
    bytes32 constant SYNC_TOPIC = keccak256("Sync(uint112,uint112)");
    bytes32 constant MINT_TOPIC = keccak256("Mint(address,uint256,uint256)");

    bool internal forked;
    V2SwapHarness internal h;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;
        h = new V2SwapHarness();
    }

    modifier forkOnly() {
        if (!forked) vm.skip(true);
        _;
    }

    // ─── What is on chain ───────────────────────────────────────────────

    function test_fork_the_proxy_runs_the_post_transfer_build() public forkOnly {
        assertEq(
            address(uint160(uint256(vm.load(EXEC, ERC1967Utils.IMPLEMENTATION_SLOT)))), IMPL, "implementation slot"
        );
        assertEq(GSL.codehash, GSL_CODEHASH, "GenericSequenceLib runtime");
        assertGt(IERC20(FLOKI).balanceOf(FLOKI_HANDLER), 0, "tax on hand: the next sell swaps back");
        assertEq(IFlokiTax(FLOKI_TAX).getTax(EXEC, PAIR_FLOKI, 1e12), 3e9, "0.3% on a sell");
    }

    // ─── The FLOKI pair: three orderings, one state ─────────────────────

    /// Both orderings that read the reserves before the transfer ask the real
    /// pair for more than its K allows.
    function test_fork_floki_pre_transfer_orderings_revert_K() public forkOnly {
        deal(FLOKI, address(h), FLOKI_IN);
        bytes memory data = abi.encode(false, FEE);
        uint256 s = vm.snapshotState();
        vm.expectRevert(bytes("UniswapV2: K"));
        h.swapPricedOnAmount(PAIR_FLOKI, FLOKI, FLOKI_IN, data);
        vm.revertToState(s);
        vm.expectRevert(bytes("UniswapV2: K"));
        h.swapReservesBeforeTransfer(PAIR_FLOKI, FLOKI, FLOKI_IN, data);
    }

    /// The code on chain: the hook trades the pair inside our transfer, and
    /// the output is the reserve formula on the reserves the hook LEFT, which
    /// the pair accepts.
    function test_fork_floki_current_ordering_prices_on_what_the_hook_left() public forkOnly {
        deal(FLOKI, address(h), FLOKI_IN);
        (uint112 w0, uint112 f0,) = IV2PairView(PAIR_FLOKI).getReserves();
        uint256 tax = IFlokiTax(FLOKI_TAX).getTax(address(h), PAIR_FLOKI, FLOKI_IN);

        vm.recordLogs();
        (uint256 out, uint256 gasUsed) = h.swapCurrent(PAIR_FLOKI, FLOKI, FLOKI_IN, abi.encode(false, FEE));
        (uint256 swaps, uint256 mints, uint256[2] memory priced) = _pairLogs(vm.getRecordedLogs(), PAIR_FLOKI);

        assertEq(swaps, 2, "the handler's swap-back, then ours");
        assertEq(mints, 1, "the handler's liquidity add");
        assertTrue(priced[0] != w0 || priced[1] != f0, "the hook moved the reserves before we priced");
        uint256 expected = _formula(FLOKI_IN - tax, priced[1], priced[0]);
        assertEq(out, expected, "reserve formula on the post-hook reserves");
        assertEq(IERC20(WETH).balanceOf(address(h)), out, "the pair paid it");
        console2.log("floki sell: WETH out", out, "gas", gasUsed);
    }

    // ─── The deployed executor, end to end ──────────────────────────────

    /// The live proxy closes WETH -> FLOKI (maker) -> WETH (V2 direct, the
    /// FLOKI pair) with the swap-back running inside its transfer.
    function test_fork_deployed_executor_closes_a_floki_cycle_through_the_pair() public forkOnly {
        (uint112 rw, uint112 rf,) = IV2PairView(PAIR_FLOKI).getReserves();
        // FLOKI per WETH at the pair, 3% better at the maker.
        MockUniV3Pool maker = new MockUniV3Pool(WETH, FLOKI, uint256(rf) * 1e18 / uint256(rw) * 103 / 100);
        deal(FLOKI, address(maker), 10 * FLOKI_IN);

        Op[] memory ops = new Op[](2);
        ops[0] = _v3Direct(address(maker), WETH, FLOKI, true, WETH_IN, 0);
        ops[1] = _v2Direct(PAIR_FLOKI, FLOKI, WETH, false, 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        uint256 before = IERC20(WETH).balanceOf(EXEC);
        assertGe(before, WETH_IN, "inventory path: the proxy holds the principal");
        vm.recordLogs();
        (bool ok, bytes memory ret, uint256 gasUsed) = _execute(_plan(WETH, WETH_IN, ops));
        assertTrue(ok, _why(ret));
        (uint256 swaps, uint256 mints,) = _pairLogs(vm.getRecordedLogs(), PAIR_FLOKI);

        assertEq(swaps, 2, "the handler's swap-back, then ours");
        assertEq(mints, 1, "the handler's liquidity add");
        assertGt(IERC20(WETH).balanceOf(EXEC), before, "the cycle closed above water");
        console2.log("deployed executor, floki cycle: WETH kept", IERC20(WETH).balanceOf(EXEC) - before);
        console2.log("deployed executor, floki cycle: gas", gasUsed);
    }

    // ─── Flash V2 on FLOKI: why the bot must not promote these ──────────

    /// Selling FLOKI into its own pair as a FLASH leg cannot settle: the input
    /// is paid INSIDE the pair's `swap`, when the pair is locked, and FLOKI's
    /// transfer then runs the handler's swap-back into that same locked pair.
    /// No pricing change can fix this; the leg has to stay direct.
    function test_fork_flashV2_selling_floki_into_its_own_pair_cannot_settle() public forkOnly {
        (uint112 rw, uint112 rf,) = IV2PairView(PAIR_FLOKI).getReserves();
        MockUniV3Pool maker = new MockUniV3Pool(WETH, FLOKI, uint256(rf) * 1e18 / uint256(rw) * 103 / 100);
        deal(FLOKI, address(maker), 10 * FLOKI_IN);

        uint256 wethOut = _formula(FLOKI_IN, rf, rw);
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Direct(PAIR_FLOKI, FLOKI, WETH, false, FLOKI_IN, 0);
        ops[0].flags = GenericSequenceLib.FLAG_V2_FLASH;
        ops[1] = _v3Direct(address(maker), WETH, FLOKI, true, 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        (bool ok, bytes memory ret,) = _execute(_plan(WETH, wethOut, ops));
        assertFalse(ok);
        assertTrue(_contains(ret, "UniswapV2: LOCKED"), _why(ret));
    }

    /// A flash leg whose OUTPUT is FLOKI hands the continuation what the pair
    /// SENT, not what arrived: the callback seeds `prevReturn` from the pair's
    /// `amount1`, and FLOKI keeps 0.3% of it. The next op then pays out more
    /// FLOKI than the executor holds. The direct path measures the balance
    /// delta instead (#43); the flash callbacks do not. Latent while
    /// `ARB_FLASH_SWAPS` is off — pinned so turning it on is a decision.
    function test_fork_flashV2_taxed_output_seeds_the_continuation_with_what_was_sent() public forkOnly {
        (uint112 rw, uint112 rf,) = IV2PairView(PAIR_FLOKI).getReserves();
        // WETH per FLOKI at the pair, 3% better at the maker.
        MockUniV3Pool maker = new MockUniV3Pool(WETH, FLOKI, uint256(rw) * 1e18 / uint256(rf) * 103 / 100);
        deal(WETH, address(maker), 10 ether);

        Op[] memory ops = new Op[](2);
        ops[0] = _v2Direct(PAIR_FLOKI, WETH, FLOKI, true, WETH_IN, 0);
        ops[0].flags = GenericSequenceLib.FLAG_V2_FLASH;
        ops[1] = _v3Direct(address(maker), FLOKI, WETH, false, 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        (bool ok, bytes memory ret,) = _execute(_plan(WETH, WETH_IN, ops));
        assertFalse(ok);
        assertTrue(_contains(ret, "FLOKI:_transfer:INSUFFICIENT_BALANCE"), _why(ret));
    }

    // ─── A plain pair: same output, and what the fix costs ──────────────

    /// USDC/WETH has no hook and no tax, so the three orderings must agree to
    /// the wei. One test per ordering, so each pays the same cold accesses.
    function test_fork_plain_pair_current_ordering() public forkOnly {
        _plainPair(0);
    }

    function test_fork_plain_pair_reserves_before_transfer() public forkOnly {
        _plainPair(1);
    }

    function test_fork_plain_pair_priced_on_amount() public forkOnly {
        _plainPair(2);
    }

    function _plainPair(uint256 which) internal {
        deal(WETH, address(h), WETH_IN);
        (uint112 ru, uint112 rw,) = IV2PairView(PAIR_USDC).getReserves();
        uint256 expected = _formula(WETH_IN, rw, ru);
        bytes memory data = abi.encode(false, FEE); // WETH is token1
        uint256 out;
        uint256 gasUsed;
        if (which == 0) (out, gasUsed) = h.swapCurrent(PAIR_USDC, WETH, WETH_IN, data);
        else if (which == 1) (out, gasUsed) = h.swapReservesBeforeTransfer(PAIR_USDC, WETH, WETH_IN, data);
        else (out, gasUsed) = h.swapPricedOnAmount(PAIR_USDC, WETH, WETH_IN, data);
        assertEq(out, expected, "the same reserve formula");
        assertEq(IERC20(USDC).balanceOf(address(h)), expected, "the same USDC received");
        console2.log("plain pair ordering", which, "USDC out", out);
        console2.log("plain pair ordering", which, "gas", gasUsed);
    }

    // ─── The deployed executor: a V2 leg via Router02 vs direct ─────────

    /// The same cycle through the live proxy twice — WETH -> USDC on the V2
    /// pair, USDC -> WETH at a maker — once with the V2 leg through Router02
    /// (`swapExactTokensForTokensSupportingFeeOnTransferTokens`, what every V2
    /// leg uses while `ARB_DIRECT_V2_SWAPS=0`) and once direct. Both must keep
    /// exactly the same WETH; the gas difference is what the flag saves.
    function test_fork_executor_v2_leg_via_router() public forkOnly {
        _routerVsDirect(false);
    }

    function test_fork_executor_v2_leg_direct() public forkOnly {
        _routerVsDirect(true);
    }

    function _routerVsDirect(bool direct) internal {
        (uint112 ru, uint112 rw,) = IV2PairView(PAIR_USDC).getReserves();
        uint256 usdcOut = _formula(WETH_IN, rw, ru);
        // WETH per USDC at the pair, 1% better at the maker (token0 USDC).
        uint256 rate = uint256(rw) * 1e18 / uint256(ru) * 101 / 100;
        MockUniV3Pool maker = new MockUniV3Pool(USDC, WETH, rate);
        deal(WETH, address(maker), 10 ether);
        uint256 expectedKept = usdcOut * rate / 1e18 - WETH_IN;

        Op[] memory ops = new Op[](2);
        if (direct) {
            ops[0] = _v2Direct(PAIR_USDC, WETH, USDC, false, WETH_IN, 0);
        } else {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = USDC;
            ops[0].target = ROUTER02;
            ops[0].amountIn = WETH_IN;
            ops[0].fromAmountPos = 4;
            ops[0].srcToken = WETH;
            ops[0].outToken = USDC;
            ops[0].callData =
                abi.encodeWithSelector(bytes4(0x5c11d795), WETH_IN, uint256(1), path, EXEC, block.timestamp + 120);
        }
        ops[1] = _v3Direct(address(maker), USDC, WETH, true, 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        bytes memory plan = _plan(WETH, WETH_IN, ops);
        uint256 before = IERC20(WETH).balanceOf(EXEC);
        (bool ok, bytes memory ret, uint256 gasUsed) = _execute(plan);
        assertTrue(ok, _why(ret));
        assertEq(IERC20(WETH).balanceOf(EXEC) - before, expectedKept, "same WETH kept either way");
        assertEq(IERC20(WETH).allowance(EXEC, ROUTER02), 0, "no allowance left behind");
        console2.log(direct ? "v2 leg DIRECT: execute gas" : "v2 leg ROUTER: execute gas", gasUsed);
        console2.log(direct ? "v2 leg DIRECT: calldata gas" : "v2 leg ROUTER: calldata gas", _calldataGas(plan));
        console2.log(direct ? "v2 leg DIRECT: calldata bytes" : "v2 leg ROUTER: calldata bytes", plan.length + 4);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _v2Direct(address pair, address src, address dst, bool zeroForOne, uint256 amountIn, uint32 extra)
        internal
        pure
        returns (Op memory op)
    {
        op.target = pair;
        op.srcToken = src;
        op.outToken = dst;
        op.amountIn = amountIn;
        op.flags = GenericSequenceLib.FLAG_V2_DIRECT | extra;
        op.callData = abi.encode(zeroForOne, FEE);
    }

    function _v3Direct(address pool, address src, address dst, bool zeroForOne, uint256 amountIn, uint32 extra)
        internal
        pure
        returns (Op memory op)
    {
        op.target = pool;
        op.srcToken = src;
        op.outToken = dst;
        op.amountIn = amountIn;
        op.flags = GenericSequenceLib.FLAG_V3_DIRECT | extra;
        op.callData = abi.encode(zeroForOne, uint160(0));
    }

    function _plan(address loanToken, uint256 amount, Op[] memory ops) internal pure returns (bytes memory) {
        return abi.encode(
            ArbTypes.ArbPlan({
                flashProviderId: 3, // Morpho, unused: the proxy holds the principal
                loanToken: loanToken,
                loanAmount: amount,
                maxFlashFee: 0,
                ops: ops,
                minProfitAmount: 0
            })
        );
    }

    function _execute(bytes memory plan) internal returns (bool ok, bytes memory ret, uint256 gasUsed) {
        bytes memory cd = abi.encodeWithSignature("execute(bytes)", plan);
        vm.prank(OPERATOR, OPERATOR);
        uint256 g = gasleft();
        (ok, ret) = EXEC.call(cd);
        gasUsed = g - gasleft();
    }

    /// Swap and Mint counts on `pair`, and the reserves the LAST swap priced
    /// on: `swap` emits Sync then Swap, so they are the Sync before the last.
    function _pairLogs(Vm.Log[] memory logs, address pair)
        internal
        pure
        returns (uint256 swaps, uint256 mints, uint256[2] memory priced)
    {
        // Scalars, not two memory arrays: `prev = last` on memory arrays
        // copies the reference, and both would end up holding the last Sync.
        uint256 prev0;
        uint256 prev1;
        uint256 last0;
        uint256 last1;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != pair) continue;
            bytes32 t = logs[i].topics[0];
            if (t == SWAP_TOPIC) {
                ++swaps;
            } else if (t == MINT_TOPIC) {
                ++mints;
            } else if (t == SYNC_TOPIC) {
                (prev0, prev1) = (last0, last1);
                (last0, last1) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        priced = [prev0, prev1];
    }

    function _formula(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * FEE;
        return (inWithFee * reserveOut) / (reserveIn * 10_000 + inWithFee);
    }

    /// Intrinsic calldata gas of `execute(plan)`: 4 per zero byte, 16 per other.
    function _calldataGas(bytes memory plan) internal pure returns (uint256 g) {
        bytes memory cd = abi.encodeWithSignature("execute(bytes)", plan);
        for (uint256 i = 0; i < cd.length; ++i) {
            g += cd[i] == 0 ? 4 : 16;
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (hay.length < needle.length) return false;
        for (uint256 i = 0; i + needle.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    function _why(bytes memory ret) internal pure returns (string memory) {
        return string(abi.encodePacked("revert: ", vm.toString(ret)));
    }
}
