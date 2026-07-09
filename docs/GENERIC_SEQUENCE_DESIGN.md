# GENERIC_SEQUENCE executor — Phase 0 design spec

Goal: move the swap-execution core from a **rigid 2-leg topology** to a **v6-style
generic call sequence**, so that (a) we can express arbitrary **value-splits**
(the +$11.4k routing gap on #222) and (b) we can **add/remove DEXes offchain**
without a contract change or redeploy — exactly the ParaSwap v5→v6 shift.

This is **additive**: the existing shapes (Single / TwoLeg / SPLIT / MixedSplit)
stay for the common gas-optimal cases. We add ONE new shape, `GENERIC_SEQUENCE`,
alongside them and dispatch by `plan.swapPlan.shape`. Zero regression on what is
already deployed and live.

### Locked decisions (Phase 0 review)

1. **Encoding = ABI-decodable `Op[]`** for Phase 1 (clarity + safety). A packed
   v6-style calldata format is a later gas optimization behind the same
   semantics — not Phase 1.
2. **V4 is in the first pass** (Phase 1), not deferred — its unlock/settle
   handler ships with the other families.
3. **Allowlist = reuse the existing governance-mutable `allowedTarget`** (already
   in the contract), granularity at **singletons/factories** (not pools), owner
   = multisig/timelock. The only new piece is a V3-factory registry for callback
   authenticity. See §6.

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
**Good news: the current contract already ships the primitives this needs** —
`GENERIC_SEQUENCE` reuses them rather than adding new trust surface:

- `modifier onlyOperator` (`msg.sender == operator`) — the swap entry is already
  **permissioned**; only our bot key can run a sequence at all.
- `mapping allowedTarget` + `setAllowedTarget(address,bool) onlyOwner` — a
  governance-mutable **target allowlist already exists**.
- `setV4HookAllowed(address,bool) onlyOwner` — V4 hook allowlist already exists.
- `owner ≠ operator`, plus `rescueERC20/ETH(onlyOwner)` for recovery.

### Layered defenses (allowlist is defense-in-depth, not the sole gate)

1. **Permissioned entry (`onlyOperator`) — primary.** An external attacker
   cannot run a sequence. Only our (hot) operator key can.
2. **Empty between txs.** The executor holds no funds and no standing approvals
   across transactions (input arrives via the flashloan each tx; approvals are
   set and cleared within the op loop). Nothing to steal from a future victim.
3. **Two-output gate (atomic backstop).** Repay + minProfit must hold at the end
   or the whole tx reverts. Value cannot leak below the promised profit.
4. **Target allowlist (`allowedTarget`, reused).** Every direct-call op requires
   `allowedTarget[op.target]`. Bounds blast radius if our offchain generator has
   a bug or the operator key is compromised. We generate the calldata ourselves,
   so this costs us nothing (ParaSwap can't have it — they need open routing).
5. **Callback authenticity (callback DEXes).** Every callback verifies
   `msg.sender == computePool(factory, initHash, tokens, fee)` from a registered
   factory set. Prevents fake-pool callback drains. This is the **one addition**
   Phase 1 needs on top of the existing primitives: a V3-factory registry
   (`setAllowedV3Factory(factory, initHash) onlyOwner`), mirroring
   `setV4HookAllowed`.
6. **Reentrancy guard** on the entry; callbacks only permitted while an op with
   the matching `IS_*_CALLBACK` flag is in flight (armed context), and only from
   the expected pool.
7. **Approval hygiene.** Approvals set to exact amount and reset to 0 after the
   consuming op (or Permit2 transient approvals) — no lingering allowance.

### Allowlist granularity — SINGLETONS, not pools

So that "add DEX without redeploy" actually holds, we allowlist singletons and
verify pools from factories, never individual pools:

| Reach | What is allowlisted | New pools |
|---|---|---|
| Direct-call via router/vault (Balancer Vault, Curve router, Uni V2 router) | the **router/vault** address | auto-covered (routed through it) |
| Direct pool call (Uni V2 pair, V3 pool) | the **factory** + verify pool derives from it | auto-covered |
| Callback (V3 + forks) | **factory + init-code-hash** (authenticity check §5) | auto-covered |
| V4 | pool manager + hook (`setV4HookAllowed`) | auto-covered |

→ adding a **new DEX = one `setAllowedTarget` / factory-register owner tx (no
redeploy)**; new pools within a known DEX = zero action. This is the v6 win.

### Management decision

- **A. Hardcoded at deploy** — rejected; defeats "add DEX without redeploy".
- **B. Governance-mutable registry (`setAllowedTarget` onlyOwner)** — **chosen;
  already implemented.** Keep.
- **C. Hybrid immutable-core + mutable** — overkill given owner + rescue exist.

**Owner-key hygiene (the one real ask):** since the allowlist root of trust is
`onlyOwner`, set **owner = multisig/timelock** (operator/bot key stays a
separate hot key — already the design). A single compromised key then cannot
instantly whitelist a malicious target; and even if it did, the two-output gate
+ empty-executor bound the loss and `rescueERC20` recovers. Revocation is
instant: `setAllowedTarget(x, false)`.

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
  shapes: op loop + injection + two-output gate + reuse `allowedTarget` + the
  full family handler set (direct-call, Uni V2, Uni V3-callback + new V3-factory
  registry, Balancer V2, Curve, **and V4 unlock/settle**). Adversarial tests
  (hostile sequence → revert; fake-pool callback → revert; unlisted target →
  revert; under-repay / under-profit → revert; calldata-patch OOB → revert).
- **Phase 2** — bot generates `swapSequence` (single route first, then splits).
- **Phase 3** — port the knapsack solver locally; feed optimal splits into ops.
- **Phase 4** — audit + redeploy + migrate the bot's default path.

Backwards-compat: the bot keeps emitting existing shapes for simple cases and
route-variant fan-out keeps working; `GENERIC_SEQUENCE` is added as one more
route variant (`generic_seq`) in the same same-nonce fan-out, so it competes on
realized coinbase with the ParaSwap and local variants during rollout.
