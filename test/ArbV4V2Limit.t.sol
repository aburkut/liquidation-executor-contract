// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ExecutorDeploy} from "./support/ExecutorDeploy.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {GenericSequenceLib} from "../src/libraries/GenericSequenceLib.sol";
import {CoinbasePaymentLib} from "../src/libraries/CoinbasePaymentLib.sol";
import {DirectSwapLib} from "../src/libraries/DirectSwapLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniV2Router} from "./mocks/MockUniV2Router.sol";
import {MockUniV3Router} from "./mocks/MockUniV3Router.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";
import {MockUniV2Pair} from "./mocks/MockDirectPools.sol";

/// A WETH9-shaped mock with BOTH `deposit` and `withdraw`, backed by a real
/// ETH reserve (`vm.deal`-funded). The arb executor's `weth` immutable must
/// answer `withdraw` (for `FLAG_WETH_UNWRAP`) and `deposit` (for the native
/// re-wrap `FLAG_WETH_WRAP`).
contract MockWETHFull is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: ETH transfer failed");
    }

    receive() external payable {}
}

/// @title ArbV4V2LimitTest
/// @notice Unit coverage for PR #747's "Minimal contract change": V4 exact-in
/// with a caller `sqrtPriceLimitX96` (192-byte single-hop blob), the native
/// re-wrap of what a short fill left (`FLAG_WETH_WRAP | FLAG_USE_PRODUCED`),
/// and a V2 direct swap to a target price (96-byte callData). Driven through
/// the REAL `ArbExecutor` entrypoint (execute → flash callback → runArb →
/// DELEGATECALL / unlockCallback), the same path production takes.
///
/// Deterministic mocks, so realized profit `G` is exact: a plan with
/// `minProfitAmount == G` must land and `G + 1` must revert
/// `InsufficientProfit(G, G+1)` — the task's G / G+1 floor binding — and each
/// such pair runs from its own `vm.snapshotState` so the second send sees the
/// first send's pre-state, not its proceeds.
contract ArbV4V2LimitTest is Test {
    ArbExecutor public exec;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockWETHFull public weth;

    MockMorphoBlue public morpho;
    MockBalancerVault public balancerFlash;
    MockUniV2Router public uniV2;
    MockUniV3Router public uniV3;
    MockParaswapAugustus public augustus;
    MockV4PoolManager public v4pm;

    address public ownerAddr = address(0xA11CE);
    address public operatorAddr = address(0xB0B);

    uint256 constant LOAN = 1_000e18;
    uint256 constant RATE = 1.1e18; // +10% per hop in the rate mocks

    // Flags (library `internal constant`s, re-declared per the suite's convention).
    uint32 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint32 constant FLAG_V4_UNLOCK = 1 << 2;
    uint32 constant FLAG_WETH_UNWRAP = 1 << 3;
    uint32 constant FLAG_V4_EXACT_IN = 1 << 4;
    uint32 constant FLAG_V2_DIRECT = 1 << 7;
    uint32 constant FLAG_V2_FLASH = 1 << 9;
    uint32 constant FLAG_WETH_WRAP = 1 << 10;
    uint32 constant FLAG_USE_PRODUCED = 1 << 11;

    uint16 constant V2_AMOUNT_POS = 4;
    // The MIN/MAX sentinels `runV4UnlockSwap` pins when the caller passes no limit.
    uint160 constant V4_MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 constant V4_MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenC = new MockERC20("C", "C", 18);
        weth = new MockWETHFull();

        morpho = new MockMorphoBlue();
        balancerFlash = new MockBalancerVault(0);
        uniV2 = new MockUniV2Router(RATE);
        uniV3 = new MockUniV3Router(RATE);
        augustus = new MockParaswapAugustus(RATE);
        v4pm = new MockV4PoolManager(RATE);

        address[] memory allowed = new address[](1);
        allowed[0] = address(v4pm); // the V4 PoolManager is the only op target used here

        vm.prank(ownerAddr);
        exec = ExecutorDeploy.arb(
            ownerAddr,
            operatorAddr,
            address(weth),
            address(balancerFlash),
            address(morpho),
            address(augustus),
            address(uniV2),
            address(uniV3),
            allowed
        );

        // Flash source + rate-mock venue liquidity.
        tokenA.mint(address(morpho), 100 * LOAN);
        weth.mint(address(morpho), 100 * LOAN);
        tokenA.mint(address(uniV2), 100 * LOAN); // close leg pays tokenA
        tokenB.mint(address(v4pm), 100 * LOAN); // V4 pays tokenB out
        tokenC.mint(address(v4pm), 100 * LOAN); // native V4 pays tokenC out
        weth.mint(address(uniV2), 100 * LOAN); // native close pays WETH

        vm.deal(address(weth), 10_000 ether); // ETH reserve behind withdraw
        vm.deal(operatorAddr, 1 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _planMorpho(address loanToken, uint256 amount, Op[] memory ops, uint256 minProfit)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ArbTypes.ArbPlan({
                flashProviderId: 3,
                loanToken: loanToken,
                loanAmount: amount,
                maxFlashFee: 0,
                ops: ops,
                minProfitAmount: minProfit
            })
        );
    }

    /// A V4 single-hop op. `limited` → 192-byte blob carrying `limit` and
    /// FLAG_V4_EXACT_IN; otherwise the 160-byte exact-in shape.
    function _v4Op(address src, address dst, uint256 amountIn, uint32 extra, bool limited, uint160 limit)
        internal
        view
        returns (Op memory op)
    {
        op.target = address(v4pm);
        op.srcToken = src;
        op.outToken = dst;
        op.amountIn = amountIn;
        op.flags = FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN | extra;
        if (limited) {
            op.callData = abi.encode(src, dst, uint24(500), int24(10), address(0), limit);
        } else {
            op.callData = abi.encode(src, dst, uint24(500), int24(10), address(0));
        }
    }

    /// Close leg through the rate router (generic allowlisted call).
    function _routerClose(address src, address dst, uint32 flags) internal view returns (Op memory op) {
        address[] memory path = new address[](2);
        path[0] = src;
        path[1] = dst;
        op.target = address(uniV2);
        op.srcToken = src;
        op.outToken = dst;
        op.flags = flags;
        op.fromAmountPos = V2_AMOUNT_POS;
        op.callData = abi.encodeWithSelector(
            MockUniV2Router.swapExactTokensForTokens.selector,
            uint256(0),
            uint256(1),
            path,
            address(exec),
            block.timestamp
        );
    }

    /// Run `plan` with `minProfit == 0` (lands), then prove the realized
    /// profit is exactly `g`: `g` lands, `g + 1` reverts. Each from the same
    /// pre-state.
    function _assertLandsAndFloorBinds(address loanToken, uint256 amount, Op[] memory ops, uint256 g) internal {
        uint256 snap = vm.snapshotState();

        vm.prank(operatorAddr);
        exec.execute(_planMorpho(loanToken, amount, ops, 0));
        vm.revertToState(snap);

        vm.prank(operatorAddr);
        exec.execute(_planMorpho(loanToken, amount, ops, g));
        vm.revertToState(snap);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(CoinbasePaymentLib.InsufficientProfit.selector, g, g + 1));
        exec.execute(_planMorpho(loanToken, amount, ops, g + 1));
        vm.revertToState(snap);
    }

    // ═══════════════════════════════════════════════════════════════
    // Change 1 — V4 exact-in with a caller sqrtPriceLimitX96
    // ═══════════════════════════════════════════════════════════════

    /// The hinted V4 pool OPENS the cycle with a caller limit, short-fills,
    /// and the untaken loan is counted back. The 192-byte blob carries the
    /// limit through to the PoolManager (asserted), the close leg chains off
    /// what the pool really paid, and the floor binds at the realized profit.
    function test_v4_exactIn_withLimit_shortFills_and_profits() public {
        uint160 limit = 123_456_789; // in V3 range; the mock only records it
        uint256 fill = 600e18;
        v4pm.setExactInLimitFill(fill);

        Op[] memory ops = new Op[](2);
        // op0: V4 exact-in tokenA->tokenB, literal 1000, but the limit (mock)
        // takes only 600 → 660 tokenB; 400 tokenA left on the executor.
        ops[0] = _v4Op(address(tokenA), address(tokenB), LOAN, 0, true, limit);
        // op1: 660 tokenB -> 726 tokenA through the router.
        ops[1] = _routerClose(address(tokenB), address(tokenA), FLAG_USE_PREV_RETURN);

        // final tokenA = 400 (untaken) + 660 * 1.1 = 1126; G = 126.
        uint256 g = 400e18 + (fill * RATE / 1e18) * RATE / 1e18 - LOAN;

        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
        assertEq(v4pm.lastSqrtPriceLimitX96(), limit, "the caller limit reached the PoolManager");
        vm.revertToState(snap);

        _assertLandsAndFloorBinds(address(tokenA), LOAN, ops, g);
    }

    /// A 192-byte single-hop blob is admitted ONLY with FLAG_V4_EXACT_IN; the
    /// exact-out buy has a fixed output, so a limit is meaningless and rejected.
    function test_v4_192Byte_withoutExactIn_reverts() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v4Op(address(tokenA), address(tokenB), LOAN, 0, true, uint160(123_456_789));
        ops[0].flags = FLAG_V4_UNLOCK; // drop FLAG_V4_EXACT_IN, keep the 192-byte blob
        ops[1] = _routerClose(address(tokenB), address(tokenA), FLAG_USE_PREV_RETURN);

        vm.prank(operatorAddr);
        vm.expectRevert(GenericSequenceLib.InvalidPlan.selector);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
    }

    /// Regression: the 160-byte exact-in blob is unchanged — no caller limit,
    /// the PoolManager sees the MIN/MAX sentinel, and the full loan is sold.
    function test_v4_160Byte_unchanged() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v4Op(address(tokenA), address(tokenB), LOAN, 0, false, 0);
        ops[1] = _routerClose(address(tokenB), address(tokenA), FLAG_USE_PREV_RETURN);

        // No short fill: 1000 -> 1100 tokenB -> 1210 tokenA; G = 210.
        uint256 g = (LOAN * RATE / 1e18) * RATE / 1e18 - LOAN;

        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
        // tokenA < tokenB is not guaranteed by deploy order; the sentinel is
        // whichever bound the swap direction pins.
        uint160 seen = v4pm.lastSqrtPriceLimitX96();
        assertTrue(
            seen == V4_MIN_SQRT_PRICE_LIMIT || seen == V4_MAX_SQRT_PRICE_LIMIT, "160-byte blob pins MIN/MAX, no limit"
        );
        vm.revertToState(snap);

        _assertLandsAndFloorBinds(address(tokenA), LOAN, ops, g);
    }

    // ═══════════════════════════════════════════════════════════════
    // Change 2 — native-ETH V4 pool + re-wrap of what the short fill left
    // ═══════════════════════════════════════════════════════════════

    /// Opening unwrap (literal) → native-in V4 exact-in with a limit → close →
    /// `FLAG_WETH_WRAP | FLAG_USE_PRODUCED` wraps exactly the native ETH the
    /// short fill left. No standing ETH is touched; the floor binds.
    function test_v4_native_shortFill_rewrapsProduced() public {
        uint256 fill = 600e18;
        v4pm.setExactInLimitFill(fill);

        Op[] memory ops = new Op[](4);
        // op0: unwrap 1000 WETH -> 1000 native ETH.
        ops[0].srcToken = address(weth);
        ops[0].amountIn = LOAN;
        ops[0].flags = FLAG_WETH_UNWRAP;
        // op1: native-in V4 exact-in, limited; sells 600 ETH -> 660 tokenC, 400 ETH left.
        ops[1] = _v4Op(address(0), address(tokenC), 0, FLAG_USE_PREV_RETURN, true, uint160(123_456_789));
        // op2: 660 tokenC -> 726 WETH through the router.
        ops[2] = _routerClose(address(tokenC), address(weth), FLAG_USE_PREV_RETURN);
        // op3: re-wrap the 400 ETH the short fill left.
        ops[3].srcToken = address(0);
        ops[3].outToken = address(weth);
        ops[3].flags = FLAG_WETH_WRAP | FLAG_USE_PRODUCED;

        // final WETH = 1000(loan) - 1000(unwrap) + 660*1.1 + 400 = 1126; G = 126.
        uint256 g = (fill * RATE / 1e18) * RATE / 1e18 + (LOAN - fill) - LOAN;

        _assertLandsAndFloorBinds(address(weth), LOAN, ops, g);
    }

    /// A FULL fill leaves no native ETH: the re-wrap op is a NO-OP, not a
    /// revert, so the same plan shape works whatever the fill took.
    function test_v4_native_fullFill_rewrapIsNoOp() public {
        v4pm.setExactInLimitFill(0); // no cap: the V4 leg takes the whole 1000 ETH

        Op[] memory ops = new Op[](4);
        ops[0].srcToken = address(weth);
        ops[0].amountIn = LOAN;
        ops[0].flags = FLAG_WETH_UNWRAP;
        ops[1] = _v4Op(address(0), address(tokenC), 0, FLAG_USE_PREV_RETURN, true, uint160(123_456_789));
        ops[2] = _routerClose(address(tokenC), address(weth), FLAG_USE_PREV_RETURN);
        ops[3].srcToken = address(0);
        ops[3].outToken = address(weth);
        ops[3].flags = FLAG_WETH_WRAP | FLAG_USE_PRODUCED;

        // 1000 ETH -> 1100 tokenC -> 1210 WETH; nothing to re-wrap; G = 210.
        uint256 g = (LOAN * RATE / 1e18) * RATE / 1e18 - LOAN;
        _assertLandsAndFloorBinds(address(weth), LOAN, ops, g);
    }

    // ═══════════════════════════════════════════════════════════════
    // Change 3 — V2 direct swap to a target price
    // ═══════════════════════════════════════════════════════════════

    /// The opening V2 pair carries a 96-byte callData with a price limit; the
    /// executor sends only as much input as the limit allows (asserted exactly
    /// against the pair's balance), the untaken loan is counted back, the
    /// close leg profits, and the floor binds.
    function test_v2_direct_toTargetPrice_shortFills_and_profits() public {
        // A real constant-product pair A/B at 1:1, no fee for clean arithmetic.
        uint256 ra = 1_000_000e18;
        uint256 rb = 1_000_000e18;
        MockUniV2Pair pair = new MockUniV2Pair(address(tokenA), address(tokenB), 10_000);
        tokenA.mint(address(pair), ra);
        tokenB.mint(address(pair), rb);
        pair.sync();
        // The close leg pays out tokenA at +50%: give the router room for it;
        // and Morpho must hold the generous literal it lends.
        tokenA.mint(address(uniV2), 10_000_000e18);
        tokenA.mint(address(morpho), 10_000_000e18);

        uint256 loan = 1_000_000e18; // far above the room the limit leaves

        // Choose a limit that leaves room R = 100_000 of tokenA (token0, sold):
        // target reserve0 = rootK * 2^96 / limit, so limit = rootK * 2^96 / (r0 + R).
        uint256 rootK = Math.sqrt(ra * rb);
        uint256 room = 100_000e18;
        uint160 limit = uint160(Math.mulDiv(rootK, 1 << 96, ra + room));
        // Recompute the executor's clamp with its own rounding, so the assert is exact.
        uint256 target = Math.mulDiv(rootK, 1 << 96, limit);
        uint256 sent = target - ra;
        assertLt(sent, loan, "the limit must bind below the literal");
        // out = sent * rb / (ra + sent) at zero fee.
        uint256 dB = sent * rb / (ra + sent);

        Op[] memory ops = new Op[](2);
        // op0: V2 DIRECT A->B on the pair, 96-byte callData with the limit.
        ops[0].target = address(pair);
        ops[0].srcToken = address(tokenA);
        ops[0].outToken = address(tokenB);
        ops[0].amountIn = loan;
        ops[0].flags = FLAG_V2_DIRECT;
        ops[0].callData = abi.encode(true, uint16(10_000), limit); // zeroForOne, fee, limit
        // op1: sell the B back through the rate router at +50% so the cycle profits.
        uniV2.setRate(1.5e18);
        ops[1] = _routerClose(address(tokenB), address(tokenA), FLAG_USE_PREV_RETURN);

        // final tokenA = (loan - sent) + dB * 1.5; G = dB*1.5 - sent.
        uint256 g = dB * 15 / 10 - sent;

        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), loan, ops, 0));
        assertEq(tokenA.balanceOf(address(pair)), ra + sent, "the pair received exactly the limit's room");
        vm.revertToState(snap);

        _assertLandsAndFloorBinds(address(tokenA), loan, ops, g);
    }

    /// Regression: the 64-byte V2 direct callData (no limit) sends the whole
    /// input, exactly as before the change.
    function test_v2_direct_64Byte_sendsFullInput() public {
        uint256 ra = 1_000_000e18;
        uint256 rb = 1_000_000e18;
        MockUniV2Pair pair = new MockUniV2Pair(address(tokenA), address(tokenB), 10_000);
        tokenA.mint(address(pair), ra);
        tokenB.mint(address(pair), rb);
        pair.sync();

        uint256 loan = 1_000e18;
        uint256 dB = loan * rb / (ra + loan);

        Op[] memory ops = new Op[](2);
        ops[0].target = address(pair);
        ops[0].srcToken = address(tokenA);
        ops[0].outToken = address(tokenB);
        ops[0].amountIn = loan;
        ops[0].flags = FLAG_V2_DIRECT;
        ops[0].callData = abi.encode(true, uint16(10_000)); // 64 bytes, no limit
        uniV2.setRate(1.5e18);
        ops[1] = _routerClose(address(tokenB), address(tokenA), FLAG_USE_PREV_RETURN);

        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), loan, ops, 0));
        assertEq(tokenA.balanceOf(address(pair)), ra + loan, "no limit: the whole input is sent");
        vm.revertToState(snap);

        uint256 g = dB * 15 / 10 - loan;
        _assertLandsAndFloorBinds(address(tokenA), loan, ops, g);
    }

    /// A 96-byte callData on a FLASH V2 op is refused: `flashV2` prices
    /// pre-transfer with the pair paying first, so a limit cannot clamp its
    /// input cleanly — it keeps the strict 64-byte shape.
    function test_v2_flash_96Byte_reverts() public {
        MockUniV2Pair pair = new MockUniV2Pair(address(tokenA), address(tokenB), 10_000);
        tokenA.mint(address(pair), 1_000_000e18);
        tokenB.mint(address(pair), 1_000_000e18);
        pair.sync();

        Op[] memory ops = new Op[](2);
        ops[0].target = address(pair);
        ops[0].srcToken = address(tokenA);
        ops[0].outToken = address(tokenB);
        ops[0].amountIn = LOAN;
        ops[0].flags = FLAG_V2_FLASH; // self-funded: the pair pays out first
        ops[0].callData = abi.encode(true, uint16(10_000), uint160(123_456_789)); // 96 bytes
        ops[1] = _routerClose(address(tokenB), address(tokenA), FLAG_USE_PREV_RETURN);

        vm.prank(operatorAddr);
        vm.expectRevert(DirectSwapLib.DirectSwapInvalid.selector);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
    }

    // ═══════════════════════════════════════════════════════════════
    // Capability version
    // ═══════════════════════════════════════════════════════════════

    /// The bot reads `version()` on chain and refuses the new shapes to an
    /// implementation that does not answer 2.
    function test_version_is_2() public view {
        assertEq(exec.version(), 2);
    }
}
