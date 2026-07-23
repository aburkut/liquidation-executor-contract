# Task 5 Report: Replace `legs[]` with `Op[]` generic-sequence execution in ArbExecutor

Branch: `feat/arb-full-parity`. Base: 26b6338 (Task 4).

## TDD evidence

**Step 1 (test written first, verbatim from brief):** Added
`test_execute_opSequence_arb_profits_and_repays` to `test/ArbExecutor.t.sol`
using the exact brief-provided body (2-op arb 100 LOAN → 100 MID → 110 LOAN
via `MockRouter`, `_swapOp`/`_encodeArbPlan`/`_fundAndAllowlist` helpers).

**Step 2 (RED):** Because `src/ArbExecutor.sol` had already been rewritten
(the natural order for this kind of struct-shape refactor — the whole test
file references `ArbTypes.ArbPlan{legs:...}` and would not compile against
the new `ops[]`-only struct either way), the authentic RED signal is the
compile failure across every un-ported call site in the old test file:

```
$ forge test --match-test test_execute_opSequence_arb 2>&1 | tail -20
Error (4974): Named argument "legs" does not match function declaration.
   --> test/ArbExecutor.t.sol:172:40
Error (4974): Named argument "legs" does not match function declaration.
   --> test/ArbExecutor.t.sol:191:40
Error (4974): Named argument "legs" does not match function declaration.
   --> test/ArbExecutor.t.sol:374:40
Error: Compilation failed
```

This is exactly the brief's predicted failure mode ("`ArbPlan` has no `ops`
field / `_encodeArbPlan` shape mismatch — compile error").

**Step 3 (rewrite):** Rewrote `ArbTypes.ArbPlan`, `execute()`,
`_runArbPipeline`, deleted `_dispatchLeg`, ported all 24 pre-existing tests
(see below) plus the new e2e test.

**Step 4 (GREEN):**
```
$ forge test --match-test test_execute_opSequence_arb -vv 2>&1 | tail -8
Ran 1 test for test/ArbExecutor.t.sol:ArbExecutorTest
[PASS] test_execute_opSequence_arb_profits_and_repays() (gas: 357272)
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

Note: the brief's literal test body has no `vm.expectEmit` — I initially
added one and found `vm.expectEmit`'s "next log" semantics don't tolerate
the several `Transfer` events emitted by the flash/swap machinery before
`ArbExecuted`; removed it to match the brief's verbatim code (balance
assertion only), which is what actually passed.

## `ArbTypes.ArbPlan` struct change

```solidity
struct ArbPlan {
    uint8 flashProviderId;
    address loanToken;
    uint256 loanAmount;
    uint256 maxFlashFee;
    Op[] ops;               // was: SwapLeg[] legs;
    uint256 coinbaseBps;
    uint256 minProfitAmount;
}
```

## `execute()` allowlist walk

Replaced the static leg-chain wiring block (`legs[0].srcToken == loanToken`,
`legs[N-1].repayToken == loanToken`, per-leg link matching,
`SwapValidationLib.validateNonV4Leg`) with:

```solidity
if (plan.ops.length == 0 || plan.ops.length > GenericSequenceLib.MAX_OPS) revert InvalidPlan();
if (plan.coinbaseBps > 10_000) revert InvalidPlan();
if (plan.coinbaseBps > 0 && plan.loanToken != weth) revert CoinbaseRequiresWethLoan();

for (uint256 i = 0; i < plan.ops.length; ++i) {
    if (plan.ops[i].flags & GenericSequenceLib.FLAG_WETH_UNWRAP != 0) continue;
    if (!allowedTargets[plan.ops[i].target]) revert TargetNotAllowed();
}
```

This is a **deliberate loss of static admission control**, by design: the
old leg-chain invariants (first-hop src, last-hop repay, per-hop link
matching) are gone entirely; the only pre-flash checks left are op-count
bounds and target allowlisting. Chaining and the repay obligation are
enforced at **runtime** inside `GenericSequenceLib.runArb` (per-srcToken
containment cap + the ABSOLUTE repay gate), exactly as specced.

## `_runArbPipeline` change + profit-formula trace

```solidity
uint256 profitBefore = IERC20(loanToken).balanceOf(address(this));
GenericSequenceLib.runArb(plan.ops, loanToken, flashRepay, plan.loanAmount, weth);
uint256 realizedProfit =
    CoinbasePaymentLib.computeRealizedProfit(loanToken, loanToken, profitBefore, plan.loanAmount, flashRepay);
```

(coinbase / repay-settle / `checkProfit` / `emit` below this are untouched.)

**Trace — is `computeRealizedProfit` correct when `profitBefore == loanAmount` (+ any residual)?**

`computeRealizedProfit(asset, profitTkn, profitBefore, principalAmount, repayAmount)`
with `asset == profitTkn == loanToken`:
```
profitNow = balanceOf(loanToken) [after runArb, before repay/coinbase]
lhs = profitNow + principalAmount
rhs = profitBefore + repayAmount
realizedProfit = lhs > rhs ? lhs - rhs : 0
```

Let `B` = any pre-existing loanToken residual on the contract (accumulated
profit from a prior arb — the contract is designed to retain it until
`withdraw`). At the point `_runArbPipeline` snapshots `profitBefore`, the
flash principal has just arrived (checked one line above), so
`profitBefore = B + loanAmount`.

`GenericSequenceLib.runArb` caps the sequence's spend of `loanToken` at
`loanAmount` (the `capAmount` passed in) via the per-srcToken containment —
so regardless of `B`, the sequence spends **at most** `loanAmount` of
`loanToken` and reproduces some final amount `X` back into `loanToken`
(`X` = 110 in the worked example). Net effect on the loanToken balance from
the sequence is `-loanAmount + X`, so:

```
profitNow = B + loanAmount - loanAmount + X = B + X
```

Plugging in:
```
lhs = profitNow + loanAmount = B + X + loanAmount
rhs = profitBefore + repayAmount = B + loanAmount + repayAmount
realizedProfit = lhs - rhs = X - repayAmount
```

`B` cancels on both sides — **the formula is correct and robust to any
standing residual balance**, for both the zero-fee (Morpho) and
fee-charging (Balancer, `repayAmount = loanAmount + fee`) cases:
  * Morpho (`repayAmount = loanAmount`): `realizedProfit = X - loanAmount`
    → worked example: `110 - 100 = 10`. Matches the e2e test assertion
    exactly (`loan.balanceOf(exec) == 10e18`).
  * Balancer with fee `f`: `realizedProfit = X - loanAmount - f`, i.e. the
    fee correctly reduces profit.

**Conclusion: no change needed to `computeRealizedProfit` or its call
site — it is correct as-is for the arb `profitBefore = loanAmount`
baseline.** No concern to flag here.

## Porting the 24 pre-existing tests

24 tests existed pre-Task-5 (20 touching `legs[]`/`ArbPlan`, 4 untouched
V4-storage/unlockCallback tests from Tasks 3/4 that reference neither):

* **16 tests directly rebuilt `SwapLeg[]`** (happy paths, coinbase/minProfit/
  flash-provider reverts, callback-caller test, operator/pause tests) — all
  ported 1:1 to `Op[]`:
  * `_v2Op`/`_v3Op` helpers build **direct-call** ops targeting the real
    `uniV2`/`uniV3` router mocks (already funded/allowlisted in `setUp`),
    with `fromAmountPos` computed from the real ABI layout
    (`swapExactTokensForTokens` → offset 4; `exactInputSingle`'s all-static
    `ExactInputSingleParams` tuple → offset 132), so ported tests exercise
    the actual production-shaped router calldata, not a synthetic mock.
  * The old `useFullBalance` chaining leg maps to `GenericSequenceLib.FLAG_USE_PREV_RETURN`
    (chains off the previous op's output delta) — the precise runtime
    analog of the old delta-based `useFullBalance` accounting.
  * All expected profit numbers (210e18, 331e18, 105e18 coinbase, etc.)
    reproduce unchanged.
* **4 tests (`test_revert_legs_empty`, `test_revert_legs_first_src_mismatch_loanToken`,
  test_revert_legs_last_repay_mismatch_loanToken`, `test_revert_legs_link_mismatch`)
  tested the STATIC chain-wiring invariants that Task 5 deliberately
  removes.** `test_revert_legs_empty` ports directly (renamed
  `test_revert_ops_empty`, same `ops.length == 0 → InvalidPlan`). The other
  three test invariants with **no analog in the new model** — there is no
  way to "port them faithfully" because the checks they exercised no
  longer exist by design (chaining is a runtime concern now). I replaced
  them 1:1 with tests pinning the **new** invariants that took their place:
    * `test_revert_ops_targetNotAllowlisted` — the new `TargetNotAllowed`
      admission check (previously untested at the `ArbExecutor` level).
    * `test_revert_ops_tooMany` — the new `MAX_OPS` bound (33 ops → `InvalidPlan`).
    * `test_revert_ops_repayShortfall` — the runtime ABSOLUTE repay gate
      bubbling `GenericSequenceLib.InsufficientRepayOutput` end-to-end
      through `execute()` (the library-level unit test for this already
      exists in `ArbGenericSequence.t.sol`; this one pins it through the
      real flash callback).
* **4 tests never touched legs at all** (`test_revert_morphoCallbackFromNonMorpho`,
  `test_revert_balancerCallbackFromNonBalancer`, `test_revert_withdrawFromNonOwner`,
  `test_revert_setAllowedTargetFromNonOwner`) — untouched.
* **4 V4-storage/unlockCallback tests** (Tasks 3/4) — untouched.

Net test count: 24 → 25 (the 3 replaced chain-wiring tests + 1 new e2e test
= net +1).

## New e2e test

`test_execute_opSequence_arb_profits_and_repays` — full `execute()` → Morpho
flash → `onMorphoFlashLoan` → `_runArbPipeline` → `GenericSequenceLib.runArb`
path through a real `MockMorphoBlue` + the shared `MockRouter` (extracted
from Task 2's `ArbGenericSequence.t.sol` into `test/support/Mocks.sol`, now
imported by both files). No fork.

## Size checkpoint

```
$ forge inspect ArbExecutor deployedBytecode | wc -c
17695
```
`(17695 - 3) / 2 = 8846` bytes deployed runtime code — well under the
24576-byte EIP-170 limit (was 11150 bytes after Task 4; dropped because
`_dispatchLeg`'s five inlined per-mode library calls
(`UniswapLib.executeUniV2Leg/executeUniV3Leg`, `SwapLegExecutorLib`,
`CurveV1Lib`, `BalancerV2Lib`) are replaced by a single external
`DELEGATECALL` stub to `GenericSequenceLib.runArb`).

## Whole-suite regression

```
$ forge test 2>&1 | tail -3
Suite result: ok. 310 passed; 0 failed; 0 skipped; finished in ...
Ran 10 test suites: 1765 tests passed, 0 failed, 8 skipped (1773 total tests)
```
Baseline 1764 → **1765** (net +1, see test-count reconciliation above). 0
failed, 8 skipped unchanged (pre-existing fork-only tests, not touched).

## Files changed

* `src/ArbExecutor.sol` — `ArbTypes.ArbPlan` struct (`ops[]` replaces
  `legs[]`), `execute()` allowlist walk, `_runArbPipeline` delegates to
  `GenericSequenceLib.runArb`, `_dispatchLeg` deleted, unused imports
  (`SwapLegExecutorLib`, `SwapValidationLib`, `CurveV1Lib`, `BalancerV2Lib`,
  `SwapMode`/`SwapLeg`) and the now-dead `InvalidSwapMode` error / `MAX_LEGS`
  constant removed. `UniswapLib` import kept (still used by `unlockCallback`
  for V4 unlock swaps).
* `test/ArbExecutor.t.sol` — full port to `Op[]`: `_v2Op`/`_v3Op` direct-call
  helpers, `_planMorpho`/`_planBalancer` updated signatures, 16 tests
  rebuilt, 3 chain-wiring tests replaced with new-model equivalents, 1 new
  e2e test + its `_swapOp`/`_encodeArbPlan`/`_fundAndAllowlist` helpers +
  `loan`/`mid`/`router` fixtures.
* `test/ArbGenericSequence.t.sol` — inline `MockRouter` extracted to
  `test/support/Mocks.sol`; imports it instead.
* `test/support/Mocks.sol` (new) — shared `MockRouter` (pull `amountIn` of
  `tokenIn`, mint `amountOut` of `tokenOut`).

## Self-review

* Confirmed via grep that no remaining `SwapLeg`/`SwapMode`/`SwapValidationLib`/
  `SwapLegExecutorLib`/`CurveV1Lib`/`BalancerV2Lib` references survive in
  `ArbExecutor.sol`.
* Confirmed `paraswapAugustusV6`/`uniV2Router`/`uniV3Router` immutables are
  still legitimately used (constructor + `allowedTargets` seeding) — not
  dead code, left in place.
* Confirmed the pre-flash allowlist walk's `FLAG_WETH_UNWRAP` exemption
  matches `LiquidationExecutor:669` verbatim in structure.
* Confirmed `GenericSequenceLib.runArb` is invoked as an ordinary Solidity
  library call (`GenericSequenceLib.runArb(...)`), which the compiler
  compiles to a real `DELEGATECALL` for external/public library functions —
  same calling convention `LiquidationExecutor._runGenericSequence` already
  uses for `GenericSequenceLib.run(...)` (verified by grep, line 1079 of
  `LiquidationExecutor.sol`).
* Ran the new e2e test, the full `ArbExecutorTest` suite, and the whole
  repo suite independently before committing.

## Concerns

None. The profit-accounting formula is verified correct by trace (see
above). The only design change worth flagging for the final Task-8
solidity-auditor gate (not a defect, but worth the auditor's attention): the
3 replaced chain-wiring tests mean `ArbExecutor.execute()` **no longer
statically validates** that an op-sequence's first hop spends `loanToken` or
that its last hop produces `loanToken` — that invariant is now purely a
runtime economic one (`GenericSequenceLib`'s ABSOLUTE repay gate reverts the
whole tx if it doesn't hold), which is correct and matches the design brief,
but is a genuine behavioral difference from the old model worth the
auditor's explicit sign-off alongside the rest of the `Op[]` admission
model.
