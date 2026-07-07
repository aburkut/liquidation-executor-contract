# GENERIC_SEQUENCE — coordinated deploy plan

The GENERIC_SEQUENCE work spans **two repos that are ABI-coupled** and MUST ship
together in one coordinated window. This is the runbook.

## 0. The hard constraint (read first)

Adding `hasGenericSequence` + `Op[]` to `SwapPlan` **changes the ABI of every
plan**, including the leg-based ones the live bot sends today. The **currently
deployed executor expects the OLD `SwapPlan` layout**.

Therefore:
- **Do NOT merge `liquidation-bot:feat/generic-seq-knapsack` to main before the
  new executor is deployed.** A bot on the new `encoder.rs` sol! layout would
  produce calldata the OLD executor cannot decode → every live liquidation
  reverts.
- Contract deploy and bot merge happen in the **same window**, contract first.

Status today: contract fix branch `design/generic-sequence-executor` is
audit-clean (4 self-audit rounds, 0 exploitable, 1739 tests / 0). Bot branch has
the knapsack + generator + encoder ABI, isolated. The live bot runs the OLD
executor + the route-variant fan-out (#184–#186) — untouched.

---

## 1. Pre-deploy — contract

1. **Merge the fix branch** `design/generic-sequence-executor` → main (contract
   repo) after CI green.
2. **Resolve the deploy-hygiene audit LEADs** (all non-exploitable, but this is
   the deploy checklist):
   - **Constructor arg ordering** — the constructor takes 9 same-type `address`
     params, each only `!= 0` checked. The deploy script MUST assert each
     configured address is the intended role (weth==WETH, uniV3Router==the V3
     SwapRouter, etc.) — a positional swap deploys a mis-wired, non-reverting
     contract. Add explicit post-deploy read-back assertions.
   - **`_verifyATokenAddress` slot-9** — the assembly reads `getReserveData()`'s
     9th word (offset 256) as `aTokenAddress`. Aave V3 pool impl has rotated
     (MEMORY: rev 11 @ 25199939). Before deploy, `cast call` the CURRENT pool's
     `getReserveData(asset)` and confirm `aTokenAddress` is still at word 9. If
     the layout moved, fix the offset. (Worst case is a fail-closed revert, but
     verify so receiveAToken liquidations still work.)
3. **Owner = multisig / timelock.** The allowlist + rescue trust root is
   `onlyOwner`. Deploy with `owner` set to a multisig (not the hot operator
   key). `operator` = the bot's hot signer (immutable).

## 2. Deploy + allowlist setup (owner txs)

1. Deploy the new executor with the verified constructor args.
2. **Fund/no-fund:** it holds zero balance between txs by design — no funding.
3. **Allowlist the DEX targets** (`setAllowedTarget`, owner):
   - The V3 SwapRouter `0xE592427A0AEce92De3Edee1F18E0157C05861564` (the
     generator's direct-call target), plus any Curve router / Balancer Vault /
     Uni V2 router the bot routes through.
   - Flash providers (Balancer Vault, Morpho) are constructor-pinned — no action.
4. **(removed)** `setV3Factory` / raw-V3-pool-callback ops and V4 ops were
   dropped from GENERIC_SEQUENCE to fit under the EIP-170 code-size limit — the
   generator only ever emitted direct-call SwapRouter ops. Nothing to register.
   Structured UNI_V4 swap legs (normal leg plans) are unaffected.
5. **V4 hooks** (`setV4HookAllowed`) — keep EMPTY unless a specific hook is
   needed and audited (still relevant for structured UNI_V4 legs).
6. **Sanity:** run one small liquidation through a leg-based plan (existing
   shape) against the new executor on a fork/tenderly before the bot cutover.

## 3. Bot activation

1. **Finish the deferred fan-out wiring** (the one remaining Phase-2 code task):
   refactor `SwapSpec` so a `GenericSequence { ops }` shape is expressible
   without the leg-centric `primary_leg()` assumption (make `src_token` /
   `deadline` first-class on `SwapSpec`, or `Option`), then push a `generic_seq`
   variant in the fan-out populate alongside `paraswap_ms` / `local_twohop`,
   built via `generic_sequence::build_v3_router_two_leg` (+ the knapsack for the
   split ratios). Best done NOW-in-window because it can finally be tested live.
2. **Point the bot's executor address** at the newly deployed contract.
3. **Merge `feat/generic-seq-knapsack`** → main (only after step 2 — the ABI now
   matches).
4. **Build release + restart** the bot (cold-start ~10 min; schedule around a
   hard-gate boundary per MEMORY to avoid a replay-from-old-snapshot window).

## 4. Rollout safety

`generic_seq` ships as **one more same-nonce route variant** in the existing
fan-out. Nonce ⇒ **≤1 of {primary, paraswap_ms, local_twohop, generic_seq}
mines**; the builder picks the highest-realizing. So a broken generic_seq
variant cannot lose a liquidation — the leg-based primary still competes. This
is the safe rollout lever: enable generic_seq, watch the fan-out monitor for
`generic_seq` selections/wins, and it can only add upside.

## 5. Rollback

- If the new executor misbehaves: point the bot back at the OLD executor
  address + revert the bot to pre-merge main (the leg-based shapes are
  unchanged), restart. No on-chain rollback needed — the OLD executor still
  exists and works.
- `pause()` (owner) halts the new executor immediately if needed.

---

## Residual audit LEADs carried into production (all traced non-exploitable)

Documented so they are not forgotten; none block deploy, but each is a
known-and-accepted item since no external audit will review them:

| LEAD | Status |
|---|---|
| V4 int256 cast sign-flip | **CLOSED** — bound-check added (`> 2^255 → revert`) |
| V4 multihop unbounded nHops | **CLOSED** — MAX_HOPS=10 cap added |
| V4 multihop callback hook re-check | accepted — safe via PM byte-forwarding + plan-hash pin; pre-validation is test-covered |
| NO_SWAP single-leg absolute repay | accepted — monotonically conservative; standing balance only adds headroom |
| MIXED_SPLIT leg1 post-hoc-only cap | accepted — net-delta check is sound |
| coinbase native-ETH funding source | accepted — value-neutral, standing ETH ≈ 0 |
| Paraswap exact-out approval = declaredIn | accepted — reactive `actualIn` check + trusted constructor-pinned Augustus |
| Balancer single-BUY missing explicit consumed cap | accepted — bounded by exact approval + Vault limit |
