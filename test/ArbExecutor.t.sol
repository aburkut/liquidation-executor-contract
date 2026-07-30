// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {GenericSequenceLib} from "../src/libraries/GenericSequenceLib.sol";
import {CoinbasePaymentLib} from "../src/libraries/CoinbasePaymentLib.sol";
import {IUniV3SwapRouter} from "../src/interfaces/IUniV3SwapRouter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniV2Router} from "./mocks/MockUniV2Router.sol";
import {MockUniV3Router} from "./mocks/MockUniV3Router.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";
import {MockRouter} from "./support/Mocks.sol";

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: ETH transfer failed");
    }

    receive() external payable {}
}

/// @title ArbExecutorTest
/// @notice Focused suite for `ArbExecutor`. The execution pipeline shares
/// its `GenericSequenceLib` op-executor with `LiquidationExecutor` (already
/// covered in the 10k-line legacy suite + `ArbGenericSequence.t.sol`), so we
/// don't re-test every containment/repay-gate edge here. Coverage instead
/// pins:
///   * Op-sequence admission control (target allowlist walk, MAX_OPS bound)
///     — this REPLACES the old static leg-chain wiring checks (first-leg
///     srcToken / last-leg repayToken / link matching), which no longer
///     exist: `ops[]` chains at runtime via `FLAG_USE_PREV_RETURN`, and the
///     repay invariant is enforced by `GenericSequenceLib.runArb`'s
///     ABSOLUTE gate, not by static validation in `execute()`.
///   * Flash callback gates (phase + planHash + provider pin).
///   * Coinbase gating (`loanToken == weth` precondition).
///   * Profit floor + withdraw + admin surface.
///   * End-to-end op-sequence execution through the real flash callback
///     (`test_execute_opSequence_arb_profits_and_repays`).
contract ArbExecutorTest is Test {
    ArbExecutor public exec;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockWETH public weth;

    MockMorphoBlue public morpho;
    MockBalancerVault public balancerFlash;
    MockUniV2Router public uniV2;
    MockUniV3Router public uniV3;
    MockParaswapAugustus public augustus; // unused in tests but required by constructor

    // ── Op-sequence e2e fixtures (Task 5) ──────────────────────────────
    MockERC20 public loan;
    MockERC20 public mid;
    MockRouter public router;
    uint8 constant FLASH_MORPHO = 3;

    address public ownerAddr = address(0xA11CE);
    address public operatorAddr = address(0xB0B);
    address public attacker = address(0xDEAD);
    address public recipient = address(0xC0DE);

    uint256 constant LOAN_AMOUNT = 1_000e18;
    uint256 constant SWAP_RATE = 1.1e18; // 10% gain per hop in the mocks

    // Uniswap V2 `swapExactTokensForTokens(uint256,uint256,address[],address,uint256)`:
    // amountIn is the first parameter, right after the 4-byte selector.
    uint16 constant V2_AMOUNT_POS = 4;
    // Uniswap V3 `exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))`:
    // the struct is all-static fields, encoded inline (no offset pointer);
    // amountIn is the 5th word: selector(4) + tokenIn(32) + tokenOut(32) + fee(32) + recipient(32) = 132.
    uint16 constant V3_AMOUNT_POS = 132;

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenC = new MockERC20("C", "C", 18);
        weth = new MockWETH();

        morpho = new MockMorphoBlue();
        balancerFlash = new MockBalancerVault(0); // flashloan fee = 0 for simpler assertions
        uniV2 = new MockUniV2Router(SWAP_RATE);
        uniV3 = new MockUniV3Router(SWAP_RATE);
        augustus = new MockParaswapAugustus(SWAP_RATE);

        loan = new MockERC20("Loan", "LOAN", 18);
        mid = new MockERC20("Mid", "MID", 18);
        router = new MockRouter();

        // No extra targets: morpho is deliberately NOT allowlisted here (nor
        // seeded by the constructor, N-Task 5 fix 1) — the flash-repay path
        // reaches Morpho exclusively via `allowedFlashProviders`, never via
        // `allowedTargets`. See `test_execute_morphoAsGenericOpTarget_reverts`.
        address[] memory allowed = new address[](0);

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

        // Wire Morpho as flash provider (mirrors LiquidationExecutor).
        vm.prank(ownerAddr);

        // Seed swap venues + flash sources with liquidity so they can
        // honour callbacks / swaps.
        tokenA.mint(address(morpho), 10 * LOAN_AMOUNT);
        tokenA.mint(address(uniV2), 10 * LOAN_AMOUNT);
        tokenA.mint(address(uniV3), 10 * LOAN_AMOUNT);
        tokenB.mint(address(uniV2), 10 * LOAN_AMOUNT);
        tokenB.mint(address(uniV3), 10 * LOAN_AMOUNT);
        tokenC.mint(address(uniV2), 10 * LOAN_AMOUNT);
        tokenC.mint(address(uniV3), 10 * LOAN_AMOUNT);
        weth.mint(address(morpho), 10 * LOAN_AMOUNT);
        weth.mint(address(uniV2), 10 * LOAN_AMOUNT);
        weth.mint(address(uniV3), 10 * LOAN_AMOUNT);

        // ETH funding so the coinbase auto-unwrap path has somewhere
        // to draw from when the executor holds WETH. Sized > the
        // maximum unwrap amount any single test would request.
        vm.deal(address(weth), 1_000 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    /// Direct-call Op targeting the real `uniV2` router mock.
    /// `flags == 0` ⇒ explicit `amountIn`; `flags == FLAG_USE_PREV_RETURN`
    /// ⇒ chains off the previous op's output delta (the ops-model analog of
    /// the old `SwapLeg.useFullBalance`).
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
            uint256(0), // placeholder — patched at runtime via fromAmountPos
            uint256(1), // amountOutMin — deterministic-rate mock, loose floor
            path,
            address(exec),
            block.timestamp + 1 hours
        );
    }

    /// Direct-call Op targeting the real `uniV3` router mock (single-hop
    /// `exactInputSingle`).
    function _v3Op(address src, address dst, uint256 amountIn, uint32 flags) internal view returns (Op memory op) {
        op.target = address(uniV3);
        op.srcToken = src;
        op.outToken = dst;
        op.amountIn = amountIn;
        op.flags = flags;
        op.fromAmountPos = V3_AMOUNT_POS;
        op.callData = abi.encodeWithSelector(
            MockUniV3Router.exactInputSingle.selector,
            IUniV3SwapRouter.ExactInputSingleParams({
                tokenIn: src,
                tokenOut: dst,
                fee: 500,
                recipient: address(exec),
                amountIn: 0, // placeholder — patched at runtime via fromAmountPos
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _planMorpho(address loanToken, uint256 amount, Op[] memory ops, uint256 minProfit, uint256 coinbaseBps)
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
            coinbaseBps: coinbaseBps,
            minProfitAmount: minProfit
        });
        return abi.encode(plan);
    }

    function _planBalancer(address loanToken, uint256 amount, uint256 maxFlashFee, Op[] memory ops, uint256 minProfit)
        internal
        pure
        returns (bytes memory)
    {
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: 2, // FLASH_PROVIDER_BALANCER
            loanToken: loanToken,
            loanAmount: amount,
            maxFlashFee: maxFlashFee,
            ops: ops,
            coinbaseBps: 0,
            minProfitAmount: minProfit
        });
        return abi.encode(plan);
    }

    // ─── Op-sequence e2e helpers (Task 5, mock MockRouter — no fork) ──

    function _swapOp(address srcToken, uint256 amountIn, address outToken, uint256 amountOut)
        internal
        view
        returns (Op memory)
    {
        bytes memory cd = abi.encodeWithSignature(
            "swap(address,uint256,address,uint256)", srcToken, amountIn, outToken, amountOut
        );
        return Op({
            target: address(router),
            value: 0,
            amountIn: amountIn,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: 0,
            srcToken: srcToken,
            outToken: outToken,
            callData: cd
        });
    }

    function _encodeArbPlan(
        uint8 flashProviderId,
        address loanToken,
        uint256 loanAmount,
        Op[] memory ops,
        uint256 coinbaseBps,
        uint256 minProfit
    ) internal pure returns (bytes memory) {
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: flashProviderId,
            loanToken: loanToken,
            loanAmount: loanAmount,
            maxFlashFee: 0,
            ops: ops,
            coinbaseBps: coinbaseBps,
            minProfitAmount: minProfit
        });
        return abi.encode(plan);
    }

    function _fundAndAllowlist() internal {
        loan.mint(address(morpho), 10 * LOAN_AMOUNT);
        vm.prank(ownerAddr);
        exec.setAllowedTarget(address(router), true);
    }

    // ─── Happy paths ─────────────────────────────────────────────────

    /// 2-hop A→B→A chain via Morpho flash, V2 router both hops.
    /// rate=1.1 ⇒ 1000 A → 1100 B → 1210 A → repay 1000 → profit 210.
    function test_happy_2hop_morpho_v2() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 100e18, 0);

        uint256 balBefore = tokenA.balanceOf(address(exec));
        vm.prank(operatorAddr);
        exec.execute(plan);
        uint256 balAfter = tokenA.balanceOf(address(exec));

        // 210 A profit retained on the contract.
        assertEq(balAfter - balBefore, 210e18, "profit retained");
    }

    /// Same chain via Balancer flash (zero fee in this test setup).
    function test_happy_2hop_balancer_v2() public {
        // Fund Balancer flash source with tokenA.
        tokenA.mint(address(balancerFlash), 10 * LOAN_AMOUNT);

        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        bytes memory plan = _planBalancer(address(tokenA), LOAN_AMOUNT, 0, ops, 100e18);

        vm.prank(operatorAddr);
        exec.execute(plan);

        assertEq(tokenA.balanceOf(address(exec)), 210e18, "profit retained");
    }

    /// 3-hop A→B→C→A across V2 and V3 routers.
    /// rate=1.1 each ⇒ 1000 → 1100 → 1210 → 1331; repay 1000 → 331 A profit.
    function test_happy_3hop_v2_v3_v2() public {
        Op[] memory ops = new Op[](3);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v3Op(address(tokenB), address(tokenC), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        ops[2] = _v2Op(address(tokenC), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 100e18, 0);

        vm.prank(operatorAddr);
        exec.execute(plan);

        assertEq(tokenA.balanceOf(address(exec)), 331e18, "3-hop profit retained");
    }

    /// Coinbase bribe: loanToken = weth, coinbaseBps = 5000 (50%) of the
    /// 210 weth realized profit ⇒ 105 weth = 105 ether goes to coinbase.
    function test_happy_coinbase_50pct_when_loan_is_weth() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(weth), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(weth), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);

        bytes memory plan = _planMorpho(address(weth), LOAN_AMOUNT, ops, 0, 5_000);

        address coinbaseAddr = address(0xC0FFEE);
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseBefore = coinbaseAddr.balance;

        vm.prank(operatorAddr);
        exec.execute(plan);

        assertEq(coinbaseAddr.balance - coinbaseBefore, 105e18, "50% of 210 weth profit bribed");
        // Residual 105 weth stays on the executor.
        assertEq(weth.balanceOf(address(exec)), 105e18, "residual weth retained");
    }

    /// Owner sweep — withdraw the retained profit to a recipient.
    function test_happy_owner_withdraws_profit() public {
        // First run a chain to accumulate profit.
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0));

        uint256 profit = tokenA.balanceOf(address(exec));
        assertEq(profit, 210e18);

        vm.prank(ownerAddr);
        exec.withdraw(address(tokenA), recipient, profit);

        assertEq(tokenA.balanceOf(recipient), profit, "recipient credited");
        assertEq(tokenA.balanceOf(address(exec)), 0, "executor swept clean");
    }

    // ─── End-to-end Op-sequence arb (Task 5) ──────────────────────────

    /// Profitable 2-op arb through the full execute() → flash → runArb
    /// path, using a mock Morpho flash provider + a mock router (no fork).
    /// ops: 100 LOAN -> 100 MID -> 110 LOAN. minProfit 5, coinbaseBps 0.
    function test_execute_opSequence_arb_profits_and_repays() public {
        _fundAndAllowlist();
        Op[] memory ops = new Op[](2);
        ops[0] = _swapOp(address(loan), 100e18, address(mid), 100e18);
        ops[1] = _swapOp(address(mid), 100e18, address(loan), 110e18);
        bytes memory planData = _encodeArbPlan(FLASH_MORPHO, address(loan), 100e18, ops, 0, 5e18);

        vm.prank(operatorAddr);
        exec.execute(planData);
        assertEq(loan.balanceOf(address(exec)), 10e18, "arb profit retained");
    }

    /// Task 8 fix 1: both flash callbacks (`receiveFlashLoan`,
    /// `onMorphoFlashLoan`) cleared `_activePlanHash` to bytes32(0) (the V10
    /// re-entry guard) BEFORE calling `_runArbPipeline`, which then read the
    /// already-zeroed slot for the `ArbExecuted` event — every emitted
    /// `planHash` topic was bytes32(0) regardless of the real plan. The fix
    /// captures the hash BEFORE the clear and threads it through explicitly.
    /// This test pins the REAL plan hash on the emitted event; reverting the
    /// fix (reading `_activePlanHash` instead of the threaded `planHash` at
    /// the `emit` site) makes this test fail with planHash == bytes32(0)
    /// (verified manually — not committed, since bytes32(0) would trivially
    /// match a same-value comparison and this assertion is the correct way
    /// to pin the regression).
    function test_arbExecuted_emits_real_planHash() public {
        _fundAndAllowlist();
        Op[] memory ops = new Op[](2);
        ops[0] = _swapOp(address(loan), 100e18, address(mid), 100e18);
        ops[1] = _swapOp(address(mid), 100e18, address(loan), 110e18);
        bytes memory planData = _encodeArbPlan(FLASH_MORPHO, address(loan), 100e18, ops, 0, 5e18);
        bytes32 expectedPlanHash = keccak256(planData);
        // Sanity: the plan hash is non-zero, so a bytes32(0) emission (the
        // pre-fix bug) would be distinguishable from the expected value.
        assertTrue(expectedPlanHash != bytes32(0), "sanity: plan hash must be non-zero");

        vm.recordLogs();
        vm.prank(operatorAddr);
        exec.execute(planData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 arbExecutedSig = keccak256("ArbExecuted(bytes32,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == arbExecutedSig) {
                found = true;
                assertEq(logs[i].topics[1], expectedPlanHash, "ArbExecuted.planHash must equal keccak256(planData)");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(loan), "ArbExecuted.loanToken");
            }
        }
        assertTrue(found, "ArbExecuted event not emitted");
    }

    // ─── Op admission-control reverts (Task 5) ────────────────────────
    // Replaces the old static leg-chain wiring checks (first-leg srcToken /
    // last-leg repayToken / link matching) — those invariants no longer
    // exist in the ops[] model. `execute()` now only pre-flash-validates
    // ops.length (1..MAX_OPS) and the target allowlist; chaining + the repay
    // gate are enforced at RUNTIME inside GenericSequenceLib.runArb (already
    // unit-tested in ArbGenericSequence.t.sol at the library level). These
    // tests pin the NEW invariants end-to-end through ArbExecutor.execute().

    function test_revert_ops_empty() public {
        Op[] memory ops = new Op[](0);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_ops_tooMany() public {
        // MAX_OPS = 32; 33 ops (content irrelevant — length check reverts
        // before the allowlist walk).
        Op[] memory ops = new Op[](33);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_ops_targetNotAllowlisted() public {
        // op[0].target is a bare address never allowlisted (not a
        // constructor-seeded router, not owner-added) → TargetNotAllowed
        // in the pre-flashloan walk, before any flashloan is even taken.
        Op[] memory ops = new Op[](1);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[0].target = address(0xBEEF);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.TargetNotAllowed.selector);
        exec.execute(plan);
    }

    /// N-Task 5 fix 1: `morphoBlue` is deliberately NOT seeded into
    /// `allowedTargets` by the constructor (nor by this test's `setUp`,
    /// which passes an empty extra-allowlist). A generic `Op` targeting
    /// Morpho Blue directly must be rejected at the pre-flashloan allowlist
    /// walk, closing the scope-creep the audit found: pre-fix, an operator
    /// could target Morpho Blue's full function surface as a generic op,
    /// contradicting the contract's "no liquidation actions" NatSpec. The
    /// flash-repay path does NOT need this entry — it is reached solely via
    /// `allowedFlashProviders[FLASH_PROVIDER_MORPHO]`, and repayment is a
    /// `forceApprove(msg.sender=Morpho, flashRepay)` that never consults
    /// `allowedTargets` at all (proven separately by every other
    /// Morpho-flash test in this suite still passing unmodified).
    function test_execute_morphoAsGenericOpTarget_reverts() public {
        Op[] memory ops = new Op[](1);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[0].target = address(morpho); // generic op aimed at Morpho Blue itself
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.TargetNotAllowed.selector);
        exec.execute(plan);
    }

    /// Task 8 fix 2: the pre-flight allowlist walk exempted ops on
    /// bit-PRESENCE (`flags & FLAG_WETH_UNWRAP != 0`), so a combined-flag op
    /// (unwrap bit set ALONGSIDE another flag, here FLAG_V4_UNLOCK) wrongly
    /// skipped the allowlist check even though it DOES carry an external
    /// `target` — reused as the V4 PoolManager under FLAG_V4_UNLOCK. This
    /// combined shape is not a real unwrap by GenericSequenceLib's own
    /// runtime contract (its exact-match guard `op.flags != FLAG_WETH_UNWRAP`
    /// would revert InvalidPlan once inside the flash), so pre-fix a plan
    /// could reach the flashloan/library entirely on the strength of a
    /// non-allowlisted target that should have been rejected before ever
    /// borrowing funds. After the fix (exact-equality), this op is NOT
    /// exempt and TargetNotAllowed fires in the pre-flashloan walk, before
    /// any flashloan is taken.
    function test_execute_combinedFlagUnwrapTarget_notExempted_reverts() public {
        Op[] memory ops = new Op[](1);
        ops[0].target = address(0xBEEF); // never allowlisted
        ops[0].srcToken = address(weth);
        ops[0].outToken = address(tokenB);
        ops[0].amountIn = 1e18;
        ops[0].flags = GenericSequenceLib.FLAG_WETH_UNWRAP | GenericSequenceLib.FLAG_V4_UNLOCK;
        ops[0].callData = abi.encode(address(weth), address(tokenB), uint24(500), int24(10), address(0));

        bytes memory plan = _planMorpho(address(weth), LOAN_AMOUNT, ops, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.TargetNotAllowed.selector);
        exec.execute(plan);
    }

    /// Confirms the fix does NOT reject a LEGIT unwrap op: `flags` EXACTLY
    /// equal to `FLAG_WETH_UNWRAP` must still be exempt from the pre-flight
    /// allowlist walk (per the library contract, a real unwrap op carries no
    /// external target). `op.target` is deliberately set to a
    /// non-allowlisted address to prove the exemption still applies — if the
    /// walk wrongly started gating pure-unwrap ops too, this would revert
    /// `TargetNotAllowed` before the flashloan is even taken. Instead it
    /// proceeds past the pre-flight walk into the flash and fails on an
    /// UNRELATED guard downstream (repay shortfall — this plan's only op
    /// spends loanToken without ever converting anything back), proving the
    /// admission control, not the repay gate, is what's being pinned here.
    function test_execute_pureUnwrapFlag_stillExempted_preflight() public {
        Op[] memory ops = new Op[](1);
        ops[0].target = address(0xBEEF); // irrelevant for a pure unwrap op
        ops[0].srcToken = address(weth);
        ops[0].amountIn = 1e18;
        ops[0].flags = GenericSequenceLib.FLAG_WETH_UNWRAP;

        bytes memory plan = _planMorpho(address(weth), LOAN_AMOUNT, ops, 0, 0);

        vm.prank(operatorAddr);
        try exec.execute(plan) {
            fail("expected a revert (repay shortfall), but execute() unexpectedly succeeded");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != ArbExecutor.TargetNotAllowed.selector,
                "pure unwrap op must stay exempt from the pre-flight allowlist walk"
            );
        }
    }

    function test_revert_ops_repayShortfall() public {
        // Sequence under-produces loanToken: 1000 A -> 900 B (rate < 1),
        // never converts back — loanAfter (0) < flashRepay (1000).
        // GenericSequenceLib's ABSOLUTE repay gate reverts INSIDE the flash
        // callback, bubbling InsufficientRepayOutput up through execute().
        uniV2.setRate(0.9e18);
        Op[] memory ops = new Op[](1);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.InsufficientRepayOutput.selector, 0, LOAN_AMOUNT));
        exec.execute(plan);
    }

    function test_revert_coinbase_bps_over_cap() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(weth), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(weth), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        bytes memory plan = _planMorpho(address(weth), LOAN_AMOUNT, ops, 0, 10_001);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_coinbase_requires_weth_loan() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 5_000);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.CoinbaseRequiresWethLoan.selector);
        exec.execute(plan);
    }

    function test_revert_minProfitAmount_floor_unmet() public {
        // 210 A realized profit; require 500 → InsufficientProfit.
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 500e18, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(CoinbasePaymentLib.InsufficientProfit.selector, 210e18, 500e18));
        exec.execute(plan);
    }

    function test_revert_invalid_flash_provider() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: 99, // not configured
            loanToken: address(tokenA),
            loanAmount: LOAN_AMOUNT,
            maxFlashFee: 0,
            ops: ops,
            coinbaseBps: 0,
            minProfitAmount: 0
        });
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.InvalidFlashProvider.selector, uint8(99)));
        exec.execute(abi.encode(plan));
    }

    // ─── Flash callback gates ────────────────────────────────────────

    function test_revert_morphoCallbackFromNonMorpho() public {
        // Direct call to onMorphoFlashLoan from attacker without a pinned
        // plan / phase → InvalidExecutionPhase (idle).
        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.InvalidExecutionPhase.selector);
        exec.onMorphoFlashLoan(LOAN_AMOUNT, hex"");
    }

    function test_revert_morphoCallbackWrongCaller_evenInsidePhase() public {
        // Plant `_executionPhase = FlashLoanActive` and `_activePlanHash`
        // matching `data` — only the caller check should reject.
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);
        bytes32 planHash = keccak256(plan);

        // Storage slots (forge inspect ArbExecutor storageLayout, post V4
        // storage-alignment — see task-3-report.md):
        //   morphoBlue              slot 2
        //   allowedFlashProviders   slot 3 (mapping)
        //   allowedTargets          slot 4 (mapping)
        //   allowedV4Hooks          slot 5 (mapping)
        //   operators               slot 6 (mapping)
        //   _activePlanHash         slot 7
        //   __reservedSlot0..2      slots 8-10 (V4 alignment padding)
        //   _activeV4PoolManager    slot 11 offset 0  (packs with _executionPhase)
        //   _executionPhase         slot 11 offset 20 (uint8 enum)
        vm.store(address(exec), bytes32(uint256(7)), planHash);
        vm.store(address(exec), bytes32(uint256(11)), bytes32(uint256(1) << 160)); // FlashLoanActive @ offset 20

        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.InvalidCallbackCaller.selector);
        exec.onMorphoFlashLoan(LOAN_AMOUNT, plan);
    }

    function test_revert_balancerCallbackFromNonBalancer() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(tokenA));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN_AMOUNT;
        uint256[] memory feeAmounts = new uint256[](1);
        feeAmounts[0] = 0;

        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.InvalidExecutionPhase.selector);
        exec.receiveFlashLoan(tokens, amounts, feeAmounts, hex"");
    }

    // ─── Admin gates ─────────────────────────────────────────────────

    function test_revert_executeFromNonOperator() public {
        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);
        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.UnauthorizedOperator.selector);
        exec.execute(plan);
    }

    function test_revert_pausedBlocksExecute() public {
        vm.prank(ownerAddr);
        exec.pause();

        Op[] memory ops = new Op[](2);
        ops[0] = _v2Op(address(tokenA), address(tokenB), LOAN_AMOUNT, 0);
        ops[1] = _v2Op(address(tokenB), address(tokenA), 0, GenericSequenceLib.FLAG_USE_PREV_RETURN);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, ops, 0, 0);

        vm.prank(operatorAddr);
        vm.expectRevert();
        exec.execute(plan);

        // Unpause restores.
        vm.prank(ownerAddr);
        exec.unpause();
        vm.prank(operatorAddr);
        exec.execute(plan);
        assertEq(tokenA.balanceOf(address(exec)), 210e18);
    }

    function test_revert_withdrawFromNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        exec.withdraw(address(tokenA), recipient, 1);
    }

    function test_revert_setAllowedTargetFromNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        exec.setAllowedTarget(address(0xBEEF), true);
    }

    // V10+: `configureMorpho` removed (Morpho is constructor-pinned).

    // ─── V4 storage-slot pinning (Task 3 of arb-full-parity) ──────────

    /// @dev Solidity cannot read another contract's private-field slot map at
    /// runtime, so this cannot name `_activeV4PoolManager`/`_activeV4TokenIn`
    /// directly. It proves the property that actually matters: slots 11/12 —
    /// the ones `GenericSequenceLib` raw-`sstore`s into under DELEGATECALL —
    /// are NOT occupied by any live field of this contract, and the alignment
    /// padding below them is genuinely dead space.
    ///
    /// This REPLACES a tautological `assertEq(10, 10)` that asserted nothing
    /// and would have sat green through the `operators`-mapping insertion that
    /// moved these fields from 10/11 to 11/12. The offline
    /// `forge inspect ArbExecutor storageLayout` remains the authority on the
    /// exact field names; this is the guard that fails in CI when they drift.
    function test_v4SlotConstantsMatchLayout() public {
        uint256 V4_PM_SLOT = 11;
        uint256 V4_TOKENIN_SLOT = 12;

        // Padding slots between `_activePlanHash` and the V4 fields must be
        // untouched dead space — if a real field ever lands there, the V4
        // fields have shifted and the lib would corrupt live state.
        assertEq(vm.load(address(exec), bytes32(uint256(8))), bytes32(0), "slot 8 must be reserved padding");
        assertEq(vm.load(address(exec), bytes32(uint256(9))), bytes32(0), "slot 9 must be reserved padding");
        assertEq(vm.load(address(exec), bytes32(uint256(10))), bytes32(0), "slot 10 must be reserved padding");

        // Snapshot every live field reachable through a public getter.
        address ownerBefore = exec.owner();
        address morphoBefore = exec.morphoBlue();
        bool pausedBefore = exec.paused();
        bool operatorBefore = exec.operators(operatorAddr);
        bool targetBefore = exec.allowedTargets(address(uniV2));
        address balProviderBefore = exec.allowedFlashProviders(exec.FLASH_PROVIDER_BALANCER());

        // Poke the slots the lib arms. If either collided with a live field,
        // one of the assertions below flips.
        vm.store(address(exec), bytes32(V4_PM_SLOT), bytes32(type(uint256).max));
        vm.store(address(exec), bytes32(V4_TOKENIN_SLOT), bytes32(type(uint256).max));

        assertEq(exec.owner(), ownerBefore, "owner must not live at slot 11/12");
        assertEq(exec.morphoBlue(), morphoBefore, "morphoBlue must not live at slot 11/12");
        assertEq(exec.paused(), pausedBefore, "paused must not live at slot 11/12");
        assertEq(exec.operators(operatorAddr), operatorBefore, "operators must not live at slot 11/12");
        assertEq(exec.allowedTargets(address(uniV2)), targetBefore, "allowedTargets must not live at slot 11/12");
        assertEq(
            exec.allowedFlashProviders(exec.FLASH_PROVIDER_BALANCER()),
            balProviderBefore,
            "allowedFlashProviders must not live at slot 11/12"
        );
    }

    function test_v4UnlockSelectorPin() public pure {
        assertEq(bytes4(keccak256("unlock(bytes)")), bytes4(0x48c89491));
    }

    // ─── unlockCallback + V4 hook allowlist (Task 4 of arb-full-parity) ───

    function test_unlockCallback_whenNotArmed_reverts() public {
        // Not in flash, not armed → must revert (fail-closed re-entry guard).
        vm.expectRevert(); // InvalidExecutionPhase or InvalidCallbackCaller
        exec.unlockCallback(abi.encode(bytes(""), int256(0)));
    }

    function test_setV4HookAllowed_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(); // Ownable: caller is not the owner
        exec.setV4HookAllowed(address(0x1234), true);
        // owner path:
        vm.prank(ownerAddr);
        exec.setV4HookAllowed(address(0x1234), true);
        assertTrue(exec.allowedV4Hooks(address(0x1234)));
    }

    // ─── Multi-operator (parallel nonce streams) ──────────────────────
    //
    // A SINGLE immutable operator forces every send through one nonce
    // stream: one stuck tx jams the queue, and the same-nonce bid fan-out
    // has to fight its own replacements. The top competitor runs NINE
    // rotating operator EOAs against one executor for exactly this reason
    // (measured on-chain, 3-month window). `operator` was immutable, so
    // this is only fixable at deploy time — hence before the first deploy.

    function test_setOperator_secondOperatorCanExecute() public {
        address operator2 = address(0xB0B2);
        _fundAndAllowlist();

        vm.prank(ownerAddr);
        exec.setOperator(operator2, true);
        assertTrue(exec.operators(operator2), "operator2 registered");

        Op[] memory ops = new Op[](2);
        ops[0] = _swapOp(address(loan), 100e18, address(mid), 100e18);
        ops[1] = _swapOp(address(mid), 100e18, address(loan), 110e18);
        bytes memory planData = _encodeArbPlan(FLASH_MORPHO, address(loan), 100e18, ops, 0, 5e18);

        vm.prank(operator2);
        exec.execute(planData);
        assertEq(loan.balanceOf(address(exec)), 10e18, "arb profit retained via second operator");
    }

    function test_setOperator_constructorOperatorStillAuthorized() public view {
        assertTrue(exec.operators(operatorAddr), "constructor operator seeded");
    }

    function test_setOperator_revokedOperatorReverts() public {
        _fundAndAllowlist();
        vm.prank(ownerAddr);
        exec.setOperator(operatorAddr, false);

        Op[] memory ops = new Op[](2);
        ops[0] = _swapOp(address(loan), 100e18, address(mid), 100e18);
        ops[1] = _swapOp(address(mid), 100e18, address(loan), 110e18);
        bytes memory planData = _encodeArbPlan(FLASH_MORPHO, address(loan), 100e18, ops, 0, 5e18);

        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.UnauthorizedOperator.selector);
        exec.execute(planData);
    }

    function test_setOperator_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(); // Ownable: caller is not the owner
        exec.setOperator(attacker, true);
        assertFalse(exec.operators(attacker), "attacker must not self-register");
    }

    function test_setOperator_zeroAddressReverts() public {
        vm.prank(ownerAddr);
        vm.expectRevert(ArbExecutor.ZeroAddress.selector);
        exec.setOperator(address(0), true);
    }
}
