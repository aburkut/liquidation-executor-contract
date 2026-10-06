# Arb executor upgrade: V4/V2 opening price limits, native re-wrap, `version()`

**needs redeploy: yes** — a new ArbExecutor implementation behind the existing
proxy. Nothing in this repository deploys or signs anything; the owner runs
step 1 and the Safe executes step 2. The LiquidationExecutor proxy and its
implementation are not touched.

| | |
|---|---|
| Arb proxy (unchanged address) | `0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c` |
| ProxyAdmin (Safe tx target) | `0x0A061E4C1410864312915e8D7fD0123f2E04707c` |
| Owner of both | Safe 2-of-2 `0xC338094Bb79AA610E9c57166fc4FA959db6234Ab` |
| Current implementation (rollback) | `0x0835F6b8b06bFeCb9d18b272D723dcaA7f31C83a` (b48587a) |
| New implementation (with the SALT below) | `0x8d65bE9AeE06EDedA31e63e4B0322817616CC355` |

## 1. Deploy the libraries and the implementation

From this commit, arb profile, with the salt (the implementation then goes
through the canonical CREATE2 deployer, so its address does not depend on the
deployer's nonce):

    SALT=$(cast keccak "liquidation-executor-contract/arb/v4-v2-opening-limits")
    # = 0x65d6ef3563b57fda41fa9eca07b8d70f982790fbe885d11d1c935f54308cccaa
    FOUNDRY_PROFILE=arb PROXY=0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c EXECUTOR_KIND=arb \
      SALT=$SALT PRIVATE_KEY=<deployer key> \
      forge script script/PrepareUpgrade.s.sol --rpc-url $RPC --broadcast --sender <deployer address>

Dry-run first on a local fork (`anvil --fork-url <rpc> --chain-id 31337` — a
chain id other than 1 keeps the tracked mainnet broadcast records untouched).

Measured on an anvil fork of mainnet block 26 131 909 — three CREATE2
transactions; every other linked library (CoinbasePaymentLib, BalancerV2Lib,
CurveV1Lib, ParaswapDecoderLib, SwapLegExecutorLib, SwapValidationLib) is
reused at its existing mainnet address:

| Contract | Address | Gas used |
|---|---|---|
| UniswapLib | `0xc09F4099201d5120E879d1e1C3D68e41817d6cF5` | 2 748 745 |
| GenericSequenceLib | `0xA6cE8D5948b43a108F123631CDD0143a2DE5c695` | 3 793 632 |
| ArbExecutor (implementation) | `0x8d65bE9AeE06EDedA31e63e4B0322817616CC355` | 4 229 159 |
| **Total** | | **10 771 536** |

At the mainnet gas price at the time (0.128 gwei) that is **≈ 0.0014 ETH**;
forge's own estimate with its fee margin was 15.1M gas / 0.0039 ETH at
0.258 gwei. The script prints the three addresses and the Safe calldata; with
the same commit, profile and salt they equal the table above.

Runtime sizes (arb profile, EIP-170 limit 24 576): ArbExecutor 19 146
(deployed b48587a: 18 738), GenericSequenceLib 17 375 (15 642), UniswapLib
12 530 (11 075).

## 2. The Safe transaction

- **to**: `0x0A061E4C1410864312915e8D7fD0123f2E04707c` (ProxyAdmin)
- **value**: `0`
- **data**: `ProxyAdmin.upgradeAndCall(0x0AA6f298…, 0x8d65bE9A…, "")`

```
0x9623609d0000000000000000000000000aa6f2988722c1f5ef8d1e2f2fbb75676093358c0000000000000000000000008d65be9aee06ededa31e63e4b0322817616cc35500000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000
```

Replayed from the Safe on the fork: status 1, 37 111 gas; implementation slot
`0x0835F6b8…` → `0x8d65bE9A…`; admin slot unchanged.

Rollback: the same call with `0x0835F6b8b06bFeCb9d18b272D723dcaA7f31C83a`.

## 3. Checklist

Before the Safe signs (fork, from this commit):
- [ ] `test/fork/ProxyReplay.t.sol` — a real landed V4 plan replays byte-for-byte
      through the proxy on the new implementation, same WETH/ETH kept.
- [ ] `test/fork/LiquidationViaFluid.t.sol` — liquidation path and library
      linkage intact.
- [ ] `test/fork/ArbUpgradeState.t.sol` — the upgrade changes nothing on the
      proxy but the implementation slot: owner, pending owner/paused, admin
      slot, Initializable namespace, operators, targets, flash providers,
      WETH/USDC/ETH balances and the RES token balance all equal before/after.
- [ ] `test/fork/ArbV4V2LimitFork.t.sol` — the V2 price-limited shape on real
      pools through the upgraded proxy; the profit floor binds.

After the Safe executes (mainnet, read-only — no key, no broadcast):
- [ ] `PROXY=0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c EXECUTOR_KIND=arb
      EXPECTED_IMPLEMENTATION=0x8d65bE9AeE06EDedA31e63e4B0322817616CC355
      forge script script/CheckDeployment.s.sol --rpc-url $RPC` — implementation,
      admin, Safe ownership, initializer spent, six immutables, providers 2/3,
      operators, not paused, Morpho/WETH not targets (all `ok` on the fork).
- [ ] `cast call 0x0AA6f298… "version()(uint256)"` → `2`.
- [ ] RES `0xAcce5500000f71A32B5E5514D1577E14b7aacC4a`
      `balanceOf(0x0AA6f298…)` → `1` (the token is bound to the proxy address,
      which does not change).
- [ ] Only then the bot flag: `MEV_SHARE_BLIND_ONE_ORDER_V4V2=1` (the bot also
      reads `version()` itself and keeps the new shapes off below 2).

No Etherscan / Sourcify / verify-bytecode for executor contracts (MEV policy);
`CheckDeployment` is the post-deploy gate.
