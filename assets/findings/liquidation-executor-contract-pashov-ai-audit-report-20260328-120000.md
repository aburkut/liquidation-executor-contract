# 🔐 Security Review — LiquidationExecutor

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default                                                |
| **Files reviewed**               | `src/LiquidationExecutor.sol`                          |
| **Confidence threshold (1-100)** | 40                                                     |

---

## Findings

[72] **1. Chained double-swap: leg-2 input validated against declared `fromAmount`, not actual consumed amount after leg 1**

`LiquidationExecutor._executeParaswapDouble` · Confidence: 72

**Description**
Before executing leg 2 in `CHAINED` mode, the contract reads `leg2FromAmount` from the raw calldata and asserts `leg2FromAmount <= amountOut1` (leg 1's actual output). However, `leg2FromAmount` is the *declared* maximum input extracted by assembly from `paraswapCalldata2`, not the amount that `_executeParaswapCall` will actually consume. For a `swapExactAmountOut` leg 2, the augustus router may internally try to spend up to the full declared maximum even if less suffices; if `amountOut1` lies slightly above `leg2FromAmount` the check passes, yet the router could consume slightly more in the actual execution due to the tolerance being checked against declared rather than real spend — the absolute repay check in `_executeSwapPlan` is the only backstop.

**Fix**

```diff
-        if (leg2FromAmount > amountOut1) revert ChainedInputExceedsOutput(leg2FromAmount, amountOut1);
+        if (leg2FromAmount > amountOut1) revert ChainedInputExceedsOutput(leg2FromAmount, amountOut1);
         // Execute leg 2
         (address src2, address dst2, uint256 amountIn2, uint256 amountOut2) =
             _executeParaswapCall(plan.paraswapCalldata2);
+        // Post-execution guard: actual consumed must not exceed leg 1 output
+        if (amountIn2 > amountOut1) revert ChainedInputExceedsOutput(amountIn2, amountOut1);
```

---

[68] **2. `_verifyATokenAddress` assembly does not update the Solidity free-memory pointer after overwriting it with returndata**

`LiquidationExecutor._verifyATokenAddress` · Confidence: 68

**Description**
The assembly block reads `mload(0x40)` to obtain `ptr`, writes the `getReserveData` calldata there, and uses the same memory region as the returndata destination, but never advances the free-memory pointer (`mstore(0x40, add(ptr, 480))`). Any Solidity-managed memory allocation that occurs in the same call frame after this assembly block returns may reuse `ptr` and silently corrupt the returndata before `canonical` is consumed; while the current control flow reads `canonical` before any further allocation, future refactoring of the surrounding code could introduce an allocation in between without a visible red-flag.

**Fix**

```diff
         assembly {
             let ptr := mload(0x40)
+            mstore(0x40, add(ptr, 480))   // advance free-memory pointer
             mstore(ptr, 0x35ea6a7500000000000000000000000000000000000000000000000000000000)
             mstore(add(ptr, 4), collateralAsset)
             let ok := staticcall(gas(), pool, ptr, 36, ptr, 480)
             if iszero(ok) { revert(0, 0) }
             canonical := mload(add(ptr, 256))
         }
```

---

[62] **3. Split double-swap: no aggregate collateral-consumption guard across both legs**

`LiquidationExecutor._executeParaswapDouble` · Confidence: 62

**Description**
In `SPLIT` mode both legs share the same `srcToken` (collateral), but the contract never checks that `amountIn1 + amountIn2` is bounded by the collateral delta received from the liquidation; a malformed (but operator-signed) plan where the sum of declared inputs exceeds the freshly received collateral could silently drain pre-existing collateral balances sitting in the contract (e.g., stuck tokens from a prior run), because the swap plan's only budget guard is the flash-repay sufficiency check on the output side.

**Fix**

```diff
+        // SPLIT: total collateral consumed must not exceed the liquidation delta
+        if (collateralAsset != address(0)) {
+            uint256 collateralDelta = IERC20(collateralAsset).balanceOf(address(this)) - collateralBefore;
+            if (amountIn1 + amountIn2 > collateralDelta) revert InsufficientSrcBalance(amountIn1 + amountIn2, collateralDelta);
+        }
```

---

[55] **4. `setFlashProvider` does not remove the old provider from `allowedTargets`, leaving stale approvals possible**

`LiquidationExecutor.setFlashProvider` · Confidence: 55

**Description**
When a flash provider is rotated via `setFlashProvider`, the old address is overwritten in `allowedFlashProviders` but remains present in `allowedTargets`; because `allowedTargets` is also used by Paraswap/Bebop execution paths to gate `forceApprove` and direct calls, the retired provider address retains the ability to receive ERC-20 approvals and arbitrary call-forwarding if it appears in future swap calldata crafted by the operator.

---

[48] **5. Morpho liquidation: `seizedAssets` return value from `IMorphoBlue.liquidate` is not compared to the expected amount**

`LiquidationExecutor._executeMorphoLiquidation` · Confidence: 48

**Description**
`IMorphoBlue.liquidate` returns `(uint256 seizedAssets, uint256 assetsRepaid)` and only `assetsRepaid` is validated against `maxRepayAssets`; the actual collateral seized (`seizedAssets`) is only indirectly verified through the post-liquidation balance delta check, meaning a Morpho market edge case (e.g., bad debt, oracle gap) that caused Morpho to seize less collateral than `liq.seizedAssets` requested would pass the approval guard but could leave the contract with insufficient collateral to cover the flash repayment.

---

[45] **6. `_payCoinbase` sends ETH to `block.coinbase` which is a builder-controlled, potentially adversarial address**

`LiquidationExecutor._payCoinbase` · Confidence: 45

**Description**
The coinbase payment is sent to `block.coinbase` with a bare `.call{value: amount}("")` and the only guard is that `block.coinbase != address(0)`; a malicious block builder could set `block.coinbase` to a contract that re-enters the `LiquidationExecutor` during the call, and although `nonReentrant` protects `execute()`, the coinbase payment occurs *inside* the existing locked execution frame — the reentrancy guard is already taken, meaning a reentrant call to `execute()` would revert, but calls to `rescueERC20`, `rescueETH`, or any owner-only function would not be blocked if the owner is the same EOA that triggered the block.

---

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [72] | Chained double-swap: leg-2 input validated against declared `fromAmount`, not actual consumed |
| 2 | [68] | `_verifyATokenAddress` assembly does not update the free-memory pointer |
| 3 | [62] | Split double-swap: no aggregate collateral-consumption guard across both legs |
| 4 | [55] | `setFlashProvider` leaves stale address in `allowedTargets` |
| 5 | [48] | Morpho: `seizedAssets` return value not validated against requested amount |
| 6 | [45] | `_payCoinbase` sends ETH to builder-controlled `block.coinbase` with no reentrancy isolation |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **ChainedRemainder event reports total balance, not swap delta** — `LiquidationExecutor._executeParaswapDouble` — Code smells: `IERC20(dst1).balanceOf(address(this))` used as event value — The event emits the *total* balance of the intermediate token after both legs, not the leftover from the chained swap; pre-existing intermediate-token balance inflates the reported remainder, which could mislead off-chain monitoring into incorrect state assumptions.

- **`_validateActions` called twice per callback without caching** — `LiquidationExecutor.executeOperation` / `receiveFlashLoan` — Code smells: duplicate `_validateActions` call, full action-array iteration repeated — Each callback calls `_validateActions` independently (once in the callback body and once implicitly via `execute()`); in a future refactor where `_validateActions` acquires a state read, this pattern would silently introduce a double-read discrepancy window, and today it wastes gas linearly in action count.

- **`_unwrapATokens` always uses `aavePool` (V3), never `aaveV2LendingPool`** — `LiquidationExecutor._unwrapATokens` — Code smells: hardcoded `aavePool` reference despite a V2 pool also existing — Although `receiveAToken=true` is currently blocked for Aave V2 in `_validateActions`, the unwrap function's unconditional use of `aavePool` means that if V2 aToken unwrapping is ever enabled, it would silently call the wrong pool and revert or misbehave without a clear diagnostic.

- **`execute()` discards `trackingToken` from `_validateActions`** — `LiquidationExecutor.execute` — Code smells: `(address collateralAsset,) = _validateActions(...)` — The `trackingToken` (aToken address when `receiveAToken=true`) is not used during pre-flight validation in `execute()`; the canonical aToken check is deferred entirely to the callback, meaning an operator submitting an incorrect `aTokenAddress` does not get a fast-fail rejection — the error surfaces only after flash loan funds have been borrowed.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
