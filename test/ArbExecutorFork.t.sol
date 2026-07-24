// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {IUniV3SwapRouter} from "../src/interfaces/IUniV3SwapRouter.sol";
import {PoolKey} from "../src/interfaces/IPoolManager.sol";

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

    // ─── Task 3 — real payable native-IN venues ────────────────────────
    /// Lido stETH (Curve stETH/ETH pool's coin(1)).
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    /// Curve.fi ETH/stETH legacy StableSwap pool. coin(0) = native ETH
    /// (sentinel 0xEeee…EEeE), coin(1) = stETH. Confirmed live + deep at
    /// FORK_BLOCK via `get_dy(0,1,1e18)` (see task-3-report.md).
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    /// Fluid DexT1 "Dex USDC-ETH" pool (Etherscan-labeled). token0 = USDC,
    /// token1 = native ETH (Fluid's own 0xEeee…EEeE sentinel) — confirmed
    /// via the real `DexReservesResolver.getAllPoolsReservesAdjusted()`
    /// (0xC93876C0EEd99645DD53937b25433e311881A27C) at FORK_BLOCK.
    address constant FLUID_USDC_ETH_POOL = 0x836951EB21F3Df98273517B7249dCEFF270d34bf;
    /// Uniswap Universal Router (current V4-aware deployment) — same
    /// address the bot's `decode.rs` pins as `UNI_V4_UNIVERSAL_ROUTER`.
    /// `execute(bytes,bytes[],uint256)` is payable and internally performs
    /// its OWN `PoolManager.unlock()` + `unlockCallback` — proving a
    /// callback-style DEX is reachable via `FLAG_NATIVE_IN` without this
    /// executor's in-contract callback ever being invoked.
    address constant V4_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

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
    /// Native-ETH input to a plain payable DEX call — `target.call{value:
    /// amount}(callData)`. See `GenericSequenceLib.FLAG_NATIVE_IN` for the
    /// full containment/ceiling rationale.
    uint32 constant FLAG_NATIVE_IN = 1 << 5;

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

    // ─── Task 3 — native-IN venue selectors/offsets ────────────────────
    /// Curve legacy `exchange(int128,int128,uint256,uint256) payable` —
    /// selector pinned by `cast sig "exchange(int128,int128,uint256,uint256)"`
    /// and confirmed callable against the real, deployed `CURVE_STETH_POOL`
    /// at FORK_BLOCK (see task-3-report.md). All four params are static
    /// scalars (no dynamic types), so the ABI encoding is a flat concat:
    /// selector(4) + i(32) + j(32) = byte 68 is where `dx` starts.
    bytes4 constant CURVE_STETH_EXCHANGE_SELECTOR = 0x3df02124;
    uint16 constant CURVE_STETH_AMOUNT_POS = 68;

    /// WETH9 `deposit() payable` — standard, well-known selector. Used as a
    /// `FLAG_NATIVE_IN` op to wrap native ETH back to WETH, closing a
    /// native-IN cycle back to the loanToken without a dedicated "wrap" op
    /// flag (mirrors `FLAG_WETH_UNWRAP`'s unwrap direction).
    bytes4 constant WETH_DEPOSIT_SELECTOR = 0xd0e30db0;

    /// Fluid DexT1 pool `swapIn(bool swap0to1_, uint256 amountIn_, uint256
    /// amountOutMin_, address to_) public payable returns (uint256)` —
    /// confirmed against Instadapp's `fluid-contracts-public` DexT1 core
    /// module (`poolT1/coreModule/core/main.sol`): the pool asserts
    /// `msg.value == amountIn_` and that the resolved input-side token
    /// equals its native-ETH sentinel whenever `msg.value > 0`. Selector
    /// pinned by `cast sig "swapIn(bool,uint256,uint256,address)"`.
    bytes4 constant FLUID_SWAP_IN_SELECTOR = 0x2668dfaa;

    /// Uniswap Universal Router `execute(bytes,bytes[],uint256)` selector —
    /// same constant the bot's `decode.rs` pins as
    /// `UNIVERSAL_ROUTER_EXECUTE_SELECTOR`.
    bytes4 constant UNIVERSAL_ROUTER_EXECUTE_SELECTOR = 0x3593564c;
    /// V4-periphery `Actions.sol` byte constants (v4-periphery is not
    /// vendored in this repo; pinned via the public source, see
    /// task-3-report.md).
    uint8 constant V4_ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant V4_ACTION_SETTLE_ALL = 0x0c;
    uint8 constant V4_ACTION_TAKE_ALL = 0x0f;
    /// Universal Router `Commands.sol` V4_SWAP command byte.
    uint8 constant V4_ROUTER_CMD_V4_SWAP = 0x10;

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

        address[] memory targets = new address[](6);
        targets[0] = V4_POOL_MANAGER;
        targets[1] = CURVE_ROUTER_NG;
        targets[2] = CURVE_STETH_POOL;
        targets[3] = WETH; // FLAG_NATIVE_IN -> WETH9.deposit(), closing a native cycle
        targets[4] = FLUID_USDC_ETH_POOL;
        targets[5] = V4_UNIVERSAL_ROUTER;

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

    /// Mirrors Uniswap v4-periphery's `IV4Router.ExactInputSingleParams`
    /// (same field order) — reproduced locally since v4-periphery isn't
    /// vendored in this repo; only used to ABI-encode the
    /// `SWAP_EXACT_IN_SINGLE` action's params for the REAL, deployed
    /// `V4_UNIVERSAL_ROUTER`.
    struct V4RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    /// Builds `UniversalRouter.execute(commands, inputs, deadline)` calldata
    /// for a single native-ETH-in exact-in V4 swap (currency0 = address(0)
    /// = native ETH, sold for `tokenOut`), reaching the pool through the
    /// router's OWN `unlockCallback` rather than this executor's — the
    /// mechanical proof that the in-contract V4 callback is optional.
    function _v4RouterNativeExactInCalldata(address tokenOut, uint24 fee, int24 tickSpacing, uint256 amountIn)
        internal
        view
        returns (bytes memory)
    {
        PoolKey memory key = PoolKey({
            currency0: address(0), currency1: tokenOut, fee: fee, tickSpacing: tickSpacing, hooks: address(0)
        });
        V4RouterExactInputSingleParams memory swapParams = V4RouterExactInputSingleParams({
            poolKey: key,
            zeroForOne: true, // selling currency0 (native ETH) for currency1 (tokenOut)
            amountIn: uint128(amountIn),
            amountOutMinimum: 0,
            hookData: ""
        });

        bytes memory actions =
            abi.encodePacked(V4_ACTION_SWAP_EXACT_IN_SINGLE, V4_ACTION_SETTLE_ALL, V4_ACTION_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(swapParams);
        params[1] = abi.encode(address(0), amountIn); // SETTLE_ALL(currency0, maxAmount)
        params[2] = abi.encode(tokenOut, uint256(0)); // TAKE_ALL(currency1, minAmount)

        bytes memory commands = abi.encodePacked(V4_ROUTER_CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        return abi.encodeWithSelector(UNIVERSAL_ROUTER_EXECUTE_SELECTOR, commands, inputs, block.timestamp + 1 hours);
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

    // ═══════════════════════════════════════════════════════════════
    // Task 3 — real payable native-IN venues (Curve + Fluid) + V4-via-
    // router parity. Tests 1-3 above used mocks/in-contract callbacks for
    // native ETH; these prove `FLAG_NATIVE_IN`'s `target.call{value:
    // amount}` routes through REAL, currently-liquid payable DEXes on this
    // fork, and that a callback-style DEX (V4) is equally reachable through
    // its own periphery ROUTER instead of this executor's in-contract
    // `unlockCallback`.
    // ═══════════════════════════════════════════════════════════════

    /// WETH_UNWRAP -> `FLAG_NATIVE_IN` `exchange{value}` on the REAL Curve
    /// stETH/ETH pool (ETH -> stETH) -> direct-call `exchange` back (stETH
    /// -> native ETH, same pool, other direction) -> `FLAG_NATIVE_IN`
    /// `WETH9.deposit{value}` wraps back to loanToken, closing the cycle.
    /// Proves a real payable pool (no ERC20 approval path at all for the
    /// ETH leg) routes under containment + the per-op ceiling.
    function test_fork_nativeIn_curve() public forkOnly {
        uint256 loanAmount = 2e18; // 2 WETH
        uint256 unwrapAmount = 1e18; // 1 WETH round-trips through the native Curve cycle
        // Buffer: Curve stETH/ETH pool fee is ~0.04% per hop, two hops
        // (ETH->stETH->ETH) is ~0.08% of 1 ETH (~0.0008 ETH); 0.02 WETH is
        // ample margin (same sizing as test_fork_splitRoute_reconverges).
        uint256 buffer = 0.02e18;
        deal(WETH, address(exec), buffer);

        Op[] memory ops = new Op[](4);
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
        // op1: native ETH -> stETH via `FLAG_NATIVE_IN` `call{value}` on the
        // real Curve stETH/ETH pool (coin(0)=ETH -> coin(1)=stETH). `dx` is
        // embedded directly (matches the literal `amountIn` used for the
        // forwarded value), so no calldata patch is needed.
        ops[1] = Op({
            target: CURVE_STETH_POOL,
            value: 0,
            amountIn: unwrapAmount,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_NATIVE_IN,
            srcToken: address(0),
            outToken: STETH,
            callData: abi.encodeWithSelector(
                CURVE_STETH_EXCHANGE_SELECTOR, int128(0), int128(1), unwrapAmount, uint256(1)
            )
        });
        // op2: prevReturn stETH -> native ETH, same pool, reverse direction
        // (coin(1)=stETH -> coin(0)=ETH). This is a plain direct-call op
        // (approve + call, NOT `FLAG_NATIVE_IN` — the input here is the
        // ERC20 stETH received above, not native ETH); `dx` is patched at
        // `CURVE_STETH_AMOUNT_POS` from the previous op's output.
        ops[2] = Op({
            target: CURVE_STETH_POOL,
            value: 0,
            amountIn: 0,
            fromAmountPos: CURVE_STETH_AMOUNT_POS,
            returnAmountPos: 0,
            flags: FLAG_USE_PREV_RETURN,
            srcToken: STETH,
            outToken: address(0),
            callData: abi.encodeWithSelector(
                CURVE_STETH_EXCHANGE_SELECTOR, int128(1), int128(0), uint256(0), uint256(1)
            )
        });
        // op3: prevReturn native ETH -> WETH via `FLAG_NATIVE_IN`
        // `WETH9.deposit{value}`, closing the cycle back to loanToken.
        ops[3] = Op({
            target: WETH,
            value: 0,
            amountIn: 0,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_NATIVE_IN | FLAG_USE_PREV_RETURN,
            srcToken: address(0),
            outToken: WETH,
            callData: abi.encodeWithSelector(WETH_DEPOSIT_SELECTOR)
        });

        // Same reasoning as the earlier tests — a non-reverting execute()
        // already proves GenericSequenceLib's repay + containment gates
        // held internally (including the FLAG_NATIVE_IN per-op ceiling on
        // both op1 and op3); Morpho pulls the flash principal back before
        // returning, so we bound the realized residual against the
        // pre-funded buffer.
        _runArb(ops, WETH, loanAmount, FLASH_PROVIDER_MORPHO);

        uint256 residual = IERC20(WETH).balanceOf(address(exec));
        assertGe(residual, buffer / 2, "round-trip lost more than expected (repay/containment may have masked a bug)");
        assertLe(residual, buffer, "residual exceeds pre-funded buffer (unexpected profit or accounting bug)");
    }

    /// WETH_UNWRAP -> `FLAG_NATIVE_IN` `swapIn{value}` on the REAL Fluid
    /// DexT1 "Dex USDC-ETH" pool (native ETH -> USDC) -> direct-call V3
    /// 0.05%-tier (USDC -> WETH) closes the cycle. Proves a SECOND,
    /// independent real payable venue (different ABI shape than Curve —
    /// `swapIn(bool,uint256,uint256,address)` vs `exchange(int128,int128,
    /// uint256,uint256)`) routes correctly under `FLAG_NATIVE_IN`.
    function test_fork_nativeIn_fluid() public forkOnly {
        uint256 loanAmount = 2e18; // 2 WETH
        uint256 unwrapAmount = 1e18; // 1 WETH round-trips through native Fluid + V3
        // Buffer: pre-funded profit-buffer, sized like the other cycle
        // tests. Measured at FORK_BLOCK this particular real Fluid pool
        // (fee=1000) + V3 0.05%-tier close leg nets a SMALL GAIN (~0.4% of
        // the 1 ETH notional) rather than a loss — real cross-venue price
        // disagreement, exactly what an arb captures; this test doesn't
        // assert on it either way (see class doc: repay + containment, not
        // profitability), so the bound below is loose enough to accept a
        // modest gain OR loss without masking a real accounting bug.
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
        // op1: native ETH -> USDC via `FLAG_NATIVE_IN` `call{value}` on the
        // real Fluid DexT1 USDC/ETH pool. Pool's token0=USDC, token1=native
        // ETH, so `swap0to1_=false` sells token1 (ETH) for token0 (USDC).
        ops[1] = Op({
            target: FLUID_USDC_ETH_POOL,
            value: 0,
            amountIn: unwrapAmount,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_NATIVE_IN,
            srcToken: address(0),
            outToken: USDC,
            callData: abi.encodeWithSelector(FLUID_SWAP_IN_SELECTOR, false, unwrapAmount, uint256(1), address(exec))
        });
        // op2: prevReturn USDC -> WETH via the real 0.05%-tier V3 pool,
        // closing the cycle.
        ops[2] = Op({
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

        _runArb(ops, WETH, loanAmount, FLASH_PROVIDER_MORPHO);

        uint256 residual = IERC20(WETH).balanceOf(address(exec));
        assertGe(residual, buffer / 2, "round-trip lost more than expected (repay/containment may have masked a bug)");
        assertLe(
            residual,
            buffer * 2,
            "residual far exceeds pre-funded buffer (accounting bug, not just cross-venue price gain)"
        );
    }

    /// Reaches the SAME native-V4 pool `test_fork_v4_nativeLeg_arbCycle`
    /// swaps through (ETH/DAI fee=3000 tickSpacing=60 hook=0) via TWO
    /// independent paths from an IDENTICAL starting fork state
    /// (`vm.snapshotState`/`vm.revertToState` brackets the two runs):
    ///   Path A — the existing in-contract `FLAG_V4_UNLOCK` leg (this
    ///            executor's own `unlockCallback` arms the PoolManager).
    ///   Path B — `FLAG_NATIVE_IN` `call{value}` into the REAL Uniswap
    ///            Universal Router's `execute(...)`, which performs its OWN
    ///            `unlock()`/`unlockCallback` entirely inside the router —
    ///            this executor's `unlockCallback` is never entered.
    /// Both paths sell the identical `unwrapAmount` of native ETH into the
    /// identical pool at the identical block; asserting the DAI output
    /// matches within a tight tolerance proves the in-contract V4 callback
    /// is OPTIONAL — any callback-style DEX can be reached through its own
    /// router as a plain payable op.
    ///
    /// Buffer is sized to DWARF loanAmount + unwrapAmount so repay +
    /// containment hold trivially regardless of swap outcome — this test
    /// isolates ROUTING PARITY, not round-trip economics (that is what
    /// tests 1/2/3 above already assert).
    function test_fork_v4_nativeIn_via_router_parity() public forkOnly {
        uint256 loanAmount = 1e18; // 1 WETH
        uint256 unwrapAmount = 0.05e18; // small, realistic native-in leg
        uint256 buffer = 1e18; // dwarfs loanAmount + unwrapAmount

        uint256 snap = vm.snapshotState();

        // ── Path A: legacy in-contract V4 unlockCallback (direct PoolManager) ──
        deal(WETH, address(exec), buffer);
        Op[] memory opsA = new Op[](2);
        opsA[0] = Op({
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
        opsA[1] = Op({
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
        _runArb(opsA, WETH, loanAmount, FLASH_PROVIDER_MORPHO);
        uint256 daiOutA = IERC20(DAI).balanceOf(address(exec));

        vm.revertToState(snap);

        // ── Path B: SAME pool, via FLAG_NATIVE_IN through the REAL V4
        // UniversalRouter — this executor's unlockCallback is never entered. ──
        deal(WETH, address(exec), buffer);
        Op[] memory opsB = new Op[](2);
        opsB[0] = Op({
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
        opsB[1] = Op({
            target: V4_UNIVERSAL_ROUTER,
            value: 0,
            amountIn: unwrapAmount,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_NATIVE_IN,
            srcToken: address(0),
            outToken: DAI,
            callData: _v4RouterNativeExactInCalldata(DAI, 3000, 60, unwrapAmount)
        });
        _runArb(opsB, WETH, loanAmount, FLASH_PROVIDER_MORPHO);
        uint256 daiOutB = IERC20(DAI).balanceOf(address(exec));

        assertGt(daiOutA, 0, "legacy callback path produced no DAI output");
        assertGt(daiOutB, 0, "router path produced no DAI output");
        // Same pool + identical starting state + identical input -> outputs
        // must match tightly. A gross routing mismatch (wrong pool, wrong
        // direction, wrong amount) would blow well past this bound.
        assertApproxEqRel(daiOutB, daiOutA, 0.001e18); // 0.1% tolerance
    }
}
