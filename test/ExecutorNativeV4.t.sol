// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecutorTest} from "./Executor.t.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";

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
}
