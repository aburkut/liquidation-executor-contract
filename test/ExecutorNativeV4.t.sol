// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecutorTest} from "./Executor.t.sol";
import {Action, AaveV3Action, AaveV2Liquidation, MorphoLiquidation} from "../src/types/SwapTypes.sol";
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
        Action[] memory actions = _singleAction(
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
        Action[] memory actions = _singleAction(
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

    // ═══════════════════════════════════════════════════════════════════
    // Task 4 (SECURITY-CRITICAL) — native ETH (srcToken == address(0)) as a
    // valid, CAPPED srcToken in GENERIC_SEQUENCE.
    //
    // Cap reasoning under test: the per-srcToken ETH snapshot is taken at
    // `run()` entry, BEFORE any FLAG_WETH_UNWRAP op credits ETH. The only
    // ETH this tx legitimately produces is the unwrap of THIS tx's seized
    // WETH collateral — a post-snapshot CREDIT. A legit native leg therefore
    // nets >= 0 against the snapshot, so the exact containment bound for
    // ETH is `allowed = 0`: any net dip below the snapshot is standing /
    // donated ETH leaving the contract and must revert CollateralOverspent.
    // (Granting collateralDelta to ETH instead would DOUBLE-COUNT — the
    // WETH bucket already grants collateralDelta to the unwrap — letting a
    // compromised operator burn up to collateralDelta of standing ETH per
    // tx through a crafted V4 pool. test_nativeEth_standingSpend_
    // withoutUnwrap_reverts pins that leak closed.)
    // ═══════════════════════════════════════════════════════════════════

    uint32 internal constant FLAG_V4_UNLOCK = 1 << 2;

    /// A native-ETH V4 single-hop exact-out op: srcToken == address(0)
    /// (native), pays ETH via `settle{value}` inside the unlock callback,
    /// takes `amountOut` of `tokenOut`. At SWAP_RATE = 1.1e18 the ETH owed
    /// is amountOut * 1e18 / 1.1e18.
    function _nativeV4Op(address tokenOut, uint256 amountOut) internal view returns (Op memory op) {
        op.target = address(uniV4Mock);
        op.srcToken = address(0); // native ETH
        op.outToken = tokenOut;
        op.flags = FLAG_V4_UNLOCK;
        op.amountIn = amountOut; // reinterpreted: exact-out amountSpec
        op.callData = abi.encode(address(0), tokenOut, uint24(500), int24(10), address(0));
    }

    /// Happy path: unwrap 10 WETH collateral -> 10 ETH, then a native V4 op
    /// spends EXACTLY those 10 ETH (exact-out 11e18 loanToken @ 1.1). The
    /// sequence must succeed, settle 10 ether native, and leave the
    /// executor's ETH balance exactly where it started (net delta 0).
    function test_nativeEth_happyPath_spendsExactlyUnwrappedCollateral() public {
        _unwrapSetUp();

        uint256 swapAmount = 1000e18; // @1.1 -> 1100e18, covers repay 1001e18
        uint256 unwrapAmount = 10 ether;

        Op[] memory ops = new Op[](3);
        ops[0] = _repaySwapOp(swapAmount, 1.1e18);
        ops[1] = _unwrapOp(unwrapAmount);
        ops[2] = _nativeV4Op(address(loanToken), 11e18); // owes exactly 10 ether ETH

        bytes memory plan = _wethCollateralPlan(ops, swapAmount + unwrapAmount);

        uint256 ethBefore = address(executor).balance;

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(uniV4Mock.settledValue(), unwrapAmount, "native leg must settle exactly the unwrapped ETH");
        assertEq(address(executor).balance, ethBefore, "ETH net delta must be zero (unwrap +10, settle -10)");
    }

    // ═══════════════════════════════════════════════════════════════════
    // FLAG_V4_EXACT_IN (commit d46c3d9) — was shipped with NO contract test.
    // These pin the exact-IN native path (sell fixed ETH, variable output)
    // and its per-op input ceiling.
    // ═══════════════════════════════════════════════════════════════════

    uint32 internal constant FLAG_V4_EXACT_IN = 1 << 4;

    /// A native-ETH V4 single-hop EXACT-IN op: srcToken == 0 (native), sells
    /// exactly `ethIn` ETH via `settle{value}`, takes `ethIn * rate` of
    /// `tokenOut`. `amountIn` is the exact INPUT (negated to a negative
    /// amountSpec by the lib), unlike the exact-out op where it is the output.
    function _nativeV4ExactInOp(address tokenOut, uint256 ethIn) internal view returns (Op memory op) {
        op.target = address(uniV4Mock);
        op.srcToken = address(0); // native ETH
        op.outToken = tokenOut;
        op.flags = FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN;
        op.amountIn = ethIn; // exact-IN: ETH sold (variable output)
        op.callData = abi.encode(address(0), tokenOut, uint24(500), int24(10), address(0));
    }

    /// Happy path (exact-IN): unwrap 10 WETH -> 10 ETH, then sell EXACTLY
    /// those 10 ETH exact-in through the native pool (rate 1.1 -> 11 loanToken).
    /// The sequence must succeed, settle exactly 10 ether, and leave the
    /// executor's ETH balance where it started (unwrap +10, settle -10).
    function test_nativeEth_exactIn_happyPath_sellsExactlyUnwrappedEth() public {
        _unwrapSetUp();

        uint256 swapAmount = 1000e18; // WETH->loanToken base repay: 1100 @1.1 covers 1001
        uint256 unwrapAmount = 10 ether;

        Op[] memory ops = new Op[](3);
        ops[0] = _repaySwapOp(swapAmount, 1.1e18);
        ops[1] = _unwrapOp(unwrapAmount);
        ops[2] = _nativeV4ExactInOp(address(loanToken), unwrapAmount); // sell exactly 10 ETH

        bytes memory plan = _wethCollateralPlan(ops, swapAmount + unwrapAmount);

        uint256 ethBefore = address(executor).balance;

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(uniV4Mock.settledValue(), unwrapAmount, "exact-in must settle exactly the unwrapped ETH");
        assertEq(address(executor).balance, ethBefore, "ETH net delta must be zero");
    }

    /// The per-op input ceiling (V4InputOverspent): a buggy/adversarial pool
    /// that settles MORE ETH than the exact-in `amount` must be caught at the
    /// op boundary — NOT only by the end-of-sequence containment cap. The
    /// executor is given standing ETH so the over-pull settle CAN pay; the
    /// ceiling, not an out-of-funds failure, must stop it.
    function test_nativeEth_exactIn_overpull_reverts_V4InputOverspent() public {
        _unwrapSetUp();

        vm.deal(address(executor), 5 ether); // standing headroom for the over-pull
        uniV4Mock.setInputInflateBps(11_000); // settle 10% more than the 10 ETH asked

        uint256 swapAmount = 1000e18;
        uint256 unwrapAmount = 10 ether;

        Op[] memory ops = new Op[](3);
        ops[0] = _repaySwapOp(swapAmount, 1.1e18);
        ops[1] = _unwrapOp(unwrapAmount);
        ops[2] = _nativeV4ExactInOp(address(loanToken), unwrapAmount); // asks 10, pool pulls 11

        bytes memory plan = _wethCollateralPlan(ops, swapAmount + unwrapAmount);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.V4InputOverspent.selector, 11 ether, unwrapAmount));
        executor.execute(plan);
    }

    /// MANDATORY SECURITY TEST 1: a native op that settles MORE ETH than the
    /// unwrap credited (11 ether settled vs 10 unwrapped — the extra wei can
    /// only come from standing ETH) must revert CollateralOverspent. The
    /// executor is deliberately given standing ETH headroom so the settle
    /// itself CAN pay — the containment cap, not an out-of-funds call
    /// failure, must be what stops the plan.
    function test_nativeEth_overspend_reverts_CollateralOverspent() public {
        _unwrapSetUp();

        vm.deal(address(executor), 5 ether); // standing headroom

        uint256 swapAmount = 1000e18;
        uint256 unwrapAmount = 10 ether;

        Op[] memory ops = new Op[](3);
        ops[0] = _repaySwapOp(swapAmount, 1.1e18);
        ops[1] = _unwrapOp(unwrapAmount);
        ops[2] = _nativeV4Op(address(loanToken), 12.1e18); // owes 11 ether > 10 unwrapped

        bytes memory plan = _wethCollateralPlan(ops, swapAmount + unwrapAmount);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.CollateralOverspent.selector, 1 ether, 0));
        executor.execute(plan);
    }

    /// MANDATORY SECURITY TEST 2 (THE KEY TEST): the executor holds large
    /// STANDING ETH. A legit native sequence spends only its own unwrapped
    /// collateral; the standing ETH must survive to the wei.
    function test_nativeEth_cannot_drain_standing_eth() public {
        _unwrapSetUp();

        uint256 standing = 100 ether;
        vm.deal(address(executor), standing);

        uint256 swapAmount = 1000e18;
        uint256 unwrapAmount = 10 ether;

        Op[] memory ops = new Op[](3);
        ops[0] = _repaySwapOp(swapAmount, 1.1e18);
        ops[1] = _unwrapOp(unwrapAmount);
        ops[2] = _nativeV4Op(address(loanToken), 11e18); // owes exactly the 10 unwrapped

        bytes memory plan = _wethCollateralPlan(ops, swapAmount + unwrapAmount);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(uniV4Mock.settledValue(), unwrapAmount, "legit spend = unwrapped collateral only");
        assertEq(address(executor).balance, standing, "standing ETH must survive untouched");
    }

    /// ADVERSARIAL PIN of the allowed=0 bound: collateral IS WETH with a huge
    /// collateralDelta, but the plan runs a native op WITHOUT any unwrap —
    /// every wei it settles is STANDING ETH. Under a naive
    /// `allowed = (collateralAsset == weth ? collateralDelta : 0)` cap this
    /// plan would PASS (10 ether < collateralDelta) and burn standing ETH
    /// through an operator-crafted V4 pool; the correct allowed=0 bound must
    /// revert CollateralOverspent(10 ether, 0).
    function test_nativeEth_standingSpend_withoutUnwrap_reverts() public {
        _unwrapSetUp();

        vm.deal(address(executor), 100 ether); // standing

        uint256 swapAmount = 1000e18;

        Op[] memory ops = new Op[](2);
        ops[0] = _repaySwapOp(swapAmount, 1.1e18);
        ops[1] = _nativeV4Op(address(loanToken), 11e18); // owes 10 ether, all standing

        bytes memory plan = _wethCollateralPlan(ops, swapAmount);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.CollateralOverspent.selector, 10 ether, 0));
        executor.execute(plan);
    }

    /// MANDATORY SECURITY TEST 3: srcToken == address(0) must ONLY be valid
    /// on a native-aware (FLAG_V4_UNLOCK) op. A plain direct-call op with
    /// srcToken == 0 and no native flag must STILL revert InvalidPlan —
    /// 0x0 can never mean "unset".
    function test_plainOp_srcTokenZero_still_reverts_InvalidPlan() public {
        _unwrapSetUp();

        Op memory op = _repaySwapOp(1 ether, 1.1e18); // direct-call shape, flags == 0
        op.srcToken = address(0);
        bytes memory plan = _wethCollateralPlan(_oneOp(op), 1 ether);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }
}
