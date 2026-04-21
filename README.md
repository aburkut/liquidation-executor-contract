# LiquidationExecutor

## Deployment (Ethereum Mainnet)

| Parameter | Value |
|---|---|
| **Contract (V4)** | `0xB5C7881500F0A7A56E985266Da6AD9d19a5CCBB4` |
| **Deploy tx** | `0x95383aabc6cf9b092ac9809facd9c1eb966be3c824e0f5f6ca583fd4374c7976` |
| **ParaswapDecoderLib** | `0x01E0B8e5B4A2A055F6a18B6442d7ecC7BC519a16` (linked via `--libraries`) |
| **Library deploy tx** | `0x1446d0fc56087032a8872d3bf09083cf341bfb91cc3924e3baa0cb6cfca17dac` |
| **Runtime bytecode size** | 24 521 bytes (55 bytes margin under EIP-170) |
| **Owner** | `0xC338094Bb79AA610E9c57166fc4FA959db6234Ab` (Safe multisig) |
| **Operator** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` (immutable) |
| **WETH** | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (immutable) |
| **Deployer** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` |
| **Aave V3 Pool** | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` (liquidation target; V3 flashloan path removed) |
| **Balancer Vault** | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` (auto-registered as flash provider id=2) |
| **ParaSwap AugustusV6** | `0x6A000F20005980200259B80c5102003040001068` |
| **Uniswap V2 Router02** | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` (immutable) |
| **Uniswap V3 SwapRouter02** | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` (immutable) |
| **Uniswap V4 PoolManager** | `0x000000000004444c5dc75cB358380D2e3dE08A90` (in `allowedTargets`, used per-swap) |
| **Morpho Blue** | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` (liquidation target + flashloan id=3 — needs `configureMorpho`) |
| **Bebop Settlement** | `0xbbbbbBB520d69a9775E85b458C58c648259FAD5F` (allowlisted) |
| **Aave V2 LendingPool** | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` (allowlisted — needs `setAaveV2LendingPool`) |
| **Solidity** | 0.8.24, Shanghai, optimizer 1 run, `via_ir=true`, `bytecode_hash=none` |

| Previous deployments | |
|---|---|
| **V3 Contract** | `0xbdBcDAa6C667582298ca70dE2CD6647d6ab105e5` (deprecated — legacy SwapMode layout with `PARASWAP_DOUBLE`; 0x11 overflow on whale BUY-side; bot migrated off on 2026-04-21) |
| **V3 deploy tx** | `0x132b93b032ced2f1f2874c8836b90ba45fa81ba0f947f75e222f67d192a69468` |
| **V2 Contract** | `0x38F4473C077c014786037cC3d82fce52510b9089` (deprecated — no Bebop, had ERC20 payment) |
| **V1 Contract** | `0x1aaED107C21B389a38a632129dC0Cb362819bC8D` (deprecated) |

---

Production-grade **Flashloan → Multi-Liquidation → Multi-Swap → Repay** execution contract for
DeFi liquidation bots.

Supports **five swap modes** (Paraswap single, Bebop multi-output, Uniswap V2 / V3 / V4),
**three liquidation protocols** (Aave V3, Aave V2, Morpho Blue), **two flashloan sources**
(Balancer Vault, Morpho Blue), and **basis-points coinbase builder payments** sized from
on-chain-measured realized profit.

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
|    +-- Swap (5 modes)                    |
|    |   +-- PARASWAP_SINGLE               |
|    |   +-- BEBOP_MULTI                   |
|    |   +-- UNI_V2                        |
|    |   +-- UNI_V3                        |
|    |   +-- UNI_V4 (hook-allow-listed)    |
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
| `BEBOP_MULTI` | Opaque Bebop settlement call, multi-output (leg1 only — not allowed as leg2) | Output validated via balance delta; both `repayDelta > 0` and `repayAfter >= repayBefore + flashRepay` asserted. Allow-listed target only; exact approval + reset pattern. |
| `UNI_V2` | Uniswap V2 Router02 `swapExactTokensForTokens`, multi-hop path | Path endpoints pinned: `v2Path[0] == srcToken`, `v2Path[last] == repayToken`, `length >= 2`. Optional `useFullBalance=true` to swap the exact collateral delta produced this call when used as leg1; when used as leg2 the amountIn is the tracked leftover of `leg2.srcToken` produced by leg1. |
| `UNI_V3` | Uniswap V3 SwapRouter02 `exactInputSingle` | Fee tier restricted to `{100, 500, 3000, 10000}`. SwapRouter02 has no deadline — the executor enforces `plan.deadline` itself. When used as leg2, `useFullBalance=true` sets amountIn to the tracked leftover of `leg2.srcToken` produced by leg1. |
| `UNI_V4` | Uniswap V4 PoolManager `unlock` → `swap` via callback | `v4SwapData` must be exactly **160 bytes** encoding `(tokenIn, tokenOut, fee, tickSpacing, hook)`. `hook` must be `address(0)` **or** in `allowedV4Hooks`. Sqrt-price limits set one tick inside allowed range — slippage is enforced by `minAmountOut`. When used as leg2, `useFullBalance=true` sets amountIn to the tracked leftover of `leg2.srcToken` produced by leg1. |

## Plan Format

```solidity
enum SwapMode {
    PARASWAP_SINGLE,
    BEBOP_MULTI,
    UNI_V2,
    UNI_V3,
    UNI_V4
}

struct SwapLeg {
    SwapMode mode;
    address srcToken;
    uint256 amountIn;           // Used when useFullBalance == false
    bool    useFullBalance;     // leg1: amountIn = collateralDelta produced this call.
                                // leg2: amountIn = balanceOf(srcToken)_after_leg1 -
                                //                  balanceOf(srcToken)_before_leg1
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
    uint256 minAmountOut;       // Per-leg output floor (must be > 0 for UNI_V2/V3/V4)
}

struct SwapPlan {
    SwapLeg leg1;
    bool    hasLeg2;            // If false, leg2 is ignored and _zeroLeg() semantics apply.
    SwapLeg leg2;               // Must be UNI_V2 / UNI_V3 / UNI_V4 when hasLeg2 == true.
    address profitToken;        // Token to measure profit in
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
    SwapPlan swapPlan;         // Post-liquidation swap configuration (one- or two-leg)
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
  - `leg2.repayToken == outer loanToken` — the final leg always delivers into the
    flashloan repay token.
- `finalRepayToken == outer loanToken` — where `finalRepayToken` is `leg2.repayToken`
  when `hasLeg2`, else `leg1.repayToken`.

Leg2 `useFullBalance == true` computes `amountIn` as:

    leg2AmountIn = balanceOf(leg2.srcToken)_after_leg1 - balanceOf(leg2.srcToken)_before_leg1

The pre-leg1 snapshot of `leg1.repayToken` balance doubles as this baseline (valid
because `leg1.repayToken == leg2.srcToken`). Consequence: any pre-existing balance
of the intermediate token is NOT consumed — only the leg1-produced delta feeds leg2.
A zero tracked leftover reverts with `Leg2ZeroLeftover`.

Final flashrepay gate is delta-based against `finalRepayToken`, unchanged from the
one-leg contract:

    balanceOf(finalRepayToken)_after_all_legs - balanceOf(finalRepayToken)_before_leg1 >= flashRepayAmount

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
| `configureMorpho(address)` | Atomic helper — sets `morphoBlue` **and** `allowedFlashProviders[FLASH_PROVIDER_MORPHO]` in one call (must be in `allowedTargets`). |
| `setMorphoBlue(address)` | Legacy: configure Morpho Blue liquidation target only (must be in `allowedTargets`) |
| `setAaveV2LendingPool(address)` | Configure Aave V2 Pool (must be in `allowedTargets`) |
| `setFlashProvider(uint8, address)` | Register flash provider by ID (must be in `allowedTargets`) |
| `setV4HookAllowed(address, bool)` | Allow-list or revoke a Uniswap V4 hook contract |
| `pause()` / `unpause()` | Emergency pause toggle |
| `rescueERC20(token, to, amount)` | Recover stuck tokens |
| `rescueAllERC20(token, to)` | Recover full token balance |
| `rescueERC20Batch(tokens[], to)` | Recover multiple token balances |
| `rescueETH(to, amount)` | Recover stuck ETH |

> **Note**: `allowedTargets` is write-once (constructor only). There is no post-deploy setter.
> All addresses that may be used with `setMorphoBlue` / `configureMorpho`,
> `setAaveV2LendingPool`, `setFlashProvider`, or a `UNI_V4` `v4PoolManager` must be included
> in the constructor's `allowedTargets_` array.

## Project Structure

```
src/
  LiquidationExecutor.sol              Main contract (~1533 lines)
  interfaces/
    IAaveV3Pool.sol                    Aave V3 Pool + getReserveData
    IBalancerVault.sol                 Balancer Vault + IFlashLoanRecipient
    IMorphoBlue.sol                    Morpho Blue (liquidate, repay, supply, withdraw, flashloan)
    IAaveV2LendingPool.sol             Aave V2 (liquidationCall, withdraw)
    IUniV2Router.sol                   Uniswap V2 Router02
    IUniV3Router.sol                   Uniswap V3 SwapRouter02 + QuoterV2
    IUniV4PoolManager.sol              Uniswap V4 PoolManager + PoolKey
  libraries/
    ParaswapDecoderLib.sol             Augustus V6.2 selector classifier + per-family decoders

test/
  Executor.t.sol                       235 unit tests
  fork/
    ExecutorForkV4.t.sol                 8 mainnet-fork tests against real V4 PoolManager
  mocks/
    MockERC20, MockAavePool, MockBalancerVault, MockParaswapAugustus,
    MockAaveV2LendingPool, MockMorphoBlue, MockBebopSettlement,
    MockUniV2Router, MockUniV3Router, MockV4PoolManager, MockSwapRouter
```

## Build & Test

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)

### Commands

```bash
forge install          # Install dependencies
forge build            # Compile
forge test             # Run 243 tests
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

### 2. Deploy (two steps — external library)

The Paraswap Augustus V6.2 selector classifier and per-family decoders live in
`src/libraries/ParaswapDecoderLib.sol` as an **external library** called via
`DELEGATECALL` from the main contract.  Pulling the decoder out of the main
contract's own bytecode is what keeps the deployed executor comfortably under
the EIP-170 24,576-byte limit — but the price is that the main contract's
compiled bytecode contains an unresolved link placeholder (`__$...$__`) where
the library address needs to be spliced in at deploy time.  `forge create`
refuses to deploy such bytecode without a concrete library address, hence the
two-step flow below.

#### 2.1 — Deploy `ParaswapDecoderLib` first

```bash
forge create src/libraries/ParaswapDecoderLib.sol:ParaswapDecoderLib \
  --rpc-url $ETHEREUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Copy the `Deployed to:` address from the output:

```bash
export LIB_ADDR=<deployed-library-address>
```

The library is stateless and has no owner — once deployed, it can be reused for
every future `LiquidationExecutor` deployment, so this step normally only runs
once per chain.

#### 2.2 — Deploy `LiquidationExecutor` linked to the library

```bash
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $ETHEREUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --libraries "src/libraries/ParaswapDecoderLib.sol:ParaswapDecoderLib:$LIB_ADDR" \
  --constructor-args \
    <OWNER_ADDRESS> \
    <OPERATOR_ADDRESS> \
    0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
    0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
    0xBA12222222228d8Ba445958a75a0704d566BF2C8 \
    0x6A000F20005980200259B80c5102003040001068 \
    0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D \
    0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 \
    "[0xbbbbbBB520d69a9775E85b458C58c648259FAD5F,0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb,0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9,0x000000000004444c5dc75cB358380D2e3dE08A90]"
```

The `--libraries` flag format is `<file>:<name>:<address>` — forge replaces the
placeholder in the linker with `$LIB_ADDR` before broadcast.  To verify both
the library and the main contract on Etherscan in the same run, append
`--verify --etherscan-api-key $ETHERSCAN_API_KEY` to each of the two `forge
create` commands above (Etherscan needs the library address to reproduce the
linked bytecode for the main contract, which is why the library must be
verified first).

Constructor arg order:
1. Owner (Safe multisig)
2. Operator (bot EOA, immutable)
3. WETH
4. Aave V3 Pool (liquidation target only — V3 flashloan path is removed in source)
5. Balancer Vault (auto-registered as flash provider id=2)
6. ParaSwap AugustusV6
7. Uniswap V2 Router02 (immutable)
8. Uniswap V3 SwapRouter02 (immutable)
9. `allowedTargets_` array — include Bebop Settlement, Morpho Blue (both liquidation target and flashloan source share the same address), Aave V2 Pool, Uniswap V4 PoolManager, and any V4 hooks you plan to allow-list later (`setV4HookAllowed`).

### 3. Post-Deploy Configuration

```bash
EXECUTOR=<DEPLOYED_ADDRESS>

# Configure Morpho Blue (atomic — sets both liquidation target and flash provider)
cast send $EXECUTOR "configureMorpho(address)" 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
  --rpc-url $ETHEREUM_RPC_URL --private-key $PRIVATE_KEY

# Configure Aave V2 LendingPool (liquidation target)
cast send $EXECUTOR "setAaveV2LendingPool(address)" 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9 \
  --rpc-url $ETHEREUM_RPC_URL --private-key $PRIVATE_KEY

# Allow-list any Uniswap V4 hooks you plan to use (optional — default disallows all)
# cast send $EXECUTOR "setV4HookAllowed(address,bool)" <HOOK> true \
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
