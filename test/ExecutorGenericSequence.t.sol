// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecutorTest} from "./Executor.t.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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
        returns (LiquidationExecutor.Op memory op)
    {
        op.target = address(dex);
        op.srcToken = tokenIn;
        op.outToken = tokenOut;
        op.flags = flags;
        op.fromAmountPos = AMOUNT_POS;
        op.callData = _dexCall(tokenIn, tokenOut, rate);
    }

    function _genericPlan(LiquidationExecutor.Op[] memory ops, address profitTkn, uint256 minProfit)
        internal
        view
        returns (bytes memory)
    {
        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.ops = ops;
        sp.profitToken = profitTkn;
        sp.minProfitAmount = minProfit;
        return _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
    }

    function _oneOp(LiquidationExecutor.Op memory op) internal pure returns (LiquidationExecutor.Op[] memory ops) {
        ops = new LiquidationExecutor.Op[](1);
        ops[0] = op;
    }

    // ── validation gates (pre-flashloan) ─────────────────────────────

    function test_GenericSequence_EmptyOps_Reverts() public {
        bytes memory plan = _genericPlan(new LiquidationExecutor.Op[](0), address(mockWeth), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.EmptyOps.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_TooManyOps_Reverts() public {
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](33);
        for (uint256 i = 0; i < 33; ++i) {
            ops[i].target = address(morphoBlue); // allowlisted; length check fires first
        }
        bytes memory plan = _genericPlan(ops, address(mockWeth), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.TooManyOps.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_UnlistedTarget_Reverts() public {
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](1);
        ops[0].target = address(0xDEAD);
        bytes memory plan = _genericPlan(ops, address(mockWeth), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.TargetNotAllowed.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_ConflictsWithOtherShape_Reverts() public {
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](1);
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
        LiquidationExecutor.Op memory op =
            _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
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
        LiquidationExecutor.Op memory op =
            _swapOp(address(collateralToken), address(loanToken), 0.5e18, FLAG_FULL_BALANCE);
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 0);
        vm.prank(operatorAddr);
        vm.expectRevert(); // InsufficientRepayOutput(actual, required)
        executor.execute(plan);
    }

    function test_GenericSequence_UnderProfit_Reverts() public {
        // Repay is covered (1.1×) but minProfit is set absurdly high.
        LiquidationExecutor.Op memory op =
            _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
        bytes memory plan = _genericPlan(_oneOp(op), address(loanToken), 1_000_000e18);
        vm.prank(operatorAddr);
        vm.expectRevert(); // InsufficientProfit(actual, required)
        executor.execute(plan);
    }

    function test_GenericSequence_OOBPatch_Reverts() public {
        // fromAmountPos past the end of callData → CalldataPatchOOB.
        LiquidationExecutor.Op memory op =
            _swapOp(address(collateralToken), address(loanToken), 1.1e18, FLAG_FULL_BALANCE);
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
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](2);
        ops[0] = _swapOp(address(collateralToken), address(interToken), 1e18, FLAG_FULL_BALANCE);
        ops[1] = _swapOp(address(interToken), address(loanToken), 1.1e18, FLAG_PREV_RETURN);
        bytes memory plan = _genericPlan(ops, address(loanToken), 1e18);

        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(interToken.allowance(address(executor), address(dex)), 0, "inter approval reset");
    }
}
