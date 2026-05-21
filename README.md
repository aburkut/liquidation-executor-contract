# LiquidationExecutor

## Deployment (Ethereum Mainnet)

| Parameter | Value |
|---|---|
| **Contract (V10)** | `0x7FF9D22393a825A735E5889624cA07f86D28A374` |
| **Deploy tx** | `0xfe000c9c7e44e06ca31ff190147a513ab746b8778a6a1d3819a97e3a9799c984` (block 25138634) |
| **BalancerV2Lib** | `0x5def208c6df62574a6949423d1d653efda80072b` (re-deployed — V10 signature drop: no longer takes `isTargetAllowed`) |
| **BalancerV2Lib deploy tx** | `0xb24f9cfb7d16a52a94cdd3fa268ac01812d54587eac97b3f2f61ae1dc54e571f` |
| **UniswapLib** | `0x532a595f32b7da458e35deb86601e24ea35be86e` (re-deployed — V4_MAX_SQRT_PRICE_LIMIT corrected to v4-core `MAX_SQRT_PRICE − 1`; pre-V10 sentinel exceeded `MAX_SQRT_PRICE` and reverted every `!zeroForOne` V4 swap with `PriceLimitOutOfBounds`) |
| **UniswapLib deploy tx** | `0xb82b9a29e14e176a59d33ed862fa916007f665863fc6612ea6369dbc43c1cd5b` |
| **SwapValidationLib** | `0x639a41463fbcc86ef11ba4f6313cb4e046922944` (new in V10 — extracted `validateNonV4Leg` + `assertNoSwapLegZeroed` + PARASWAP_SINGLE `minAmountOut > 0` floor) |
| **SwapValidationLib deploy tx** | `0x50c689b18b5366835010875dd4a0ebcd5e959b69ce332dfa0794a28ee5cd2cc2` |
| **CoinbasePaymentLib** | `0x0c89bfe7abf50fe03300620affd589499ad398f2` (new in V10 — extracted `payCoinbase` / `computeRealizedProfit` / `checkProfit`) |
| **CoinbasePaymentLib deploy tx** | `0xdef7d8283a509a1093b2cfd0f9868451c79ef5cba6bf9d1edf02956ea0264e4f` |
| **SwapLegExecutorLib** | `0x1483a7e66a792bfc6c39a6bdfba61fb501b8e75c` (re-deployed for V10 signature alignment) |
| **SwapLegExecutorLib deploy tx** | `0x9952c51c2b17c171e1ec3b13f244c6ecf43be8f733e1229da941e7dc95869528` |
| **CurveV1Lib** | `0xf72becd7512fa82e4374646374b51a728cba2602` (re-deployed — V10 signature drop: no longer takes `isTargetAllowed`) |
| **CurveV1Lib deploy tx** | `0x04bf8a4159ed9318f9c521d037a0619fb8b4b46f2d2f9f159319ca4ff61210bc` |
| **ParaswapDecoderLib** | `0x498e1dc8e2d7d221da9afc8d1a1aaa82b3b2ee08` (re-used from V9 — internal dependency of `SwapLegExecutorLib`, source unchanged) |
| **Runtime bytecode size** | 22 633 bytes (1 943 bytes margin under EIP-170) — V10 absorbs the V9 feature set while freeing ~1.9 KB via the SwapValidationLib + CoinbasePaymentLib extraction and the `allowedExtSwapTargets` mapping removal (constructor-pinned Morpho/Balancer eliminates the runtime allow-list lookup for those targets) |
| **Owner** | `0xC338094Bb79AA610E9c57166fc4FA959db6234Ab` (Safe multisig) |
| **Operator** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` (immutable) |
| **WETH** | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (immutable) |
| **Deployer** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` |
| **Aave V3 Pool** | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` (liquidation target; V3 flashloan path removed) |
| **Balancer Vault** | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` (constructor-pinned as flash provider id=2 — V10 dropped the post-deploy `setFlashProvider` setter) |
| **ParaSwap AugustusV6** | `0x6A000F20005980200259B80c5102003040001068` |
| **Uniswap V2 Router02** | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` (immutable) |
| **Uniswap V3 SwapRouter02** | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` (immutable) |
| **Uniswap V4 PoolManager** | `0x000000000004444c5dc75cB358380D2e3dE08A90` (in `allowedTargets`, used per-swap) |
| **Morpho Blue** | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` (liquidation target + flashloan id=3 — constructor-pinned in V10, `configureMorpho` removed) |
| **Bebop Settlement** | `0xbbbbbBB520d69a9775E85b458C58c648259FAD5F` (allowlisted) |
| **Aave V2 LendingPool** | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` (allowlisted — set via `setAaveV2LendingPool` when V2 liquidations are wired) |
| **Solidity** | 0.8.24, Shanghai, optimizer 1 run, `via_ir=true`, `bytecode_hash=none` |
| **Total deploy cost** | 9 948 191 gas / 0.001009 ETH (gas price 0.101 gwei across blocks 25138631-25138634) |

V10 is a refactor pass on top of V9: same feature surface, structural cleanup, one critical V4 bug-fix.

Headline changes:

1. **V4_MAX_SQRT_PRICE_LIMIT corrected** (`src/libraries/UniswapLib.sol`). The pre-V10 sentinel was `1_461_446_703_529_909_599_001_367_844_790_673_715_015_930_149_261` — strictly greater than v4-core `TickMath.MAX_SQRT_PRICE`. V4 PoolManager reverts `PriceLimitOutOfBounds(uint160)` when `!zeroForOne && sqrtPriceLimitX96 >= MAX_SQRT_PRICE`, so every token1→token0 V4 swap reverted by construction since the first V4 commit. Fix: `MAX_SQRT_PRICE − 1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341`. Pinned by `UniswapLibV4SqrtConstantsTest` (4 regression assertions anchoring both `V4_MIN_SQRT_PRICE_LIMIT` and `V4_MAX_SQRT_PRICE_LIMIT` to v4-core literals and to the PoolManager's strict-inequality check).
2. **`allowedExtSwapTargets` mapping removed** (was V9 slot 9). Curve V1 and Balancer V2 dispatchers now route through the existing `allowedTargets` allowlist alongside Uni V2/V3/V4 — one allowlist for everything. `_activePlanHash` and successors shift down one slot (`9` → was `10`, etc.). `setExtSwapTarget` removed accordingly.
3. **Morpho / Balancer Vault constructor-pinned.** `configureMorpho` and the BALANCER-only `setFlashProvider` are gone — both addresses are constructor arguments now and live in immutable storage, eliminating the post-deploy desync window where the contract could exist with one provider unset.
4. **`SwapValidationLib` extracted** (~ first half of the V9 `_validateLeg` body). Hosts `validateNonV4Leg` + `assertNoSwapLegZeroed`. Adds the deferred audit fix: PARASWAP_SINGLE now requires `leg.minAmountOut > 0` — restores per-leg slippage parity with every other swap mode (V9 deferred to Augustus' calldata-embedded floor, making the dispatch-side `amountOut < leg.minAmountOut` check a no-op when the struct field was 0).
5. **`CoinbasePaymentLib` extracted.** Hosts `payCoinbase` + `computeRealizedProfit` + `checkProfit` — the bribe-sizing math the contract uses to compute the basis-points coinbase payment from on-chain-measured realized profit.

Carried forward from V9: Curve V1 + Balancer V2 dispatchers (SELL + BUY, leg1 + leg2). Carried forward from V8: same-asset NO_SWAP + hasMixedSplit (`col == debt != WETH` opportunities with a coinbase-capable WETH bribe leg). Carried forward from V7: V4 unlock-callback re-entry + tokenIn pin, explicit NO_SWAP + hasLeg2 / hasMixedSplit guards (the latter relaxed in V8 for the same-asset case). Carried forward from V6: `hasMixedSplit` plan shape; all three of {`hasLeg2`, `hasSplit`, `hasMixedSplit`} remain mutually exclusive — enforced pre-flashloan with `PlanShapeConflict`.

V9's audit-LEAD hardenings remain in force (the underlying invariants stay intact in V10; only their host surfaces shifted):

1. **Curve V1 / Balancer V2 SwapModes** — `CURVE_V1`, `CURVE_V1_BUY`, `BAL_V2`, `BAL_V2_BUY` are dispatched out of `CurveV1Lib` / `BalancerV2Lib`. V10 routes them through the unified `allowedTargets` allowlist (the V9 `allowedExtSwapTargets` mapping is gone, see headline change #2 above).
2. **Skip-unwrap leg1.amountIn cap** — `_runFlashloanPipeline` caps `leg1.amountIn ≤ aTokenDelta` in the `receiveAToken=true` branch, symmetric to the existing collateral cap.
3. **`_verifyATokenAddress` returndatasize guard** — assembly read of slot 9 from `getReserveData` gated by `returndatasize() ≥ 288`.
4. **Morpho / Balancer Vault wiring locked at construction time** — V9 routed this through `configureMorpho` + a BALANCER-only `setFlashProvider`. V10 promotes both to constructor parameters (see headline change #3), so the desync window is eliminated structurally rather than by setter-level guards.
5. **Paraswap per-leg `minAmountOut` floor** — `SwapLegExecutorLib.executeParaswapLeg` enforces BOTH the calldata-embedded `minAmountOut` AND `leg.minAmountOut`. V10 additionally rejects `leg.minAmountOut == 0` at the validator (see headline change #4).
6. **V4 multihop non-simple-path rejection** — `UniswapLib.decodeAndValidateV4MultihopShape` rejects any hop whose `tokenOut` aliases `srcToken` or an earlier hop's `tokenOut`.
7. **`_v3PathEndpoints` precondition tightened** to `>= 43` bytes (token + fee + token minimum), forbidding degenerate lengths where first-20 / last-20 loads could overlap.
8. **`balancerVault` public storage slot removed** (V9 re-audit cleanup) — Balancer-flashloan path authority lives in `allowedFlashProviders[FLASH_PROVIDER_BALANCER]`.

The one remaining LEAD (Bebop arbitrary calldata) is a design constraint: `target.call(leg.bebopCalldata)` is structurally an arbitrary-call primitive against allowlisted contracts. The output-delta floor blocks pure value-extraction; closing the state-only side-effect surface would require either removing Bebop or porting it to a typed-interface dispatcher with selector whitelisting.

| Previous deployments | |
|---|---|
| **V9 Contract** | `0x5b1E7FCf175Aac717F4841321bA2C8D17558a6Fd` (deprecated — superseded by V10: V4_MAX_SQRT_PRICE_LIMIT fix + SwapValidationLib/CoinbasePaymentLib extraction + constructor-pinned Morpho/Balancer + `allowedExtSwapTargets` mapping removal) |
| **V9 deploy tx** | `0x460acabd932c1e7e8a5738ce9b9fbe863602c90c0f848c954b7aab277a9669f8` |
| **V8 Contract** | `0xB48378b1035dDA425bB9AA76F81c7f1695B0aeE0` (deprecated — superseded by V9 Curve V1 + Balancer V2 dispatchers + 9 audit-LEAD hardenings) |
| **V8 deploy tx** | `0xe011e1029adb704e0f64a37b072bc17a82d9ddd1a403a6d06ad5370f63cc6827` |
| **V7 Contract** | `0xb18e3A861961BF399b08Bdd8500019319Be58779` (deprecated — superseded by V8 same-asset NO_SWAP + hasMixedSplit support; V7 rejected the combination outright) |
| **V7 deploy tx** | `0x1a48be1e2fffecb1486542d23a40eec6747fc6a1b711c62b13846f012e2ddfd3` |
| **V6 Contract** | `0x4AEdDDF5E0D18D454E5F0Cc5E37E86B061fC0D1c` (deprecated — superseded by V7 security hardening: V4 callback re-entry + tokenIn pin, explicit NO_SWAP + hasLeg2 / hasMixedSplit guards) |
| **V6 deploy tx** | `0xeefff46d96063f64479253849b41d25468a53a5cdbf794d5ec520a26edb6fa62` |
| **V5 Contract** | `0xECf5F37Ff877a787a75777Ab054048d590684b48` (deprecated — SPLIT mode required both legs Uni, so thin coll↔debt pairs couldn't use SPLIT for coinbase; superseded by V6 MIXED_SPLIT which permits any-mode leg1) |
| **V5 deploy tx** | `0x53daf1d6b8a88dd3cf5d22ad42a775e672b57c3334b8c713b0848531ae1ea1d7` |
| **V4 Contract** | `0xB5C7881500F0A7A56E985266Da6AD9d19a5CCBB4` (deprecated — flat SwapPlan (16 fields) without two-leg / SPLIT; superseded by V5 leg-based + SPLIT mode) |
| **V4 deploy tx** | `0x95383aabc6cf9b092ac9809facd9c1eb966be3c824e0f5f6ca583fd4374c7976` |
| **V3 Contract** | `0xbdBcDAa6C667582298ca70dE2CD6647d6ab105e5` (deprecated — legacy SwapMode layout with `PARASWAP_DOUBLE`; 0x11 overflow on whale BUY-side; bot migrated off on 2026-04-21) |
| **V3 deploy tx** | `0x132b93b032ced2f1f2874c8836b90ba45fa81ba0f947f75e222f67d192a69468` |
| **V2 Contract** | `0x38F4473C077c014786037cC3d82fce52510b9089` (deprecated — no Bebop, had ERC20 payment) |
| **V1 Contract** | `0x1aaED107C21B389a38a632129dC0Cb362819bC8D` (deprecated) |

---

Production-grade **Flashloan → Multi-Liquidation → Multi-Swap → Repay** execution contract for
DeFi liquidation bots.

Supports **six swap modes** (Paraswap single, Bebop multi-output, Uniswap V2 / V3 / V4,
NO_SWAP for same-token liquidations), **four composition patterns** (single leg, sequential
two-leg with on-chain tracked leftover, parallel split between repay and WETH-profit,
mixed-split with any-mode repay leg + Uni-only profit leg), **three liquidation protocols**
(Aave V3, Aave V2, Morpho Blue), **two flashloan sources** (Balancer Vault, Morpho Blue),
and **basis-points coinbase builder payments** sized from on-chain-measured realized profit.

## Architecture

```
Operator Bot
    |
    v
+------------------------------------------+
|         LiquidationExecutor              |
|  Ownable2Step / Pausable                 |
|  ReentrancyGuard / ExecutionPhase guard  |
+------------------------------------------+
|  execute(planData)                       |
|    +-- Deadline check                    |
|    +-- Validate Plan                     |
|    |   +-- actions > 0, <= 10            |
|    |   +-- at least 1 liquidation        |
|    |   +-- single debt asset             |
|    |   +-- single collateral asset       |
|    |   +-- repayToken == loanToken       |
|    |   +-- mode-specific validation      |
|    +-- Flash Loan                        |
|    |   +-- Balancer Vault (id=2)         |
|    |   +-- Morpho Blue (id=3)            |
|    +-- Execute Actions (loop)            |
|    |   +-- Aave V3 liquidation           |
|    |   +-- Aave V2 liquidation           |
|    |   +-- Morpho Blue liquidation       |
|    +-- Collateral delta check            |
|    +-- aToken unwrap (if receiveAToken)  |
|    +-- Swap (6 modes)                    |
|    |   +-- PARASWAP_SINGLE               |
|    |   +-- BEBOP_MULTI                   |
|    |   +-- UNI_V2                        |
|    |   +-- UNI_V3                        |
|    |   +-- UNI_V4 (hook-allow-listed)    |
|    |   +-- NO_SWAP (same-token liq)      |
|    +-- Repay sufficiency (delta-based)   |
|    +-- Realized profit snapshot          |
|    +-- Internal actions                  |
|    |   +-- Coinbase payment (bps)        |
|    +-- Profit check                      |
|    +-- Repay flash loan                  |
+------------------------------------------+
```

### Execution Flow

1. **Operator** calls `execute(bytes planData)` with an ABI-encoded `Plan`.
2. Contract validates the plan (deadline, repayToken, action consistency, mode-specific fields).
3. Contract initiates a flash loan from the configured provider (**Balancer** or **Morpho**).
4. Inside the callback:
   - Phase guard + hash check + caller verification
   - Derive collateral asset and tracking token from validated actions
   - Verify canonical aToken address (if `receiveAToken=true`)
   - Snapshot collateral and profit token balances
   - Execute all liquidation actions
   - Verify collateral delta (balance must increase)
   - Unwrap aTokens to underlying if needed (delta-only, not full balance)
   - Execute swap via selected mode (`repayDelta` checked vs. `flashRepayAmount`)
   - Snapshot realized profit **before** any coinbase payment
   - Execute internal actions (coinbase payment sized from bps × realized profit)
   - Verify minimum profit (effective = realized − coinbase paid)
   - Repay flash loan
5. Remaining profit stays in the contract for the owner to rescue.

## Supported Protocols

| Category | Protocol | ID | Status |
|---|---|---|---|
| Flash Provider | ~~Aave V3~~ | ~~1~~ | **Removed** (path deleted from source) |
| Flash Provider | Balancer Vault | `2` | Supported |
| Flash Provider | Morpho Blue | `3` | Supported |
| Liquidation | Aave V3 | `1` | Supported (actionType=4 only) |
| Liquidation | Aave V2 | `3` | Supported (`receiveAToken=false` only) |
| Liquidation | Morpho Blue | `2` | Supported (`seizedAssets` mode only) |
| Swap | ParaSwap AugustusV6 | — | `PARASWAP_SINGLE` (ExactIn **or** ExactOut, selector-validated) |
| Swap | Bebop Settlement | — | `BEBOP_MULTI` (opaque calldata, allowlist + delta check) |
| Swap | Uniswap V2 Router02 | — | `UNI_V2` (multi-hop path, input = collateral delta option) |
| Swap | Uniswap V3 SwapRouter02 | — | `UNI_V3` (single-hop, fee tier pinned) |
| Swap | Uniswap V4 PoolManager | — | `UNI_V4` (single-hop, hook-allow-listed, struct-encoded PoolKey) |
| Swap | (no DEX) | — | `NO_SWAP` — same-token liquidation (debt asset == collateral asset). `srcToken == repayToken` required; bypasses all DEX paths and the leg validator. Allowed for **single-leg** plans, and (V8+) for **`hasMixedSplit` when `col == loanToken`** so the residual loanToken can be swapped to WETH via the leg2 profit leg for coinbase bribe. Combining with `hasLeg2` is still rejected with `PlanShapeConflict`. |
| Payment | Coinbase (ETH) | — | Requires `profitToken == WETH`; amount = **bps of realized profit** |

> **Stable IDs**: `FLASH_PROVIDER_AAVE_V3` was id `1`. The identifier is not reused — id `1` is
> now unbound so bot-side code that still references it fails fast rather than silently
> routing through a different provider. Balancer remained `2` and Morpho is `3`.

### Capability Matrix

| Protocol | `receiveAToken=false` | `receiveAToken=true` | Canonical verification |
|---|---|---|---|
| Aave V3 | Supported | Supported | `getReserveData` on-chain |
| Aave V2 | Supported | **Blocked** (`ReceiveATokenV2Unsupported`) | No on-chain verification |
| Morpho Blue | N/A | N/A | N/A |

### Swap Modes

| Mode | Description | Notes |
|---|---|---|
| `PARASWAP_SINGLE` | Single Paraswap swap, `srcToken → repayToken` (leg1 only — not allowed as leg2) | Augustus V6.2 selector-classified; ExactIn requires `amountIn == declared`, ExactOut requires `amountIn <= declared`. Selector validation is done by `ParaswapDecoderLib` (external library, DELEGATECALL). |
| `BEBOP_MULTI` | Opaque Bebop settlement call, multi-output (leg1 only — not allowed as leg2) | Output validated via balance delta against `leg.minAmountOut` (matches UniV2/V3/V4 — `InsufficientRepayOutput` on underdelivery); `leg.minAmountOut > 0` required pre-flashloan; pipeline-level `repayDelta >= flashRepayAmount` layered on top. Allow-listed target only; exact approval + reset pattern. |
| `UNI_V2` | Uniswap V2 Router02 `swapExactTokensForTokens`, multi-hop path | Path endpoints pinned: `v2Path[0] == srcToken`, `v2Path[last] == repayToken`, `length >= 2`. Optional `useFullBalance=true` to swap the exact collateral delta produced this call when used as leg1; when used as leg2 the amountIn is the tracked leftover of `leg2.srcToken` produced by leg1. |
| `UNI_V3` | Uniswap V3 SwapRouter02 `exactInputSingle` | Fee tier restricted to `{100, 500, 3000, 10000}`. SwapRouter02 has no deadline — the executor enforces `plan.deadline` itself. When used as leg2, `useFullBalance=true` sets amountIn to the tracked leftover of `leg2.srcToken` produced by leg1. |
| `UNI_V4` | Uniswap V4 PoolManager `unlock` → `swap` via callback | `v4SwapData` must be exactly **160 bytes** encoding `(tokenIn, tokenOut, fee, tickSpacing, hook)`. `hook` must be `address(0)` **or** in `allowedV4Hooks`. Sqrt-price limits set one tick inside allowed range — slippage is enforced by `minAmountOut`. When used as leg2, `useFullBalance=true` sets amountIn to the tracked leftover of `leg2.srcToken` produced by leg1. |

### Composition Patterns

A `SwapPlan` runs in one of four mutually-exclusive shapes (`hasLeg2`, `hasSplit`, `hasMixedSplit` are mutually exclusive — `PlanShapeConflict` if more than one is set; all-false = single-leg):

| Pattern | Flag | leg1 role | leg2 role | Allowed leg modes |
|---|---|---|---|---|
| **Single-leg** | all flags false | Swap collateral → loanToken (or `NO_SWAP` when collateral == loanToken) | ignored | Any (Paraswap / Bebop / Uni V2/V3/V4 / NO_SWAP) |
| **Sequential two-leg** | `hasLeg2 == true` | Swap collateral → intermediate | Swap intermediate → loanToken via on-chain tracked leftover (`leg2.useFullBalance==true`) | leg1: any (NO_SWAP rejected with `PlanShapeConflict`); leg2: Uni V2/V3/V4 only |
| **Parallel split** | `hasSplit == true` | Swap `(1 − splitBps/10000) × collateralDelta` → loanToken (repay leg) | Swap `splitBps/10000 × collateralDelta` → WETH (profit leg for coinbase) | Both legs: Uni V2/V3/V4 only |
| **Mixed split** | `hasMixedSplit == true` | Any-mode repay leg with `(1 − splitBps/10000) × collateralDelta` → loanToken (Paraswap / Bebop allowed for deep repay routing) | Uni-only profit leg with `splitBps/10000 × collateralDelta` → WETH for coinbase | leg1: any incl. **NO_SWAP when `col == loanToken`** (V8+, same-asset bribe path); leg2: Uni V2/V3/V4 only |

## Plan Format

```solidity
enum SwapMode {
    PARASWAP_SINGLE,
    BEBOP_MULTI,
    UNI_V2,
    UNI_V3,
    UNI_V4,
    NO_SWAP            // Same-token liquidation: srcToken == repayToken, no DEX call.
                       // Allowed for single-leg plans, and (V8+) for hasMixedSplit when
                       // col == loanToken (same-asset bribe path: leg2 swaps the residual
                       // loanToken to WETH for coinbase). Combining with hasLeg2 still
                       // reverts with PlanShapeConflict.
}

struct SwapLeg {
    SwapMode mode;
    address srcToken;
    uint256 amountIn;           // Used when useFullBalance == false
    bool    useFullBalance;     // leg1: amountIn = collateralDelta produced this call.
                                // leg2: MUST be true (enforced on-chain) — amountIn =
                                //       balanceOf(srcToken)_after_leg1 -
                                //       balanceOf(srcToken)_before_leg1
                                //       (tracked leftover — pre-existing dust is NOT consumed).
                                // Paraswap / Bebop: MUST be false.
    uint256 deadline;
    bytes   paraswapCalldata;   // PARASWAP_SINGLE only (leg1 only)
    address bebopTarget;        // BEBOP_MULTI only (leg1 only)
    bytes   bebopCalldata;      // BEBOP_MULTI only (leg1 only)
    address[] v2Path;           // UNI_V2: path[0]==srcToken, path[last]==repayToken, len >= 2
    uint24  v3Fee;              // UNI_V3: {100, 500, 3000, 10000}
    address v4PoolManager;      // UNI_V4 only (must be allow-listed)
    bytes   v4SwapData;         // UNI_V4 only, strict 160 bytes:
                                //   abi.encode(tokenIn, tokenOut, fee, tickSpacing, hook)
    address repayToken;         // leg1 one-leg plan: == outer loanToken.
                                // leg1 two-leg plan: == leg2.srcToken (intermediate).
                                // leg2 always:       == outer loanToken.
    uint256 minAmountOut;       // Per-leg output floor (must be > 0 for UNI_V2/V3/V4 and BEBOP_MULTI)
}

struct SwapPlan {
    SwapLeg leg1;               // Sequential:  the one-leg / first-leg swap.
                                // Split:       the REPAY leg (collateral → loanToken).
                                // MixedSplit:  the REPAY leg (any mode, deep routing).
    bool    hasLeg2;            // If false AND hasSplit==false AND hasMixedSplit==false,
                                // leg2 is ignored.
    SwapLeg leg2;               // Sequential (hasLeg2==true):       must be UNI_V2/V3/V4.
                                // Split     (hasSplit==true):       the PROFIT leg
                                //                                   (collateral → WETH).
                                // MixedSplit(hasMixedSplit==true):  the PROFIT leg
                                //                                   (collateral → WETH,
                                //                                   Uni-only).
    bool    hasSplit;           // Parallel split (both legs Uni; mutually exclusive
                                // with hasLeg2 and hasMixedSplit).
    uint16  splitBps;           // Split / MixedSplit only: share of collateralDelta
                                // routed into the profit leg (0 < splitBps < 10000).
                                // The repay leg receives (10000 - splitBps) / 10000.
    bool    hasMixedSplit;      // Mixed split (any-mode repay leg + Uni-only profit
                                // leg; mutually exclusive with hasLeg2 and hasSplit).
    address profitToken;        // Token to measure profit in. For split / mixedSplit
                                // mode MUST be WETH.
    uint256 minProfitAmount;    // Effective profit floor (after coinbase)
}

struct Action {
    uint8 protocolId;  // 1=Aave V3, 2=Morpho Blue, 3=Aave V2, 100=Internal
    bytes data;        // ABI-encoded action struct
}

struct Plan {
    uint8    flashProviderId;  // 2=Balancer, 3=Morpho
    address  loanToken;        // Token to borrow (debt asset)
    uint256  loanAmount;       // Amount to borrow
    uint256  maxFlashFee;      // Max acceptable flash fee
    Action[] actions;          // Ordered actions (1-10, at least 1 liquidation)
    SwapPlan swapPlan;         // Post-liquidation swap configuration (single-leg, sequential two-leg, or parallel split)
}
```

### Two-leg execution model

A `SwapPlan` can be either a single-leg plan (`hasLeg2 == false`) or a two-leg
plan (`hasLeg2 == true`). Two-leg plans chain a first swap (any `SwapMode`)
into a second swap (restricted to `UNI_V2 / UNI_V3 / UNI_V4`).

Invariants enforced on-chain in `execute()` BEFORE the flashloan is requested:

- `leg1.srcToken == collateralAsset` (the debt liquidation's collateral).
- If `hasLeg2`:
  - `leg2.mode ∈ {UNI_V2, UNI_V3, UNI_V4}` — Paraswap and Bebop are disallowed as leg2
    (`Leg2ModeNotAllowed`). Both carry their input amount inside calldata, which
    would decouple from the tracked-leftover semantic.
  - `leg1.repayToken == leg2.srcToken` (`InvalidLegLink`) — the intermediate token
    is pinned by the plan, not inferred from trace.
  - `leg2.useFullBalance == true` (`InvalidPlan`) — leg2's `amountIn` MUST come from
    the on-chain tracked leftover; off-chain-supplied `leg2.amountIn` is rejected.
  - `leg2.repayToken == outer loanToken` — the final leg always delivers into the
    flashloan repay token.
- `finalRepayToken == outer loanToken` — where `finalRepayToken` is `leg2.repayToken`
  when `hasLeg2`, else `leg1.repayToken`.

Leg2 `amountIn` is always computed on-chain as:

    leg2AmountIn = balanceOf(leg2.srcToken)_after_leg1 - balanceOf(leg2.srcToken)_before_leg1

The pre-leg1 snapshot of `leg1.repayToken` balance doubles as this baseline (valid
because `leg1.repayToken == leg2.srcToken`). Consequence: any pre-existing balance
of the intermediate token is NOT consumed — only the leg1-produced delta feeds leg2.
A zero tracked leftover reverts with `Leg2ZeroLeftover`.

Final flashrepay gate is delta-based against `finalRepayToken`, unchanged from the
one-leg contract:

    balanceOf(finalRepayToken)_after_all_legs - balanceOf(finalRepayToken)_before_leg1 >= flashRepayAmount

### Split execution model

When `hasSplit == true`, a single `execute()` routes `collateralDelta` in parallel
into two independent on-chain swaps: one leg delivers into the loanToken for flash
repay, the other delivers into WETH so a coinbase BPS action can unwrap + bid on
the same transaction. This is mutually exclusive with `hasLeg2` (sequential chain)
and reuses the `leg1` / `leg2` slots as repay / profit legs respectively.

Invariants enforced on-chain in `execute()` BEFORE the flashloan is requested:

- `hasSplit && !hasLeg2` — the two composition modes cannot combine.
- `splitBps ∈ (0, 10000)` — `splitBps == 0` or `splitBps >= 10000` rejects
  with `InvalidPlan`; the repay leg gets `(10000 − splitBps)/10000` of the delta.
- `leg1.mode ∈ {UNI_V2, UNI_V3, UNI_V4}` and `leg2.mode ∈ {UNI_V2, UNI_V3, UNI_V4}`
  — Paraswap / Bebop are disallowed in split mode (their `amountIn` is baked into
  calldata; only Uni legs accept a runtime-computed `amountIn`).
- `leg1.srcToken == leg2.srcToken == collateralAsset` — both legs source from
  the liquidation output.
- `leg1.repayToken == outer loanToken` and `leg2.repayToken == WETH` —
  repay routes into the flashloan-repay token; profit routes into WETH for
  coinbase payment.
- Neither leg may set `useFullBalance` — amounts come from the split split, not
  from a "consume everything" read.

Runtime split arithmetic (inside `_executeSwapPlan`):

    profitAmount = (collateralDelta × splitBps) / 10000
    repayAmount  = collateralDelta − profitAmount
    assert(profitAmount > 0 && repayAmount > 0)   // else revert InvalidPlan

    dispatch leg1 (repay leg) with amountIn = repayAmount
    dispatch leg2 (profit leg) with amountIn = profitAmount

The outer `repayDelta >= flashRepayAmount` gate is unchanged — it measures the
loanToken balance delta across the whole `_executeSwapPlan` invocation, which
in split mode comes entirely from the repay leg. The coinbase BPS flow is
untouched: `profitToken == WETH`, realized profit is the WETH balance delta,
and `ACTION_PAY_COINBASE(bps)` unwraps `bps/10000 × realizedProfit` for the
builder.

### Action Data Encoding

**Aave V3 Liquidation** (`protocolId = 1`, `actionType = 4`):
```solidity
struct AaveV3Action {
    uint8 actionType;        // Must be 4 (liquidation only)
    address asset;           // unused for liquidation
    uint256 amount;          // unused for liquidation
    uint256 interestRateMode;// unused for liquidation
    address onBehalfOf;      // unused for liquidation
    address collateralAsset; // Token received
    address debtAsset;       // Token paid (must equal plan.loanToken)
    address user;            // User being liquidated
    uint256 debtToCover;     // Amount of debt to repay (> 0)
    bool    receiveAToken;   // true = receive aToken (V3 only, verified on-chain)
    address aTokenAddress;   // Required when receiveAToken=true
}
```

**Aave V2 Liquidation** (`protocolId = 3`):
```solidity
struct AaveV2Liquidation {
    address collateralAsset;
    address debtAsset;       // Must equal plan.loanToken
    address user;
    uint256 debtToCover;     // > 0
    bool    receiveAToken;   // Must be false (V2 receiveAToken blocked)
}
```

**Morpho Blue Liquidation** (`protocolId = 2`):
```solidity
struct MorphoLiquidation {
    MarketParams marketParams; // loanToken, collateralToken, oracle, irm, lltv
    address borrower;          // User being liquidated
    uint256 seizedAssets;      // Collateral to seize (> 0, share mode unsupported)
    uint256 repaidShares;      // Debt shares (passed to Morpho, not validated)
    uint256 maxRepayAssets;    // Max loan-token approval (> 0, loan-token units)
}
```

**Coinbase Payment** (`protocolId = 100`, `actionType = 1`):
```solidity
// data = abi.encode(uint8(1), uint256 coinbaseBps)   where 0 <= coinbaseBps <= 10_000
//
// coinbaseBps is a PERCENTAGE of realized on-chain profit (snapshot taken between
// swap completion and coinbase payment). The contract sizes the actual bid itself:
//
//   coinbasePaid = realizedProfit * coinbaseBps / 10_000
//
// Requires profitToken == WETH. Auto-unwraps WETH if insufficient ETH.
// No-op when realizedProfit == 0 or coinbaseBps == 0.
```

> **Migration note**: older deployments of this contract accepted an absolute ETH amount here.
> The bps-based encoding fixes the attack where a validator-proposer could reorder the pending
> oracle update and the liquidation call such that the operator's fixed bid exceeded realized
> profit — the on-chain bps sizing makes the coinbase bid impossible to over-pay.

## Security Model

- **No upgradeability** — immutable logic, no proxies.
- **Liquidation-only execution** — non-liquidation Aave actions rejected (`UnsupportedActionType`).
- **Morpho share-based liquidation explicitly blocked** — `MorphoShareModeUnsupported`.
- **V2 `receiveAToken` explicitly blocked** — `ReceiveATokenV2Unsupported`.
- **Execution phase guard** — callbacks only accepted during `FlashLoanActive` phase.
- **Single debt/collateral asset** — mixed asset flows rejected at validation.
- **External calls restricted to allowlist** — `allowedTargets` enforced on all protocol interactions.
- **V4 hook allowlist** — only hooks registered via `setV4HookAllowed` (plus `address(0)`) may appear in a V4 `PoolKey`.
- **No infinite approvals** — exact `forceApprove` before each interaction, reset to 0 after.
- **Fail-closed** — all custom errors, all unknown states revert.
- **Collateral delta check** — balance must increase after liquidation (not absolute check).
- **aToken canonical verification** — V3 aToken address verified on-chain via `getReserveData`.
- **Delta-only aToken unwrap** — only liquidation-produced aTokens are redeemed.
- **Delta-based repay sufficiency** — the swap's repayToken **delta** (not absolute balance) must cover `flashRepayAmount`, preventing a pre-funded balance from masking a bad swap.
- **Coinbase payment capped** — `coinbaseBps <= 10_000` and `coinbasePaid <= realizedProfit` both enforced; `CoinbaseExceedsProfit` reverts if a multi-action sum would over-pay.
- **Profit gate** — `minProfitAmount` enforced on **effective** profit (`realized − coinbasePaid`).
- **Strict callback validation** — phase + `msg.sender` + `initiator` + plan hash + asset + amount.
- **Access control** — `Ownable2Step` for config, `onlyOperator` for execution (immutable).
- **Pausable** — owner can pause/unpause all execution.
- **ReentrancyGuard** — prevents reentrant calls to `execute`.
- **V4 PoolManager callback isolation** — `_activeV4PoolManager` pins exactly which PoolManager may invoke `unlockCallback`; stray callbacks from other allow-listed managers revert.
- **V4 unlock-callback `tokenIn` pin** (V7) — `_activeV4TokenIn` is set at unlock time and read back inside `unlockCallback` instead of trusting decoded calldata. A malicious / mis-allowlisted hook re-entering and substituting `tokenIn` mid-callback is structurally impossible. The slot is cleared on entry, doubling as a re-entry guard.
- **NO_SWAP plan-shape guards** (V7) — `NO_SWAP + hasLeg2` reverts pre-flashloan with `PlanShapeConflict`. Closes a validator/executor mismatch where the two-leg branch silently dropped `leg1` if its mode was `NO_SWAP`.
- **Same-asset NO_SWAP + hasMixedSplit** (V8) — allowed only when `leg1.srcToken == leg1.repayToken == loanToken` (i.e. `col == loanToken`). Diff-asset misconfigurations revert `InvalidPlan` at validation time; runtime path sweeps `leg1RepayBefore − flashRepayAmount` of the residual loanToken through the Uni-only leg2 → WETH for the coinbase bribe.

### Custom Errors (selected — full list in `src/LiquidationExecutor.sol`)

| Error | Cause |
|---|---|
| `NoActions()` | Empty actions array |
| `TooManyActions(count)` | More than 10 actions |
| `NoLiquidationAction()` | No liquidation action (all internal) |
| `UnsupportedActionType(type)` | Non-liquidation Aave V3 action |
| `InvalidProtocolId(id)` | Unknown protocol ID |
| `MorphoShareModeUnsupported()` | seizedAssets=0 in Morpho liquidation |
| `MorphoMixedModeUnsupported()` | Morpho actions disagree on share vs asset mode |
| `MorphoInvalidMarketParams()` | Zero loanToken or collateralToken |
| `ReceiveATokenV2Unsupported()` | V2 receiveAToken=true attempted |
| `ATokenAddressRequired()` | receiveAToken=true without aToken address |
| `InvalidATokenAddress(provided, canonical)` | aToken doesn't match on-chain |
| `MixedReceiveAToken()` | Actions disagree on receiveAToken |
| `DebtAssetMismatch(expected, actual)` | Action debt != loanToken |
| `CollateralAssetMismatch(expected, actual)` | Actions use different collateral |
| `ZeroActionAmount()` | Action with zero amount |
| `RepayTokenMismatch(expected, actual)` | repayToken != loanToken |
| `SrcTokenNotCollateral(expected, actual)` | Swap source != collateral |
| `NoCollateralReceived()` | Collateral balance didn't increase |
| `UnwrapFailed()` | aToken unwrap produced no underlying |
| `InvalidFlashLoan()` | Flash loan balance below expected |
| `FlashProviderNotAllowed()` | Plan references an unregistered flash provider |
| `FlashFeeExceeded(actual, max)` | Flash provider fee above `maxFlashFee` |
| `InsufficientRepayOutput(actual, required)` | Swap `repayDelta` didn't cover flashRepay |
| `InsufficientRepayBalance(required, available)` | Absolute balance too low to push repay |
| `InsufficientProfit(actual, required)` | Effective profit below minimum |
| `SwapDeadlineExpired(deadline, current)` | Plan deadline passed |
| `InvalidSwapMode()` | Unknown `SwapMode` enum value |
| `InvalidExecutionPhase()` | Callback outside flash loan phase |
| `ParaswapSrcTokenMismatch(expected, actual)` | Paraswap decoded src token != `plan.srcToken` |
| `ParaswapAmountInMismatch(expected, actual)` | ExactIn: consumed != declared; ExactOut: consumed > declared |
| `ParaswapDstTokenUnexpected(dstToken)` | Paraswap decoded dst token != `plan.repayToken` |
| `ParaswapSwapFailed()` | Paraswap Augustus call reverted |
| `InvalidParaswapSelector(selector)` | Selector not in Augustus V6.2 family classifier |
| `SwapRecipientInvalid(recipient)` | Paraswap recipient patched to non-executor address |
| `ZeroAmountIn()` / `ZeroSwapInput()` / `ZeroSwapOutput()` / `ZeroRepayOutput()` | Swap path produced or requested zero |
| `InvalidV2Path()` | V2 path shorter than 2 or endpoints don't match `srcToken`/`repayToken` |
| `InvalidV3Fee(fee)` | V3 fee tier not in `{100, 500, 3000, 10000}` |
| `InvalidV4Data()` / `InvalidV4Fee()` / `InvalidV4FeeOrSpacing()` / `InvalidV4TokenOut(exp, act)` / `InvalidV4NativeToken()` | V4 `v4SwapData` decode / validation failures |
| `V4HookNotAllowed(hook)` | V4 `PoolKey.hook` is not `address(0)` and not in `allowedV4Hooks` |
| `V4UnexpectedDelta()` | V4 PoolManager settle/take delta inconsistent |
| `InvalidV4CallbackHook()` | V4 unlockCallback invoked by a PoolManager other than the one that initiated unlock |
| `CoinbasePaymentRequiresWethProfit()` | Coinbase payment but `profitToken != WETH` |
| `CoinbaseExceedsProfit(coinbase, profit)` | Sum of coinbase payments > realized profit |
| `InvalidCoinbaseBps()` | `coinbaseBps > 10_000` |
| `CoinbasePaymentFailed()` | ETH transfer to coinbase failed |
| `InvalidCoinbase()` | `block.coinbase == address(0)` at payment time |
| `TargetNotAllowed(target)` | External call target not in `allowedTargets` |
| `InsufficientSrcBalance(required, available)` | Swap source balance < `amountIn` |
| `InsufficientEth(required, available)` | Coinbase payment needs more ETH than held / unwrappable |
| `BalancerSingleTokenOnly()` | Balancer flashloan with > 1 asset |
| `Leg2ModeNotAllowed(mode)` | leg2 uses a mode outside `{UNI_V2, UNI_V3, UNI_V4}` in the two-leg path (`hasLeg2`). The `hasSplit` / `hasMixedSplit` branches collapsed this to `InvalidPlan()` in V8 to fit the EIP-170 limit. |
| `InvalidLegLink(leg1Out, leg2In)` | `leg1.repayToken != leg2.srcToken` (two-leg intermediate token mismatch) |
| `Leg2ZeroLeftover()` | Two-leg plan: `leg2.srcToken` balance delta across leg1 is zero (defensive; normally unreachable because leg1's own `minAmountOut >= 1` forces a non-zero delta) |
| `LegUseFullBalanceNotAllowed(mode)` | Paraswap / Bebop leg set `useFullBalance=true` (both modes carry their own `amountIn` in calldata) |
| `PlanShapeConflict()` | More than one of `{hasLeg2, hasSplit, hasMixedSplit}` is set, OR `NO_SWAP` leg1 combined with `hasLeg2` (V7+ guard). V8 lifted the `NO_SWAP + hasMixedSplit` rejection for the same-asset path. |
| `InvalidPlan()` | Generic plan-shape rejection — includes `hasLeg2 && !leg2.useFullBalance`, `leg.srcToken == leg.repayToken` for non-NO_SWAP modes, `minAmountOut == 0` on UNI_V2/V3/V4 and BEBOP_MULTI legs, Morpho `maxRepayAssets == 0`, and (V8) the consolidated MIXED_SPLIT validation rejections that previously used `RepayTokenMismatch`, `SrcTokenNotCollateral`, and `Leg2ModeNotAllowed`. |

## Configuration

### Constructor Parameters

| Parameter | Description |
|---|---|
| `owner_` | Initial contract owner (Ownable2Step) |
| `operator_` | Bot address authorized to call `execute` (**immutable**) |
| `weth_` | WETH token address (**immutable**) |
| `aavePool_` | Aave V3 Pool address (auto-whitelisted; liquidation target only — no V3 flashloan path) |
| `balancerVault_` | Balancer Vault address (auto-whitelisted, auto-registered as `FLASH_PROVIDER_BALANCER`) |
| `paraswapAugustus_` | ParaSwap AugustusV6 router (auto-whitelisted) |
| `uniV2Router_` | Uniswap V2 Router02 (**immutable**, auto-whitelisted) |
| `uniV3Router_` | Uniswap V3 SwapRouter02 (**immutable**, auto-whitelisted) |
| `allowedTargets_` | Additional whitelisted targets (Bebop Settlement, Morpho Blue, Aave V2 Pool, Uniswap V4 PoolManager, etc.) |

### Post-Deploy Owner Functions

| Function | Description |
|---|---|
| `setAaveV2LendingPool(address)` | Configure Aave V2 Pool (must be in `allowedTargets`) |
| `setAllowedTarget(address, bool)` | Allow-list or revoke a call target (Bebop settlement, Curve pool, Balancer Vault entry, etc.) |
| `setV4HookAllowed(address, bool)` | Allow-list or revoke a Uniswap V4 hook contract |
| `pause()` / `unpause()` | Emergency pause toggle |
| `rescueERC20(token, to, amount)` | Recover stuck tokens |
| `rescueAllERC20(token, to)` | Recover full token balance |
| `rescueERC20Batch(tokens[], to)` | Recover multiple token balances |
| `rescueETH(to, amount)` | Recover stuck ETH |

> **Note**: V10 dropped `setMorphoBlue`, `configureMorpho`, and `setFlashProvider`.
> Morpho Blue and the Balancer Vault are now constructor parameters and live in
> immutable storage. Any address that may appear as a `UNI_V4` `v4PoolManager`,
> as a target for `setAaveV2LendingPool`, or as a swap target must either be
> included in the constructor's `allowedTargets_` array or added later via
> `setAllowedTarget(addr, true)`.

## Project Structure

```
src/
  LiquidationExecutor.sol              Main contract (~1701 lines)
  interfaces/
    IAaveV3Pool.sol                    Aave V3 Pool + getReserveData
    IBalancerVault.sol                 Balancer Vault + IFlashLoanRecipient
    IMorphoBlue.sol                    Morpho Blue (liquidate, repay, supply, withdraw, flashloan)
    IAaveV2LendingPool.sol             Aave V2 (liquidationCall, withdraw)
    IUniV2Router.sol                   Uniswap V2 Router02
    IUniV3Router.sol                   Uniswap V3 SwapRouter02 + QuoterV2
    IUniV4PoolManager.sol              Uniswap V4 PoolManager + PoolKey
  libraries/
    ParaswapDecoderLib.sol             Augustus V6.2 selector classifier + per-family decoders (~271 lines)
    SwapLegExecutorLib.sol             Paraswap / UniV2 / UniV3 leg executors (DELEGATECALL, ~182 lines)

test/
  Executor.t.sol                       258 unit tests
  fork/
    ExecutorForkV4.t.sol                 8 mainnet-fork tests against real V4 PoolManager
  mocks/
    MockERC20, MockAavePool, MockBalancerVault, MockParaswapAugustus,
    MockAaveV2LendingPool, MockMorphoBlue, MockBebopSettlement,
    MockUniV2Router, MockUniV3Router, MockV4PoolManager, MockSwapRouter,
    MaliciousV4PoolManager (V7 callback-substitution attack mock)
```

## Build & Test

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)

### Commands

```bash
forge install          # Install dependencies
forge build            # Compile
forge test             # Run 764 tests (756 unit + 8 fork)
forge test -vvv        # Verbose output
forge coverage         # Coverage report
```

## Deployment

### 1. Environment Setup

Create a `.env` file (do NOT commit):

```bash
PRIVATE_KEY=0x...
ETHEREUM_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=...
```

### 2. Deploy (single `forge script` run)

`script/Deploy.s.sol` is the canonical entry-point: it deploys
`LiquidationExecutor` against the canonical mainnet protocol addresses and lets
forge auto-deploy + link the seven external libraries (`UniswapLib`,
`BalancerV2Lib`, `CurveV1Lib`, `SwapLegExecutorLib`, `SwapValidationLib`,
`CoinbasePaymentLib`, plus the internal `ParaswapDecoderLib` dependency of
`SwapLegExecutorLib`). Each subsequent run on the same chain reuses libraries
whose source has not changed — forge tracks per-chain library addresses in
`broadcast/Deploy.s.sol/<chain>/run-latest.json` under the `libraries` field
and matches them by bytecode hash.

```bash
PRIVATE_KEY=$PRIVATE_KEY forge script script/Deploy.s.sol:Deploy \
  --rpc-url $ETHEREUM_RPC_URL \
  --broadcast \
  --legacy
```

The script's `run()` returns the deployed executor address and logs every
library + executor address; both also land in
`broadcast/Deploy.s.sol/1/run-latest.json` for downstream tooling.

`ArbExecutor` is intentionally NOT deployed by this script — it ships in a
separate run when bot-side arb integration is ready.

### 3. Post-Deploy Configuration

V10 wires Morpho and the Balancer Vault in the constructor, so neither
`configureMorpho` nor `setFlashProvider` exists anymore. The only routine
post-deploy step is wiring Aave V2 when V2 liquidations are added; everything
else is constructor-supplied.

```bash
EXECUTOR=<DEPLOYED_ADDRESS>

# Configure Aave V2 LendingPool (must already be in `allowedTargets`)
cast send $EXECUTOR "setAaveV2LendingPool(address)" 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9 \
  --rpc-url $ETHEREUM_RPC_URL --private-key $PRIVATE_KEY

# Allow-list any Uniswap V4 hooks you plan to use (optional — default disallows all)
# cast send $EXECUTOR "setV4HookAllowed(address,bool)" <HOOK> true \
#   --rpc-url $ETHEREUM_RPC_URL --private-key $PRIVATE_KEY

# Add a swap / liquidation target after deploy (e.g. a new Curve pool)
# cast send $EXECUTOR "setAllowedTarget(address,bool)" <TARGET> true \
#   --rpc-url $ETHEREUM_RPC_URL --private-key $PRIVATE_KEY
```

### 4. Verify Deployment

```bash
cast call $EXECUTOR "owner()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "operator()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "weth()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "uniV2Router()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "uniV3Router()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "morphoBlue()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 2 --rpc-url $ETHEREUM_RPC_URL # Balancer
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 3 --rpc-url $ETHEREUM_RPC_URL # Morpho
cast call $EXECUTOR "paused()(bool)" --rpc-url $ETHEREUM_RPC_URL
```

### 5. Protocol Addresses (Ethereum Mainnet)

| Protocol | Address |
|---|---|
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Aave V2 LendingPool | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| ParaSwap AugustusV6 | `0x6A000F20005980200259B80c5102003040001068` |
| Uniswap V2 Router02 | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| Uniswap V3 SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Bebop Settlement | `0xbbbbbBB520d69a9775E85b458C58c648259FAD5F` |

## Compiler Settings

| Setting | Value |
|---|---|
| Solidity | 0.8.24 |
| EVM Target | Shanghai |
| Optimizer | Enabled, **1 run** (biased toward smaller runtime bytecode to stay under EIP-170) |
| `via_ir` | true |
| `bytecode_hash` | `none` (cbor metadata stripped — ~53 bytes saved) |

## License

MIT
