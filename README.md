# LiquidationExecutor

## Deployment (Ethereum Mainnet)

| Parameter | Value |
|---|---|
| **Contract** | `0x38F4473C077c014786037cC3d82fce52510b9089` |
| **Deploy tx** | `0x0da58098a540a127b98e7b8ae7e783134236cb2e4ec870260b156dc62808db6b` |
| **Owner** | `0xC338094Bb79AA610E9c57166fc4FA959db6234Ab` (Safe multisig) |
| **Operator** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` (immutable) |
| **WETH** | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (immutable) |
| **Deployer** | `0x1e9e18152552609175826f3ee6F8bFD639532E37` |
| **Aave V3 Pool** | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| **Balancer Vault** | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| **ParaSwap Augustus** | `0x6A000F20005980200259B80c5102003040001068` |
| **Aave V2 LendingPool** | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` (whitelisted, not yet configured) |
| **Solidity** | 0.8.24, Shanghai, optimizer 200 runs |

| Previous deployment | |
|---|---|
| **V1 Contract** | `0x1aaED107C21B389a38a632129dC0Cb362819bC8D` (deprecated) |

---

Production-grade **Flashloan → Multi-Liquidation → Swap → Repay** execution contract for DeFi liquidation bots.

Single deployable bytecode targeting **Ethereum Mainnet**, **Base**, and **Optimism**.

## Architecture

```
Operator Bot
    |
    v
+--------------------------------+
|     LiquidationExecutor        |
|  Ownable2Step / Pausable       |
|  ReentrancyGuard               |
+--------------------------------+
|  execute(planData)             |
|    +-- Validate Plan           |
|    |   +-- actions > 0, <= 10  |
|    |   +-- single debt asset   |
|    |   +-- single collateral   |
|    |   +-- swap spec matches   |
|    +-- Flash Loan              |
|    |   +-- Aave V3 (id=1)     |
|    |   +-- Balancer Vault(id=2)|
|    +-- Execute Actions (loop)  |
|    |   +-- Aave V3 liquidation |
|    |   +-- Aave V2 liquidation |
|    +-- Swap via ParaSwap V6   |
|    +-- Profit Check           |
|    +-- Repay Flash Loan       |
+--------------------------------+
```

### Execution Flow

1. **Operator** calls `execute(bytes planData)` with an ABI-encoded `Plan`
2. Contract validates the plan:
   - All actions are liquidations (actionType == 4 for V3, all V2 actions are liquidations)
   - All actions use the same `debtAsset == plan.loanToken`
   - All actions produce the same `collateralAsset`
   - `swapSpec.dstToken == plan.loanToken` (swap produces repayment token)
   - `swapSpec.srcToken == collateralAsset` (swap consumes liquidation output)
   - All action amounts > 0
3. Contract initiates a flash loan from the configured provider (Aave V3 or Balancer)
4. Inside the callback:
   - Verify flash loan balance received (`INVALID_FLASH_LOAN`)
   - Execute **all actions** in order (multiple liquidations in one tx)
   - Verify collateral was received (`NO_COLLATERAL`)
   - **Swap** received collateral back to loan token via ParaSwap AugustusV6
   - Enforce **minimum profit** gate
   - **Repay** the flash loan + fee
5. Remaining profit stays in the contract for the owner to rescue

#### Liquidation Example (Single)

```
Flash loan USDC (debt asset)
  → liquidationCall(collateral=WETH, debt=USDC, user, amount)
    → pays USDC debt, receives WETH collateral (with bonus)
  → swap WETH → USDC via ParaSwap
  → repay flash loan (USDC + fee)
  → profit = remaining USDC
```

#### Multi-Liquidation Example

```
Flash loan USDC (debt asset)
  → liquidationCall(collateral=WETH, debt=USDC, user1, amount1)
  → liquidationCall(collateral=WETH, debt=USDC, user2, amount2)
  → swap total WETH → USDC via ParaSwap
  → repay flash loan (USDC + fee)
  → profit = remaining USDC
```

## Supported Protocols

| Category | Protocol | ID | Actions |
|---|---|---|---|
| Flash Provider | Aave V3 | `1` | `flashLoanSimple` |
| Flash Provider | Balancer Vault | `2` | `flashLoan` |
| Target | Aave V3 | `1` | liquidation (actionType=4) only |
| Target | Aave V2 | `3` | `liquidationCall` |
| Swap | ParaSwap AugustusV6 | - | `swapExactAmountIn` / `swapExactAmountOut` |

> **Note**: Only liquidation actions are supported. Non-liquidation actions (repay, withdraw, supply) are rejected at validation with `UNSUPPORTED_ACTION`. Morpho Blue protocol (id=2) is rejected with `INVALID_PROTOCOL`.

## Plan Format

The off-chain bot encodes a `Plan` struct and passes it as `bytes calldata`:

```solidity
struct SwapSpec {
    address srcToken;       // Token received from liquidation (collateral)
    address dstToken;       // Token needed for flash loan repay (= loanToken)
    uint256 amountIn;
    uint256 minAmountOut;
    uint256 deadline;
    bytes paraswapCalldata; // Pre-built calldata from ParaSwap API
}

struct Action {
    uint8 protocolId;       // 1 = Aave V3, 3 = Aave V2
    bytes data;             // ABI-encoded action struct
}

struct Plan {
    uint8   flashProviderId;    // 1 = Aave V3, 2 = Balancer
    address loanToken;          // Token to borrow (= debt asset)
    uint256 loanAmount;         // Amount to borrow
    uint256 maxFlashFee;        // Max acceptable flash fee
    Action[] actions;           // Ordered liquidation actions (1-10)
    SwapSpec swapSpec;          // Post-liquidation swap specification
    address profitToken;        // Token to measure profit in
    uint256 minProfit;          // Minimum profit required (or revert)
}
```

**Invariants enforced at validation**:
- `actions.length > 0` and `<= 10`
- All `debtAsset == plan.loanToken` (`INVALID_DEBT_ASSET`)
- All `collateralAsset` identical (`INVALID_COLLATERAL_ASSET`)
- `swapSpec.dstToken == plan.loanToken` (`INVALID_SWAP_SPEC`)
- `swapSpec.srcToken == collateralAsset` (`INVALID_SWAP_SPEC`)
- All action amounts > 0 (`ZERO_ACTION_AMOUNT`)
- Only liquidation actions allowed (`UNSUPPORTED_ACTION`, `INVALID_PROTOCOL`)

### Target Action Data Encoding

**Aave V3 Liquidation** (`protocolId = 1`, `actionType = 4`):
```solidity
struct AaveV3Action {
    uint8 actionType;        // Must be 4 (liquidation)
    address asset;           // unused for liquidation
    uint256 amount;          // unused for liquidation
    uint256 interestRateMode;// unused for liquidation
    address onBehalfOf;      // unused for liquidation
    address collateralAsset; // Token received (must be same across actions)
    address debtAsset;       // Token paid (must equal plan.loanToken)
    address user;            // User being liquidated
    uint256 debtToCover;     // Amount of debt to repay (must be > 0)
    bool receiveAToken;      // false = receive underlying
}
```

**Aave V2 Liquidation** (`protocolId = 3`):
```solidity
struct AaveV2Liquidation {
    address collateralAsset; // Token received
    address debtAsset;       // Token paid (must equal plan.loanToken)
    address user;            // User being liquidated
    uint256 debtToCover;     // Amount (must be > 0)
    bool receiveAToken;
}
```

## Security Model

- **No upgradeability** — immutable logic, no proxies
- **Liquidation-only execution** — non-liquidation actions rejected at validation
- **Single debt/collateral asset** — mixed asset flows rejected at validation
- **External calls restricted to allowlist** — all protocol interactions go through `allowedTargets`
- **No infinite approvals** — exact `forceApprove` before each interaction, reset to 0 after
- **Fail-closed** — custom errors, all unknown states revert
- **Pre-execution validation** — invalid plans rejected before flash loan is initiated
- **Flash loan balance verification** — callback verifies received balance matches plan
- **Post-action collateral check** — verifies collateral was actually received before swap
- **Swap output validation** — `minAmountOut` checked via balance diff
- **Swap invariant** — `dstToken == loanToken` ensures swap produces repayment token
- **Profit gate** — `minProfit` enforced post-operations, reverts if not met
- **Strict callback validation** — `msg.sender`, `initiator`, plan hash, asset, amount all verified
- **Access control** — `Ownable2Step` for config, `onlyOperator` for execution
- **Pausable** — owner can pause/unpause all execution
- **ReentrancyGuard** — prevents reentrant calls to `execute`
- **Flash fee cap** — `maxFlashFee` per plan, reverts if exceeded
- **Action count cap** — max 10 actions per plan (`TOO_MANY_ACTIONS`)
- **Fail-closed setters** — `setMorphoBlue`, `setAaveV2LendingPool`, `setFlashProvider` require address in `allowedTargets`

### Validation Error Reference

| Error | Cause |
|---|---|
| `NO_ACTIONS` | Empty actions array |
| `TOO_MANY_ACTIONS` | More than 10 actions |
| `UNSUPPORTED_ACTION` | Aave V3 action with actionType != 4 |
| `INVALID_PROTOCOL` | Unknown protocol ID (not 1 or 3) |
| `INVALID_DEBT_ASSET` | Action debtAsset != plan.loanToken |
| `INVALID_COLLATERAL_ASSET` | Mixed collateral assets across actions |
| `INVALID_SWAP_SPEC` | Swap tokens don't match plan invariants |
| `ZERO_ACTION_AMOUNT` | Action with debtToCover == 0 |
| `INVALID_FLASH_LOAN` | Flash loan callback received insufficient balance |
| `NO_COLLATERAL` | No collateral received after executing actions |
| `InsufficientProfit` | Profit below minProfit after swap |
| `InsufficientSwapOutput` | Swap output below minAmountOut |
| `FlashFeeExceeded` | Flash loan fee exceeds maxFlashFee |

## Configuration

### Constructor Parameters (set at deploy time)

| Parameter | Description |
|---|---|
| `owner_` | Initial contract owner (Ownable2Step) |
| `operator_` | Bot address authorized to call `execute` (**immutable**) |
| `weth_` | WETH token address for coinbase payment auto-unwrap (**immutable**) |
| `aavePool_` | Aave V3 Pool address (auto-whitelisted in `allowedTargets`) |
| `balancerVault_` | Balancer Vault address (auto-whitelisted in `allowedTargets`) |
| `paraswapAugustus_` | ParaSwap AugustusV6 router address (auto-whitelisted in `allowedTargets`) |
| `allowedTargets_` | Array of additional whitelisted target contract addresses |

### Post-Deploy Owner Functions

| Function | Description |
|---|---|
| `setMorphoBlue(address)` | Configure Morpho Blue address (must be in `allowedTargets`) |
| `setAaveV2LendingPool(address)` | Configure Aave V2 Lending Pool address (must be in `allowedTargets`) |
| `setUniswapV3Router(address)` | Legacy setter (not used in current execution flow) |
| `setFlashProvider(uint8, address)` | Register a flash provider by ID (must be in `allowedTargets`) |
| `pause()` / `unpause()` | Emergency pause toggle |
| `rescueERC20(token, to, amount)` | Recover specific amount of stuck tokens |
| `rescueAllERC20(token, to)` | Recover full balance of a stuck token |
| `rescueERC20Batch(tokens[], to)` | Recover full balances of multiple stuck tokens |
| `rescueETH(to, amount)` | Recover stuck ETH |

## Project Structure

```
src/
  LiquidationExecutor.sol              Main contract (716 lines)
  interfaces/
    IAaveV3Pool.sol                    Aave V3 Pool + IFlashLoanSimpleReceiver
    IBalancerVault.sol                 Balancer Vault + IFlashLoanRecipient
    IMorphoBlue.sol                    Morpho Blue with MarketParams
    IAaveV2LendingPool.sol             Aave V2 liquidationCall
    ISwapRouter.sol                    Uniswap V3 SwapRouter (legacy)

test/
  Executor.t.sol                       92 tests + inline helper mocks
  mocks/
    MockERC20.sol                      Standard ERC20 with mint/burn
    MockAavePool.sol                   Aave V3 mock (flash + liquidation)
    MockBalancerVault.sol              Balancer Vault mock
    MockParaswapAugustus.sol           ParaSwap mock (fallback-based, configurable rate)
    MockAaveV2LendingPool.sol          Aave V2 mock
    MockMorphoBlue.sol                 Morpho Blue mock
    MockSwapRouter.sol                 Uniswap V3 mock (legacy)
```

## Build & Test

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)

### Install Dependencies

```bash
forge install
```

### Build

```bash
forge build
```

### Run Tests

```bash
forge test
```

Verbose output:

```bash
forge test -vvv
```

### Test Coverage

```bash
forge coverage
```

## Test Suite (120 tests)

| Category | Count |
|---|---|
| Access control (onlyOwner, onlyOperator, Ownable2Step) | 11 |
| Pause mechanism | 2 |
| Happy paths (Aave V3/V2, Aave/Balancer flash) | 4 |
| Real liquidation flow (zero pre-funding) | 1 |
| Multi-liquidation flow (2 actions, 1 flash loan) | 1 |
| Callback validation (initiator, caller, plan hash, asset, amount) | 6 |
| ParaSwap gating (swap revert, slippage, approval reset) | 3 |
| Aave V2 liquidation (happy, revert, approval reset) | 3 |
| Aave V3 liquidation + allowance reset | 1 |
| Profit gate (Aave V3, Balancer, profitToken==loanToken) | 5 |
| Fee cap (Aave V3, Balancer) | 2 |
| Failure propagation (liquidation revert, morpho revert) | 2 |
| Flash provider validation | 1 |
| Swap invariants (dstToken, srcToken, deadline, recipient, selector, amountIn) | 6 |
| Invalid plan decoding (zero loan, zero address) | 2 |
| Action validation (empty, too many, zero amount, unsupported, invalid protocol) | 5 |
| Asset consistency (invalid debt, invalid collateral, invalid swap spec) | 3 |
| Flash loan balance verification | 1 |
| No collateral received | 1 |
| Swap slippage revert | 1 |
| Non-profitable execution revert | 1 |
| Multi-action partial failure (atomicity) | 1 |
| Config zero-address checks (operator, morpho, aaveV2, uniswap, flashProvider, owner) | 8 |
| Setter allowedTargets guards (morpho, aaveV2, flashProvider rejected if not whitelisted) | 5 |
| Events (FlashExecuted, LiquidationExecuted) | 2 |
| Rescue — ERC20 (single, all, batch), ETH, validations | 13 |

## Compiler Settings

| Setting | Value |
|---|---|
| Solidity | 0.8.24 |
| EVM Target | Shanghai |
| Optimizer | Enabled (200 runs) |

## Deployment Checklist

Before deploying, verify every item below. Misconfiguration **cannot be fixed post-deploy** for `allowedTargets` (there is no setter).

### 1. Constructor configuration

| Parameter | Description |
|---|---|
| `owner_` | Initial contract owner (receives Ownable2Step ownership). Also set as the initial `operator`. |
| `aavePool_` | Aave V3 Pool address (also registered as flash provider for id=1) |
| `balancerVault_` | Balancer Vault address (also registered as flash provider for id=2) |
| `paraswapAugustus_` | ParaSwap AugustusV6 router address |
| `allowedTargets_` | Array of additional whitelisted target contract addresses (see below) |

### 2. Required targets in `allowedTargets`

The constructor automatically whitelists `aavePool_`, `balancerVault_`, and `paraswapAugustus_`. The `allowedTargets_` array provides **additional** addresses to whitelist.

**Auto-whitelisted by constructor (no action needed):**
- Aave V3 Pool
- Balancer Vault
- ParaSwap Augustus

**Must be included in `allowedTargets_` if those protocols will be used:**
- Aave V2 LendingPool — required before calling `setAaveV2LendingPool`

### 3. Why targets must be pre-whitelisted

The executor enforces `allowedTargets[target] == true` before every external call to a protocol contract. If a protocol address is not in `allowedTargets`, execution reverts with:

```
TargetNotAllowed(address)
```

There is **no post-deploy setter** for `allowedTargets`. If you forget to include an address, you must redeploy.

### 4. No post-deploy asset configuration

- Any ERC20 token can be used as `loanToken`, `srcToken`, `dstToken`, or `profitToken`
- Safety is enforced via plan validation (single debt/collateral invariants) and the `allowedTargets` check on the swap router

### 5. Operator configuration

- `operator` is set in the constructor and is **immutable** (cannot be changed post-deploy)
- Only the operator can call `execute(bytes)`
- To change operator, redeploy the contract

---

## Deployment

### 1. Environment Setup

Create a `.env` file (do NOT commit it):

```bash
# Deployer private key (also initial owner)
PRIVATE_KEY=0x...

# RPC endpoints
ETHEREUM_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY

# Etherscan API keys (for verification)
ETHERSCAN_API_KEY=...
```

### 2. Deploy

```bash
# Ethereum Mainnet
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
    "[0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9]"
```

### 3. Post-Deploy Configuration

```bash
EXECUTOR=<DEPLOYED_ADDRESS>
RPC=$ETHEREUM_RPC_URL
PK=<OWNER_PRIVATE_KEY>

# Optional: Aave V2 (must be in allowedTargets deployed array)
cast send $EXECUTOR "setAaveV2LendingPool(address)" 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9 --rpc-url $RPC --private-key $PK
```

### 4. Protocol Addresses (Ethereum Mainnet)

| Protocol | Address |
|---|---|
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Aave V2 LendingPool | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| ParaSwap AugustusV6 | `0x6A000F20005980200259B80c5102003040001068` |

### 5. Verify Deployment

```bash
cast call $EXECUTOR "owner()(address)" --rpc-url $RPC
cast call $EXECUTOR "operator()(address)" --rpc-url $RPC
cast call $EXECUTOR "weth()(address)" --rpc-url $RPC
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 1 --rpc-url $RPC
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 2 --rpc-url $RPC
cast call $EXECUTOR "allowedTargets(address)(bool)" 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 --rpc-url $RPC
cast call $EXECUTOR "paused()(bool)" --rpc-url $RPC
```

### 6. Fork Testing Before Production

```bash
forge test --fork-url $ETHEREUM_RPC_URL -vvv
```

## License

MIT
