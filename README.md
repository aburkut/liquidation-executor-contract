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
|    +-- Target Action           |
|    |   +-- Aave V3 (id=1)     |
|    |   +-- Morpho Blue (id=2) |
|    |   +-- Aave V2 (id=3)     |
|    +-- Swap via ParaSwap V6   |
|    +-- Profit Check           |
|    +-- Repay Flash Loan       |
+--------------------------------+
```

### Execution Flow

1. **Operator** calls `execute(bytes planData)` with an ABI-encoded `Plan`
2. Contract initiates a flash loan from the configured provider (Aave V3 or Balancer)
3. Inside the callback:
   - Execute the **target action** (Aave V3 repay/withdraw/supply, Morpho Blue repay/withdrawCollateral/supplyCollateral, or Aave V2 liquidation)
   - **Swap** collateral to loan token via ParaSwap AugustusV6
   - Enforce **minimum profit** gate
   - **Repay** the flash loan + fee
4. Remaining profit stays in the contract for the owner to rescue

## Supported Protocols

| Category | Protocol | ID | Actions |
|---|---|---|---|
| Flash Provider | Aave V3 | `1` | `flashLoanSimple` |
| Flash Provider | Balancer Vault | `2` | `flashLoan` |
| Target | Aave V3 | `1` | repay (1), withdraw (2), supply (3) |
| Target | Morpho Blue | `2` | repay (1), withdrawCollateral (2), supplyCollateral (3) |
| Target | Aave V2 | `3` | liquidationCall |
| Swap | ParaSwap AugustusV6 | - | Arbitrary swap via pre-built calldata |

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
- **No arbitrary external calls** -- only whitelisted protocols
- **No infinite approvals** -- exact `forceApprove` before each interaction, reset to 0 after
- **Fail-closed** -- custom errors, all unknown states revert
- **Strict callback validation**:
  - `msg.sender` must match the configured flash provider
  - `initiator` must be `address(this)`
  - Plan hash must match `_activePlanHash`
  - Callback asset and amount must match the plan (prevents malicious provider spoofing)
- **Allowlists** -- assets, flash providers, and target contracts are individually whitelisted
- **Access control** -- `Ownable2Step` for config, `onlyOperator` for execution
- **Pausable** -- owner can pause/unpause all execution
- **ReentrancyGuard** -- prevents reentrant calls to `execute`
- **Flash fee cap** -- `maxFlashFee` per plan, reverts if exceeded
- **Profit gate** -- `minProfit` enforced post-operations
- **Swap output validation** -- `minAmountOut` checked via balance diff

## Owner Configuration

| Function | Description |
|---|---|
| `setOperator(address)` | Set the bot address authorized to call `execute` |
| `setAavePool(address)` | Configure Aave V3 Pool address |
| `setMorphoBlue(address)` | Configure Morpho Blue address |
| `setBalancerVault(address)` | Configure Balancer Vault address |
| `setParaswapAugustusV6(address)` | Configure ParaSwap router address |
| `setAaveV2LendingPool(address)` | Configure Aave V2 Lending Pool address |
| `setUniswapV3Router(address)` | Configure Uniswap V3 Router address |
| `setAssetAllowed(address, bool)` | Whitelist/delist a token |
| `setFlashProvider(uint8, address)` | Register a flash provider by ID |
| `setTargetAllowed(address, bool)` | Whitelist/delist a target contract |
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

## Test Suite (64 tests)

| Category | Count |
|---|---|
| Access control | 14 |
| Pause mechanism | 2 |
| Happy paths (all provider/target combos) | 4 |
| Callback validation (initiator, caller, plan hash) | 6 |
| ParaSwap gating (swap revert, slippage, balance) | 3 |
| Aave V2 liquidation (happy, revert, protocolId) | 3 |
| Aave V3 liquidation | 1 |
| Profit gate (incl. profitToken==loanToken regression) | 5 |
| Fee cap | 2 |
| Partial failure / revert propagation | 2 |
| Flash provider validation | 1 |
| Asset allowlist | 1 |
| Invalid plan decoding | 3 |
| Config zero-address checks | 11 |
| Events | 2 |
| Rescue & Ownable | 4 |

## Compiler Settings

| Setting | Value |
|---|---|
| Solidity | 0.8.24 |
| EVM Target | Shanghai |
| Optimizer | Enabled (200 runs) |

## Deployment

Контракт использует один и тот же байткод для всех чейнов. Адреса протоколов задаются после деплоя через owner-функции.

### 1. Подготовка окружения

Создайте `.env` файл (не коммитьте его):

```bash
# Приватный ключ деплоера (он же initial owner)
PRIVATE_KEY=0x...

# RPC endpoints
ETHEREUM_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
OPTIMISM_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY

# Etherscan API keys (для верификации)
ETHERSCAN_API_KEY=...
BASESCAN_API_KEY=...
OPTIMISTIC_ETHERSCAN_API_KEY=...
```

### 2. Деплой контракта

```bash
# Ethereum Mainnet
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $ETHEREUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <OWNER_ADDRESS> \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY

# Base
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <OWNER_ADDRESS> \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY

# Optimism
forge create src/LiquidationExecutor.sol:LiquidationExecutor \
  --rpc-url $OPTIMISM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <OWNER_ADDRESS> \
  --verify \
  --etherscan-api-key $OPTIMISTIC_ETHERSCAN_API_KEY
```

### 3. Принятие ownership (Ownable2Step)

Если `OWNER_ADDRESS` отличается от деплоера, owner должен вызвать:

```bash
cast send <EXECUTOR_ADDRESS> "acceptOwnership()" \
  --rpc-url <RPC_URL> \
  --private-key <OWNER_PRIVATE_KEY>
```

### 4. Конфигурация протоколов

После деплоя owner настраивает адреса через `cast send`. Ниже пример для Ethereum Mainnet:

```bash
EXECUTOR=<DEPLOYED_ADDRESS>
RPC=$ETHEREUM_RPC_URL
PK=<OWNER_PRIVATE_KEY>

# Протоколы
cast send $EXECUTOR "setAavePool(address)" 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setBalancerVault(address)" 0xBA12222222228d8Ba445958a75a0704d566BF2C8 --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setParaswapAugustusV6(address)" 0x6A000F20005980200259B80c5102003040001068 --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setAaveV2LendingPool(address)" 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9 --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setMorphoBlue(address)" 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb --rpc-url $RPC --private-key $PK

# Flash providers
cast send $EXECUTOR "setFlashProvider(uint8,address)" 1 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setFlashProvider(uint8,address)" 2 0xBA12222222228d8Ba445958a75a0704d566BF2C8 --rpc-url $RPC --private-key $PK

# Оператор (бот)
cast send $EXECUTOR "setOperator(address)" <BOT_ADDRESS> --rpc-url $RPC --private-key $PK

# Target allowlist
cast send $EXECUTOR "setTargetAllowed(address,bool)" 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setTargetAllowed(address,bool)" 0xBA12222222228d8Ba445958a75a0704d566BF2C8 true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setTargetAllowed(address,bool)" 0x6A000F20005980200259B80c5102003040001068 true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setTargetAllowed(address,bool)" 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9 true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setTargetAllowed(address,bool)" 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb true --rpc-url $RPC --private-key $PK

# Asset allowlist (пример: WETH, USDC, USDT, DAI, WBTC)
cast send $EXECUTOR "setAssetAllowed(address,bool)" 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setAssetAllowed(address,bool)" 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setAssetAllowed(address,bool)" 0xdAC17F958D2ee523a2206206994597C13D831ec7 true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setAssetAllowed(address,bool)" 0x6B175474E89094C44Da98b954EedeAC495271d0F true --rpc-url $RPC --private-key $PK
cast send $EXECUTOR "setAssetAllowed(address,bool)" 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 true --rpc-url $RPC --private-key $PK
```

### 5. Адреса протоколов по чейнам

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

> **Важно**: Aave V2 и Morpho Blue доступны не на всех чейнах. Пропускайте вызовы `setAaveV2LendingPool` / `setMorphoBlue` и соответствующие `setTargetAllowed` на чейнах, где эти протоколы отсутствуют. Контракт не требует настройки всех протоколов -- неиспользуемые останутся `address(0)` и будут безопасно ревертить при попытке вызова.

### 6. Проверка деплоя

```bash
# Проверить owner
cast call $EXECUTOR "owner()(address)" --rpc-url $RPC

# Проверить operator
cast call $EXECUTOR "operator()(address)" --rpc-url $RPC

# Проверить настроенный Aave Pool
cast call $EXECUTOR "aavePool()(address)" --rpc-url $RPC

# Проверить flash provider
cast call $EXECUTOR "allowedFlashProviders(uint8)(address)" 1 --rpc-url $RPC

# Проверить whitelist ассета
cast call $EXECUTOR "allowedAssets(address)(bool)" 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 --rpc-url $RPC

# Проверить что контракт не на паузе
cast call $EXECUTOR "paused()(bool)" --rpc-url $RPC
```

### 7. Тест на форке перед продакшном

```bash
# Ethereum mainnet fork
forge test --fork-url $ETHEREUM_RPC_URL -vvv

# Base fork
forge test --fork-url $BASE_RPC_URL -vvv

# Optimism fork
forge test --fork-url $OPTIMISM_RPC_URL -vvv
```

## License

MIT
