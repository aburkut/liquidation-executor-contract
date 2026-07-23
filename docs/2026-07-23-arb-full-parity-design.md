# ArbExecutor → LiquidationExecutor routing parity — design spec

**Date:** 2026-07-23
**Repo:** `liquidation-executor-contract` (Foundry)
**Goal:** bring `ArbExecutor` to full routing parity with `LiquidationExecutor` — percentage splits, multi-hop across multiple intermediate tokens, native V4 legs, and the generic `Op[]` sequence — so the same cross-venue knapsack that gives us +$2.9k on liquidations can execute arbitrage backruns.

**Money contract.** Audited. This spec sequences the change so each piece is independently testable and the mandatory `solidity-auditor` pass gates the redeploy.

---

## 1. Problem

Today `ArbExecutor` executes only a **linear chain** of single-venue legs (`legs[]`, `_dispatchLeg`): `leg[0].src == loanToken`, `leg[i+1].src == leg[i].repay`, `last.repay == loanToken`, ≤ 8 legs. It supports **no percentage splits**, **no V4 legs**, and rejects the native multi-hop modes (`CURVE_V1_MH`, `BAL_V2_MH`). The cross-venue split routing that `LiquidationExecutor` gets from `GenericSequenceLib` is entirely absent.

`GenericSequenceLib.run(Op[], …)` is the shared, audited engine that DOES all of this — a **flat `Op[]`** array expresses splits (multiple ops spending one `srcToken` to different venues), multi-hop chains, V4 unlock legs, and WETH unwrap, all under a per-srcToken containment cap. It is already a shared library, not liquidation-specific code. But two things in it are liquidation-shaped, and one hard coupling blocks arb reuse.

### 1.1 The two liquidation-shaped semantics

1. **Containment cap** (`run` line ~375):
   `allowed = (t != address(0) && t == collateralAsset) ? collateralDelta : 0`.
   Arb has no collateral. Its working capital is the **flash principal** of `loanToken`; the arb-correct cap is `allowed = loanAmount` for `loanToken`, `0` for every other token (intermediates are produced by the sequence, nothing standing may be spent).

2. **Repay gate** (`run` line ~349):
   `repayDelta = loanAfter − loanBefore ≥ flashRepayAmount`.
   In liquidation, `loanBefore ≈ 0` (the flashed debt token was spent on `liquidationCall` before `run`), so the sequence must *reproduce* `flashRepay`. In arb, `loanBefore = loanAmount` (full principal present at `run` entry — the sequence itself spends AND reproduces `loanToken`), so the **delta** gate is wrong by exactly `loanAmount`. Arb needs the **absolute** gate `loanAfter ≥ flashRepayAmount`.

### 1.2 The hard coupling: V4 arming slots

`GenericSequenceLib` arms the V4 callback via raw `sstore` into **hardcoded slots** `V4_PM_SLOT = 10` (`_activeV4PoolManager` + `_executionPhase`) and `V4_TOKENIN_SLOT = 11` (`_activeV4TokenIn` + `_v4Armed`). These are `LiquidationExecutor`'s storage slots, pinned by `test_v4SlotConstantsMatchLayout` against `forge inspect storageLayout`. For `ArbExecutor` to reuse the V4 branch via DELEGATECALL, its storage must place the same fields at the same slot numbers, AND it must implement the matching `unlockCallback` + `_v4Armed`/`_activeV4TokenIn`/`_activeV4PoolManager` guards + the `UniswapLib.runV4UnlockSwap` path.

---

## 2. Approach (decided)

**Shared engine + arb entry point.** No duplication of the 397-line audited lib (a duplicate means two engines to audit and drift risk — violates no-kostyli). Full parity in one redeploy: splits + Curve/Bal multi-hop modes + V4 legs + generic sequence.

### 2.1 `GenericSequenceLib` — extract shared loop, add `runArb`

- Extract the per-op execution loop (the ~180-line body: snapshot → op loop with WETH-unwrap / FULL_BALANCE / PREV_RETURN / V4-unlock / direct-call / out-delta → containment post-check) into an **internal** `_executeOps(...)` that takes the containment parameters abstractly:
  - `capToken` — the single token allowed a nonzero spend bound (collateral for liq, loanToken for arb).
  - `capAmount` — its allowed net spend (collateralDelta for liq, loanAmount for arb).
  - `repayGate` — an enum/bool selecting **delta** (`loanAfter − loanBefore`) vs **absolute** (`loanAfter`) comparison against `flashRepayAmount`.
- `run(...)` (existing liquidation entry) becomes a thin wrapper: `_executeOps(ops, loanToken, flashRepay, collateralAsset, collateralDelta, weth, RepayGate.Delta)`. **Byte-identical behavior** — the existing liquidation test suite must stay green unchanged.
- **New** `runArb(ops, loanToken, flashRepay, loanAmount, weth)` → `_executeOps(ops, loanToken, flashRepay, loanToken, loanAmount, weth, RepayGate.Absolute)`.
  - Containment: `capToken = loanToken`, `capAmount = loanAmount`. Every non-loanToken bucket keeps `allowed = 0`. The loanToken bucket is snapshotted at `loanAmount` (full principal) and may be net-spent by at most `loanAmount` — a sequence that dips standing loanToken profit reverts.
  - Repay: **absolute** `loanAfter ≥ flashRepayAmount`.
- **V4 slots stay pinned constants** (`10`/`11`). Do NOT parametrize them into `runArb` (a caller-supplied arming slot is new attack surface). Instead, constrain `ArbExecutor`'s layout to match (§2.2).

### 2.2 `ArbExecutor` — V4 machinery + generic-sequence execution

- **Storage layout**: arrange inherited contracts + field declaration order so `_activeV4PoolManager`+`_executionPhase` land at **slot 10** and `_activeV4TokenIn`+`_v4Armed` at **slot 11**, byte-identical packing to `LiquidationExecutor` (address in bytes 0..19, the phase/armed byte at 20). Pin with an `ArbExecutor`-owned `test_v4SlotConstantsMatchLayout` reading `forge inspect ArbExecutor storageLayout` — layout drift fails the suite, exactly as for the liquidation side.
  - `ArbExecutor` currently inherits `Ownable2Step, Pausable, ReentrancyGuard` (same as `LiquidationExecutor`) and already has `_activePlanHash` + `_executionPhase`. It must ADD `_activeV4PoolManager`, `_activeV4TokenIn`, `_v4Armed` in the order + position that reproduces slots 10/11. The pinning test is the source of truth; the plan computes the exact declaration order from `forge inspect`.
- **Port the V4 callback path** from `LiquidationExecutor`: `unlockCallback(bytes)` with the `_v4Armed` CLAIM-on-entry re-entry guard, `UniswapLib.runV4UnlockSwap` (native + ERC20 settle), and the V4 hook allowlist (`setV4HookAllowed` / `allowedV4Hooks`). This is a lift of the already-audited native-V4 code — the same bytes reviewed in the native-eth-v4 change.
- **Switch execution**: replace the `legs[]` + `_dispatchLeg` linear path with a generic-sequence path:
  - `ArbPlan` gains `Op[] ops` (or a `hasGenericSequence` + `ops` pair mirroring `SwapPlan`). Keep `legs[]` ONLY if a gas-optimal simple path is still wanted; otherwise replace it (decide in the plan — leaning replace, since `Op[]` subsumes the linear chain and dead code is audit surface).
  - `execute()` pre-flashloan validation walks `ops[]` and asserts every `op.target ∈ allowedTargets` (mirrors the liquidation pre-flash allowlist walk, incl. the `FLAG_WETH_UNWRAP` exemption which carries no external target).
  - Inside the flash callback, call `GenericSequenceLib.runArb(plan.ops, loanToken, flashRepay, loanAmount, weth)` via DELEGATECALL.
  - Coinbase bribe + `minProfit` guard stay in `_runArbPipeline` around the sequence (unchanged shape — realized profit is `loanAfter − loanBefore − 0`; note the profit computation must account for the arb `loanBefore = loanAmount` baseline, distinct from liquidation).
- **EIP-170**: adding the V4 callback + generic-sequence path grows the runtime. Measure after each task; if it crosses 24576 bytes, move the incremental logic to a DELEGATECALL library exactly as the native-V4 change did (`SwapValidationLib`/`GenericSequenceLib` already off-loaded). The plan includes a size checkpoint.

### 2.3 Off-chain (bot) — `ArbPlan` `Op[]` encoder

Out of scope for THIS contract spec (flagged, separate bot work): the bot must encode `ShadowArb` (and the cross-venue knapsack output) into `ArbPlan.ops[]`, reusing the SAME `Op[]` encoder the liquidation knapsack already produces. That is what feeds split routes into the new engine. The contract change is a prerequisite; the encoder + deploy + `ARB_EXECUTOR` wiring is the follow-on.

---

## 3. Security invariants (must all hold post-change)

1. **onlyOperator** entry; execution-phase gate on every flash callback; plan-hash pin cleared before external calls (existing).
2. **Per-srcToken containment**: `runArb` bounds loanToken net-spend to `loanAmount`, every other token to `0`. A compromised operator cannot route out standing profit / donations / residue of ANY token — same guarantee the liquidation cap gives, re-expressed for the arb capital model. Pin with: standing-token-spend-reverts, standing-ETH-spend-reverts (no unwrap), loanToken-overspend-reverts.
3. **No native value forwarding** (`op.value == 0`), native ETH only via `settle{value}` inside the V4 callback (existing lib invariant, inherited by `runArb`).
4. **V4 re-entry**: `_v4Armed` CLAIM-on-entry; a stray `unlockCallback` when not armed reverts; nested unlock reverts (ported guarantee).
5. **V4 exact-in per-op ceiling** (`V4InputOverspent`) — inherited from the shared loop.
6. **Absolute repay gate** never lets the flash go unrepaid; a sequence that fails to reproduce `flashRepay` reverts (arb variant pinned).
7. **Existing liquidation suite stays 100% green** — the `run` → `_executeOps` extraction must be behavior-preserving.

---

## 4. Testing (Foundry, TDD)

- **Refactor safety**: run the full existing suite after the `_executeOps` extraction — zero diffs in liquidation behavior.
- **`runArb` unit**: split route (2 ops from loanToken → two venues → reconverge), multi-hop (loanToken→A→B→loanToken), Curve/Bal multi-hop modes, V4 native leg in an arb cycle, all netting profit and repaying the flash on a mainnet fork.
- **Containment adversarial**: loanToken overspend reverts (`CollateralOverspent`/arb equivalent); standing intermediate-token spend reverts; standing-ETH spend without unwrap reverts; V4 exact-in over-pull reverts.
- **Slot pinning**: `ArbExecutor` `test_v4SlotConstantsMatchLayout` + `test_v4UnlockSelectorPin`.
- **Repay gate**: arb sequence that under-produces loanToken reverts on the absolute gate; a profitable one passes.
- **EIP-170**: assert runtime ≤ 24576 after the final task.
- **MANDATORY**: full `solidity-auditor` pass over the changed `GenericSequenceLib` (`_executeOps` extraction + `runArb`) and the new `ArbExecutor` V4 + generic-sequence path before deploy.

## 5. Deploy (flagged, out of plan scope)

New immutable `ArbExecutor` address. Same chain as native-V4: audit → deploy from operator key → allowlist targets (owner tx, no redeploy for future venues) → bot `ArbPlan` encoder + `ARB_EXECUTOR` wiring → shadow-validate on real opps → switch live.
