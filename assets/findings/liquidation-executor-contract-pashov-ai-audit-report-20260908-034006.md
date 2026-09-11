# 🔐 Security Review — LiquidationExecutor · ArbExecutor (second pass)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default (branch `perf/standing-allowances`, PR #37, after `bfae053`) |
| **Files reviewed**               | `ArbExecutor.sol` · `LiquidationExecutor.sol` · `deploy/SeededExecutors.sol`<br>`libraries/AllowanceLib.sol` · `libraries/BalancerV2Lib.sol` · `libraries/CoinbasePaymentLib.sol`<br>`libraries/CurveV1Lib.sol` · `libraries/DirectSwapLib.sol` · `libraries/GenericSequenceLib.sol`<br>`libraries/ParaswapDecoderLib.sol` · `libraries/SwapLegExecutorLib.sol` · `libraries/SwapValidationLib.sol`<br>`libraries/UniswapLib.sol` · `types/SwapTypes.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

This pass re-audited the tree after the first pass's fixes. Nothing is live: `AllowanceLib.sol` arrives with this branch. Every finding below is fixed in `804120c`.

---

## Findings

[92] **1. A bounded allowance still outlives the op that granted it**

`GenericSequenceLib._runOps` · `SwapLegExecutorLib.executeParaswapLeg` · `UniswapLib.executeUniV2Leg` · `UniswapLib.executeUniV3Leg` · `LiquidationExecutor._executeAaveV3Liquidation` · Confidence: 92 · [agents: 7]

**Description**
Bounding the grant to `amount` does not help when the target spends less than it was approved — the normal outcome for every `amountInMaximum`, every exact-output route and every padded `debtToCover` — so the remainder stands to an allowlisted router, which is exactly the precondition for the containment bypass in `_finishOps`; and in the generic op branch `amount` is `op.amountIn`, an unbounded operator literal, so one valid plan could leave `type(uint256).max` standing.

**Fix**

```diff
                 (bool ok, bytes memory ret) = op.target.call(data);
                 ...
+                if (amount != 0) {
+                    AllowanceLib.clear(op.srcToken, op.target);
+                }
```
applied at every `ensure` site reachable with a live remainder. The two flash-repay grants keep no `clear`: the provider pulls after the callback returns.

---

[88] **2. The take-back skipped the op shape with the largest approval**

`GenericSequenceLib._runOps` · Confidence: 88

**Description**
The first version of the take-back was gated on `op.amountIn != 0 || FLAG_USE_PREV_RETURN`, which is not the set that receives an approval: a `FLAG_USE_FULL_BALANCE` op carries `amountIn == 0` and is approved from the whole balance, so it skipped the clear entirely.

**Fix**

```diff
-                if (op.amountIn != 0 || (op.flags & FLAG_USE_PREV_RETURN) != 0) {
+                if (amount != 0) {
```
Mirroring the `ensure` condition is the only form that cannot drift from it.

---

[86] **3. The lending pools are generic call targets, and two shapes escape the containment cap**

`LiquidationExecutor.execute` · Confidence: 86 · [agents: 2]

**Description**
The constructor seeds Aave V3, Aave V2 and Morpho into `allowedTargets` so the liquidation paths can re-read it as their kill-switch, which also hands a generic op their whole function surface: `borrow(asset, Y, 2, 0, this)` RAISES the balance the cap measures so the borrowed principal routes out unseen, and `withdraw(asset, max, attacker)` burns the executor's own aTokens with no allowance and no `srcToken`, so the token is never bucketed at all.

**Fix**

```diff
+                if (
+                    ops[i].target == aavePool || ops[i].target == morphoBlue
+                        || ops[i].target == aaveV2LendingPool
+                        || ops[i].target == allowedFlashProviders[FLASH_PROVIDER_BALANCER]
+                ) revert TargetNotAllowed();
```
placed above the direct-pool exemption, so every op is seen. `ArbExecutor` already refuses to seed Morpho for this reason.

---

[84] **4. The per-target kill-switch does not reach three of the highest-value call surfaces**

`LiquidationExecutor._dispatchLeg` · Confidence: 84

**Description**
`setAllowedTarget(t, false)` silently does nothing for Paraswap Augustus and both Uniswap routers, because those three dispatch paths read no allowlist at all — while every other path re-reads it even for constructor-pinned addresses — leaving `pause()` (stops everything) as the owner's only lever against a compromised aggregator.

**Fix**

```diff
+            if (!allowedTargets[paraswapAugustusV6]) revert TargetNotAllowed();
             SwapLegExecutorLib.executeParaswapLeg(leg, paraswapAugustusV6);
```
and the same for `uniV2Router` and `uniV3Router`.

---

[80] **5. The Paraswap approval is sized from calldata while the cap is enforced on the struct**

`SwapLegExecutorLib.executeParaswapLeg` · Confidence: 80

**Description**
`declaredIn` is decoded from operator-built calldata and bounded only by the executor's own balance, while the post-call ceiling is checked against `leg.amountIn`, so the approved amount could exceed the amount the plan declared and the plan-level `leg1AmountIn > collateralDelta` cap.

**Fix**

```diff
+        if (declaredIn > leg.amountIn) revert ParaswapAmountInMismatch(leg.amountIn, declaredIn);
         AllowanceLib.ensure(srcToken, augustus, declaredIn);
```

---

[78] **6. The V2 fee scale still cannot express PancakeSwap's 0.25%**

`DirectSwapLib._v2Out` · Confidence: 78

**Description**
Carried over unfixed from the first pass: the denominator is hard-coded to 1000, so a 25/10000 fork is either quoted at 998 (output above the pair's K limit, every such leg reverts) or at 997 (~5 bps of every hop donated to the pool). The fix is a coordinated contract-and-bot change and wants PancakeSwap V2's mainnet fee confirmed on-chain first.

---

[76] **7. Both Uniswap legs compute an input ceiling and discard it**

`UniswapLib.executeUniV2Leg` · `UniswapLib.executeUniV3Leg` · Confidence: 76

**Description**
`actualIn` is assigned on both branches and never read, so the BUY paths delegate their input containment entirely to the router's own `amountInMaximum` while every sibling library asserts the ceiling itself.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [92] | A bounded allowance still outlives the op that granted it |
| 2 | [88] | The take-back skipped the op shape with the largest approval |
| 3 | [86] | The lending pools are generic call targets, and two shapes escape the containment cap |
| 4 | [84] | The per-target kill-switch does not reach three of the highest-value call surfaces |
| 5 | [80] | The Paraswap approval is sized from calldata while the cap is enforced on the struct |
| 6 | [78] | The V2 fee scale still cannot express PancakeSwap's 0.25% |
| 7 | [76] | Both Uniswap legs compute an input ceiling and discard it |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **The containment cap is opt-in on the plan's own declaration** — `GenericSequenceLib._finishOps` — Code smells: `snapTok` is built from `ops[i].srcToken`, so it is a law over tokens the plan volunteers rather than a conservation law over balances. Removing standing allowances removes the known vehicle; a target that moves funds without an allowance would still escape it. Reported by 4 agents across both passes.
- **ArbExecutor's V4 multihop callback enforces no hook allowlist** — `ArbExecutor.unlockCallback` — Code smells: the `else` branch calls `runV4UnlockMultihop` with no hook check, and unlike `LiquidationExecutor` there is no pre-flight validator to inherit one from. Unreachable today only because `GenericSequenceLib` pins `op.callData.length == V4_SWAP_DATA_LENGTH`. Reported by 5 agents in the first pass and 4 in the second — the single most persistent lead.
- **Direct-pool ops propagate a claimed output, not a measured one** — `GenericSequenceLib._runOps` — Code smells: `directOut` skips the balance-delta check and feeds the pool's own reported amount into the next op's approval size and into `_patchWord`. The pool is operator-named and deliberately not allowlisted. The in-code justification reasons about the spend, not the approval.
- **Two NO_SWAP branches settle the flash against an absolute balance** — `LiquidationExecutor._executeSwapPlan` — Code smells: every sibling branch asserts a delta against a pre-leg snapshot; the single-leg NO_SWAP path returns with no repay assertion at all, leaving `_finalizeFlashloan`'s absolute check, which a standing balance satisfies.
- **A hardcoded 10k gas stipend to `block.coinbase`** — `CoinbasePaymentLib.payCoinbase` — Code smells: a contract fee-recipient doing one cold SSTORE exceeds it, and the failure is a hard revert of the whole bundle rather than a skipped bid. Carried over unfixed.
- **`renounceOwnership` is inherited and not overridden** — both executors — Code smells: `Ownable2Step` guards transfer but not renounce, on contracts designed to accumulate withdrawable balances. Self-harm, so not scored.
- **Nine positional same-type constructor arguments** — `LiquidationExecutor.constructor` — Code smells: all immutable, several seeded into `allowedTargets`; a transposition passes every check and cannot be corrected without redeploying.
- **`checkProfit` saturates, so a loss reads as zero profit** — `GenericSequenceLib._finishOps` — Code smells: with `minProfitAmount == 0` a loss-making cycle settles out of standing inventory rather than reverting.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
