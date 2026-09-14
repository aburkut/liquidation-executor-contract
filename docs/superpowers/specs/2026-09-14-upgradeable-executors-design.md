# Upgradeable executors — design

Date: 2026-09-14
Status: approved in discussion, pending written-spec review
Scope: `ArbExecutor` and `LiquidationExecutor`

## Problem

Every executor change ships as a new contract address. `ArbExecutor` moved
three times in three days — four addresses: `0xfC127EB8` → `0x726Eba4B` →
`0x79F55E2e` → `0x4d3AbD5d`, 2026-09-11..13. Each move costs deploy gas, an `.env` change, a
bot restart, re-seeding allowlists and operators, and a fresh Resolver Access
Token mint for the 1inch book.

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
is the priority; the owner accepts that the owner key can replace the code the
executor runs.

## Non-goals

- Lifting the EIP-170 ceiling. `LiquidationExecutor` has 380 bytes of room;
  that remains a separate problem, handled as today by moving code into
  libraries. The chosen design does not add bytes to either implementation and
  does not rule out a facet router behind the same proxy later.
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
   without a `DELEGATECALL`, so WETH9 `withdraw` (a 2300-gas `transfer`, used at
   `GenericSequenceLib` wrap/unwrap and `CoinbasePaymentLib.payCoinbase`) does
   not depend on proxy overhead. No behaviour is lost: both implementations'
   `receive` is empty today. The OZ v5 constructor deploys a `ProxyAdmin` owned
   by the owner EOA.
2. **Implementation** — today's `ArbExecutor` / `LiquidationExecutor`. The
   constructor keeps only immutables (WETH, routers, Balancer, Morpho, Aave) and
   calls `_disableInitializers()`. It no longer writes storage.
3. **`Genesis`** — a one-shot implementation whose runtime is only
   `initialize(owner, operators[], allowedTargets[], blockedV4Hooks[],
   flashProviders, aaveV2Pool)` guarded by `initializer`. The proxy is created
   pointing at `Genesis` with the `initialize` calldata (atomic), then upgraded
   to the real implementation.

   Why not `initialize` inside the implementation: initializer code is runtime
   code and `LiquidationExecutor` cannot absorb it. `SeededExecutors` already
   moved seeding out of runtime for the same reason.

**Shared storage base.** State variables move into `ArbExecutorStorage` /
`LiquidationExecutorStorage` — `Ownable2Step`, `Pausable`,
`ReentrancyGuardTransient` and the mappings, in today's order. `Genesis` and
the implementation both inherit it, so their layouts match by construction.
`Ownable` v5's constructor argument is satisfied in the implementation with a
non-zero placeholder (implementation storage is never used); `Genesis` sets the
real owner in proxy storage via `_transferOwnership`.

**Setters.** `setAllowedTarget`, `setOperator`, `setV4HookBlocked`,
`setAaveV2LendingPool` stay. `allowedFlashProviders` has no setter; `Genesis`
seeds it, and changing a provider later is an upgrade.

**Upgrade call.** `ProxyAdmin.upgradeAndCall(proxy, newImplementation, "")`.

### 2. Layout and upgrade safety

- **Layout snapshot.** `layout/ArbExecutor.json` and
  `layout/LiquidationExecutor.json` hold `forge inspect <C> storageLayout`
  normalised to label, slot, offset and type. `script/check_layout.sh` runs in
  CI and fails when an existing entry changes, disappears or moves; appending is
  allowed. Updating a snapshot is a deliberate commit. The same script checks
  that `Genesis` matches its implementation.
- **Fork gate before every mainnet upgrade.** A fork test takes the live proxy,
  deploys the candidate implementation, upgrades as the `ProxyAdmin` owner and
  asserts: owner, operators, allowlist entries, blocked hooks, flash providers,
  paused flag and token balances are unchanged; a recorded production plan
  replays through the proxy (as `ForkDirectV2K` does); ETH arrives through the
  proxy's `receive` for a WETH unwrap and a coinbase payment. No upgrade ships
  without it.
- **Authority.** The `ProxyAdmin` owner and the executor owner are the same
  EOA. Implementations are locked. `Genesis.initialize` runs once, atomically in
  the proxy constructor, so there is no uninitialised window; while the proxy
  still points at `Genesis` it cannot execute plans. Owner calls reach the
  implementation — the transparent proxy intercepts only `ProxyAdmin`.
- **Rollback.** Keep the previous implementation address; rollback is one
  `upgradeAndCall` back, valid while the layout has only been appended to
  (enforced by `check_layout.sh`).
- **Transient slots 0–17** are unchanged. The proxy uses no transient storage,
  and ERC-1967 slots are hashes that cannot meet the sequential layout.

### 3. One-time migration

This is the last address move, and it is the batch for #45 and #46 (neither is
deployed today; the live `ArbExecutor` predates #45).

1. **Contract PR:** storage bases, `Genesis`, `ExecutorProxy`, layout snapshots
   and `check_layout.sh`, the fork gate, and `DeployArbProxy` /
   `DeployLiqProxy`. The scripts extend today's read-back assertions with the
   `ProxyAdmin` owner, the ERC-1967 implementation slot and every seeded entry.
   The first implementation includes #45 and #46.
2. **Mainnet deploy — owner's decision only.** One run per executor: libraries
   → implementation → `Genesis` → proxy with `initialize` → `upgradeAndCall` →
   assertions.
3. **Fork gate against the deployed proxies.** No green, no cut-over.
4. **Resolver Access Token** minted by the owner to the arb proxy — the last
   mint.
5. **Cut-over in one launchd restart:** `.env` `ARB_EXECUTOR_ADDRESS` and
   `EXECUTOR_ADDRESS` switch to the proxies, and the bot is rebuilt from `main`
   with bot #611 at the same time (V2 fee scale must match the executor at the
   same moment). `ARB_DIRECT_V2_SWAPS` stays off. Verify `Execution worker
   started` and `ONEINCH_RESOLVER_ACCESS held=true executor=<proxy>`.
6. **Old executors:** withdraw the dust (on 2026-09-14: arb 0.00249 WETH /
   0.098 USDC, liquidation 0.00051 WETH / 0.588 USDC) and `pause()`. Not
   destroyed.
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
liquidation `EXECUTOR_GAS_LIMIT = 800_000`. The fork gate measures proxy
overhead on entry and per pool callback and records it in the PR. If it
exceeds 1% of `ARB_GAS_UNITS`, the constants are adjusted in the same change;
otherwise they are left alone.

**Contract tests.**
1. The whole existing suite (1893 tests) runs through the proxy: `setUp`
   deploys `Genesis` + proxy + `upgradeAndCall` instead of the bare contract,
   so every test exercises delegation.
2. New unit tests: `Genesis.initialize` is one-shot; implementations are
   locked; an upgrade preserves state and a rollback works; only the
   `ProxyAdmin` owner can upgrade; the proxy's `receive` accepts ETH from WETH9
   within the 2300-gas stipend.
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
  today (base targets, extra targets, Fluid pools, operators, blocked hooks)
  and pass them to `Genesis.initialize` in one call; `aaveV2Pool == address(0)`
  means none. Seeding moves from the constructor, `SeededExecutors` and
  `DeployArb.s.sol` into that one call; the seeded values do not change.
- **Fork-gate replays.** Three recorded production transactions, taken from
  landing logs: an arb landing with a V3 pool callback (a pool calls the proxy),
  a liquidation with a WETH unwrap and a coinbase payment (ETH arrives through
  the proxy), and the FLOKI `UniswapV2: K` revert already pinned by
  `ForkDirectV2K` (proves #45 and #46 on the proxy).
