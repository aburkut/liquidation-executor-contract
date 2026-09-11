# 🔐 Security Review — LiquidationExecutor · ArbExecutor

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default (branch `perf/standing-allowances`, PR #37)    |
| **Files reviewed**               | `ArbExecutor.sol` · `LiquidationExecutor.sol` · `deploy/SeededExecutors.sol`<br>`libraries/AllowanceLib.sol` · `libraries/BalancerV2Lib.sol` · `libraries/CoinbasePaymentLib.sol`<br>`libraries/CurveV1Lib.sol` · `libraries/DirectSwapLib.sol` · `libraries/GenericSequenceLib.sol`<br>`libraries/ParaswapDecoderLib.sol` · `libraries/SwapLegExecutorLib.sol` · `libraries/SwapValidationLib.sol`<br>`libraries/UniswapLib.sol` · `types/SwapTypes.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

**None of this is live.** `AllowanceLib.sol` does not exist on `main`; it is introduced by this branch. Every asset-loss finding below is pre-deploy.

---

## Findings

[90] **1. A standing unlimited allowance is granted to a spender the operator names**

`BalancerV2Lib.executeLeg` · `BalancerV2Lib.executeLegBatchSwap` · `CurveV1Lib.executeLegMultihop` · Confidence: 90 · [agents: 6]

**Description**
All three pass `leg.bebopTarget` — a plain plan field, checked only for `!= address(0)` and `code.length > 0`, never against `allowedTargets` — into `AllowanceLib.ensure`, which writes `forceApprove(spender, type(uint256).max)` and never resets, so one otherwise valid liquidation leaves a permanent unlimited spender chosen by a hot key, drained later with a plain `transferFrom` that no `pause()`, `setOperator(op,false)` or `setAllowedTarget(t,false)` can stop.

**Fix**

```diff
-    function ensure(address token, address spender, uint256 amount) internal {
-        if (IERC20(token).allowance(address(this), spender) < amount) {
-            IERC20(token).forceApprove(spender, type(uint256).max);
-        }
-    }
+    function ensure(address token, address spender, uint256 amount) internal {
+        IERC20(token).forceApprove(spender, amount);
+    }
+
+    function clear(address token, address spender) internal {
+        IERC20(token).forceApprove(spender, 0);
+    }
```
plus `AllowanceLib.clear(leg.srcToken, spender)` immediately after each external swap call.

---

[88] **2. The Bebop leg spends what its calldata says, not what the plan declared**

`SwapLegExecutorLib.executeBebopLeg` · Confidence: 88 · [agents: 3]

**Description**
`bebopCalldata` is opaque and operator-built while the approval was unlimited, so the allowlist check on `target` bounds nothing: naming an allowlisted multicall router and appending a second transfer to an attacker address pulls the executor's entire `srcToken` balance while `leg.amountIn`, `fill` and `collateralDelta` all bound a declared number that nothing compares against the real spend.

**Fix**

```diff
         (bool ok,) = target.call(leg.bebopCalldata);
         if (!ok) revert BebopSwapFailed();
+        AllowanceLib.clear(leg.srcToken, target);
+        uint256 consumed = srcBal - IERC20(leg.srcToken).balanceOf(address(this));
+        if (consumed > fill) revert BebopInputOverspent(consumed, fill);
```

---

[85] **3. The containment cap measures only the tokens the plan declares**

`GenericSequenceLib._executeOps` · `GenericSequenceLib._finishOps` · Confidence: 85 · [agents: 3]

**Description**
`snapTok` is built exclusively from `ops[i].srcToken`, so a token the plan never names has no bucket and no cap — and a standing unlimited allowance to an allowlisted multicall router lets an op's opaque calldata move exactly such a token, defeating the invariant stated directly above the loop ("keeps a compromised operator from routing out a standing balance of ANY token").

**Fix**

```diff
-        if (IERC20(token).allowance(address(this), spender) < amount) {
-            IERC20(token).forceApprove(spender, type(uint256).max);
-        }
+        IERC20(token).forceApprove(spender, amount);
```
Removing the standing grant removes the precondition: an allowance bounded by the op's own `amount` cannot be used by a later transaction to move an undeclared token.

---

[82] **4. Nothing can lower an allowance once granted**

`LiquidationExecutor.setAllowedTarget` · `ArbExecutor.setAllowedTarget` · Confidence: 82 · [agents: 2]

**Description**
`withdraw`, `rescueERC20`, `rescueAllERC20` and `rescueETH` move tokens the contract still holds and no owner-callable function anywhere writes an allowance, so the documented kill-switches (allowlist flip, operator revocation, `pause()`) cannot revoke spending power that was already handed out.

**Fix**

```diff
+    /// @notice Take back a spender's allowance on `token`. The kill-switch
+    /// that `setAllowedTarget(t,false)` and `pause()` do not provide.
+    function revokeAllowance(address token, address spender) external onlyOwner {
+        IERC20(token).forceApprove(spender, 0);
+    }
```

---

[78] **5. The V2 fee scale cannot express PancakeSwap's 0.25%**

`DirectSwapLib._v2Out` · Confidence: 78

**Description**
`out = amount*feeNum*reserveOut / (reserveIn*1000 + amount*feeNum)` fixes the fee at thousandths, but PancakeSwap V2 charges 25/10000: at 997 the swap under-requests by ~5 bps of input on every Pancake leg, and at 998 — the value this repo's own NatSpec and the bot's fork table both name for Pancake — the pair's K invariant fails and every such leg reverts.

---

[75] **6. A partial Bebop fill is measured against a full-size floor**

`SwapLegExecutorLib.executeBebopLeg` · Confidence: 75

**Description**
`fill` is scaled down to the collateral actually seized and the taker amount is patched to match, but `leg.minAmountOut` is left at its full-size value, so the output check compares a pro-rata fill against an un-scaled floor and reverts in precisely the case the partial-fill feature exists for.

---

[75] **7. The two executors disagree on the same pre-flight flag test**

`LiquidationExecutor.execute` · Confidence: 75 · [agents: 4]

**Description**
The generic-sequence target walk skips unwrap ops by bit presence (`flags & FLAG_WETH_UNWRAP != 0`) where `ArbExecutor` uses exact equality and documents why, so `FLAG_WETH_UNWRAP | FLAG_V4_UNLOCK` and `FLAG_WETH_UNWRAP | FLAG_V3_FLASH` skip both the allowlist check and the flash rejection at the executor level, leaving a library backstop as the only gate.

---

[75] **8. ArbExecutor's V4 multihop callback enforces no hook allowlist**

`ArbExecutor.unlockCallback` · Confidence: 75 · [agents: 5]

**Description**
The single-hop branch re-checks `allowedV4Hooks[hook]` and the multihop branch checks nothing; `LiquidationExecutor` may rely on its pre-flashloan `decodeAndValidateV4MultihopShape` walk, but `ArbExecutor` has no structured-leg validator at all, so the hook allowlist it exposes is enforced only by an incidental 160-byte length constant in another library.

---

[75] **9. Arming an immediate swap leaves the previous continuation hash live**

`DirectSwapLib.swapV3` · `DirectSwapLib.beginContinuation` · Confidence: 75 · [agents: 3]

**Description**
`_armContinuation` deliberately zeroes `TOKENIN_TSLOT`/`MAX_TSLOT` so the immediate path cannot fire during a flash arming, but `swapV3`/`swapV2` never zero `CONT_HASH_TSLOT` and `beginContinuation` does not clear it on claim, so a pool armed for an immediate swap inside a live continuation can answer with the outer continuation's bytes and re-enter the remaining ops.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | A standing unlimited allowance is granted to a spender the operator names |
| 2 | [88] | The Bebop leg spends what its calldata says, not what the plan declared |
| 3 | [85] | The containment cap measures only the tokens the plan declares |
| 4 | [82] | Nothing can lower an allowance once granted |
| 5 | [78] | The V2 fee scale cannot express PancakeSwap's 0.25% |
| 6 | [75] | A partial Bebop fill is measured against a full-size floor |
| 7 | [75] | The two executors disagree on the same pre-flight flag test |
| 8 | [75] | ArbExecutor's V4 multihop callback enforces no hook allowlist |
| 9 | [75] | Arming an immediate swap leaves the previous continuation hash live |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Aave Pool and Morpho are generic call targets** — `LiquidationExecutor.execute` — Code smells: the constructor seeds `allowedTargets[aavePool_]` and `allowedTargets[morpho_]`, so a `GENERIC_SEQUENCE` op may call either with arbitrary calldata. Pure-exfiltration shapes are blocked by the per-op `outDelta == 0 → OpOutputNotReceived` gate; a `borrow(asset, N, 2, 0, address(this))` shape does satisfy `outDelta > 0` and was not dismissed. `ArbExecutor` deliberately does not seed Morpho, and says so.
- **A hardcoded 10k gas stipend to `block.coinbase`** — `CoinbasePaymentLib.payCoinbase` — Code smells: `call{value: amount, gas: 10_000}` with a hard revert on failure; several mainnet builders use a contract fee-recipient, and one cold SSTORE in its `receive()` exceeds the stipend, turning every bid-carrying send into a revert in blocks that builder wins. No concrete over-10k coinbase was verified.
- **The BUY-side input cap is computed and discarded** — `UniswapLib.executeUniV2Leg` / `executeUniV3Leg` — Code smells: `actualIn` is assigned and never read, while every sibling path enforces a post-call ceiling. With bounded approvals this is defense-in-depth rather than a hole.
- **Direct-pool ops propagate a claimed output, not a measured one** — `DirectSwapLib.receivedV3` / `_v2Out` — Code smells: `directOut = true` skips the balance-delta check and feeds the pool-reported amount into `_patchWord(data, op.returnAmountPos, prevReturn)`, i.e. a fabricated word lands inside an allowlisted router's calldata. No profitable patch target was constructed.
- **V2 and V3 flash callbacks share one arming word** — `DirectSwapLib.beginContinuation` — Code smells: `POOL_TSLOT`/`CONT_HASH_TSLOT` do not record which callback shape was armed, so a pool armed by `flashV3` can enter through `uniswapV2Call` and choose the continuation's first `prevReturn`. Containment appears to hold; the equivalence was not proven for every op layout.
- **`loanAmount` is a free number on the self-funded path** — `ArbExecutor._execute` — Code smells: the `selfFunded` branch takes no flash loan and asserts no balance, yet forwards `plan.loanAmount` as the `loanToken` containment cap. Held closed today only by an unrelated `held < profitBefore` line in `_runArbPipeline`, with no test tying the two together.
- **Nine positional same-type constructor arguments** — `LiquidationExecutor.constructor` — Code smells: all validated only for `!= address(0)`, all immutable, several auto-seeded into `allowedTargets` and given allowances. A transposition deploys a contract that passes every check and cannot be corrected without redeploying; no post-deploy read-back assertion exists in `SeededExecutors`.
- **`renounceOwnership` is inherited and not overridden** — `ArbExecutor` · `LiquidationExecutor` — Code smells: `Ownable2Step` is used to make transfer two-step, but the single-step renounce is left reachable on contracts designed to accumulate withdrawable balances. Self-harm, so not scored.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
