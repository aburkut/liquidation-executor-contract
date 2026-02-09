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
    uint8 actionType;        // 1=repay, 2=withdraw, 3=supply
    address asset;
    uint256 amount;
    uint256 interestRateMode;
    address onBehalfOf;
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

## Test Suite (61 tests)

| Category | Count |
|---|---|
| Access control | 14 |
| Pause mechanism | 2 |
| Happy paths (all provider/target combos) | 4 |
| Callback validation (initiator, caller, plan hash) | 6 |
| ParaSwap gating (swap revert, slippage, balance) | 3 |
| Aave V2 liquidation (happy, revert, protocolId) | 3 |
| Profit gate | 3 |
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

1. Deploy the contract with the owner address:
   ```solidity
   new LiquidationExecutor(ownerAddress)
   ```
2. Owner accepts ownership via `acceptOwnership()` (Ownable2Step)
3. Configure all protocol addresses via setter functions
4. Whitelist assets, flash providers, and target contracts
5. Set the operator bot address via `setOperator(address)`

## License

MIT
