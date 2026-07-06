# GENERIC_SEQUENCE executor — Phase 0 design spec

Goal: move the swap-execution core from a **rigid 2-leg topology** to a **v6-style
generic call sequence**, so that (a) we can express arbitrary **value-splits**
(the +$11.4k routing gap on #222) and (b) we can **add/remove DEXes offchain**
without a contract change or redeploy — exactly the ParaSwap v5→v6 shift.

This is **additive**: the existing shapes (Single / TwoLeg / SPLIT / MixedSplit)
stay for the common gas-optimal cases. We add ONE new shape, `GENERIC_SEQUENCE`,
alongside them and dispatch by `plan.swapPlan.shape`. Zero regression on what is
already deployed and live.

---

## 1. Why the 2-leg model blocks us

Today a plan carries exactly two `SwapLeg`s that encode two **roles**, not two
swaps:

- `repayLeg` — collateral → loanToken (repay the flashloan)
- `profitLeg` — residual collateral → WETH (coinbase bribe)

Each leg is **one route** (one pool, or one linear multi-hop path). There is no
way to route a single conversion across **N pools in parallel** (order-splitting
for slippage), which is exactly what the #222 winner did (11.648 WBTC via
WBTC/WETH + 0.441 WBTC via WBTC/USDT). ParaSwap's knapsack solver produces such
splits; our contract cannot execute them.

## 2. The generic model — roles stay, legs dissolve

The contract stops encoding swap **topology**. It runs a flat, offchain-built
sequence of DEX calls and only enforces the two **invariants** it already
enforces today:

```
run(swapSequence)                               // arbitrary DEX calls: splits, multi-hop, any DEX
assert loanToken.balanceOf(this) >= flashRepay  // repay role
realizedProfit = WETH.balanceOf(this) - wethBefore
assert realizedProfit >= minProfitAmount        // profit role  (InsufficientProfit)
coinbase = min(bps * realizedProfit, realizedProfit)   // CoinbaseExceedsProfit guard
```

The sequence itself produces BOTH outputs (loanToken for repay + WETH for
profit); how to split between them is baked into the bytes by the bot. The
existing shapes become **special cases** of this (Single = 1 call; MixedSplit =
[coll→loanToken exact-out],[residual→WETH]).

Runtime sizing that the 2-leg model did via "measure collateralDelta after
leg1, size leg2" generalizes to the v6 injection mechanism (§4): read a balance /
previous return between calls and inject it into the next call's calldata.

---

## 3. DEX-family table — what needs contract code vs pure offchain calldata

DEXes cluster into a handful of settlement families. Implement each family's
handler **once**; thereafter adding pools or new forks **inside** a family is
pure offchain calldata — no contract change, no redeploy.

| Family | Settlement mechanic | Contract handler needed | New DEX/pool in family → contract change? |
|---|---|---|---|
| **Direct-call** (generic AMM/router) | `approve(target)` then `call(target, swapCalldata)`; target pulls src, sends dst | none — generic `call` + `approve` op | **No** |
| **Curve V1/V2/NG** | `approve(pool)`, `exchange(i,j,dx,minDy)` (+ `exchange_underlying`, router `exchange`) | none — direct-call | **No** |
| **Balancer V2** | `approve(Vault)`, `Vault.swap` / `batchSwap` (GIVEN_IN/OUT) | none — direct-call | **No** |
| **Uniswap V2 forks** | `transfer(pair, amtIn)` then `swap(a0Out,a1Out,to,"")` | none — two ops in the sequence (transfer + call) | **No** |
| **Uniswap V3 forks (std callback)** | `pool.swap(...)` → `uniswapV3SwapCallback(d0,d1,data)` → pay pool | `uniswapV3SwapCallback` handler + factory/init-code-hash registry | **No** if same callback sig; **register factory** for a new fork |
| **Uni V3 forks (custom callback name)** (Pancake `pancakeV3SwapCallback`, Algebra `algebraSwapCallback`) | same, different callback selector | add that callback function (one-time per fork family) | one-time |
| **Uniswap V4** | `PoolManager.unlock` → callback `settle`/`take` | V4 unlock/settle handler | one-time |
| **RFQ / 0x / signed-order routers** | `call(target, signedOrderCalldata)` | none — direct-call | **No** |

For our mainnet universe the relevant families are Uni V2/V3/V4, Curve,
Balancer (+ a couple V3 forks). That is **~5–6 handlers, implemented once**;
after that, adding pools/forks-in-family is offchain-only. This is the v6 win.

### Why callbacks are special (and the security tie-in)
A V3 pool calls **back into us** mid-swap; we must pay it in the callback. That
requires (1) a callback function of the exact selector the pool uses, and (2) a
**pool-authenticity check** — recompute the pool address from
`factory + init-code-hash + (token0,token1,fee)` and require the caller equals
it. Without (2) any contract could invoke our callback and drain the payment.
The authenticity check **is** the allowlist for callback DEXes (see §6).

---

## 4. Encoding spec — `swapSequence`

Informed by ParaSwap v6 `Executor01` but fitted to our flashloan flow (two
required outputs, no user/fees). We define a clear ABI-decodable format for
Phase 1; a tightly-packed calldata variant (v6-style) is a later gas
optimization behind the same semantics.

```solidity
struct Op {
    address target;        // DEX pool / router / token (for approve/transfer ops)
    uint256 value;         // native ETH to send (usually 0)
    uint16  fromAmountPos;  // byte offset in callData to inject a runtime amount; 0 = none
    uint16  returnAmountPos;// byte offset to inject the PREVIOUS op's output; 0 = none (chaining)
    uint32  flags;         // see below
    bytes   callData;      // selector + args, pre-built offchain
}
// swapSequence = abi.encode(Op[] ops)
```

**Runtime injection** (why offchain calldata still works despite unknown
amounts): before each op the contract patches `callData` in-place:
- `fromAmountPos != 0` → write a 32-byte amount at that offset. Which amount is
  chosen by flags: a literal baked in the op, or `balanceOf(srcToken)` (full
  balance), or the previous op's return (`returnAmountPos`).
- `returnAmountPos != 0` → write the previous op's measured output (balance
  delta of the op's outToken) — this is how leg1→leg2 chaining generalizes.

**Flags (bitfield):**
| bit | name | meaning |
|---|---|---|
| 0 | `USE_FULL_BALANCE` | inject `balanceOf(srcToken)` at `fromAmountPos` |
| 1 | `USE_PREV_RETURN` | inject previous op output at `fromAmountPos` |
| 2 | `IS_APPROVE` | op is an ERC20 approve (target=token); executor sets/clears allowance |
| 3 | `IS_V3_CALLBACK` | this op triggers a V3-style callback; arm the callback context |
| 4 | `IS_V4_UNLOCK` | V4 unlock/settle path |
| 5 | `SEND_VALUE` | forward `value` wei |
| … | reserved | |

**Src/out token tags** per op (needed for balance-delta measurement and the
allowlist): carried in a parallel compact array or appended to each op —
`{ srcToken, outToken }`. Kept explicit so the executor never has to parse
DEX-specific calldata to know what moved.

---

## 5. Execution algorithm (contract, inside the flashloan callback)

```
wethBefore = WETH.balanceOf(this)
for op in ops:
    require(allowed(op.target, op.flags))            // §6 allowlist / factory registry
    if op.flags & IS_APPROVE: setAllowance(op.target, op.spender, amount); continue
    amount = pick(op, flags, prevReturn, balances)   // literal / full-balance / prev-return
    if op.fromAmountPos: patch(op.callData, op.fromAmountPos, amount)
    if op.returnAmountPos: patch(op.callData, op.returnAmountPos, prevReturn)
    outBefore = op.outToken.balanceOf(this)
    (ok, ) = op.target.call{value: op.value}(op.callData)   // callbacks handled by armed context
    require(ok)  // bubble revert reason
    prevReturn = op.outToken.balanceOf(this) - outBefore
// gates (unchanged invariants)
require(loanToken.balanceOf(this) >= flashRepay)                 // repay
realizedProfit = WETH.balanceOf(this) - wethBefore
require(realizedProfit >= minProfitAmount, InsufficientProfit)   // profit
coinbase = clampCoinbase(bps, realizedProfit)                    // CoinbaseExceedsProfit
```

The flash provider's own repay check + these two gates are the atomic backstop:
a wrong/hostile sequence can only **revert**, never under-repay or under-profit.

---

## 6. Security / threat model

The generic executor's attack surface is "arbitrary `call(target, data)`."
It is bounded by:

1. **Empty between txs.** The executor holds no funds and no standing approvals
   across transactions (input arrives via the flashloan each tx; approvals are
   set and cleared within the op loop). A hostile sequence has nothing to steal
   from a future victim — worst case is this tx reverts.
2. **Two-output gate (atomic backstop).** Repay + minProfit must hold at the end
   or the whole tx reverts. Value cannot leak below the promised profit.
3. **Target allowlist (direct-call).** `allowedTargets[target]` gate on every
   direct op — even a bug in our offchain generator cannot call an unknown
   contract. We generate the calldata ourselves (trusted), so this is a free
   defense-in-depth ParaSwap can't have (they need open routing).
4. **Callback authenticity (callback DEXes).** Every callback verifies
   `msg.sender == computePool(factory, initHash, tokens, fee)` from a registered
   factory set. Prevents fake-pool callback drains.
5. **Reentrancy guard** on the entry; callbacks only permitted while an op with
   the matching `IS_*_CALLBACK` flag is in flight (armed context), and only from
   the expected pool.
6. **Approval hygiene.** Approvals set to exact amount and reset to 0 after the
   consuming op (or use Permit2 transient approvals) — no lingering allowance.

Open items to nail in Phase 1 review: calldata patch bounds-checking
(`fromAmountPos + 32 <= callData.length`), gas-griefing via long sequences
(cap op count), and native-ETH handling.

---

## 7. #222 worked example (why this closes the gap)

Winner seized 12.089 WBTC, split to minimize slippage, kept profit in WETH.
As a `swapSequence` (schematic):

```
op0  approve WBTC → WBTC/WETH pool           (IS_APPROVE)
op1  WBTC/WETH.swap  in=11.648 WBTC → WETH    (IS_V3_CALLBACK, split A)
op2  approve WBTC → WBTC/USDT pool            (IS_APPROVE)
op3  WBTC/USDT.swap  in=0.441 WBTC → USDT     (IS_V3_CALLBACK, split B)
op4  USDT/USDC stableswap  exact-out = flashRepay USDC   (USE_PREV_RETURN sizing)
op5  (residual WETH stays)
gates: USDC.balance >= flashRepay ✓   WETH profit >= minProfit ✓   coinbase = bps*profit
```

Today this is **inexpressible** (needs 2 parallel WBTC→{WETH,USDT} routes >
2 legs). Under `GENERIC_SEQUENCE` it is just 6 ops. The offchain **knapsack**
(ported from ParaSwap `solver.ts`, ~150 lines) decides the split ratios and
emits these ops.

---

## 8. Phased plan

- **Phase 0** (this doc) — families table + encoding + security model.
- **Phase 1** — `GENERIC_SEQUENCE` shape in the contract alongside existing
  shapes: op loop + injection + two-output gate + target allowlist + the ~5–6
  family handlers (direct-call, V2, V3-callback+factory registry, Balancer,
  Curve; V4 optional). Adversarial tests (hostile sequence → revert; fake-pool
  callback → revert; under-repay/under-profit → revert).
- **Phase 2** — bot generates `swapSequence` (single route first, then splits).
- **Phase 3** — port the knapsack solver locally; feed optimal splits into ops.
- **Phase 4** — audit + redeploy + migrate the bot's default path.

Backwards-compat: the bot keeps emitting existing shapes for simple cases and
route-variant fan-out keeps working; `GENERIC_SEQUENCE` is added as one more
route variant (`generic_seq`) in the same same-nonce fan-out, so it competes on
realized coinbase with the ParaSwap and local variants during rollout.
