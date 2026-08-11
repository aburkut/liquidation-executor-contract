# Generic native-ETH for ANY DEX — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** Make native-ETH pools work on any leg of any DEX through the generic `Op[]` path, so adding a future DEX (native or ERC20, callback or not) needs only an owner `setAllowedTarget` tx + off-chain encoder — never a redeploy.

**Architecture:** Two surgical changes to the shared `GenericSequenceLib._executeOps` — (1) `FLAG_NATIVE_IN` forwards `call{value: amount}` for payable DEXes, bounded by the EXISTING per-srcToken containment cap on the `address(0)` bucket + a per-op input ceiling; (2) native output delta-checks via `_balOf`. Callback DEXes route through their router (off-chain policy, no contract code). Shared lib ⇒ both `LiquidationExecutor` (0xB543) and `ArbExecutor` (PR #32) get it and both redeploy+re-audit.

**Tech Stack:** Solidity ^0.8.24, Foundry, mainnet-fork tests. Design spec: `docs/2026-07-24-generic-native-any-dex-design.md`.

## Global Constraints

- Branch: `feat/arb-full-parity` (continues; the native change layers on top of the arb-parity work already on this branch). Design spec committed at `14e3551`.
- `docs/` is `.gitignore`d — commit docs with `git add -f`. Do NOT commit `broadcast/*.json`.
- Audited MONEY CONTRACT, SHARED library. BOTH suites must stay 100% green every task: arb (`test/ArbExecutor*.t.sol`) AND liquidation (whole repo). Run `forge test --no-match-path "test/*Fork*.t.sol"` as the regression gate (~10 min; run once per task at the end). Non-fork baseline: **1772** passing.
- CI disabled (Actions minutes exhausted) — verify locally.
- Current `GenericSequenceLib` anchors: FLAG consts lines 57-101, `FLAG_KNOWN_MASK` at 101, `op.value != 0` ban at 252, `srcToken == address(0) && FLAG_V4_UNLOCK == 0` reject at 261, `~FLAG_KNOWN_MASK` reject at 264, native-out hardcodes at 305 + 425, `_balOf` at 500. `FLAG_V4_EXACT_IN = 1 << 4` is the highest existing flag.
- The `op.value != 0` blanket ban (line 252) must STAY for every op EXCEPT a `FLAG_NATIVE_IN` op — value forwarding is expressed only via the flag + `amount`, never the raw `op.value` field (that stays hard-0).
- Security invariant that MUST survive: standing/donated ETH bucket cap = 0 (the audit's `test_arb_standingEthSpend_withoutUnwrap` guarantee). `FLAG_NATIVE_IN` is bounded by that same cap + a per-op ceiling.
- **OUT OF SCOPE (flag, do not do here):** deploy of either executor; the bot `Op[]` encoder emitting `FLAG_NATIVE_IN` + the router-routing policy for callback DEXes.
- **MANDATORY final task:** full `solidity-auditor` pass, hard-focused on whether relaxing `op.value==0` opens any standing-ETH drain.

---

### Task 1: Native-ETH output via `_balOf` (Change 2)

Enable a leg that delivers native ETH to pass the output delta-check. Behavior-preserving for ERC20 outputs.

**Files:**
- Modify: `src/libraries/GenericSequenceLib.sol` (lines 305, 425)
- Test: `test/ArbGenericSequence.t.sol` (or `test/ArbExecutorSecurity.t.sol`)

**Interfaces:**
- Consumes: existing `_balOf(address) → address(0)?address(this).balance:balanceOf` (line 500).
- Produces: native-output ops now delta-check against ETH balance; `prevReturn` chaining unchanged.

- [ ] **Step 1: Write the failing test**

In `test/ArbGenericSequence.t.sol`, add a `MockNativeRouter` that pulls `amountIn` of an ERC20 (via transferFrom) and sends native ETH back to the caller, plus a test that runs a single `runArb` op with `outToken = address(0)` and asserts the op SUCCEEDS (repay/containment aside) — i.e. the native output is credited via `_balOf`, not rejected. Structure it so that BEFORE the fix (`? 0 :` hardcode) the op reverts `OpOutputNotReceived`.

```solidity
// MockNativeRouter.swap: pull `amountIn` srcToken, send `amountOut` wei ETH back
contract MockNativeRouter {
    function swap(address srcToken, uint256 amountIn, uint256 amountOut) external {
        IERC20(srcToken).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = msg.sender.call{value: amountOut}("");
        require(ok, "eth send");
    }
    receive() external payable {}
}
// test: op{ srcToken: LOAN, outToken: address(0), target: nativeRouter, amountIn: X }
// harness holds flash principal LOAN; runArb with loanToken=LOAN. Fund router with ETH.
// Assert: harness ETH balance increased by amountOut (op credited native output).
```
(Repay gate: this single op spends LOAN and produces ETH, not LOAN, so it won't satisfy the loanToken repay — build the test as a 2-op cycle that re-converges to LOAN, OR assert the specific `OpOutputNotReceived`-vs-not distinction on a harness that ignores repay. Simplest: 2-op cycle `LOAN→ETH (native out) →` a second op `ETH→LOAN` — but the 2nd op needs FLAG_NATIVE_IN from Task 2. So for THIS task, test the native-output delta in isolation via a harness variant that calls `_executeOps` with `RepayGate.Delta` + a mock that also returns enough LOAN — OR assert via `vm.expectRevert(OpOutputNotReceived)` BEFORE the fix and success after on a repay-satisfied setup. Pick the cleanest that proves the delta path; document the choice.)

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --match-test test_nativeOutput 2>&1 | tail -8`
Expected: FAIL — `OpOutputNotReceived` (the hardcoded-0 delta rejects the native output).

- [ ] **Step 3: Implement**

In `src/libraries/GenericSequenceLib.sol`, replace both native-out hardcodes:
```diff
-            uint256 outBefore = op.outToken == address(0) ? 0 : IERC20(op.outToken).balanceOf(address(this));
+            uint256 outBefore = _balOf(op.outToken);
```
(line 305) and
```diff
-            uint256 outBal = op.outToken == address(0) ? 0 : IERC20(op.outToken).balanceOf(address(this));
+            uint256 outBal = _balOf(op.outToken);
```
(line 425). No other change.

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --match-test test_nativeOutput 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 5: Full regression + commit**

Run: `forge test --no-match-path "test/*Fork*.t.sol" 2>&1 | tail -3`
Expected: 1772 + new, 0 failed (ERC20 outputs unaffected — `_balOf` for a nonzero token == the old `balanceOf`).
```bash
git add src/libraries/GenericSequenceLib.sol test/ArbGenericSequence.t.sol
git commit -m "feat(seq): native-ETH op output via _balOf (Change 2)

Native-output legs now delta-check against address(this).balance instead of a
hardcoded 0 (was OpOutputNotReceived). Behavior-preserving for ERC20 outputs.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BwKApsGUSyyK7SdNn6r55w"
```

---

### Task 2: `FLAG_NATIVE_IN` — forward `call{value}` under containment (Change 1)

The security-critical change: a payable DEX leg forwards native ETH as `msg.value`, bounded by the per-srcToken containment cap + a per-op ceiling.

**Files:**
- Modify: `src/libraries/GenericSequenceLib.sol`
- Test: `test/ArbGenericSequence.t.sol` (happy + adversarial)

**Interfaces:**
- Consumes: `_balOf`, the per-srcToken containment snapshot/cap, the direct-call branch.
- Produces: `uint32 internal constant FLAG_NATIVE_IN = 1 << 5;` added to `FLAG_KNOWN_MASK`. A `FLAG_NATIVE_IN` op does `op.target.call{value: amount}(patchedCalldata)` with `op.srcToken == address(0)`; per-op ceiling reverts `V4InputOverspent`-style if consumed native > `amount` (reuse `V4InputOverspent` or add `NativeInputOverspent`).

- [ ] **Step 1: Write the failing tests**

In `test/ArbGenericSequence.t.sol`:
```solidity
// A native-IN payable router: takes msg.value ETH, mints `amountOut` outToken back.
contract MockPayableRouter {
    function swapNative(address outToken, uint256 amountOut) external payable {
        MockERC20(outToken).mint(msg.sender, amountOut);
    }
}
// test_runArb_nativeIn_happy: op0 = WETH_UNWRAP (flags==FLAG_WETH_UNWRAP) producing X ETH,
//   op1 = FLAG_NATIVE_IN { srcToken: address(0), target: payableRouter,
//   callData: swapNative(LOAN, Y), amountIn: X, outToken: LOAN } → forwards X ETH, mints Y LOAN.
//   Assert repay satisfied (loanAfter >= flashRepay), no revert.
// test_runArb_nativeIn_standingEth_reverts: donate ETH to harness, a lone FLAG_NATIVE_IN op
//   (no preceding unwrap) spends standing ETH → address(0) bucket cap 0 → CollateralOverspent(spent,0).
// test_runArb_nativeIn_overpull_reverts: a malicious payable router that reenters/pulls MORE
//   than `amount` (or the op declares amount < what the target consumes) → per-op ceiling revert.
// test_runArb_nativeIn_flagCombo_reverts: FLAG_NATIVE_IN | FLAG_V4_UNLOCK (and | FLAG_WETH_UNWRAP,
//   | FLAG_USE_FULL_BALANCE) → InvalidPlan.
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-test test_runArb_nativeIn 2>&1 | tail -10`
Expected: FAIL — `FLAG_NATIVE_IN` undefined / the `op.value`/srcToken guards reject the op.

- [ ] **Step 3: Implement**

In `src/libraries/GenericSequenceLib.sol`:

Add the flag + mask:
```diff
     uint32 internal constant FLAG_V4_EXACT_IN = 1 << 4;
+    /// Native-ETH input for a plain payable DEX call: `target.call{value: amount}`.
+    /// `srcToken` MUST be address(0). The forwarded ETH is bounded by the
+    /// per-srcToken containment cap on the address(0) bucket (standing ETH
+    /// allowed=0 → only ETH produced this tx is spendable) + a per-op ceiling.
+    uint32 internal constant FLAG_NATIVE_IN = 1 << 5;
     uint32 internal constant FLAG_KNOWN_MASK =
-        FLAG_USE_FULL_BALANCE | FLAG_USE_PREV_RETURN | FLAG_V4_UNLOCK | FLAG_WETH_UNWRAP | FLAG_V4_EXACT_IN;
+        FLAG_USE_FULL_BALANCE | FLAG_USE_PREV_RETURN | FLAG_V4_UNLOCK | FLAG_WETH_UNWRAP | FLAG_V4_EXACT_IN | FLAG_NATIVE_IN;
```

Admit native srcToken for the flag (line 261):
```diff
-            if (op.srcToken == address(0) && op.flags & FLAG_V4_UNLOCK == 0) revert InvalidPlan();
+            if (op.srcToken == address(0) && op.flags & (FLAG_V4_UNLOCK | FLAG_NATIVE_IN) == 0) revert InvalidPlan();
```

In the direct-call `else` branch, before the `forceApprove`, handle `FLAG_NATIVE_IN`:
```solidity
            } else if (op.flags & FLAG_NATIVE_IN != 0) {
                // Native-ETH input to a payable DEX. srcToken must be native;
                // amount is the ETH forwarded, bounded by the address(0)
                // containment bucket (standing ETH allowed=0) + this ceiling.
                if (op.srcToken != address(0)) revert InvalidPlan();
                // Mutually exclusive with the other input-shaping / special flags.
                if (op.flags != (FLAG_NATIVE_IN | (op.flags & FLAG_USE_PREV_RETURN)))
                    // allow ONLY NATIVE_IN, optionally + PREV_RETURN sizing; reject V4/UNWRAP/FULL_BALANCE combos
                    { if (op.flags & (FLAG_V4_UNLOCK | FLAG_WETH_UNWRAP | FLAG_USE_FULL_BALANCE) != 0) revert InvalidPlan(); }
                bytes memory ndata = op.callData;
                if (op.fromAmountPos != 0) _patchWord(ndata, op.fromAmountPos, amount);
                if (op.returnAmountPos != 0) _patchWord(ndata, op.returnAmountPos, prevReturn);
                uint256 nBefore = address(this).balance;
                (bool okN, bytes memory retN) = op.target.call{value: amount}(ndata);
                if (!okN) { if (retN.length > 0) { assembly { revert(add(retN,0x20), mload(retN)) } } revert OpCallFailed(i); }
                // Per-op ceiling: the target must not have net-pulled more ETH
                // than `amount` (a reentrant/over-pull dip into standing ETH).
                uint256 nAfter = address(this).balance;
                uint256 nConsumed = nBefore > nAfter ? nBefore - nAfter : 0;
                if (nConsumed > amount) revert V4InputOverspent(nConsumed, amount);
            } else {
                // ...existing ERC20 approve+call branch unchanged...
```
(Adjust the exact flag-exclusivity check to be clean — the intent: a `FLAG_NATIVE_IN` op may carry `FLAG_USE_PREV_RETURN` for input sizing but NOT `FLAG_V4_UNLOCK`/`FLAG_WETH_UNWRAP`/`FLAG_USE_FULL_BALANCE`. Verify `amount` is resolved correctly for the PREV_RETURN case before this branch — `amount` is computed above the branch, so PREV_RETURN already flows into `amount`.)

The out-delta check after the branch (now using `_balOf` from Task 1) still pins the output to the executor.

- [ ] **Step 4: Run to verify pass**

Run: `forge test --match-test test_runArb_nativeIn 2>&1 | tail -10`
Expected: all 4 PASS — happy path repays, standing-ETH reverts `CollateralOverspent`, over-pull reverts the ceiling, flag-combos revert `InvalidPlan`.

- [ ] **Step 5: Full regression + size + commit**

Run:
```bash
forge test --no-match-path "test/*Fork*.t.sol" 2>&1 | tail -3
forge inspect ArbExecutor deployedBytecode | wc -c
```
Expected: green; ArbExecutor deployedBytecode/2 < 24576.
```bash
git add src/libraries/GenericSequenceLib.sol test/ArbGenericSequence.t.sol
git commit -m "feat(seq): FLAG_NATIVE_IN — payable-dex call{value} under containment (Change 1)

Native-ETH input forwarded as msg.value, bounded by the address(0) containment
bucket (standing ETH cap=0) + per-op ceiling. op.value blanket ban stays for
every non-NATIVE_IN op. Adversarial tests: standing-ETH spend reverts, over-pull
reverts, flag combos reject.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BwKApsGUSyyK7SdNn6r55w"
```

---

### Task 3: Mainnet-fork native cycles (Fluid + Curve native + router-routed V4 parity)

Prove real payable venues route on a fork through `FLAG_NATIVE_IN`.

**Files:**
- Modify: `test/ArbExecutorFork.t.sol` (add native tests) — gated skip-without-RPC, `--evm-version cancun`.

- [ ] **Step 1: Write the fork tests**

```solidity
// test_fork_nativeIn_curve: WETH_UNWRAP → Curve stETH/ETH exchange{value}(ETH→stETH) → back to loanToken.
// test_fork_nativeIn_fluid: WETH_UNWRAP → Fluid native pool swapIn{value}(ETH→stable) → back.
// test_fork_v4_via_router_parity: reach the SAME native-V4 pool through the V4 router
//   as a FLAG_NATIVE_IN call{value}, assert output within tolerance of the legacy
//   unlockCallback path — proving the in-contract callback is now optional.
```
Fill with real pool/router addresses + calldata (Curve stETH pool `0xDC24…`, Fluid resolver-listed native pool, V4 router). Assert repay + containment, not profit. Allowlist the targets in setUp.

- [ ] **Step 2: Run the fork tests**

Run: `export ETHEREUM_RPC_URL=$(grep ^ETHEREUM_RPC_URL /Users/alexanderburkut/workspace/liquidation-bot/.env | cut -d= -f2- | tr -d '"'); MAINNET_RPC_URL=$ETHEREUM_RPC_URL forge test --match-contract ArbExecutorFork --fork-url $ETHEREUM_RPC_URL --evm-version cancun -vv 2>&1 | tail -20`
Expected: the 3 new native tests PASS (flash repaid, no overspend). Substitute a venue if a pool can't route at the pinned block; report it.

- [ ] **Step 3: Commit**

```bash
git add test/ArbExecutorFork.t.sol
git commit -m "test(seq): mainnet-fork native-IN cycles — Curve/Fluid payable + V4-via-router parity"
```

---

### Task 4: Liquidation-side native regression + both-executor coherence

Confirm the shared-lib change did not regress the liquidation executor and that a native `FLAG_NATIVE_IN` op works through `LiquidationExecutor`'s generic sequence too.

**Files:**
- Test: the liquidation generic-sequence test file (`test/ExecutorGenericSequence.t.sol` or sibling) — add one `FLAG_NATIVE_IN` op test on the LIQUIDATION path.

- [ ] **Step 1: Write a liquidation-path native test**
A `run(...)` (RepayGate.Delta) sequence with a `FLAG_NATIVE_IN` op, proving the same flag works for the collateral-cap model (cap = collateral, native ETH from an unwrap of seized WETH collateral).
- [ ] **Step 2: Run + full regression**
Run: `forge test --no-match-path "test/*Fork*.t.sol" 2>&1 | tail -3`
Expected: whole repo green (both executors).
- [ ] **Step 3: Commit**

---

### Task 5: MANDATORY solidity-auditor pass

- [ ] **Step 1:** Invoke `solidity-auditor` with:
`src/libraries/GenericSequenceLib.sol src/ArbExecutor.sol — native-ETH-any-dex change on branch feat/arb-full-parity. New: FLAG_NATIVE_IN (op.target.call{value: amount} for payable DEXes, srcToken==address(0)) + native output via _balOf. The op.value==0 blanket ban is RELAXED to allow value forwarding ONLY via FLAG_NATIVE_IN, bounded by the per-srcToken containment cap on the address(0) bucket (standing ETH allowed=0) + a per-op ceiling (nConsumed <= amount). HARD FOCUS: does this relaxation open ANY standing/donated-ETH drain by a compromised operator? Can a FLAG_NATIVE_IN op forward MORE ETH than was produced this tx? Can a malicious allowlisted target reenter to pull standing ETH past the per-op ceiling or the containment cap? Flag-combo bypasses (NATIVE_IN + other flags)? Native-output delta-check recipient pinning. Regression to the existing V4/unwrap/ERC20 paths.`
- [ ] **Step 2:** Triage: fix Critical/Important with a regression test, re-audit the changed file.
- [ ] **Step 3:** Final full regression (both executors) green; update the PR (#32) body with the native-ETH addition + the auditor result.

**FLAGGED OUT OF SCOPE:** redeploy of both executors (LiquidationExecutor 0xB543 replacement is the heavier op — hard-gate boundary + snapshot + switch); bot `Op[]` encoder emitting `FLAG_NATIVE_IN` + the router-routing policy for callback DEXes.

---

## Self-Review

- **Spec coverage:** Change 1 → Task 2; Change 2 → Task 1; Change 3 (router policy, no contract code) → covered by the parity test in Task 3 + flagged as off-chain encoder work; invariants §Security → adversarial tests in Task 2 + auditor Task 5; both-executor blast radius → Task 4. ✅
- **Placeholder scan:** the fork-test pool addresses/calldata (Task 3) and the exact flag-exclusivity expression (Task 2 Step 3) are pointed at real sources / stated intent — the implementer resolves the precise expression against the surrounding code; every other step has concrete diffs.
- **Type consistency:** `FLAG_NATIVE_IN = 1<<5` used in mask (Task 2), the direct-call branch (Task 2), and admission (Task 2). `_balOf` used identically in Task 1 both sites. Per-op ceiling reuses `V4InputOverspent`.
