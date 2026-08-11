# Generic native-ETH support for ANY DEX — redeploy-free venue extensibility

**Date:** 2026-07-24
**Repo:** `liquidation-executor-contract` (Foundry)
**Applies to BOTH executors** (shared `GenericSequenceLib`): `LiquidationExecutor` (live 0xB543) + `ArbExecutor` (PR #32). Both redeploy + re-audit.

## Goal (user-stated, strong form)

Adding a new DEX in the future — native-ETH or ERC20, present or not-yet-existing — must require **only** an owner `setAllowedTarget` tx + an off-chain `Op[]` encoder change. **NEVER a contract redeploy.** Native-ETH pools must work on ANY leg of ANY swap, for ANY DEX, exactly as ERC20 pools already do.

## Where we are (verified in code)

The generic `Op[]` path in `GenericSequenceLib._executeOps` is already **venue-agnostic** for the ERC20 case: `forceApprove(target, amount) → target.call(calldata) → forceApprove(0) → out-delta on address(this)`. A new ERC20/router DEX needs no code — allowlist + encoder only. **Two things** still force per-DEX contract code:

1. **Native-ETH input** — `if (op.value != 0) revert InvalidPlan();` bans forwarding ETH to a target. A payable DEX (`swapIn{value}`, Curve `exchange{value}`, a router taking `msg.value`) cannot be called.
2. **Native-ETH output** — `outBefore/outBal = op.outToken == address(0) ? 0 : balanceOf(...)` hardcodes 0 for native output, so a swap that legitimately delivers ETH always fails `OpOutputNotReceived`.

Plus one special-case that is NOT generic: the V4 `unlockCallback` machinery (armed slots 10/11) exists because V4 uses an unlock/callback flashswap pattern that a plain `call` can't drive. Any *future* callback-architecture DEX with a different callback selector would, under today's design, need its own in-contract handler → a redeploy. That violates the goal too.

## Design — three changes, all in shared `GenericSequenceLib`

### Change 1 — native input via `FLAG_NATIVE_IN` (generic, any payable DEX)

New op flag `FLAG_NATIVE_IN = 1 << 5`. When set, the direct-call branch does
`op.target.call{value: amount}(patchedCalldata)` instead of `approve+call`
(no allowance — native ETH is sent as value). `op.srcToken` MUST be
`address(0)` (native) for this flag; `amount` is the ETH forwarded.

**Security — the value-forwarding ban is relaxed, NOT removed.** Today
`op.value != 0 → revert` is a blanket ban the audit approved as "operator
cannot push the executor's ETH to an arbitrary target." Under this change,
ETH forwarding is allowed ONLY via `FLAG_NATIVE_IN` and the amount is bounded
by the **existing per-srcToken containment cap** on the `address(0)` bucket:
- standing/donated ETH bucket has `allowed = 0` (unchanged), so a
  `FLAG_NATIVE_IN` op can only forward ETH **produced within this same tx**
  (a preceding `WETH_UNWRAP` or a preceding native-output leg) — identical to
  the guarantee that already governs V4 `settle{value}`.
- a per-op input ceiling (mirror of the V4 exact-in `V4InputOverspent` check):
  snapshot `_balOf(address(0))` before, assert consumed ≤ `amount` after, so a
  malicious target can't pull more standing ETH than the op declared.
`op.value` field on the struct stays hard-0 (the raw field is never honored);
value forwarding is expressed only through the flag + `amount`, so there is no
second path.

### Change 2 — native output via `_balOf` (generic)

Replace `op.outToken == address(0) ? 0 : IERC20(op.outToken).balanceOf(...)`
with `_balOf(op.outToken)` (already exists: `address(0) → address(this).balance`)
for BOTH `outBefore` and `outBal`. A native-ETH-output leg now delta-checks
against the executor's ETH balance — the same recipient-pinning guarantee the
ERC20 path has. Fixes the audit-flagged native-output DoS. `prevReturn`
chaining works unchanged (it's a uint256 amount, token-agnostic).

### Change 3 — prefer ROUTER-driven callback DEXes (policy, not code) + keep V4 legacy path

The remaining per-DEX-code risk is **callback/flashswap** DEXes (Uni V3
pool-direct, V4, Pancake pool-direct, hooks). The redeploy-free answer is a
**routing policy, enforced off-chain in the encoder, needing no contract
code**: route every such DEX through its ROUTER, which internally runs the
callback and accepts ETH via `msg.value`. Then:
- Uni V3 / Pancake V3 → their `SwapRouter` / `SmartRouter` (`exactInputSingle`),
  a plain `approve+call` generic op — already works, redeploy-free.
- Uni V4 → the Universal Router / V4 router entrypoint that takes `msg.value`
  and does the unlock internally → a `FLAG_NATIVE_IN` `call{value}` generic op.
- Fluid / Curve native → `swapIn{value}` / `exchange{value}` → `FLAG_NATIVE_IN`.

The existing in-contract V4 `unlockCallback` + armed slots 10/11 stay as a
**gas-optimized legacy fast-path for the specific native-V4 pools already
wired** (do not remove — it's audited and live on 0xB543), but it is no longer
the ONLY way to reach V4, and NO future callback DEX needs an in-contract
handler: it goes through its router as a generic `call{value}`. This is what
makes the architecture redeploy-free forever.

**No generic arbitrary-callback trampoline** is built — that would be a large,
dangerous surface (owner-configurable selector→handler dispatch on a money
contract). Router-routing achieves the same redeploy-free property without it.

## Resulting property (the goal, met)

| DEX class | Native? | Redeploy to add a NEW one? |
|---|---|---|
| ERC20 router / aggregator (UniV2/V3, Pancake, Curve, Bal, Paraswap, Bebop, 1inch, 0x, Fluid ERC20) | — | **No** (allowlist + encoder) |
| Payable router / pool (`call{value}`: Fluid native, Curve native, V4 via router) | native | **No** (allowlist + encoder, uses `FLAG_NATIVE_IN`) |
| Pool-direct callback flashswap (V3/V4 pool-direct) | either | routed via its router → **No**. In-contract pool-direct kept only for the already-wired native-V4 fast path. |

Every leg, any DEX, native or not, composes freely (up to `MAX_OPS=32`),
subject to the unchanged invariants: cap-token containment, absolute repay
gate, `FLAG_USE_FULL_BALANCE` only on the cap token, sequence reconverges to
loanToken.

## Security invariants (must all still hold)

1. Standing/donated ETH bucket cap = 0 → a compromised operator cannot drain
   standing native ETH (the audit's `test_arb_standingEthSpend_withoutUnwrap`
   guarantee) — `FLAG_NATIVE_IN` is bounded by the same cap.
2. `FLAG_NATIVE_IN` per-op input ceiling (consumed ≤ amount) — no settle/call
   over-pull of standing ETH beyond the declared amount.
3. `op.srcToken == address(0)` admitted only with `FLAG_NATIVE_IN` or
   `FLAG_V4_UNLOCK` (extend the existing `srcToken==0 && !FLAG_V4_UNLOCK`
   reject to also allow `FLAG_NATIVE_IN`).
4. `FLAG_NATIVE_IN` mutually exclusive with `FLAG_WETH_UNWRAP` /
   `FLAG_V4_UNLOCK` / `FLAG_USE_FULL_BALANCE` (flag-combo rejects, like V4).
5. Native output delta-check pins recipient to the executor (Change 2).
6. Existing V4 path, containment cap, absolute repay gate, re-entry CLAIM
   unchanged — behavior-preserving for everything already working.
7. Both executors' liquidation + arb suites stay 100% green.

## Testing (Foundry, TDD)

- `FLAG_NATIVE_IN` happy path: `WETH_UNWRAP → Curve exchange{value}(ETH→stable)`
  and `→ Fluid swapIn{value}` cycles on a mainnet fork, repay + containment.
- Native output: a leg delivering ETH passes the `_balOf` delta-check and
  chains via `prevReturn` into a following `FLAG_NATIVE_IN` leg.
- Adversarial: `FLAG_NATIVE_IN` forwarding standing ETH (no preceding
  unwrap/native-output) reverts `CollateralOverspent`; over-pull beyond
  `amount` reverts the per-op ceiling; flag-combo rejects.
- Router-routed V4 via `FLAG_NATIVE_IN` reaches the same native pool as the
  legacy `unlockCallback` path (parity), proving the callback fast-path is
  now optional.
- Full liquidation + arb regression green on both executors.
- **MANDATORY** `solidity-auditor` pass, hard-focused on: does relaxing
  `op.value==0` open ANY standing-ETH drain? (the exact invariant the last
  audit approved).

## Deploy (out of plan scope, flagged)

Redeploy BOTH executors (shared lib change): new immutable `ArbExecutor`
(folds into the PR #32 deploy) + new `LiquidationExecutor` to replace live
0xB543 (the bigger operational step — hard-gate boundary, S3 snapshot,
executor-switch, per the native-V4 deploy playbook). Bot: `Op[]` encoder
emits `FLAG_NATIVE_IN` ops + the router-routing policy for callback DEXes.
