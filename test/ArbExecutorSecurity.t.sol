// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {GenericSequenceLib} from "../src/libraries/GenericSequenceLib.sol";
import {IUniV3SwapRouter} from "../src/interfaces/IUniV3SwapRouter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniV2Router} from "./mocks/MockUniV2Router.sol";
import {MockUniV3Router} from "./mocks/MockUniV3Router.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";
import {MockWETH} from "./ArbExecutor.t.sol";

/// @title ArbExecutorSecurityTest
/// @notice Task 7 (feat/arb-full-parity) — pins the adversarial containment
/// invariants of `GenericSequenceLib.runArb` through the REAL `ArbExecutor`
/// entrypoint (`execute()` -> flash callback -> `runArb` -> DELEGATECALL),
/// not just at the library level (already covered by
/// `ArbGenericSequence.t.sol`). Every revert test below is deliberately
/// engineered so the ABSOLUTE repay gate (or whatever earlier guard could
/// plausibly fire) is either satisfied or provably not what's firing --
/// each test's inline comment traces the exact arithmetic that proves the
/// pinned revert is reached via the intended containment/ceiling check, not
/// an unrelated guard (target allowlist, phase, empty ops, etc).
///
/// `runArb`'s cap model (see GenericSequenceLib._executeOps): capToken =
/// loanToken, capAmount = loanAmount, EVERY other token (including native
/// ETH, bucketed at address(0)) has allowed-spend ZERO. The native-ETH
/// bucket's allowed is unconditionally zero for the ARB executor (capToken
/// is always an ERC20, so `t == capToken` can never match `t ==
/// address(0)`) -- a legit FLAG_WETH_UNWRAP-funded native leg still passes
/// because the unwrap CREDITS ether above the pre-op snapshot before the
/// native leg spends it back down to (or above) that snapshot, netting
/// spend <= 0.
contract ArbExecutorSecurityTest is Test {
    ArbExecutor public exec;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockWETH public weth;

    MockMorphoBlue public morpho;
    MockBalancerVault public balancerFlash;
    MockUniV2Router public uniV2;
    MockUniV3Router public uniV3;
    MockParaswapAugustus public augustus;
    MockV4PoolManager public v4pm;

    address public ownerAddr = address(0xA11CE);
    address public operatorAddr = address(0xB0B);

    uint256 constant LOAN_AMOUNT = 1_000e18;
    uint256 constant SWAP_RATE = 1.1e18; // 10% gain per hop in the V2/V4 mocks

    // Uniswap V2 `swapExactTokensForTokens`: amountIn is the first param,
    // right after the 4-byte selector (same constant as ArbExecutor.t.sol).
    uint16 constant V2_AMOUNT_POS = 4;

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenC = new MockERC20("C", "C", 18);
        weth = new MockWETH();

        morpho = new MockMorphoBlue();
        balancerFlash = new MockBalancerVault(0);
        uniV2 = new MockUniV2Router(SWAP_RATE);
        uniV3 = new MockUniV3Router(SWAP_RATE);
        augustus = new MockParaswapAugustus(SWAP_RATE);
        v4pm = new MockV4PoolManager(SWAP_RATE);

        address[] memory allowed = new address[](1);
        allowed[0] = address(v4pm);

        vm.prank(ownerAddr);
        exec = new ArbExecutor(
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

        // Flash-source + swap-venue liquidity.
        tokenA.mint(address(morpho), 20 * LOAN_AMOUNT);
        tokenA.mint(address(uniV2), 20 * LOAN_AMOUNT);
        tokenB.mint(address(uniV2), 20 * LOAN_AMOUNT);
        weth.mint(address(morpho), 20 * LOAN_AMOUNT);
        tokenC.mint(address(v4pm), 20 * LOAN_AMOUNT);

        // MockWETH.withdraw() forwards ETH out of ITS OWN balance -- fund it
        // well beyond anything a single test unwraps.
        vm.deal(address(weth), 1_000 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _v2Op(address src, address dst, uint256 amountIn, uint32 flags) internal view returns (Op memory op) {
        address[] memory path = new address[](2);
        path[0] = src;
        path[1] = dst;
        op.target = address(uniV2);
        op.srcToken = src;
        op.outToken = dst;
        op.amountIn = amountIn;
        op.flags = flags;
        op.fromAmountPos = V2_AMOUNT_POS;
        op.callData = abi.encodeWithSelector(
            MockUniV2Router.swapExactTokensForTokens.selector,
            uint256(0), // placeholder -- patched at runtime via fromAmountPos
            uint256(1),
            path,
            address(exec),
            block.timestamp + 1 hours
        );
    }

    /// WETH -> native-ETH unwrap op (FLAG_WETH_UNWRAP). No external target
    /// (exempt from the pre-flash allowlist walk), no ERC20 output.
    function _unwrapOp(uint256 amount) internal view returns (Op memory op) {
        op.srcToken = address(weth);
        op.amountIn = amount;
        op.flags = GenericSequenceLib.FLAG_WETH_UNWRAP;
    }

    /// Native-ETH V4 single-hop EXACT-OUT op: srcToken == address(0), pays
    /// ETH via `settle{value}`, takes `amountOut` of `tokenOut`. At
    /// SWAP_RATE = 1.1e18 the ETH owed is amountOut * 1e18 / 1.1e18.
    function _nativeV4Op(address tokenOut, uint256 amountOut) internal view returns (Op memory op) {
        op.target = address(v4pm);
        op.srcToken = address(0);
        op.outToken = tokenOut;
        op.flags = GenericSequenceLib.FLAG_V4_UNLOCK;
        op.amountIn = amountOut; // reinterpreted: exact-out amountSpec
        op.callData = abi.encode(address(0), tokenOut, uint24(500), int24(10), address(0));
    }

    /// Native-ETH V4 single-hop EXACT-IN op: srcToken == address(0), sells
    /// exactly `ethIn` ETH, takes whatever output the pool gives.
    function _nativeV4ExactInOp(address tokenOut, uint256 ethIn) internal view returns (Op memory op) {
        op.target = address(v4pm);
        op.srcToken = address(0);
        op.outToken = tokenOut;
        op.flags = GenericSequenceLib.FLAG_V4_UNLOCK | GenericSequenceLib.FLAG_V4_EXACT_IN;
        op.amountIn = ethIn; // exact-IN: ETH sold
        op.callData = abi.encode(address(0), tokenOut, uint24(500), int24(10), address(0));
    }

    function _planMorpho(address loanToken, uint256 amount, Op[] memory ops, uint256 minProfit)
        internal
        pure
        returns (bytes memory)
    {
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: 3, // FLASH_PROVIDER_MORPHO
            loanToken: loanToken,
            loanAmount: amount,
            maxFlashFee: 0,
            ops: ops,
            minProfitAmount: minProfit
        });
        return abi.encode(plan);
    }

    // ═══════════════════════════════════════════════════════════════
    // 1. loanToken net-spend past the principal cap
    // ═══════════════════════════════════════════════════════════════

    /// The executor is seeded with 3000 tokenA of STANDING balance (e.g.
    /// retained profit from an earlier arb) IN ADDITION to this tx's 1000
    /// tokenA flash principal -- snapshot = 4000. op0 spends the FULL
    /// current balance (4000 -> 4400 tokenB); op1 converts back only 1000
    /// of that tokenB (-> 1100 tokenA). Final tokenA = 1100, which clears
    /// the ABSOLUTE repay gate (1100 >= flashRepay 1000) -- so the ONLY
    /// thing that can stop this plan is the containment cap catching the
    /// net tokenA spend since the snapshot (4000 -> 1100 = 2900) exceeding
    /// `loanAmount` (1000). Proves the cap independently of the repay gate:
    /// a plan can fully honour repay and still burn standing loanToken-
    /// denominated profit past what THIS tx is allowed to move.
    function test_arb_loanTokenOverspend_reverts() public {
        uint256 donation = 3_000e18;
        tokenA.mint(address(exec), donation);

        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT + donation, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 1_000e18, 0);

        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0);

        // spent = snapshot(4000) - final(1100) = 2900; allowed = loanAmount = 1000.
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.CollateralOverspent.selector, 2_900e18, LOAN_AMOUNT));
        exec.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════
    // 2. Standing native ETH, no preceding unwrap -> CollateralOverspent
    // ═══════════════════════════════════════════════════════════════

    /// The executor holds 100 ETH of STANDING balance (donated, not
    /// unwrapped this tx). ops[0..1] legitimately repay the flash
    /// (tokenA -> tokenB -> tokenA, 1000 -> 1100 -> 1210, clears the 1000
    /// repay floor with room), then op2 is a native V4 exact-out op with NO
    /// preceding FLAG_WETH_UNWRAP -- it settles 10 ETH that can ONLY have
    /// come from the standing balance (this tx unwrapped nothing). The
    /// native-ETH bucket's allowed-spend is unconditionally 0 for arb
    /// (capToken is always the ERC20 loanToken, never address(0)), so any
    /// net ETH dip below the pre-op-loop snapshot must revert. Repay is
    /// satisfied BEFORE the containment loop runs (1210 >= 1000), and the
    /// tokenA/tokenB buckets both net to >= their snapshot (no spend) --
    /// isolating the native-ETH bucket as the sole failing check.
    function test_arb_standingEthSpend_withoutUnwrap_reverts() public {
        uint256 standing = 100 ether;
        vm.deal(address(exec), standing);

        Op[] memory ops = new Op[](3);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        ops[2] = _nativeV4Op(address(tokenC), 11e18); // owes exactly 10 ether, all standing

        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.CollateralOverspent.selector, 10 ether, 0));
        exec.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════
    // 3. V4 exact-in over-pull -> V4InputOverspent
    // ═══════════════════════════════════════════════════════════════

    /// Unwraps 10 WETH -> 10 native ETH, then sells it exact-in through a
    /// pool configured to settle 10% MORE than asked (11 ETH pulled for a
    /// 10 ETH ask). 5 ETH of standing headroom is pre-funded so the
    /// over-pull settle CAN actually pay (15 ETH available, 11 ETH pulled)
    /// -- proving the per-op input CEILING fires, not an out-of-funds call
    /// failure. This reverts INSIDE the op loop (before the repay gate or
    /// containment loop ever run), so no repay-satisfying leg is needed.
    function test_arb_v4ExactIn_overpull_reverts() public {
        vm.deal(address(exec), 5 ether); // standing headroom for the over-pull
        v4pm.setInputInflateBps(11_000); // settle 10% more than the 10 ETH asked

        uint256 unwrapAmount = 10 ether;

        Op[] memory ops = new Op[](2);
        ops[0] = _unwrapOp(unwrapAmount);
        ops[1] = _nativeV4ExactInOp(address(tokenC), unwrapAmount); // asks 10, pool pulls 11

        bytes memory plan = _planMorpho(address(weth), LOAN_AMOUNT, ops, 0);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.V4InputOverspent.selector, 11 ether, unwrapAmount));
        exec.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════
    // 4. Repay shortfall -> InsufficientRepayOutput (ABSOLUTE gate)
    // ═══════════════════════════════════════════════════════════════

    /// The op sequence round-trips at a LOSS (rate 0.9 both hops: 1000 ->
    /// 900 -> 810 tokenA), so the ABSOLUTE repay gate (`loanAfter >=
    /// flashRepay`) fails: 810 < 1000. Every op target is constructor-
    /// allowlisted (uniV2) and the plan is otherwise well-formed, so the
    /// ONLY guard that can fire is the repay gate -- pinned with the exact
    /// realized `actual` (810e18), not a placeholder/zero value, to prove
    /// it's reached with real arithmetic rather than short-circuited by an
    /// earlier check.
    function test_arb_repayShortfall_reverts() public {
        uniV2.setRate(0.9e18);
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(GenericSequenceLib.InsufficientRepayOutput.selector, 810e18, LOAN_AMOUNT)
        );
        exec.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════
    // 5. EIP-170 deployed-bytecode size ceiling
    // ═══════════════════════════════════════════════════════════════

    function test_arb_deployedBytecode_underEip170() public view {
        bytes memory code = address(exec).code;
        assertLt(code.length, 24576, "ArbExecutor exceeds EIP-170");
    }
}
