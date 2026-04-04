# LiquidationExecutor

## Deployment (Ethereum Mainnet)

| Parameter | Value |
|---|---|
| **Contract** | `0xbdBcDAa6C667582298ca70dE2CD6647d6ab105e5` |
| **Deploy tx** | `0x132b93b032ced2f1f2874c8836b90ba45fa81ba0f947f75e222f67d192a69468` |
| **Owner** | `0xC338094Bb79AA610E9c57166fc4FA959db6234Ab` (Safe multisig) |
| **Operator** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` (immutable) |
| **WETH** | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (immutable) |
| **Deployer** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` |
| **Aave V3 Pool** | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| **Balancer Vault** | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| **ParaSwap Augustus** | `0x6A000F20005980200259B80c5102003040001068` |
| **Bebop Settlement** | `0xbbbbbBB520d69a9775E85b458C58c648259FAD5F` (whitelisted) |
| **Aave V2 LendingPool** | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` (whitelisted) |
| **Solidity** | 0.8.24, Shanghai, optimizer 200 runs |

| Previous deployments | |
|---|---|
| **V2 Contract** | `0x38F4473C077c014786037cC3d82fce52510b9089` (deprecated — no Bebop, had ERC20 payment) |
| **V1 Contract** | `0x1aaED107C21B389a38a632129dC0Cb362819bC8D` (deprecated) |

---

Production-grade **Flashloan → Multi-Liquidation → Multi-Swap → Repay** execution contract for DeFi liquidation bots.

Supports three swap modes (Paraswap single, Paraswap double, Bebop multi-output), three liquidation protocols (Aave V3, Aave V2, Morpho Blue), and coinbase builder payments.

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
|    |   +-- Aave V3 (id=1)               |
|    |   +-- Balancer Vault (id=2)         |
|    +-- Execute Actions (loop)            |
|    |   +-- Aave V3 liquidation           |
|    |   +-- Aave V2 liquidation           |
|    |   +-- Morpho Blue liquidation       |
|    +-- Collateral delta check            |
|    +-- aToken unwrap (if receiveAToken)  |
|    +-- Swap (3 modes)                    |
|    |   +-- PARASWAP_SINGLE               |
|    |   +-- BEBOP_MULTI                   |
|    |   +-- PARASWAP_DOUBLE               |
|    +-- Repay sufficiency check           |
|    +-- Internal actions                  |
|    |   +-- Coinbase payment              |
|    +-- Profit check                      |
|    +-- Repay flash loan                  |
+------------------------------------------+
```

### Execution Flow

1. **Operator** calls `execute(bytes planData)` with an ABI-encoded `Plan`
2. Contract validates the plan (deadline, repayToken, action consistency, mode-specific fields)
3. Contract initiates a flash loan from the configured provider (Aave V3 or Balancer)
4. Inside the callback:
   - Phase guard + hash check + caller verification
   - Derive collateral asset and tracking token from validated actions
   - Verify canonical aToken address (if `receiveAToken=true`)
   - Snapshot collateral and profit token balances
   - Execute all liquidation actions
   - Verify collateral delta (balance must increase)
   - Unwrap aTokens to underlying if needed (delta-only, not full balance)
   - Execute swap via selected mode
   - Verify absolute repay balance covers flash loan obligation
   - Execute internal actions (coinbase payment)
   - Verify minimum profit
   - Repay flash loan
5. Remaining profit stays in the contract for the owner to rescue

## Supported Protocols

| Category | Protocol | ID | Status |
|---|---|---|---|
| Flash Provider | Aave V3 | `1` | Supported |
| Flash Provider | Balancer Vault | `2` | Supported |
| Liquidation | Aave V3 | `1` | Supported (actionType=4 only) |
| Liquidation | Aave V2 | `3` | Supported (receiveAToken=false only) |
| Liquidation | Morpho Blue | `2` | Supported (seizedAssets mode only) |
| Swap | ParaSwap AugustusV6 | — | PARASWAP_SINGLE, PARASWAP_DOUBLE |
| Swap | Bebop Settlement | — | BEBOP_MULTI (opaque calldata) |
| Payment | Coinbase (ETH) | — | Requires profitToken == WETH |

### Capability Matrix

| Protocol | receiveAToken=false | receiveAToken=true | Canonical verification |
|---|---|---|---|
| Aave V3 | Supported | Supported | `getReserveData` on-chain |
| Aave V2 | Supported | **Blocked** (`ReceiveATokenV2Unsupported`) | No on-chain verification |
| Morpho Blue | N/A | N/A | N/A |

### Swap Modes

| Mode | Description | profitToken constraint |
|---|---|---|
| `PARASWAP_SINGLE` | Single Paraswap swap, collateral → repayToken | dstToken must equal repayToken |
| `BEBOP_MULTI` | Opaque Bebop settlement call, multi-output | Output validated via balance delta |
| `PARASWAP_DOUBLE (SPLIT)` | Two Paraswap swaps from same collateral, different outputs | One leg → repayToken, other → profitToken |
| `PARASWAP_DOUBLE (CHAINED)` | Two Paraswap swaps, leg 1 output feeds leg 2 | profitToken must equal repayToken |

## Plan Format

```solidity
enum SwapMode { PARASWAP_SINGLE, BEBOP_MULTI, PARASWAP_DOUBLE }
enum DoubleSwapPattern { SPLIT, CHAINED }

struct SwapPlan {
    SwapMode mode;
    address srcToken;          // SINGLE/BEBOP only (ignored by DOUBLE)
    uint256 amountIn;          // SINGLE/BEBOP only
    uint256 deadline;          // Executor-level deadline (all modes)
    bytes paraswapCalldata;    // SINGLE: swap calldata. DOUBLE: swap 1 calldata.
    address bebopTarget;       // BEBOP only
    bytes bebopCalldata;       // BEBOP only
    DoubleSwapPattern doubleSwapPattern; // DOUBLE only
    bytes paraswapCalldata2;   // DOUBLE only (swap 2 calldata)
    address repayToken;        // Must equal loanToken
    address profitToken;       // Token to measure profit in
    uint256 minProfitAmount;   // Minimum profit or revert
}

struct Action {
    uint8 protocolId;          // 1=Aave V3, 2=Morpho Blue, 3=Aave V2, 100=Internal
    bytes data;                // ABI-encoded action struct
}

struct Plan {
    uint8   flashProviderId;   // 1=Aave V3, 2=Balancer
    address loanToken;         // Token to borrow (debt asset)
    uint256 loanAmount;        // Amount to borrow
    uint256 maxFlashFee;       // Max acceptable flash fee
    Action[] actions;          // Ordered actions (1-10, at least 1 liquidation)
    SwapPlan swapPlan;         // Post-liquidation swap configuration
}
```

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
    bool receiveAToken;      // true = receive aToken (V3 only, verified on-chain)
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
    bool receiveAToken;      // Must be false (V2 receiveAToken blocked)
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
// data = abi.encode(uint8(1), uint256 amount)
// Requires profitToken == WETH. Auto-unwraps WETH if insufficient ETH.
```

## Security Model

- **No upgradeability** — immutable logic, no proxies
- **Liquidation-only execution** — non-liquidation Aave actions rejected (`UnsupportedActionType`)
- **Morpho share-based liquidation explicitly blocked** — `MorphoShareModeUnsupported`
- **V2 receiveAToken explicitly blocked** — `ReceiveATokenV2Unsupported`
- **Execution phase guard** — callbacks only accepted during `FlashLoanActive` phase
- **Single debt/collateral asset** — mixed asset flows rejected at validation
- **External calls restricted to allowlist** — `allowedTargets` enforced on all protocol interactions
- **No infinite approvals** — exact `forceApprove` before each interaction, reset to 0 after
- **Fail-closed** — all custom errors, all unknown states revert
- **Collateral delta check** — balance must increase after liquidation (not absolute check)
- **aToken canonical verification** — V3 aToken address verified on-chain via `getReserveData`
- **Delta-only aToken unwrap** — only liquidation-produced aTokens are redeemed
- **Absolute repay sufficiency** — total repayToken balance must cover flashRepayAmount
- **Profit gate** — `minProfitAmount` enforced post-operations
- **CHAINED profit invariant** — profitToken must equal repayToken in chained mode
- **Strict callback validation** — phase + `msg.sender` + `initiator` + plan hash + asset + amount
- **Access control** — `Ownable2Step` for config, `onlyOperator` for execution (immutable)
- **Pausable** — owner can pause/unpause all execution
- **ReentrancyGuard** — prevents reentrant calls to `execute`
- **Coinbase accounting** — WETH unwrap captured in delta, pre-existing ETH not over-deducted

### Custom Errors

| Error | Cause |
|---|---|
| `NoActions()` | Empty actions array |
| `TooManyActions(count)` | More than 10 actions |
| `NoLiquidationAction()` | No liquidation action (all internal) |
| `UnsupportedActionType(type)` | Non-liquidation Aave V3 action |
| `InvalidProtocolId(id)` | Unknown protocol ID |
| `MorphoShareModeUnsupported()` | seizedAssets=0 in Morpho liquidation |
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
| `InsufficientRepayOutput(actual, required)` | Repay balance insufficient |
| `InsufficientRepayBalance(required, available)` | Cannot cover repayment |
| `InsufficientProfit(actual, required)` | Profit below minimum |
| `SwapDeadlineExpired(deadline, current)` | Plan deadline passed |
| `InvalidExecutionPhase()` | Callback outside flash loan phase |
| `ChainedProfitMustMatchRepay()` | CHAINED mode: profitToken != repayToken |
| `CoinbasePaymentRequiresWethProfit()` | Coinbase payment without WETH profit |
| `CoinbasePaymentFailed()` | ETH transfer to coinbase failed |

## Configuration

### Constructor Parameters

| Parameter | Description |
|---|---|
| `owner_` | Initial contract owner (Ownable2Step) |
| `operator_` | Bot address authorized to call `execute` (**immutable**) |
| `weth_` | WETH token address (**immutable**) |
| `aavePool_` | Aave V3 Pool address (auto-whitelisted) |
| `balancerVault_` | Balancer Vault address (auto-whitelisted) |
| `paraswapAugustus_` | ParaSwap AugustusV6 router (auto-whitelisted) |
| `allowedTargets_` | Additional whitelisted targets (Bebop, Morpho, Aave V2, etc.) |

### Post-Deploy Owner Functions

| Function | Description |
|---|---|
| `setMorphoBlue(address)` | Configure Morpho Blue (must be in `allowedTargets`) |
| `setAaveV2LendingPool(address)` | Configure Aave V2 Pool (must be in `allowedTargets`) |
| `setFlashProvider(uint8, address)` | Register flash provider by ID (must be in `allowedTargets`) |
| `pause()` / `unpause()` | Emergency pause toggle |
| `rescueERC20(token, to, amount)` | Recover stuck tokens |
| `rescueAllERC20(token, to)` | Recover full token balance |
| `rescueERC20Batch(tokens[], to)` | Recover multiple token balances |
| `rescueETH(to, amount)` | Recover stuck ETH |

> **Note**: `allowedTargets` is write-once (constructor only). There is no post-deploy setter. All addresses that may be used with `setMorphoBlue`, `setAaveV2LendingPool`, or `setFlashProvider` must be included in the constructor's `allowedTargets_` array.

## Project Structure

```
src/
  LiquidationExecutor.sol              Main contract (~1180 lines)
  interfaces/
    IAaveV3Pool.sol                    Aave V3 Pool + IFlashLoanSimpleReceiver + getReserveData
    IBalancerVault.sol                 Balancer Vault + IFlashLoanRecipient
    IMorphoBlue.sol                    Morpho Blue (liquidate, repay, supply, withdraw)
    IAaveV2LendingPool.sol             Aave V2 (liquidationCall, withdraw)
    ISwapRouter.sol                    Uniswap V3 SwapRouter (legacy, unused)

test/
  Executor.t.sol                       136 tests + inline helper mocks
  mocks/
    MockERC20.sol                      Standard ERC20 with mint/burn
    MockAavePool.sol                   Aave V3 mock (flash, liquidation, getReserveData, aToken)
    MockBalancerVault.sol              Balancer Vault mock
    MockParaswapAugustus.sol           ParaSwap mock (fallback-based, configurable rate)
    MockAaveV2LendingPool.sol          Aave V2 mock (liquidation, withdraw, aToken)
    MockMorphoBlue.sol                 Morpho Blue mock (liquidate, repay, supply, withdraw)
    MockBebopSettlement.sol            Bebop settlement mock (multi-output)
    MockSwapRouter.sol                 Uniswap V3 mock (legacy, unused)
```

## Build & Test

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)

### Commands

```bash
forge install          # Install dependencies
forge build            # Compile
forge test             # Run 136 tests
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

### 2. Deploy

```bash
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $ETHEREUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --constructor-args \
    <OWNER_ADDRESS> \
    <OPERATOR_ADDRESS> \
    0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
    0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
    0xBA12222222228d8Ba445958a75a0704d566BF2C8 \
    0x6A000F20005980200259B80c5102003040001068 \
    "[0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9,<MORPHO_ADDRESS>,<BEBOP_ADDRESS>]"
```

### 3. Post-Deploy Configuration

```bash
EXECUTOR=<DEPLOYED_ADDRESS>

# Configure Morpho Blue (must be in allowedTargets)
cast send $EXECUTOR "setMorphoBlue(address)" <MORPHO_ADDRESS> --rpc-url $ETHEREUM_RPC_URL --private-key $PRIVATE_KEY

# Configure Aave V2 (must be in allowedTargets)
cast send $EXECUTOR "setAaveV2LendingPool(address)" 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9 --rpc-url $ETHEREUM_RPC_URL --private-key $PRIVATE_KEY
```

### 4. Verify Deployment

```bash
cast call $EXECUTOR "owner()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "operator()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "weth()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "morphoBlue()(address)" --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 1 --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 2 --rpc-url $ETHEREUM_RPC_URL
cast call $EXECUTOR "paused()(bool)" --rpc-url $ETHEREUM_RPC_URL
```

### 5. Protocol Addresses (Ethereum Mainnet)

| Protocol | Address |
|---|---|
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Aave V2 LendingPool | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| ParaSwap AugustusV6 | `0x6A000F20005980200259B80c5102003040001068` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |

## Compiler Settings

| Setting | Value |
|---|---|
| Solidity | 0.8.24 |
| EVM Target | Shanghai |
| Optimizer | Enabled (200 runs) |

## License

MIT
