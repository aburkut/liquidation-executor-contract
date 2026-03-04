# LiquidationExecutor

Production-grade **Flashloan + Swap + Repay/Liquidation** execution contract for DeFi liquidation bots.

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
|    +-- Flash Loan              |
|    |   +-- Aave V3 (id=1)     |
|    |   +-- Balancer Vault(id=2)|
|    +-- Swap via ParaSwap V6   |
|    +-- Target Action           |
|    |   +-- Aave V3 (id=1)     |
|    |   +-- Morpho Blue (id=2) |
|    |   +-- Aave V2 (id=3)     |
|    +-- Profit Check           |
|    +-- Repay Flash Loan       |
+--------------------------------+
```

### Execution Flow

1. **Operator** calls `execute(bytes planData)` with an ABI-encoded `Plan`
2. Contract validates swap invariant (`srcToken == loanToken`)
3. Contract initiates a flash loan from the configured provider (Aave V3 or Balancer)
4. Inside the callback:
   - **Swap** loan token via ParaSwap AugustusV6 (Augustus must be in `allowedTargets`)
   - Execute the **target action** (Aave V3 repay/withdraw/supply/liquidation, Morpho Blue repay/withdrawCollateral/supplyCollateral, or Aave V2 liquidation)
   - Enforce **minimum profit** gate
   - **Repay** the flash loan + fee
5. Remaining profit stays in the contract for the owner to rescue

## Supported Protocols

| Category | Protocol | ID | Actions |
|---|---|---|---|
| Flash Provider | Aave V3 | `1` | `flashLoanSimple` |
| Flash Provider | Balancer Vault | `2` | `flashLoan` |
| Target | Aave V3 | `1` | repay (1), withdraw (2), supply (3), liquidation (4) |
| Target | Morpho Blue | `2` | repay (1), withdrawCollateral (2), supplyCollateral (3) |
| Target | Aave V2 | `3` | liquidationCall |
| Swap | ParaSwap AugustusV6 | - | Any selector (target must be in `allowedTargets`) |

## Plan Format

The off-chain bot encodes a `Plan` struct and passes it as `bytes calldata`:

```solidity
struct SwapSpec {
    address srcToken;
    address dstToken;
    uint256 amountIn;
    uint256 minAmountOut;
    bytes paraswapCalldata;  // Pre-built calldata from ParaSwap API
}

struct Plan {
    uint8   flashProviderId;    // 1 = Aave V3, 2 = Balancer
    address loanToken;          // Token to borrow
    uint256 loanAmount;         // Amount to borrow
    uint256 maxFlashFee;        // Max acceptable flash fee
    uint8   targetProtocolId;   // 1 = Aave V3, 2 = Morpho Blue, 3 = Aave V2
    bytes   targetActionData;   // ABI-encoded action struct
    SwapSpec swapSpec;          // Swap specification
    address profitToken;        // Token to measure profit in
    uint256 minProfit;          // Minimum profit required
}
```

**Swap invariant**: `swapSpec.srcToken` must equal `loanToken`. This guarantees the swap consumes the flashloan token. The `dstToken` is unrestricted, allowing swaps into any token needed for the target action.

### Target Action Data Encoding

**Aave V3** (`protocolId = 1`):
```solidity
struct AaveV3Action {
    uint8 actionType;        // 1=repay, 2=withdraw, 3=supply, 4=liquidation
    address asset;
    uint256 amount;
    uint256 interestRateMode;
    address onBehalfOf;
    // Liquidation fields (actionType == 4 only)
    address collateralAsset;
    address debtAsset;
    address user;
    uint256 debtToCover;
    bool receiveAToken;
}
```

**Morpho Blue** (`protocolId = 2`):
```solidity
struct MorphoBlueAction {
    uint8 actionType;        // 1=repay, 2=withdrawCollateral, 3=supplyCollateral
    MarketParams marketParams;
    uint256 assets;
    uint256 shares;
    address onBehalfOf;
}
```

**Aave V2 Liquidation** (`protocolId = 3`):
```solidity
struct AaveV2Liquidation {
    address collateralAsset;
    address debtAsset;
    address user;
    uint256 debtToCover;
    bool receiveAToken;
}
```

## Security Model

- **No upgradeability** -- immutable logic, no proxies
- **External calls restricted to allowlist** -- all protocol interactions go through `allowedTargets`. Swaps are executed via Paraswap Augustus (a trusted generic router) using operator-supplied calldata; Augustus itself must be in `allowedTargets`
- **No infinite approvals** -- exact `forceApprove` before each interaction, reset to 0 after
- **Fail-closed** -- custom errors, all unknown states revert
- **Constructor-based configuration** -- Aave pool, Balancer vault, ParaSwap Augustus, flash providers, operator, and allowed targets are set at deploy time
- **Any standard ERC20 token accepted** -- no on-chain asset allowlist (`setAssetAllowed` has been removed); token usability is constrained by the selected flash provider's supported assets and the swap route (Paraswap). Fee-on-transfer, rebasing, and other non-standard ERC20 tokens are not supported and may break balance-diff accounting
- **Swap invariant** -- `srcToken == loanToken` ensures the swap consumes the flashloan token
- **Fail-closed setters** -- `setMorphoBlue`, `setAaveV2LendingPool`, and `setFlashProvider` require the address to be in `allowedTargets`; prevents configuring unwhitelisted addresses that would revert at runtime
- **Strict callback validation**:
  - `msg.sender` must match the configured flash provider
  - `initiator` must be `address(this)`
  - Plan hash must match `_activePlanHash`
  - Callback asset and amount must match the plan (prevents malicious provider spoofing)
- **Access control** -- `Ownable2Step` for config, `onlyOperator` for execution
- **Pausable** -- owner can pause/unpause all execution
- **ReentrancyGuard** -- prevents reentrant calls to `execute`
- **Flash fee cap** -- `maxFlashFee` per plan, reverts if exceeded
- **Profit gate** -- `minProfit` enforced post-operations
- **Swap output validation** -- `minAmountOut` checked via balance diff

## Configuration

### Constructor Parameters (set at deploy time)

| Parameter | Description |
|---|---|
| `owner_` | Initial contract owner (Ownable2Step) |
| `aavePool_` | Aave V3 Pool address |
| `balancerVault_` | Balancer Vault address |
| `paraswapAugustus_` | ParaSwap AugustusV6 router address |
| `allowedTargets_` | Array of whitelisted target contract addresses |

### Post-Deploy Owner Functions

| Function | Description |
|---|---|
| `setOperator(address)` | Set the bot address authorized to call `execute` |
| `setMorphoBlue(address)` | Configure Morpho Blue address (must be in `allowedTargets`) |
| `setAaveV2LendingPool(address)` | Configure Aave V2 Lending Pool address (must be in `allowedTargets`) |
| `setUniswapV3Router(address)` | Configure Uniswap V3 Router address |
| `setFlashProvider(uint8, address)` | Register a flash provider by ID (must be in `allowedTargets`) |
| `pause()` / `unpause()` | Emergency pause toggle |
| `rescueERC20(address, address, uint256)` | Recover stuck tokens |
| `rescueETH(address, uint256)` | Recover stuck ETH |

## Project Structure

```
src/
  LiquidationExecutor.sol              Main contract
  interfaces/
    IAaveV3Pool.sol                    Aave V3 Pool + IFlashLoanSimpleReceiver
    IBalancerVault.sol                 Balancer Vault + IFlashLoanRecipient
    IMorphoBlue.sol                    Morpho Blue with MarketParams
    IAaveV2LendingPool.sol             Aave V2 liquidationCall
    ISwapRouter.sol                    Uniswap V3 SwapRouter

test/
  Executor.t.sol                       61 tests + inline liar mocks
  mocks/
    MockERC20.sol                      Standard ERC20 with mint/burn
    MockAavePool.sol                   Aave V3 mock
    MockBalancerVault.sol              Balancer Vault mock
    MockParaswapAugustus.sol           ParaSwap mock (fallback-based)
    MockAaveV2LendingPool.sol          Aave V2 mock
    MockMorphoBlue.sol                 Morpho Blue mock
    MockSwapRouter.sol                 Uniswap V3 mock
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

## Test Suite (61 tests)

| Category | Count |
|---|---|
| Access control | 11 |
| Pause mechanism | 2 |
| Happy paths (all provider/target combos) | 4 |
| Callback validation (initiator, caller, plan hash) | 6 |
| ParaSwap gating (swap revert, slippage, balance) | 3 |
| Aave V2 liquidation (happy, revert, approval) | 3 |
| Aave V3 liquidation | 1 |
| Profit gate (incl. profitToken==loanToken regression) | 5 |
| Fee cap | 2 |
| Partial failure / revert propagation | 2 |
| Flash provider validation | 1 |
| Swap invariants (srcToken) | 1 |
| Invalid plan decoding | 3 |
| Config zero-address checks | 8 |
| Setter allowedTargets guards | 5 |
| Events | 2 |
| Rescue & Ownable | 2 |

## Compiler Settings

| Setting | Value |
|---|---|
| Solidity | 0.8.24 |
| EVM Target | Shanghai |
| Optimizer | Enabled (200 runs) |

## Deployment Checklist

Before deploying, verify every item below. Misconfiguration **cannot be fixed post-deploy** for `allowedTargets` (there is no setter).

### 1. Constructor configuration

The constructor requires:

| Parameter | Description |
|---|---|
| `owner_` | Initial contract owner (receives Ownable2Step ownership). Also set as the initial `operator`. |
| `aavePool_` | Aave V3 Pool address (also registered as flash provider for id=1) |
| `balancerVault_` | Balancer Vault address (also registered as flash provider for id=2) |
| `paraswapAugustus_` | ParaSwap AugustusV6 router address |
| `allowedTargets_` | Array of whitelisted target contract addresses (see below) |

### 2. Required targets in `allowedTargets`

The constructor automatically whitelists `aavePool_`, `balancerVault_`, and `paraswapAugustus_`. The `allowedTargets_` array provides **additional** addresses to whitelist.

**Required** (auto-whitelisted by constructor — no action needed):
- Aave V3 Pool
- Balancer Vault
- ParaSwap Augustus

**Optional but must be included in `allowedTargets_` if those protocols will be used:**
- Morpho Blue — required before calling `setMorphoBlue`
- Aave V2 LendingPool — required before calling `setAaveV2LendingPool`

### 3. Why targets must be pre-whitelisted

The executor enforces `allowedTargets[target] == true` before every external call to a protocol contract. If a protocol address is not in `allowedTargets`, execution reverts with:

```
TargetNotAllowed(address)
```

This applies at **runtime** (inside `_executeSwap`, `_executeAaveV3Action`, `_executeMorphoBlueAction`, `_executeAaveV2Liquidation`) **and at configuration time**:

- `setMorphoBlue(address)` — reverts if the address is not in `allowedTargets`
- `setAaveV2LendingPool(address)` — reverts if the address is not in `allowedTargets`

There is **no post-deploy setter** for `allowedTargets`. If you forget to include an address, you must redeploy.

### 4. No post-deploy asset configuration

- `setAssetAllowed` has been **removed** — there is no asset whitelist
- Any ERC20 token can be used as `loanToken`, `srcToken`, `dstToken`, or `profitToken`
- Safety is enforced via the swap invariant (`srcToken == loanToken`) and the `allowedTargets` check on the swap router

### 5. Operator configuration

- `operator` is initialized to `owner_` in the constructor
- The owner may change it later via `setOperator(address)`
- Only the operator can call `execute(bytes)`

---

## Deployment

The contract is **fully configured at deploy time** via constructor arguments. No post-deploy configuration setters are required for core protocol addresses and target allowlists.

### 1. Environment Setup

Create a `.env` file (do NOT commit it):

```bash
# Deployer private key (also initial owner)
PRIVATE_KEY=0x...

# RPC endpoints
ETHEREUM_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
OPTIMISM_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY

# Etherscan API keys (for verification)
ETHERSCAN_API_KEY=...
BASESCAN_API_KEY=...
OPTIMISTIC_ETHERSCAN_API_KEY=...
```

### 2. Deploy

The constructor requires: `owner`, `aavePool`, `balancerVault`, `paraswapAugustus`, and an array of `allowedTargets`.

```bash
# Ethereum Mainnet
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $ETHEREUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <OWNER_ADDRESS> \
    0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
    0xBA12222222228d8Ba445958a75a0704d566BF2C8 \
    0x6A000F20005980200259B80c5102003040001068 \
    "[0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,0xBA12222222228d8Ba445958a75a0704d566BF2C8,0x6A000F20005980200259B80c5102003040001068,0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9,0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb]" \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY

# Base
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <OWNER_ADDRESS> \
    0xA238Dd80C259a72e81d7e4664a9801593F98d1c5 \
    0xBA12222222228d8Ba445958a75a0704d566BF2C8 \
    0x6A000F20005980200259B80c5102003040001068 \
    "[0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,0xBA12222222228d8Ba445958a75a0704d566BF2C8,0x6A000F20005980200259B80c5102003040001068,0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb]" \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY

# Optimism
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $OPTIMISM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <OWNER_ADDRESS> \
    0x794a61358D6845594F94dc1DB02A252b5b4814aD \
    0xBA12222222228d8Ba445958a75a0704d566BF2C8 \
    0x6A000F20005980200259B80c5102003040001068 \
    "[0x794a61358D6845594F94dc1DB02A252b5b4814aD,0xBA12222222228d8Ba445958a75a0704d566BF2C8,0x6A000F20005980200259B80c5102003040001068]" \
  --verify \
  --etherscan-api-key $OPTIMISTIC_ETHERSCAN_API_KEY
```

### 3. Accept Ownership (Ownable2Step)

If `OWNER_ADDRESS` differs from the deployer, the owner must call:

```bash
cast send <EXECUTOR_ADDRESS> "acceptOwnership()" \
  --rpc-url <RPC_URL> \
  --private-key <OWNER_PRIVATE_KEY>
```

### 4. Post-Deploy Configuration

The constructor initializes the operator (set to `owner_`), flash providers (Aave V3 and Balancer), and core `allowedTargets`. Only optional protocol addresses need post-deploy setup. **Important**: `setMorphoBlue` and `setAaveV2LendingPool` require the address to already be in `allowedTargets` (set at deploy time), otherwise the call reverts.

```bash
EXECUTOR=<DEPLOYED_ADDRESS>
RPC=$ETHEREUM_RPC_URL
PK=<OWNER_PRIVATE_KEY>

# Optional: Change operator to a different bot address (default is owner)
cast send $EXECUTOR "setOperator(address)" <BOT_ADDRESS> --rpc-url $RPC --private-key $PK

# Optional: Morpho Blue (must be in allowedTargets deployed array)
cast send $EXECUTOR "setMorphoBlue(address)" 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb --rpc-url $RPC --private-key $PK

# Optional: Aave V2 (must be in allowedTargets deployed array)
cast send $EXECUTOR "setAaveV2LendingPool(address)" 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9 --rpc-url $RPC --private-key $PK
```

### 5. Protocol Addresses by Chain

#### Ethereum Mainnet

| Protocol | Address |
|---|---|
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Aave V2 LendingPool | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| ParaSwap AugustusV6 | `0x6A000F20005980200259B80c5102003040001068` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |

#### Base

| Protocol | Address |
|---|---|
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| Aave V2 LendingPool | -- (not deployed on Base) |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| ParaSwap AugustusV6 | `0x6A000F20005980200259B80c5102003040001068` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDbC | `0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6Ca` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| cbETH | `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22` |

#### Optimism

| Protocol | Address |
|---|---|
| Aave V3 Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| Aave V2 LendingPool | -- (not deployed on Optimism) |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| ParaSwap AugustusV6 | `0x6A000F20005980200259B80c5102003040001068` |
| Morpho Blue | -- (not deployed on Optimism) |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |
| USDT | `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58` |
| DAI | `0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1` |
| WBTC | `0x68f180fcCe6836688e9084f035309E29Bf0A2095` |

> **Note**: Aave V2 and Morpho Blue are not available on all chains. Skip `setAaveV2LendingPool` / `setMorphoBlue` on chains where these protocols are absent. The contract does not require all protocols to be configured -- unconfigured ones remain `address(0)` and safely revert on attempted use. Ensure the address is included in the `allowedTargets_` constructor array before calling the setter.

### 6. Verify Deployment

```bash
# Check owner
cast call $EXECUTOR "owner()(address)" --rpc-url $RPC

# Check operator
cast call $EXECUTOR "operator()(address)" --rpc-url $RPC

# Check configured Aave Pool
cast call $EXECUTOR "aavePool()(address)" --rpc-url $RPC

# Check configured Balancer Vault
cast call $EXECUTOR "balancerVault()(address)" --rpc-url $RPC

# Check configured ParaSwap Augustus
cast call $EXECUTOR "paraswapAugustusV6()(address)" --rpc-url $RPC

# Check flash provider
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 1 --rpc-url $RPC

# Check target allowlist
cast call $EXECUTOR "allowedTargets(address)(bool)" 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 --rpc-url $RPC

# Check contract is not paused
cast call $EXECUTOR "paused()(bool)" --rpc-url $RPC
```

### 7. Fork Testing Before Production

```bash
# Ethereum Mainnet fork
forge test --fork-url $ETHEREUM_RPC_URL -vvv

# Base fork
forge test --fork-url $BASE_RPC_URL -vvv

# Optimism fork
forge test --fork-url $OPTIMISM_RPC_URL -vvv
```

## License

MIT
