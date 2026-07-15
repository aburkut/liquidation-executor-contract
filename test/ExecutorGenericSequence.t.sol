// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecutorTest} from "./Executor.t.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";

interface IMiniERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// Minimal direct-call DEX: pull `amountIn` of tokenIn (caller must approve),
/// send `amountIn * rate / 1e18` of tokenOut. `amountIn` sits at calldata byte
/// offset 68 (selector 4 + tokenIn 32 + tokenOut 32), which the executor
/// patches with the resolved runtime amount.
contract MockGenericDex {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 rate) external {
        IMiniERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e18;
        IMiniERC20(tokenOut).transfer(msg.sender, out);
    }
}

/// Phase 1 GENERIC_SEQUENCE coverage.
///   * validation gates (revert before flashloan) — no DEX needed.
///   * runtime gates (revert inside _runGenericSequence / outer pipeline) —
///     exercised end-to-end through a direct-call MockGenericDex.
contract ExecutorGenericSequenceTest is ExecutorTest {
    MockGenericDex internal dex;
    MockERC20 internal interToken; // intermediate hop token for chaining

    uint32 internal constant FLAG_FULL_BALANCE = 1 << 0;
    uint32 internal constant FLAG_PREV_RETURN = 1 << 1;
    uint16 internal constant AMOUNT_POS = 68; // byte offset of `amountIn` in swap(...)

    function setUp() public virtual override {
        super.setUp();
        dex = new MockGenericDex();
        interToken = new MockERC20("Inter", "INT", 18);

        // Allowlist the direct-call DEX (owner-gated, reused primitive).
        vm.prank(owner);
        executor.setAllowedTarget(address(dex), true);

        // Fund the DEX so it can pay out swap outputs.
        loanToken.mint(address(dex), 1_000_000e18);
        interToken.mint(address(dex), 1_000_000e18);
        MockERC20(address(mockWeth)).mint(address(dex), 1_000_000e18);
    }

    // ── helpers ──────────────────────────────────────────────────────

    function _dexCall(address tokenIn, address tokenOut, uint256 rate) internal pure returns (bytes memory) {
        // amountIn placeholder (0) is overwritten at AMOUNT_POS at runtime.
        return abi.encodeWithSelector(MockGenericDex.swap.selector, tokenIn, tokenOut, uint256(0), rate);
    }

    function _swapOp(address tokenIn, address tokenOut, uint256 rate, uint32 flags)
        internal
        view
        returns (Op memory op)
    {
        op.target = address(dex);
        op.srcToken = tokenIn;
        op.outToken = tokenOut;
        op.flags = flags;
        op.fromAmountPos = AMOUNT_POS;
        op.callData = _dexCall(tokenIn, tokenOut, rate);
    }

    function _genericPlan(Op[] memory ops, address profitTkn, uint256 minProfit) internal view returns (bytes memory) {
        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.ops = ops;
        sp.profitToken = profitTkn;
        sp.minProfitAmount = minProfit;
        return _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
    }

    function _oneOp(Op memory op) internal pure returns (Op[] memory ops) {
        ops = new Op[](1);
        ops[0] = op;
    }

    // ── validation gates (pre-flashloan) ─────────────────────────────

    function test_GenericSequence_EmptyOps_Reverts() public {
        bytes memory plan = _genericPlan(new Op[](0), address(mockWeth), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.EmptyOps.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_TooManyOps_Reverts() public {
        Op[] memory ops = new Op[](33);
        for (uint256 i = 0; i < 33; ++i) {
            ops[i].target = address(morphoBlue); // allowlisted; length check fires first
        }
        bytes memory plan = _genericPlan(ops, address(mockWeth), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.TooManyOps.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_UnlistedTarget_Reverts() public {
        Op[] memory ops = new Op[](1);
        ops[0].target = address(0xDEAD);
        bytes memory plan = _genericPlan(ops, address(mockWeth), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.TargetNotAllowed.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_ConflictsWithOtherShape_Reverts() public {
        Op[] memory ops = new Op[](1);
        ops[0].target = address(dex);
        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.hasSplit = true; // conflict
        sp.ops = ops;
        sp.profitToken = address(mockWeth);
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.PlanShapeConflict.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_OnlyOperator() public {
        bytes memory plan = _genericPlan(
            _oneOp(_swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE)),
            address(loanToken),
            0
        );
        vm.prank(address(0xBAD));
        vm.expectRevert(LiquidationExecutor.Unauthorized.selector);
        executor.execute(plan);
    }

    // ── runtime gates (through the DEX) ──────────────────────────────

    function test_GenericSequence_DirectCall_HappyPath() public {
        // Full-balance collateral → loanToken at 1.1×: covers flashRepay
        // (1001e18) and leaves loanToken profit.
        Op memory op = _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 1e18);

        uint256 before = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        assertGe(loanToken.balanceOf(address(executor)), before, "profit retained after flash repay");
        // Approval fully reset (no lingering allowance to the DEX).
        assertEq(collateralToken.allowance(address(executor), address(dex)), 0, "approval reset");
    }

    function test_GenericSequence_UnderRepay_Reverts() public {
        // 0.5× output cannot cover the flash repay → InsufficientRepayOutput.
        Op memory op = _swapOp(address(collateralToken), address(loanToken), 0.5e18, FLAG_FULL_BALANCE);
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(); // InsufficientRepayOutput(actual, required)
        executor.execute(plan);
    }

    function test_GenericSequence_UnderProfit_Reverts() public {
        // Repay is covered (1.1×) but minProfit is set absurdly high.
        Op memory op = _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 1_000_000e18);
        vm.prank(operatorAddr);
        vm.expectRevert(); // InsufficientProfit(actual, required)
        executor.execute(plan);
    }

    function test_GenericSequence_OOBPatch_Reverts() public {
        // fromAmountPos past the end of callData → CalldataPatchOOB.
        Op memory op = _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
        op.fromAmountPos = 200; // callData is 132 bytes
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CalldataPatchOOB.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_PrevReturnChaining_HappyPath() public {
        // op0: full collateral → intermediate (1.0×); op1: prev-return
        // intermediate → loanToken (1.1×). Verifies output-of-prev feeds the
        // next op's amount, and the chain repays + profits.
        Op[] memory ops = new Op[](2);
        ops[0] = _swapOp(address(collateralToken), address(interToken), 1e18, FLAG_FULL_BALANCE);
        ops[1] = _swapOp(address(interToken), address(loanToken), 1.1e18, FLAG_PREV_RETURN);
        bytes memory plan = _genericPlan(ops, address(loanToken), 1e18);

        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(interToken.allowance(address(executor), address(dex)), 0, "inter approval reset");
    }

    // ── containment (audit fix): compromised operator cannot drain ──

    function test_GenericSequence_FullBalanceOnNonCollateral_Reverts() public {
        // FULL_BALANCE is permitted ONLY for the collateral asset, so it can
        // never sweep a standing balance of some other token.
        Op memory op = _swapOp(address(loanToken), address(loanToken), 1e18, FLAG_FULL_BALANCE);
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_CollateralOverspend_Reverts() public {
        // Pre-fund STANDING collateral, then try to spend more than this tx's
        // collateralDelta (COLLATERAL_REWARD) via an explicit literal amount →
        // CollateralOverspent (the containment cap).
        collateralToken.mint(address(executor), 500e18); // standing balance
        Op memory op = _swapOp(address(collateralToken), address(loanToken), 1.1e18, 0);
        op.amountIn = COLLATERAL_REWARD + 500e18; // dips into the standing 500e18
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(); // CollateralOverspent(spent, allowed)
        executor.execute(plan);
    }

    function test_GenericSequence_NonZeroValue_Reverts() public {
        Op memory op = _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
        op.value = 1; // native ETH forwarding forbidden
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    // Re-audit finding: the per-srcToken cap must protect a standing balance of
    // ANY token, not only the collateral asset. A sequence that repays via
    // collateral but ALSO spends a standing non-collateral balance (accumulated
    // WETH profit awaiting owner rescue) must revert.
    function test_GenericSequence_StandingNonCollateralDrain_Reverts() public {
        uint256 standing = 10e18;
        MockERC20(address(mockWeth)).mint(address(executor), standing); // standing profit

        Op[] memory ops = new Op[](2);
        // op0: legit collateral → loanToken, satisfies the repay gate.
        ops[0] = _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
        // op1: spend the standing WETH via an explicit literal amount.
        ops[1] = _swapOp(address(mockWeth), address(loanToken), 1e18, 0);
        ops[1].amountIn = standing;

        bytes memory plan = _genericPlan(ops, address(loanToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(); // CollateralOverspent(spent=standing, allowed=0) on WETH
        executor.execute(plan);
    }

    // ── FLAG_V4_UNLOCK ops (V4 single-hop exact-out via PoolManager) ──

    uint32 internal constant FLAG_V4_UNLOCK = 1 << 2;

    /// Build a V4 unlock op: exact-out `amountOut` of `tokenOut` paid from
    /// `tokenIn` through the mock PoolManager. callData is the RAW 160-byte
    /// single-hop v4SwapData 5-tuple (not selector-prefixed) — the lib wraps
    /// it into `unlock(abi.encode(inner, int256(amountOut)))` itself.
    function _v4Op(address tokenIn, address tokenOut, uint256 amountOut) internal view returns (Op memory op) {
        op.target = address(uniV4Mock);
        op.srcToken = tokenIn;
        op.outToken = tokenOut;
        op.flags = FLAG_V4_UNLOCK;
        op.amountIn = amountOut; // reinterpreted: exact-out amountSpec
        op.callData = abi.encode(tokenIn, tokenOut, uint24(500), int24(10), address(0));
    }

    /// Selector pin: the lib hardcodes `unlock(bytes)` = 0x48c89491 (same
    /// pinned-selector idiom as the Curve RouterNG dispatcher).
    function test_v4UnlockSelectorPin() public pure {
        assertEq(bytes4(keccak256("unlock(bytes)")), bytes4(0x48c89491), "unlock selector drifted");
    }

    /// Happy path: single V4 exact-out op repays the flash loan; leftover
    /// collateral is the profit. Passing THROUGH the executor's real
    /// `unlockCallback` (guards: `msg.sender == _activeV4PoolManager`,
    /// `_activeV4TokenIn != 0`) is what proves the lib armed the correct
    /// storage slots — wrong slot constants revert InvalidCallbackCaller.
    function test_GenericSequence_V4UnlockOp_ExactOut_HappyPath() public {
        uint256 repay = LOAN_AMOUNT + FLASH_FEE; // 1001e18 exact-out
        bytes32 slot10Before = vm.load(address(executor), bytes32(uint256(10)));

        Op memory op = _v4Op(address(collateralToken), address(loanToken), repay);
        bytes memory plan = _genericPlan(_oneOp(op), address(collateralToken), 1e18);

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Disarm proof: slot 10 (PM address bytes 0..19, packed with
        // _executionPhase at byte 20) is bit-identical to pre-execute — the
        // arm preserved the phase byte and the disarm cleared the PM. Slot 11
        // (tokenIn) is zero (CLAIMed by the callback, re-cleared by the lib).
        assertEq(vm.load(address(executor), bytes32(uint256(10))), slot10Before, "slot 10 must round-trip (PM + phase)");
        assertEq(vm.load(address(executor), bytes32(uint256(11))), bytes32(0), "tokenIn slot must be cleared");
    }

    /// Multihop v4SwapData (> 160 bytes) is forbidden on the op path — its
    /// hook allowlist walk lives in the structured-leg validator that generic
    /// ops bypass.
    function test_GenericSequence_V4UnlockOp_WrongDataLength_Reverts() public {
        Op memory op = _v4Op(address(collateralToken), address(loanToken), LOAN_AMOUNT + FLASH_FEE);
        op.callData =
            abi.encode(address(collateralToken), address(loanToken), uint24(500), int24(10), address(0), uint256(1)); // 192 bytes
        bytes memory plan = _genericPlan(_oneOp(op), address(collateralToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    /// FULL_BALANCE / PREV_RETURN inject an INPUT amount; a V4 op's amount is
    /// the exact-OUT spec — the combination must be rejected.
    function test_GenericSequence_V4UnlockOp_FullBalanceCombo_Reverts() public {
        Op memory op = _v4Op(address(collateralToken), address(loanToken), LOAN_AMOUNT + FLASH_FEE);
        op.flags = FLAG_V4_UNLOCK | FLAG_FULL_BALANCE;
        bytes memory plan = _genericPlan(_oneOp(op), address(collateralToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_V4UnlockOp_ZeroAmount_Reverts() public {
        Op memory op = _v4Op(address(collateralToken), address(loanToken), 0);
        bytes memory plan = _genericPlan(_oneOp(op), address(collateralToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    /// The op-target allowlist walk in the main contract covers V4 ops like
    /// every other op — an unlisted PoolManager never reaches the lib.
    function test_GenericSequence_V4UnlockOp_UnlistedPM_Reverts() public {
        MockV4PoolManager stray = new MockV4PoolManager(1.1e18);
        Op memory op = _v4Op(address(collateralToken), address(loanToken), LOAN_AMOUNT + FLASH_FEE);
        op.target = address(stray);
        bytes memory plan = _genericPlan(_oneOp(op), address(collateralToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.TargetNotAllowed.selector);
        executor.execute(plan);
    }

    /// The callback-time hook allowlist re-check stays authoritative on the
    /// op path (single-hop shape guarantees the branch that performs it).
    function test_GenericSequence_V4UnlockOp_DisallowedHook_Reverts() public {
        Op memory op = _v4Op(address(collateralToken), address(loanToken), LOAN_AMOUNT + FLASH_FEE);
        op.callData = abi.encode(address(collateralToken), address(loanToken), uint24(500), int24(10), address(0xBEEF));
        bytes memory plan = _genericPlan(_oneOp(op), address(collateralToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV4CallbackHook.selector);
        executor.execute(plan);
    }
}
