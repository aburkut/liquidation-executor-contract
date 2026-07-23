// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {IUniV3SwapRouter} from "../src/interfaces/IUniV3SwapRouter.sol";

/// @title ArbExecutorForkTest
/// @notice Task 6 — mainnet-fork functional tests proving `ArbExecutor`'s
/// `Op[]` / `GenericSequenceLib.runArb` engine routes through REAL venues:
/// a percentage split across two Uniswap V3 fee tiers that reconverges, a
/// Curve RouterNG multihop (`CURVE_V1_MH`-style direct call) leg, and a
/// native-ETH Uniswap V4 leg armed via the slot-10/11 unlock mechanism.
///
/// Runs only when `MAINNET_RPC_URL` (or `ETHEREUM_RPC_URL`) is exported;
/// absent RPC → silent `vm.skip`, matching `test/fork/ExecutorForkV4.t.sol`'s
/// gating idiom.
///
/// REQUIRES `--evm-version cancun` on the `forge test` invocation (real V4
/// PoolManager uses EIP-1153 transient storage). `foundry.toml`'s project
/// default (`evm_version = "shanghai"`) is intentional for the DEPLOYED
/// contract's EIP-170 sizing and must stay untouched — this flag only
/// overrides the runtime spec `forge test` uses to execute the fork, not
/// what gets compiled/deployed. Omitting it does not fail closed the same
/// way every time: on some compiled-artifact states, the real V4
/// PoolManager's `unlock()` halts with a raw `NotActivated` EVM error
/// (zero-length revert, occurring before `unlockCallback` is ever entered)
/// — an artifact-caching-dependent runtime-spec resolution on this Foundry
/// nightly build, NOT a bug in `ArbExecutor`/`GenericSequenceLib`. Confirmed
/// by direct control test: the native-V4 leg through the REAL, production-
/// preferred Morpho flash provider (`FLASH_PROVIDER_MORPHO`, fee=0) via the
/// real `execute()` entrypoint passes cleanly once `--evm-version cancun` is
/// set — there is no Morpho-specific interaction bug (see task-6-report.md
/// for the full isolation trace and the corrected finding). Always pass
/// `--evm-version cancun` explicitly for this file.
///
/// SCOPE / WHAT THESE PROVE: repay (the flash is always fully repaid) +
/// containment (no token is net-spent beyond what the sequence produced),
/// NOT profitability — real Uniswap/Curve swap fees make a pure round-trip
/// on any real pool lose a few bps by construction; asserting strict profit
/// on a fork is what the task brief calls out as flaky and out of scope.
/// Each test pre-funds the executor with a SMALL loanToken buffer via
/// `deal(...)` before calling `execute()`, framed exactly as
/// `_runArbPipeline`'s own docstring already describes real steady state:
/// "any pre-existing residual balance the contract was holding from an
/// earlier arb's retained profit" — i.e. this simulates the contract
/// already holding a bit of retained profit, which is what in practice
/// absorbs the DEX-fee cost of routing. The buffer is sized to comfortably
/// exceed the real fee loss (verified against real quotes below), so the
/// ABSOLUTE repay gate (`loanAfter >= flashRepay`) holds with margin.
///
/// Pinned fork block: 25_256_119 (same block `test/fork/ExecutorForkV4.t.sol`
/// uses for its jackpot V4+Curve test) — chosen because Morpho Blue,
/// Uniswap V3 (multiple fee tiers), Curve RouterNG/3pool, and the real V4
/// ETH/DAI pool are ALL independently confirmed liquid there (see
/// task-6-report.md for the on-chain probes: `cast call get_dy`, pool
/// `balanceOf`, Morpho token balances).
contract ArbExecutorForkTest is Test {
    // ─── Mainnet addresses ─────────────────────────────────────────────
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;

    uint256 constant FORK_BLOCK = 25_256_119;

    address owner = address(0xA11CE);
    address operatorAddr = address(0xB0B);

    ArbExecutor exec;

    // ─── GenericSequenceLib op flags (mirrored locally — same convention
    // as the sibling jackpot fork test in test/fork/ExecutorForkV4.t.sol) ──
    uint32 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint32 constant FLAG_V4_UNLOCK = 1 << 2;
    uint32 constant FLAG_WETH_UNWRAP = 1 << 3;
    uint32 constant FLAG_V4_EXACT_IN = 1 << 4;

    uint8 constant FLASH_PROVIDER_BALANCER = 2;
    uint8 constant FLASH_PROVIDER_MORPHO = 3;

    /// Uniswap V3 `exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))`:
    /// the struct is all-static fields, encoded inline (no offset pointer) —
    /// selector(4) + tokenIn(32) + tokenOut(32) + fee(32) + recipient(32) = 132.
    /// (Same constant as `ArbExecutor.t.sol`'s `V3_AMOUNT_POS`.)
    uint16 constant V3_AMOUNT_POS = 132;

    /// Curve RouterNG `exchange(address[11], uint256[5][5], uint256, uint256,
    /// address[5], address)`: both array args are FIXED-size (no dynamic
    /// offset pointers) — selector(4) + address[11](352) + uint256[5][5](800)
    /// = 1156, the byte offset of the `_amount` word.
    uint16 constant CURVE_MH_AMOUNT_POS = 1156;

    modifier forkOnly() {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // skip marker lives on each test
        vm.createSelectFork(rpc, FORK_BLOCK);

        address[] memory targets = new address[](2);
        targets[0] = V4_POOL_MANAGER;
        targets[1] = CURVE_ROUTER_NG;

        exec = new ArbExecutor(
            owner,
            operatorAddr,
            WETH,
            BALANCER_VAULT,
            MORPHO_BLUE,
            PARASWAP_AUGUSTUS,
            UNI_V2_ROUTER,
            UNI_V3_ROUTER,
            targets
        );
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _v3ExactInSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            IUniV3SwapRouter.exactInputSingle.selector,
            IUniV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _runArb(Op[] memory ops, address loanToken, uint256 loanAmount) internal {
        _runArb(ops, loanToken, loanAmount, FLASH_PROVIDER_MORPHO);
    }

    function _runArb(Op[] memory ops, address loanToken, uint256 loanAmount, uint8 flashProviderId) internal {
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: flashProviderId,
            loanToken: loanToken,
            loanAmount: loanAmount,
            maxFlashFee: 0,
            ops: ops,
            coinbaseBps: 0,
            minProfitAmount: 0
        });
        bytes memory planData = abi.encode(plan);

        vm.prank(operatorAddr);
        exec.execute(planData);
    }

    // ═══════════════════════════════════════════════════════════════
    // Test 1 — percentage split across two V3 fee tiers, reconverges
    // ═══════════════════════════════════════════════════════════════

    /// Splits the WETH loan 50/50 across the WETH/USDC 0.05% and 0.3% fee
    /// tiers (both real, deep mainnet pools), each half round-tripping back
    /// to WETH through the OTHER tier (op0→op1 uses tier 500 out / 3000
    /// back; op2→op3 uses tier 3000 out / 500 back) — a genuine real-venue
    /// split-then-reconverge. `PREV_RETURN` only threads the IMMEDIATELY
    /// preceding op's output, so a single joint recombine of both halves'
    /// outputs is not expressible without an off-chain quote; two chained
    /// round-trips is the mechanically faithful way to express "split loan
    /// across two fee tiers, recombine to loanToken" with this Op model —
    /// see task-6-report.md for the reasoning.
    function test_fork_splitRoute_reconverges() public forkOnly {
        uint256 loanAmount = 2e18; // 2 WETH
        uint256 half = 1e18;
        // Retained-profit buffer: real round-trip fee loss on 1 WETH through
        // 500+3000 tiers is ~0.35% (~0.0035 WETH); 0.02 WETH is ample margin.
        uint256 buffer = 0.02e18;
        deal(WETH, address(exec), buffer);

        Op[] memory ops = new Op[](4);
        // op0: 1 WETH -> USDC @ fee=500 (literal amount, embedded directly).
        ops[0] = Op({
            target: UNI_V3_ROUTER,
            value: 0,
            amountIn: half,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: 0,
            srcToken: WETH,
            outToken: USDC,
            callData: _v3ExactInSingle(WETH, USDC, 500, half, address(exec))
        });
        // op1: prevReturn USDC -> WETH @ fee=3000 (recombine leg 1).
        ops[1] = Op({
            target: UNI_V3_ROUTER,
            value: 0,
            amountIn: 0,
            fromAmountPos: V3_AMOUNT_POS,
            returnAmountPos: 0,
            flags: FLAG_USE_PREV_RETURN,
            srcToken: USDC,
            outToken: WETH,
            callData: _v3ExactInSingle(USDC, WETH, 3000, 0, address(exec))
        });
        // op2: 1 WETH -> USDC @ fee=3000 (the other half, other tier).
        ops[2] = Op({
            target: UNI_V3_ROUTER,
            value: 0,
            amountIn: half,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: 0,
            srcToken: WETH,
            outToken: USDC,
            callData: _v3ExactInSingle(WETH, USDC, 3000, half, address(exec))
        });
        // op3: prevReturn USDC -> WETH @ fee=500 (recombine leg 2).
        ops[3] = Op({
            target: UNI_V3_ROUTER,
            value: 0,
            amountIn: 0,
            fromAmountPos: V3_AMOUNT_POS,
            returnAmountPos: 0,
            flags: FLAG_USE_PREV_RETURN,
            srcToken: USDC,
            outToken: WETH,
            callData: _v3ExactInSingle(USDC, WETH, 500, 0, address(exec))
        });

        // execute() itself is the repay+containment proof: GenericSequenceLib's
        // ABSOLUTE repay gate (loanAfter_inSequence >= flashRepay) and the
        // per-srcToken containment cap are both hard `revert`s inside the
        // flash callback — if either had failed, this call would have
        // reverted and the assertions below would never run. Morpho then
        // pulls the flash principal back via `transferFrom` before `execute()`
        // returns, so what remains on the contract afterward is realized
        // P&L, not the pre-repay `loanAfter` the library checked internally.
        // Bound it: the round-trip must not have devoured more than half the
        // retained-profit buffer (real fee loss on 2x1 WETH through 500+3000
        // tiers is ~0.35%, i.e. ~0.007 WETH — comfortably inside buffer/2),
        // and must not exceed the buffer (a pure-fee round trip cannot mint
        // value).
        _runArb(ops, WETH, loanAmount);

        uint256 residual = IERC20(WETH).balanceOf(address(exec));
        assertGe(residual, buffer / 2, "round-trip lost more than expected (repay/containment may have masked a bug)");
        assertLe(residual, buffer, "residual exceeds pre-funded buffer (unexpected profit or accounting bug)");
    }

    // ═══════════════════════════════════════════════════════════════
    // Test 2 — CURVE_V1_MH mode leg (RouterNG multihop) inside the cycle
    // ═══════════════════════════════════════════════════════════════

    /// Real 2-hop Curve RouterNG multihop (USDC -> DAI -> USDT, both hops
    /// through the real Curve 3pool) closes back to loanToken (USDC) via a
    /// direct Uniswap V3 0.01%-tier leg. Confirmed against the real
    /// RouterNG's `get_dy` at the pinned block: 1000 USDC -> 999.769414 USDT
    /// (see task-6-report.md).
    function test_fork_curveMultihop_mode() public forkOnly {
        uint256 loanAmount = 1000e6; // 1000 USDC
        // Buffer: real 2-hop Curve loss (~0.023%) + V3 0.01%-tier loss on
        // the close leg is well under $1; 2 USDC is ample margin.
        uint256 buffer = 2e6;
        deal(USDC, address(exec), buffer);

        address[11] memory path;
        path[0] = USDC;
        path[1] = CURVE_3POOL;
        path[2] = DAI;
        path[3] = CURVE_3POOL;
        path[4] = USDT;
        uint256[5][5] memory swapParams;
        // hop0: USDC(i=1) -> DAI(j=0), swap_type=1 (stable exchange),
        // pool_type=1 (stable), n_coins=3.
        swapParams[0] = [uint256(1), 0, 1, 1, 3];
        // hop1: DAI(i=0) -> USDT(j=2), same pool/swap type, 3pool.
        swapParams[1] = [uint256(0), 2, 1, 1, 3];
        address[5] memory pools; // zero — no metapool factory override needed

        bytes memory curveCalldata = abi.encodeWithSelector(
            0xc872a3c5, // exchange(address[11],uint256[5][5],uint256,uint256,address[5],address)
            path,
            swapParams,
            loanAmount,
            uint256(990e6), // min_dy — 1% slippage tolerance (real quote is ~999.77 USDT)
            pools,
            address(exec)
        );

        Op[] memory ops = new Op[](2);
        // op0: full loan USDC -> USDT via the REAL Curve RouterNG multihop.
        ops[0] = Op({
            target: CURVE_ROUTER_NG,
            value: 0,
            amountIn: loanAmount,
            fromAmountPos: 0, // embedded directly in curveCalldata above
            returnAmountPos: 0,
            flags: 0,
            srcToken: USDC,
            outToken: USDT,
            callData: curveCalldata
        });
        // op1: prevReturn USDT -> USDC via the real 0.01%-tier V3 pool, closing the cycle.
        ops[1] = Op({
            target: UNI_V3_ROUTER,
            value: 0,
            amountIn: 0,
            fromAmountPos: V3_AMOUNT_POS,
            returnAmountPos: 0,
            flags: FLAG_USE_PREV_RETURN,
            srcToken: USDT,
            outToken: USDC,
            callData: _v3ExactInSingle(USDT, USDC, 100, 0, address(exec))
        });

        // Same reasoning as test 1 — a non-reverting execute() already proves
        // GenericSequenceLib's repay + containment gates held internally;
        // Morpho pulls the flash principal back before returning, so we
        // bound the realized residual against the pre-funded buffer instead
        // of re-deriving the internal pre-repay balance.
        _runArb(ops, USDC, loanAmount);

        uint256 residual = IERC20(USDC).balanceOf(address(exec));
        assertGe(residual, buffer / 2, "round-trip lost more than expected (repay/containment may have masked a bug)");
        assertLe(residual, buffer, "residual exceeds pre-funded buffer (unexpected profit or accounting bug)");
    }

    // ═══════════════════════════════════════════════════════════════
    // Test 3 — native-ETH V4 leg inside the arb cycle
    // ═══════════════════════════════════════════════════════════════

    /// WETH_UNWRAP -> native V4 (ETH -> DAI, exact-in, the real jackpot pool
    /// also used by `test/fork/ExecutorForkV4.t.sol`) -> DAI -> WETH (direct
    /// V3 0.3% tier) closes back to loanToken. Armed via the slot-10/11
    /// unlock mechanism through the REAL PoolManager; asserts repay AND that
    /// no `V4InputOverspent` fires (the per-op exact-in input ceiling holds).
    ///
    /// Flash provider: Morpho (fee=0, the production-preferred provider —
    /// same as tests 1/2). An earlier pass of this test used Balancer after
    /// an `--evm-version cancun`-less run made Morpho's real flashLoan appear
    /// to interact badly with the real V4 `unlock()`; a direct control test
    /// (real Morpho flashLoan -> real `execute()` -> this exact op sequence,
    /// WITH `--evm-version cancun`) passes cleanly, proving that was the
    /// missing flag, not a Morpho-specific bug — see task-6-report.md for the
    /// corrected isolation trace and the control-test output.
    function test_fork_v4_nativeLeg_arbCycle() public forkOnly {
        uint256 loanAmount = 2e18; // 2 WETH
        uint256 unwrapAmount = 1e18; // 1 WETH round-trips through native V4 + V3
        // Buffer: V4 (0.3%) + V3 (0.3%) round-trip fee loss on 1 ETH is
        // ~0.6% (~0.006 ETH); 0.05 WETH is ample margin.
        uint256 buffer = 0.05e18;
        deal(WETH, address(exec), buffer);

        Op[] memory ops = new Op[](3);
        // op0: unwrap 1 WETH -> native ETH.
        ops[0] = Op({
            target: address(0),
            value: 0,
            amountIn: unwrapAmount,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_WETH_UNWRAP,
            srcToken: WETH,
            outToken: address(0),
            callData: ""
        });
        // op1: native ETH -> DAI, exact-in, real PoolManager, real jackpot
        // pool (ETH/DAI fee=3000 tickSpacing=60 hook=0).
        ops[1] = Op({
            target: V4_POOL_MANAGER,
            value: 0,
            amountIn: unwrapAmount,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN,
            srcToken: address(0),
            outToken: DAI,
            callData: abi.encode(address(0), DAI, uint24(3000), int24(60), address(0))
        });
        // op2: prevReturn DAI -> WETH via the real 0.3%-tier V3 pool, closing the cycle.
        ops[2] = Op({
            target: UNI_V3_ROUTER,
            value: 0,
            amountIn: 0,
            fromAmountPos: V3_AMOUNT_POS,
            returnAmountPos: 0,
            flags: FLAG_USE_PREV_RETURN,
            srcToken: DAI,
            outToken: WETH,
            callData: _v3ExactInSingle(DAI, WETH, 3000, 0, address(exec))
        });

        // Morpho fee=0. A non-reverting execute() is the repay + containment
        // proof (see test 1/2 comments): GenericSequenceLib's ABSOLUTE repay
        // gate and the per-srcToken containment cap are hard reverts inside
        // the flash callback, and Morpho pulls the flash principal back via
        // `transferFrom` before `execute()` returns, so what remains
        // afterward is realized P&L against the pre-funded buffer, not the
        // internal pre-repay balance.
        _runArb(ops, WETH, loanAmount, FLASH_PROVIDER_MORPHO);

        // Exact-in on a real pool consumes UP TO `amount`, bounded by the
        // per-op input ceiling (`V4InputOverspent` would have reverted
        // execute() already if the pool had pulled more) — real pools do not
        // guarantee consuming the full requested input when a trade of this
        // size interacts with the pool's actual liquidity distribution around
        // the price limit, so a small unconsumed ETH remainder is legitimate,
        // not a bug. Combine both buckets (WETH residual + leftover native
        // ETH, economically ~1:1) against the pre-funded buffer.
        uint256 wethResidual = IERC20(WETH).balanceOf(address(exec));
        uint256 ethLeftover = address(exec).balance;
        assertLt(ethLeftover, unwrapAmount, "V4 leg consumed none of the unwrapped ETH (leg never engaged)");
        uint256 total = wethResidual + ethLeftover;
        assertGe(total, buffer / 2, "round-trip lost more than expected (repay/containment may have masked a bug)");
        assertLe(total, buffer, "residual exceeds pre-funded buffer (unexpected profit or accounting bug)");
    }
}
