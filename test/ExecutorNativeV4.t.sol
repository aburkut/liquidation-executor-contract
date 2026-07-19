// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecutorTest} from "./Executor.t.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {MockGenericDex} from "./ExecutorGenericSequence.t.sol";

/// Task 1 — dedicated `_v4Armed` sentinel decoupled from `tokenIn != 0`.
///
/// Native-ETH V4 legs (tokenIn == address(0)) are still rejected upstream by
/// `_validateLeg` (`leg.srcToken == address(0) -> ZeroAddress`) and would
/// also trip `_executeUniV4Leg`'s `IERC20(tokenIn).balanceOf` call (calling
/// an ERC20 method on address(0) reverts — no code there). Loosening those
/// gates is later tasks' scope (settle path / unwrap / containment cap), not
/// this one. This test therefore isolates ONLY the `unlockCallback` re-entry
/// sentinel: it primes the executor's storage exactly the way
/// `_executeUniV4Leg` would mid-unlock for a native-ETH leg (phase armed, PM
/// pinned, tokenIn left at its zero default) and proves the callback no
/// longer bounces off `InvalidCallbackCaller` merely because tokenIn == 0.
contract ExecutorNativeV4Test is ExecutorTest {
    // Storage layout (forge inspect LiquidationExecutor storage-layout):
    //   slot 10 = _activeV4PoolManager (address, offset 0) | _executionPhase (uint8, offset 20)
    //   slot 11 = _activeV4TokenIn     (address, offset 0) | _v4Armed        (bool,   offset 20)
    uint256 constant V4_PM_PHASE_SLOT = 10;
    uint256 constant V4_TOKENIN_ARMED_SLOT = 11;
    uint256 constant PHASE_FLASHLOAN_ACTIVE = 1; // ExecutionPhase.FlashLoanActive

    /// Prime storage as if `_executeUniV4Leg` were mid-unlock for a
    /// native-ETH leg: PM pinned, phase active, tokenIn left at its zero
    /// default (native), armed bit set iff `setArmedBit`.
    function _armNativeCallback(bool setArmedBit) internal {
        bytes32 slot10 = bytes32(uint256(uint160(address(uniV4Mock)))) | bytes32(PHASE_FLASHLOAN_ACTIVE << 160);
        vm.store(address(executor), bytes32(V4_PM_PHASE_SLOT), slot10);

        bytes32 slot11 = setArmedBit ? bytes32(uint256(1) << 160) : bytes32(0);
        vm.store(address(executor), bytes32(V4_TOKENIN_ARMED_SLOT), slot11);
    }

    /// Minimal well-formed single-hop unlock payload: (inner, amountSpec)
    /// where inner = (tokenIn[ignored by the callback decode], tokenOut,
    /// fee, tickSpacing, hook). The real tokenIn is read from storage, not
    /// from this payload — see `unlockCallback`'s substitution-drain note.
    function _nativeUnlockData() internal view returns (bytes memory) {
        bytes memory inner = abi.encode(address(0), address(loanToken), uint24(3000), int24(60), address(0));
        return abi.encode(inner, int256(-1 ether));
    }

    /// PRIMARY TASK-1 TEST (TDD): fails pre-fix with InvalidCallbackCaller
    /// (tokenIn==0 trips the old sentinel even though PM+phase are valid).
    /// Passes post-fix: the armed bit — not tokenIn — gates the callback,
    /// so it either returns or reverts with something OTHER than
    /// InvalidCallbackCaller (the out-of-scope settle-path revert for a
    /// native tokenIn is acceptable and expected at this task's boundary).
    function test_nativeEthV4Leg_arms_and_callbacks() public {
        _armNativeCallback(true);

        vm.prank(address(uniV4Mock));
        try executor.unlockCallback(_nativeUnlockData()) {
        // Reached and returned — arming alone was enough; nothing
        // further to assert for Task 1's scope.
        }
        catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            assertTrue(
                sel != LiquidationExecutor.InvalidCallbackCaller.selector,
                "armed native-ETH callback must not bounce off the sentinel"
            );
        }
    }

    /// Bit-exactness control: the same PM + phase setup but WITHOUT the
    /// armed bit must still revert InvalidCallbackCaller — proving the new
    /// guard truly gates on `_v4Armed` (and hasn't merely been widened to
    /// let everything through). Also passes pre-fix (tokenIn==0 already
    /// reverts there), so it's a sanity/invariant check, not the TDD driver.
    function test_unarmedCallback_stillRejected() public {
        _armNativeCallback(false);

        vm.prank(address(uniV4Mock));
        vm.expectRevert(LiquidationExecutor.InvalidCallbackCaller.selector);
        executor.unlockCallback(_nativeUnlockData());
    }

    // ═══════════════════════════════════════════════════════════════════
    // Task 2 — native-ETH settle{value} in runV4UnlockSwap
    // ═══════════════════════════════════════════════════════════════════

    /// Same shape as `_nativeUnlockData()` but with a caller-chosen
    /// exact-in `amountSpec` (SELL: negative = exact input wei).
    function _nativeUnlockData(uint256 amountIn) internal view returns (bytes memory) {
        bytes memory inner = abi.encode(address(0), address(loanToken), uint24(3000), int24(60), address(0));
        return abi.encode(inner, -int256(amountIn));
    }

    /// Drives a native-ETH single-hop V4 leg through the real
    /// `unlockCallback` -> `UniswapLib.runV4UnlockSwap` path: primes the
    /// same mid-unlock storage `_armNativeCallback(true)` uses (PM pinned,
    /// phase active, tokenIn left at its native/zero default, armed), funds
    /// the executor with `amountIn` wei (standing in for the Task-3 unwrap
    /// this task deliberately does not implement), and lets the PM mock
    /// pull `settle{value: amountIn}()`.
    function _runNativeV4Leg(uint256 amountIn) internal {
        _armNativeCallback(true);
        vm.deal(address(executor), amountIn);

        vm.prank(address(uniV4Mock));
        executor.unlockCallback(_nativeUnlockData(amountIn));
    }

    /// TDD driver for Task 2: pre-fix this reverts (validator rejects
    /// native tokenIn, or the ERC20-only settle path sends no value).
    /// Post-fix: `pm.settle{value: amountIn}()` forwards exactly amountIn
    /// wei and `pm.take` credits the executor with tokenOut (loanToken).
    function test_nativeEthV4_settles_with_value() public {
        uint256 amountIn = 5 ether;
        uint256 loanBefore = loanToken.balanceOf(address(executor));

        _runNativeV4Leg(amountIn);

        assertEq(uniV4Mock.settledValue(), amountIn, "must settle native value");
        assertGt(loanToken.balanceOf(address(executor)), loanBefore, "executor must receive swapped-out tokenOut");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Task 3 — FLAG_WETH_UNWRAP: convert WETH collateral to native ETH
    // before a native-ETH V4 leg. Isolated to the unwrap op itself — no
    // V4/native leg wired here (that's Task 5's fork-test scope).
    // ═══════════════════════════════════════════════════════════════════

    uint32 internal constant FLAG_WETH_UNWRAP = 1 << 3;
    uint16 internal constant DEX_AMOUNT_POS = 68; // selector(4) + tokenIn(32) + tokenOut(32)

    MockGenericDex internal genericDex;

    function _unwrapSetUp() internal {
        genericDex = new MockGenericDex();
        vm.prank(owner);
        executor.setAllowedTarget(address(genericDex), true);
        loanToken.mint(address(genericDex), 1_000_000e18);
    }

    /// A GENERIC_SEQUENCE op that unwraps `amount` of WETH into native ETH.
    /// `target`/`outToken` are left at their zero default: the unwrap branch
    /// never calls `op.target` (it calls `weth.withdraw` internally) and has
    /// no ERC20 output to delta-check.
    function _unwrapOp(uint256 amount) internal view returns (Op memory op) {
        op.srcToken = address(mockWeth);
        op.amountIn = amount;
        op.flags = FLAG_WETH_UNWRAP;
    }

    /// A direct-call dex op that spends WETH to produce loanToken — same
    /// srcToken (and so the same per-srcToken cap bucket) as the unwrap op,
    /// used to satisfy the repay gate alongside it.
    function _repaySwapOp(uint256 amountIn, uint256 rate) internal view returns (Op memory op) {
        op.target = address(genericDex);
        op.srcToken = address(mockWeth);
        op.outToken = address(loanToken);
        op.amountIn = amountIn;
        op.fromAmountPos = DEX_AMOUNT_POS;
        op.callData = abi.encodeWithSelector(
            MockGenericDex.swap.selector, address(mockWeth), address(loanToken), uint256(0), rate
        );
    }

    /// Builds a GENERIC_SEQUENCE plan whose liquidation action seizes
    /// `collateralReward` of WETH (debtToCover == the full flash-loan amount,
    /// the standard single-shot pattern: loanBefore == 0 at the start of the
    /// op-loop, so the repay gate measures the ops' full output).
    function _wethCollateralPlan(Op[] memory ops, uint256 collateralReward) internal returns (bytes memory) {
        aavePool.setLiquidationCollateralReward(collateralReward);
        LiquidationExecutor.Action[] memory actions = _singleAction(
            1, _buildAaveV3LiquidationAction(address(mockWeth), address(loanToken), address(0x1234), LOAN_AMOUNT, false)
        );
        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.ops = ops;
        sp.profitToken = address(loanToken);
        sp.minProfitAmount = 0;
        return _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, sp);
    }

    /// PRIMARY TASK-3 TEST (TDD): seeds the executor with WETH collateral via
    /// a real liquidation, then runs a two-op GENERIC_SEQUENCE — op0 repays
    /// the flash loan (WETH -> loanToken through a direct-call dex), op1
    /// unwraps the remaining WETH into native ETH. Proves the unwrap op
    /// converts WETH -> ETH 1:1 and is contained by the existing
    /// per-srcToken cap (WETH is the collateral asset here).
    function test_unwrap_op_converts_weth_to_eth() public {
        _unwrapSetUp();

        uint256 unwrapAmount = 10 ether;
        uint256 swapAmount = 1000e18; // @ 1.1x covers LOAN_AMOUNT + FLASH_FEE (1001e18)

        Op[] memory ops = new Op[](2);
        ops[0] = _repaySwapOp(swapAmount, 1.1e18);
        ops[1] = _unwrapOp(unwrapAmount);

        // Seize EXACTLY swap + unwrap of WETH this tx, so the containment cap
        // (collateralDelta) admits the full spend and the executor's STANDING
        // WETH (pre-seeded in setUp) is neither touched nor needed.
        bytes memory plan = _wethCollateralPlan(ops, swapAmount + unwrapAmount);

        uint256 ethBefore = address(executor).balance;
        uint256 wethBefore = mockWeth.balanceOf(address(executor));

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Core proof: N WETH became N native ETH in the executor's balance.
        assertEq(address(executor).balance, ethBefore + unwrapAmount, "executor ETH must rise by the unwrapped amount");
        // The seized WETH (swap + unwrap) was fully consumed — net WETH change
        // is zero, so the ETH increase is genuinely funded by an unwrap (not a
        // mint) AND the standing balance is preserved by the per-srcToken cap.
        assertEq(
            mockWeth.balanceOf(address(executor)),
            wethBefore,
            "seized WETH fully spent (swap + unwrap); standing WETH preserved"
        );
    }

    /// Security invariant: the flag must only ever call `withdraw` on the
    /// executor's OWN constructor-pinned `weth`, never an operator-chosen
    /// address — otherwise FLAG_WETH_UNWRAP would be an open call surface to
    /// any contract exposing `withdraw(uint256)`.
    function test_unwrapOp_WrongSrcToken_Reverts() public {
        _unwrapSetUp();

        // A real ERC20 that is NOT the executor's constructor-pinned `weth`
        // (collateralToken has a working `balanceOf`, so the per-srcToken
        // snapshot succeeds and the lib's `srcToken == weth` guard is what
        // fires — proving the flag can't `withdraw` on an arbitrary address).
        Op memory op = _unwrapOp(1 ether);
        op.srcToken = address(collateralToken);
        bytes memory plan = _wethCollateralPlan(_oneOp(op), 1 ether);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    /// FULL_BALANCE/PREV_RETURN inject an INPUT amount; an unwrap op's
    /// `amountIn` is an explicit WETH amount, not derived from either — the
    /// combination must be rejected rather than silently mis-sized.
    function test_unwrapOp_FullBalanceCombo_Reverts() public {
        _unwrapSetUp();

        Op memory op = _unwrapOp(1 ether);
        op.flags = FLAG_WETH_UNWRAP | (1 << 0); // | FLAG_USE_FULL_BALANCE
        bytes memory plan = _wethCollateralPlan(_oneOp(op), 1 ether);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    /// Containment cap re-audit (mirrors
    /// `ExecutorGenericSequenceTest.test_GenericSequence_StandingNonCollateralDrain_Reverts`):
    /// a STANDING WETH balance (not this tx's collateral) must not be
    /// unwrappable — the per-srcToken cap bounds WETH spend at
    /// `collateralDelta`, zero when WETH isn't this tx's collateral asset.
    function test_unwrapOp_StandingWeth_Reverts() public {
        _unwrapSetUp();

        uint256 standing = 10 ether;
        mockWeth.mint(address(executor), standing); // pre-existing, not seized this tx

        // Collateral asset is collateralToken (not WETH) this time, so the
        // standing WETH's allowed spend is 0.
        aavePool.setLiquidationCollateralReward(COLLATERAL_REWARD);
        LiquidationExecutor.Action[] memory actions = _singleAction(
            1,
            _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), LOAN_AMOUNT, false
            )
        );

        Op[] memory ops = new Op[](2);
        ops[0] = _repaySwapOp(0, 1.1e18); // placeholder, overwritten below
        ops[0].srcToken = address(collateralToken);
        ops[0].amountIn = COLLATERAL_REWARD;
        ops[0].callData = abi.encodeWithSelector(
            MockGenericDex.swap.selector, address(collateralToken), address(loanToken), uint256(0), 1.1e18
        );
        ops[1] = _unwrapOp(standing);

        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.ops = ops;
        sp.profitToken = address(loanToken);
        sp.minProfitAmount = 0;
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, sp);

        vm.prank(operatorAddr);
        vm.expectRevert(); // CollateralOverspent(spent=standing, allowed=0) on WETH
        executor.execute(plan);
    }

    function _oneOp(Op memory op) internal pure returns (Op[] memory ops) {
        ops = new Op[](1);
        ops[0] = op;
    }
}
