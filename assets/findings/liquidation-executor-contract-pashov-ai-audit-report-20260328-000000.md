# 🔐 Security Review — LiquidationExecutor

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default (full repo)                                    |
| **Files reviewed**               | `src/LiquidationExecutor.sol`                          |
| **Confidence threshold (1-100)** | 60                                                     |

---

## Findings

[85] **1. `swapExactAmountOut` Is Permanently Broken in PARASWAP_SINGLE Mode**

`LiquidationExecutor._executeParaswapSingle` · Confidence: 85

**Description**
After executing a Paraswap call, the contract measures the actual source-token consumption via balance delta (`amountIn = srcBefore - srcAfter`) and then asserts strict equality `amountIn != plan.amountIn`. For `swapExactAmountOut` trades, Paraswap is designed to consume *up to* the declared `fromAmount` but will typically use less — causing this equality check to always revert and making `swapExactAmountOut` unusable in SINGLE mode even when the trade is profitable and all flash-loan obligations are satisfied.

**Fix**

```diff
- if (amountIn != plan.amountIn) revert ParaswapAmountInMismatch(plan.amountIn, amountIn);
+ if (amountIn > plan.amountIn) revert ParaswapAmountInMismatch(plan.amountIn, amountIn);
```

---

[78] **2. Pre-Existing Native ETH Consumed by Coinbase Payment Is Not Reflected in Profit Accounting**

`LiquidationExecutor._payCoinbase` / `_checkProfit` · Confidence: 78

**Description**
When the contract holds pre-existing native ETH (received via `receive()` from prior WETH unwraps or direct transfers), `_payCoinbase` uses it without unwrapping WETH (`wethUnwrapped = 0`). In `_checkProfit`, the deduction formula is `costNotInDelta = totalCoinbasePayment - totalWethUnwrapped`. When `wethUnwrapped = 0`, the full coinbase payment is deducted from `effectiveProfit`. However, if `address(this).balance >= amount` at call time, WETH is not touched at all — the ETH originated outside the current WETH profit flow. This is sound accounting when native ETH is truly external, but if the contract previously received ETH from a WETH `withdraw()` in a prior (separate) transaction, that ETH was already accounted for in a prior profit check and is now being double-deducted from the current run's profit. The result is that the operator's `minProfitAmount` guard may become spuriously unsatisfiable, causing a DoS on otherwise-profitable executions.

**Fix**

```diff
- if (address(this).balance < amount) {
+ // Snapshot ETH balance before any unwrap; only deduct the externally-sourced
+ // portion (balance pre-existing before this call) from profit accounting.
+ uint256 ethBalanceBefore = address(this).balance;
+ if (ethBalanceBefore < amount) {
      // ... unwrap logic ...
  }
  // Return both wethUnwrapped AND the pre-existing ETH used, letting _checkProfit
  // distinguish the two sources.
```

---

[72] **3. CHAINED Double-Swap: Intermediate Token Stranding When Leg-2 Uses `swapExactAmountOut`**

`LiquidationExecutor._executeParaswapDouble` · Confidence: 72

**Description**
In the CHAINED pattern, the contract validates `leg2FromAmount <= amountOut1` (declared max input ≤ leg-1 output), then executes leg 2. If leg 2 is a `swapExactAmountOut`, Paraswap may consume only a subset of the approved `leg2FromAmount`, leaving unconsumed intermediate tokens (e.g. WBTC or WETH) stranded in the contract. The `ChainedRemainder` event is emitted for observability, but there is no on-chain mechanism to route the surplus back to the operator or into profit accounting — the tokens are silently locked until an owner calls `rescueERC20`, creating a capital-loss scenario per execution.

**Fix**

```diff
  // After leg 2, sweep any leftover intermediate token to profit:
  uint256 intermediateBalance = IERC20(dst1).balanceOf(address(this));
  if (intermediateBalance > 0) {
      emit ChainedRemainder(dst1, intermediateBalance);
+     // Revert if intermediate tokens are left — operator must consume all leg-1 output
+     revert ChainedInputExceedsOutput(intermediateBalance, 0);
  }
```

Or alternatively, assert that leg-2 actual consumed equals its declared `fromAmount` for `swapExactAmountIn` selectors.

---

[68] **4. Bebop Multi-Swap: Source Token Surplus Silently Stranded — No Consumed-Amount Validation**

`LiquidationExecutor._executeBebopMulti` · Confidence: 68

**Description**
After the Bebop settlement call, the contract verifies only that the repay-token balance increased sufficiently (via `_executeSwapPlan`'s absolute balance check) but never validates how much of `plan.srcToken` (the collateral) Bebop actually consumed. If Bebop's settlement uses less than `plan.amountIn` of collateral — a legitimate outcome for partial fills or best-execution routing — the remaining collateral stays in the contract indefinitely, silently reducing the operator's realized yield without triggering any revert or event flag.

**Fix**

```diff
  uint256 srcBefore = IERC20(plan.srcToken).balanceOf(address(this));
  IERC20(plan.srcToken).forceApprove(target, plan.amountIn);
  (bool ok,) = target.call(plan.bebopCalldata);
  IERC20(plan.srcToken).forceApprove(target, 0);
  if (!ok) revert BebopSwapFailed();
+ uint256 srcAfter = IERC20(plan.srcToken).balanceOf(address(this));
+ uint256 actualConsumed = srcBefore - srcAfter;
+ if (actualConsumed < plan.amountIn) revert InsufficientSrcBalance(plan.amountIn, actualConsumed);
```

---

[62] **5. Morpho Liquidation: `assetsRepaid > maxRepayAssets` Post-Check Uses Wrong Error Revert Arguments**

`LiquidationExecutor._executeMorphoLiquidation` · Confidence: 62

**Description**
The post-liquidation guard `if (assetsRepaid > liq.maxRepayAssets) revert InsufficientRepayBalance(assetsRepaid, liq.maxRepayAssets)` is semantically inverted: `InsufficientRepayBalance(required, available)` normally means "needed more than available," but here `assetsRepaid` (the actual pulled) is passed as `required` and `maxRepayAssets` (the bound) as `available`, producing a confusing error payload in off-chain tooling. While not a fund-loss bug, the inverted arguments mean monitoring/alerting systems that parse this error will misdiagnose the failure direction.

**Fix**

```diff
- if (assetsRepaid > liq.maxRepayAssets) revert InsufficientRepayBalance(assetsRepaid, liq.maxRepayAssets);
+ if (assetsRepaid > liq.maxRepayAssets) revert InsufficientRepayBalance(liq.maxRepayAssets, assetsRepaid);
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | `swapExactAmountOut` Is Permanently Broken in PARASWAP_SINGLE Mode |
| 2 | [78] | Pre-Existing Native ETH Consumed by Coinbase Payment Is Not Reflected in Profit Accounting |
| 3 | [72] | CHAINED Double-Swap: Intermediate Token Stranding When Leg-2 Uses `swapExactAmountOut` |
| 4 | [68] | Bebop Multi-Swap: Source Token Surplus Silently Stranded — No Consumed-Amount Validation |
| 5 | [62] | Morpho Liquidation: `assetsRepaid > maxRepayAssets` Post-Check Uses Wrong Error Revert Arguments |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **PARASWAP_DOUBLE SPLIT: No Per-Leg Amount Validation** — `LiquidationExecutor._executeParaswapDouble` — Code smells: SINGLE mode validates `amountIn == plan.amountIn` but DOUBLE/SPLIT mode has no equivalent per-leg declared-vs-actual check — In SPLIT mode, each leg's actual consumed amount is not bounded on-chain; Paraswap could consume an asymmetric split of collateral between the repay leg and profit leg that differs from the operator's off-chain intent, requiring verification of whether the `_activePlanHash` commitment alone provides sufficient protection.

- **Fee-on-Transfer Loan Token DoS** — `LiquidationExecutor.executeOperation` / `receiveFlashLoan` — Code smells: `if (IERC20(plan.loanToken).balanceOf(address(this)) < plan.loanAmount) revert InvalidFlashLoan()` — If the flash-loan token charges a transfer fee (e.g. a rebasing stablecoin that temporarily reduces balances), this pre-execution balance check will revert and permanently block all liquidations for that token, requiring verification of whether all anticipated loan tokens are fee-exempt.

- **`minProfitAmount = 0` Bypass** — `LiquidationExecutor.execute` — Code smells: no lower bound enforced on `plan.swapPlan.minProfitAmount` — The operator can set `minProfitAmount = 0`, disabling the only on-chain slippage guard; while the operator is trusted, an exploited/compromised operator key combined with a zero minProfit allows MEV sandwich attacks to extract collateral value with no revert safety net.

- **Balancer Vault Impersonation Window** — `LiquidationExecutor.receiveFlashLoan` — Code smells: `msg.sender` is checked against `allowedFlashProviders[FLASH_PROVIDER_BALANCER]` at callback time, but `setFlashProvider` can update this address — Between `execute()` committing `_activePlanHash` and the Balancer callback arriving, an owner `setFlashProvider` call could theoretically change the validated vault address; since this requires owner cooperation it is low-risk, but worth verifying that `setFlashProvider` is protected against front-running by monitoring the mempool.

- **aToken Unwrap Delta Arithmetic Precision** — `LiquidationExecutor.executeOperation` — Code smells: `aTokenDelta = IERC20(trackingToken).balanceOf(address(this)) - collateralBefore` then `_unwrapATokens(collateralAsset, aTokenDelta)` — If aTokens are rebasing upward between the `collateralBefore` snapshot and the subtraction, `aTokenDelta` will be slightly larger than the actual liquidation output and the contract will attempt to `withdraw` more aTokens than received from the liquidation, potentially pulling from residual aToken balance held from prior executions without accounting for it.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
