# Upgradeable executors — design

Date: 2026-09-14
Status: approved; implementation plan in
`docs/superpowers/plans/2026-09-14-upgradeable-executors.md`
Scope: `ArbExecutor` and `LiquidationExecutor`

## Problem

Every executor change ships as a new contract address. `ArbExecutor` moved
three times in three days — four addresses: `0xfC127EB8` → `0x726Eba4B` →
`0x79F55E2e` → `0x4d3AbD5d`, 2026-09-11..13. Each move costs deploy gas, an
`.env` change, a bot restart, re-seeding allowlists and operators, and a fresh
Resolver Access Token mint for the 1inch book.

Root cause, from git: of the six fixes #40–#46, five touched only libraries
(#41, #45, #46 `DirectSwapLib`; #43, #44 `GenericSequenceLib`). The executors
reach `GenericSequenceLib` through external library calls — `DELEGATECALL` to
an address linked into the executor's bytecode at deploy — so new library code
means a new executor. The sixth (#40) changed the executors themselves.

A second, process cause: #41, #43 and #45 were three successive attempts at the
same direct-V2 fee-on-transfer problem, each reaching deploy before it was
proven against the real failing transaction on a fork.

## Goal

A permanent address per executor, with any code change — libraries, callbacks,
pre-flight checks, immutables — shipped as one owner transaction. Flexibility
is the priority; the owner accepts that the owner can replace the code the
executor runs.

The owner of both executors is the Safe `0xC338094Bb79AA610E9c57166fc4FA959db6234Ab`
(2-of-2). "One owner transaction" is therefore one Safe transaction.

## Non-goals

- Lifting the EIP-170 ceiling. `LiquidationExecutor` has 380 bytes of room;
  that remains a separate problem, handled as today by moving code into
  libraries. The chosen design adds no bytes to either implementation and does
  not rule out a facet router behind the same proxy later.
- `src/bin/tenderly_replay.rs` in the bot. Its hardcoded storage slots are
  already stale against the current layout; fixing it is separate work.

## Options considered

| option | outcome |
|---|---|
| Owner-settable library pointer | Rejected: does not cover executor-side changes such as #40. |
| UUPS (ERC-1822 + ERC-1967) | Rejected by measurement: `UUPSUpgradeable` adds **1065 bytes** of runtime with this repo's compiler settings (`via_ir`, `optimizer_runs = 1`; probe 196 → 1261 bytes). `LiquidationExecutor` has 380. |
| Diamond (EIP-2535) | Rejected: function-level upgrades are not needed (a full implementation swap is also one transaction); costs a selector lookup `SLOAD` on every call and every pool callback, and far more code, tests, deploy tooling and audit surface. |
| **Transparent proxy (ERC-1967)** | **Chosen.** Upgrade logic lives in the proxy, so implementation size is unchanged; standard OpenZeppelin v5.5 code already vendored in `lib/`. |

## Design

### 1. Contracts per executor

1. **`ExecutorProxy`** — extends OZ `TransparentUpgradeableProxy` and adds an
   empty `receive() external payable {}`. Plain ETH is accepted by the proxy
   without a `DELEGATECALL`, so WETH9 `withdraw` (a 2300-gas `transfer`, used by
   `GenericSequenceLib` unwraps and `CoinbasePaymentLib.payCoinbase`) does not
   depend on proxy overhead. No behaviour is lost: both implementations'
   `receive` is empty today. The OZ v5 constructor deploys a `ProxyAdmin` owned
   by `initialOwner` — the Safe.
2. **Implementation** — today's `ArbExecutor` / `LiquidationExecutor`. The
   constructor keeps only immutables (WETH, routers, Balancer, Morpho, Aave),
   passes a `0xdEaD` placeholder to `Ownable`, and calls
   `_disableInitializers()`. It no longer writes storage; its own storage is
   never used.
3. **`ArbExecutorGenesis` / `LiquidationExecutorGenesis`** — a one-shot initial
   implementation whose runtime is only `initialize(...)`, guarded by
   `initializer`. The proxy is constructed with `Genesis` as its first
   implementation and the `initialize` calldata. Running inside the proxy's
   constructor, `initialize` seeds owner, operators, flash providers, allowlist
   and hooks, and as its last step writes the real implementation into the
   ERC-1967 slot (`ERC1967Utils.upgradeToAndCall(implementation, "")`). One
   deploy transaction yields a proxy that already runs the implementation and
   whose `ProxyAdmin` already belongs to the Safe: there is no window in which
   the proxy is uninitialised or still on `Genesis`, and no deployer-held admin.

   Why not `initialize` inside the implementation: initializer code is runtime
   code and `LiquidationExecutor` cannot absorb it. `SeededExecutors` already
   moved seeding out of runtime for the same reason.

   `Genesis` reads the implementation's own immutables (Balancer vault on the
   arb side, Morpho, Paraswap, routers, Aave pool) to seed the base allowlist
   and flash providers, so seeds cannot drift from the code they sit behind.
   `LiquidationExecutor` keeps no Balancer immutable, so its `Genesis` takes
   the vault as a parameter. The arb side still never allowlists Morpho as a
   target; the liquidation side does, as today.

**Shared storage base.** State variables move into `ArbExecutorStorage` /
`LiquidationExecutorStorage` — `Ownable2Step`, `Pausable`,
`ReentrancyGuardTransient`, `Initializable` and the variables, in today's
order. `Initializable` keeps its state in an ERC-7201 namespace and adds no
sequential slot. `Genesis` and the implementation both inherit the base, so
their layouts match by construction.

**Setters.** `setAllowedTarget`, `setOperator`, `setV4HookBlocked`,
`setAaveV2LendingPool` stay. `allowedFlashProviders` has no setter; `Genesis`
seeds it, and changing a provider later is an upgrade.

**Upgrade call.** A Safe transaction to the proxy's `ProxyAdmin`:
`upgradeAndCall(proxy, newImplementation, "")`. `script/PrepareUpgrade.s.sol`
deploys the new implementation with the live immutables and prints that
calldata plus the current implementation (the rollback target).

### 2. Layout and upgrade safety

Pinned layout today (`forge inspect … storageLayout`):

| slot | offset | ArbExecutor | LiquidationExecutor |
|---|---|---|---|
| 0 | 0 | `_owner` | `_owner` |
| 1 | 0 | `_pendingOwner` | `_pendingOwner` |
| 1 | 20 | `_paused` | `_paused` |
| 2 | 0 | `allowedFlashProviders` | `aaveV2LendingPool` |
| 3 | 0 | `allowedTargets` | `allowedFlashProviders` |
| 4 | 0 | `blockedV4Hooks` | `allowedTargets` |
| 5 | 0 | `operators` | `blockedV4Hooks` |
| 6 | 0 | — | `operators` |

- **Layout snapshot.** `layout/ArbExecutor.json` and
  `layout/LiquidationExecutor.json` hold that layout normalised to slot,
  offset, label and type. `script/check_layout.sh` runs in CI and fails when an
  existing entry changes, disappears or moves; appending is allowed. Updating a
  snapshot is a deliberate commit. The same script requires each `Genesis` to
  match its implementation exactly.
- **Fork gate before every mainnet upgrade** — no upgrade ships without it:
  1. **Arb landing replay.** Transaction `0xc444fb52…` (block 25 974 940,
     route v4>hashflow) replays from its pre-transaction state with proxy code
     etched onto the live address, delegating to the candidate implementation.
     The live storage already has the proxy's layout, and the live address is
     the one the signed Hashflow quote and the 1inch token are bound to. Its
     receipt holds a Uniswap V4 swap (the PoolManager calls the executor's
     `unlockCallback`) and two WETH `Withdrawal`s to the executor (ETH under the
     2300-gas stipend). It must succeed with the same balances as the bare
     implementation, and the gas difference is the proxy overhead — measured
     at 6 321 gas (arb profile); the owner set the 10 000-gas ceiling on
     2026-09-15.
  2. **Liquidation.** `test_fork_jackpot_unwrap_v4_curve_liquidate` — a real
     Aave V3 `liquidationCall` on a fork, then a WETH unwrap whose ETH lands in
     `receive`, a V4 swap and a Curve swap — runs through the proxy.
  3. **FLOKI `UniswapV2: K`** (`ForkDirectV2K`) through the proxy, proving #45
     and #46 on it. Its calldata comes from the `K_CALLDATA` environment
     variable and is not in the repository; without it the test skips, so it
     is a supplementary check rather than a required one.

  After the migration the same tests run against the deployed proxies.
- **Authority.** The `ProxyAdmin` owner and the executor owner are the same
  Safe. Implementations and `Genesis` contracts are locked
  (`_disableInitializers`). `initialize` runs once, inside the proxy
  constructor. Owner calls reach the implementation — the transparent proxy
  intercepts only calls from `ProxyAdmin`, which may call nothing but
  `upgradeToAndCall`.
- **Rollback.** Keep the previous implementation address; rollback is one Safe
  transaction back, valid while the layout has only been appended to (enforced
  by `check_layout.sh`).
- **Transient slots 0–17** are unchanged. The proxy uses no transient storage,
  and ERC-1967 slots are hashes that cannot meet the sequential layout.

### 3. One-time migration

This is the last address move, and it is the batch for #45 and #46 (neither is
deployed today; the live `ArbExecutor` predates #45).

1. **Contract PR:** storage bases, `Genesis`, `ExecutorProxy`, layout snapshots
   and `check_layout.sh`, the fork gate, and deploy scripts that deploy
   implementation → `Genesis` → proxy and extend today's read-back assertions
   with the `ProxyAdmin` owner, the ERC-1967 implementation slot, immutables,
   flash providers and every seeded entry. The first implementation includes
   #45 and #46.
2. **Mainnet deploy — owner's decision only.** `DeployArb.s.sol`
   (`FOUNDRY_PROFILE=arb`) and `Deploy.s.sol` (default profile). No Safe
   transaction is needed to finish a deploy.
3. **Fork gate against the deployed proxies.** No green, no cut-over.
4. **Resolver Access Token** minted to the arb proxy — the last mint.
5. **Cut-over in one launchd restart:** `.env` `ARB_EXECUTOR_ADDRESS` and
   `EXECUTOR_ADDRESS` switch to the proxies, and the bot is rebuilt from `main`
   with bot #611 at the same time (the V2 fee scale must match the executor at
   the same moment). `ARB_DIRECT_V2_SWAPS` stays off. Verify `Execution worker
   started` and `ONEINCH_RESOLVER_ACCESS held=true executor=<proxy>`.
6. **Old executors:** withdraw the dust (on 2026-09-14: arb 0.00249 WETH /
   0.098 USDC, liquidation 0.00051 WETH / 0.588 USDC) and `pause()` — Safe
   transactions. Not destroyed.
7. **Rollback** until landings through the proxy confirm it: restore the old
   addresses in `.env`, roll the bot back to the build before #611, `unpause()`
   the old executors.
8. **`ARB_DIRECT_V2_SWAPS`** is a separate step after the first proxy landings,
   on the owner's word.

### 4. Bot, gas, tests

**Bot.** No code is needed for the proxy itself; only the two `.env`
addresses change. Verified: the live path never reads executor bytecode
(`crate::simulation` is used only for its types), and liquidation gas comes
from simulation (`worker.rs`, `base_sim.gas_used`).

**Gas.** Arb gas comes from constants: `ARB_GAS_UNITS = 500_000` (profit
model), `ESTIMATED_GAS_PER_LEG = 175_000`, `ARB_GAS_LIMIT = 1_500_000`;
liquidation `EXECUTOR_GAS_LIMIT = 800_000`. The landing replay measures the
proxy overhead and fails above 10 000 gas (2% of `ARB_GAS_UNITS`) — measured
cold overhead is 6 321 gas (arb profile), and the owner set that ceiling on
2026-09-15; above it the bot constants move in the same change.

**Contract tests.**
1. The whole existing suite runs through the proxy: every construction goes
   through a test helper that deploys implementation + `Genesis` + proxy, so
   every test exercises delegation.
2. New unit tests: `Genesis` seeds the proxy and hands it to the
   implementation; `initialize` is one-shot and `Genesis` is locked; a zero
   owner is refused; implementations are ownerless and locked; the proxy's
   `receive` accepts ETH within the 2300-gas stipend; only the `ProxyAdmin`
   owner can upgrade; an upgrade preserves state and a rollback works; the
   `ProxyAdmin` cannot reach the executor.
3. `check_layout.sh` (snapshot; `Genesis` equals implementation).
4. `check_sizes.sh` unchanged — implementation sizes must not grow.
5. The fork gate.

**Bot tests.** The four `ci.yml` commands, only if the gas constants change.

## Process rule this design enables

A merged contract PR is not a reason to deploy. Each contract PR states
"needs upgrade: yes/no" and what it unblocks; upgrades are batched, go out on
the owner's word, and only after the fork gate is green.

## Decisions settled after review

- **Genesis seeding.** The deploy scripts build exactly the lists they build
  today (extra targets, Fluid pools, operators, blocked hooks) and pass them to
  `Genesis.initialize` in one call; `aaveV2LendingPool == address(0)` means
  none. Base targets and flash providers come from the implementation's
  immutables. The seeded values do not change.
- **Fork-gate replays.** No landing in the logs has a V3 pool calling the
  executor directly (the V3 legs that landed went through the router), so the
  arb replay is the V4 landing `0xc444fb52…`, where the PoolManager calls the
  executor. No liquidation has landed recently; the liquidation gate is the
  existing real-Aave fork test.
