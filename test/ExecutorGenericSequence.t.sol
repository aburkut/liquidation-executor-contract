// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecutorTest} from "./Executor.t.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";

/// Phase 1, step 1 — adversarial coverage for the GENERIC_SEQUENCE validation
/// gates. These all revert in `execute()` BEFORE the flashloan, so no DEX mock
/// is needed. Runtime coverage (happy path, under-repay, under-profit, OOB
/// calldata patch) lands with the direct-call DEX mock in the next step.
contract ExecutorGenericSequenceTest is ExecutorTest {
    // Build a minimal-but-valid Plan whose swap shape is GENERIC_SEQUENCE with
    // the supplied ops. Everything else (loanToken, actions, profitToken) is
    // valid so validation reaches the op-list checks.
    function _genericPlan(LiquidationExecutor.Op[] memory ops) internal view returns (bytes memory) {
        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.ops = ops;
        sp.profitToken = address(mockWeth); // non-zero (validation requires it)
        sp.minProfitAmount = 0;

        return _buildPlan(
            2, // morphoBlue flash provider
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            sp
        );
    }

    function _op(address target) internal pure returns (LiquidationExecutor.Op memory op) {
        op.target = target;
        op.srcToken = address(0);
        op.outToken = address(0);
        op.callData = "";
    }

    function test_GenericSequence_EmptyOps_Reverts() public {
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](0);
        bytes memory plan = _genericPlan(ops);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.EmptyOps.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_TooManyOps_Reverts() public {
        // MAX_OPS = 32 → 33 ops trips TooManyOps (before any target check).
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](33);
        for (uint256 i = 0; i < 33; ++i) {
            ops[i] = _op(address(morphoBlue)); // allowlisted, but length check fires first
        }
        bytes memory plan = _genericPlan(ops);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.TooManyOps.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_UnlistedTarget_Reverts() public {
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](1);
        ops[0] = _op(address(0xDEAD)); // never allowlisted
        bytes memory plan = _genericPlan(ops);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.TargetNotAllowed.selector);
        executor.execute(plan);
    }

    function test_GenericSequence_ConflictsWithOtherShape_Reverts() public {
        // hasGenericSequence + hasSplit → shape XOR guard trips.
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](1);
        ops[0] = _op(address(morphoBlue));

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
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](1);
        ops[0] = _op(address(morphoBlue));
        bytes memory plan = _genericPlan(ops);

        // A non-operator caller is rejected before any shape logic.
        vm.prank(address(0xBAD));
        vm.expectRevert(LiquidationExecutor.Unauthorized.selector);
        executor.execute(plan);
    }
}
