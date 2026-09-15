# Upgradeable Executors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put `ArbExecutor` and `LiquidationExecutor` behind permanent ERC-1967 transparent proxies so any future code change ships as one Safe transaction instead of a new address.

**Architecture:** Persistent state moves into storage base contracts shared by the implementation and a one-shot `Genesis` implementation. `ExecutorProxy` (OZ `TransparentUpgradeableProxy` + a non-delegating `receive`) is constructed with `Genesis`; `Genesis.initialize` seeds the proxy and switches it to the real implementation inside the same constructor. A committed storage-layout snapshot and a fork gate (a real landing replayed through the proxy) guard every upgrade.

**Tech Stack:** Solidity 0.8.24 (`via_ir`), Foundry (forge/cast/anvil), OpenZeppelin Contracts v5.5.0 (vendored), Python 3 for the layout check.

**Spec:** `docs/superpowers/specs/2026-09-14-upgradeable-executors-design.md`

## Global Constraints

- Repository: `aburkut/liquidation-executor-contract`. Branch from `origin/main` once PR #46 is merged; until then branch from `origin/fix/fee-numerator-in-ten-thousandths` (the fee scale and `ForkDirectV2K._plan(bool)` come from #46).
- Compiler as configured: solc 0.8.24, `evm_version = "cancun"`, `via_ir = true`, `optimizer_runs = 1` (default profile). `ArbExecutor` deploys with `FOUNDRY_PROFILE=arb`; `LiquidationExecutor` with the default profile.
- No new dependency. OpenZeppelin v5.5.0 is already in `lib/openzeppelin-contracts`.
- Owner of both executors and of every `ProxyAdmin`: the Safe `0xC338094Bb79AA610E9c57166fc4FA959db6234Ab` (2-of-2).
- EIP-170: `script/check_sizes.sh 24200` stays green, and runtime sizes stay exactly at baseline (default profile): `LiquidationExecutor` 24196, `ArbExecutor` 14128.
- Storage layout is append-only. Today: ArbExecutor slots 0 `_owner`, 1 `_pendingOwner`, 1+20 `_paused`, 2 `allowedFlashProviders`, 3 `allowedTargets`, 4 `blockedV4Hooks`, 5 `operators`. LiquidationExecutor slots 0 `_owner`, 1 `_pendingOwner`, 1+20 `_paused`, 2 `aaveV2LendingPool`, 3 `allowedFlashProviders`, 4 `allowedTargets`, 5 `blockedV4Hooks`, 6 `operators`.
- Transient slots 0–17 (executors, `GenericSequenceLib`, `DirectSwapLib`) are not touched.
- No mainnet broadcast anywhere in this plan. Mainnet deploy and upgrades are the owner's decision (spec §3).
- Everything written to git or GitHub is in English. Every commit message ends with the session trailer; export it once per shell before committing (the commit commands below pass it as `-m "$TRAILER"`):
  ```bash
  export TRAILER="Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01PJjQdQZ9GedsSqtexqqWAX"
  ```
- Local gate = the CI steps in `.github/workflows/test.yml`: `forge fmt --check`, `forge build --sizes`, `script/check_sizes.sh 24200`, `script/check_layout.sh` (added in Task 1), `forge test -vvv`. Run builds and tests under `nice -n 19`: the live bot shares this machine, and a full `via_ir` build takes 25–35 minutes here.
- Fork tests use `MAINNET_RPC_URL=https://rpc-eth.blockmachine.io` (archive state verified at blocks 25 256 119, 25 971 663 and 25 974 939). Never the bot's production RPC key.
- `docs/` is gitignored since `forge init`; files under it are added with `git add -f`.

## File Structure

| path | status | responsibility |
|---|---|---|
| `script/layout_compare.py` | create | normalise `forge inspect storageLayout` JSON, compare with a snapshot (append-only or exact), or write it |
| `script/check_layout.sh` | create | run the comparison for both executors and both Genesis contracts; `--write` regenerates snapshots |
| `layout/ArbExecutor.json`, `layout/LiquidationExecutor.json` | create | committed layout snapshots |
| `.github/workflows/test.yml` | modify | run `check_layout.sh` in CI |
| `src/storage/ArbExecutorStorage.sol` | create | every persistent variable of an arb executor, in pinned order |
| `src/storage/LiquidationExecutorStorage.sol` | create | the same for the liquidator |
| `src/ArbExecutor.sol`, `src/LiquidationExecutor.sol` | modify | inherit the storage base; constructor becomes immutables-only and locked |
| `src/proxy/ExecutorProxy.sol` | create | permanent address: transparent proxy + non-delegating `receive` |
| `src/proxy/ArbExecutorGenesis.sol` | create | one-shot initializer for an arb proxy; hands over to the implementation |
| `src/proxy/LiquidationExecutorGenesis.sol` | create | the same for the liquidator |
| `test/support/ExecutorDeploy.sol` | create | test helper: implementation + Genesis + proxy behind the old constructor argument lists |
| `test/support/LiquidationExecutorHarness.sol` | modify | constructor follows the implementation's |
| `test/ExecutorProxy.t.sol` | create | unit tests for proxy, Genesis, locking, upgrade and rollback |
| `test/ArbExecutor.t.sol`, `test/ArbExecutorFork.t.sol`, `test/ArbExecutorSecurity.t.sol`, `test/Executor.t.sol`, `test/fork/ExecutorForkV4.t.sol` | modify | construct through `ExecutorDeploy` |
| `foundry.toml` | modify | read permission for `test/fixtures` |
| `test/fixtures/landing_c444fb52.hex` | create | calldata of the landing replayed by the fork gate |
| `test/support/ProxyEtch.sol` | create | fork helper: proxy code at a live executor address |
| `test/fork/ProxyReplay.t.sol` | create | fork gate: the landing through the proxy vs the bare implementation, gas overhead |
| `test/ForkDirectV2K.t.sol` | modify | the FLOKI plan through the proxy |
| `script/DeployArb.s.sol`, `script/Deploy.s.sol` | modify | deploy implementation + Genesis + proxy; extended read-backs |
| `script/PrepareUpgrade.s.sol` | create | deploy a new implementation with live immutables; print the Safe calldata |
| `src/deploy/SeededExecutors.sol` | delete | replaced by Genesis |
| `.github/pull_request_template.md` | create | "Needs upgrade" section |

---

### Task 1: Storage layout snapshot and CI check

**Files:**
- Create: `script/layout_compare.py`
- Create: `script/check_layout.sh`
- Create: `layout/ArbExecutor.json`, `layout/LiquidationExecutor.json` (generated)
- Modify: `.github/workflows/test.yml` (after the "Check executor sizes" step)

**Interfaces:**
- Produces: `script/check_layout.sh` (no args = check, exit 1 on violation; `--write` = regenerate). `script/layout_compare.py <snapshot.json> <ContractName> [--write|--exact]` reading `forge inspect <C> storageLayout --json` on stdin. Later tasks add Genesis lines using `--exact`.

- [ ] **Step 1: Write the comparator**

`script/layout_compare.py`:

```python
#!/usr/bin/env python3
"""Compare a contract's storage layout with its committed snapshot.

    forge inspect <C> storageLayout --json | layout_compare.py <snapshot> <C> [--write|--exact]

Default mode is append-only: every snapshot entry must still be at the same
index with the same slot, offset, label and type; new entries may follow.
`--exact` also refuses appended entries (a Genesis must equal its
implementation). `--write` replaces the snapshot with the current layout.

An executor behind a proxy keeps its storage across implementations, so a
moved or retyped variable silently reads another variable's bytes. This check
is the only thing standing between an upgrade and that.
"""
import json
import sys


def normalise(raw: str) -> list:
    data = json.loads(raw)
    types = data.get("types") or {}
    return [
        {
            "slot": str(entry["slot"]),
            "offset": int(entry["offset"]),
            "label": entry["label"],
            "type": types.get(entry["type"], {}).get("label", entry["type"]),
        }
        for entry in data["storage"]
    ]


def main() -> int:
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        print(__doc__)
        return 2
    snapshot_path, name = args
    current = normalise(sys.stdin.read())

    if "--write" in flags:
        with open(snapshot_path, "w") as f:
            json.dump(current, f, indent=2)
            f.write("\n")
        print(f"wrote {snapshot_path}: {len(current)} entries from {name}")
        return 0

    with open(snapshot_path) as f:
        snapshot = json.load(f)

    bad = False
    for i, want in enumerate(snapshot):
        got = current[i] if i < len(current) else None
        if got != want:
            print(f"!! {name}: entry {i} was {want}, now {got}")
            bad = True
    extra = current[len(snapshot):]
    if "--exact" in flags and extra:
        print(f"!! {name}: {len(extra)} entries beyond {snapshot_path}: {extra}")
        bad = True
    if bad:
        return 1
    note = f", {len(extra)} appended" if extra else ""
    print(f"ok {name}: {len(snapshot)} entries match {snapshot_path}{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Write the check script**

`script/check_layout.sh`:

```bash
#!/usr/bin/env bash
# Storage-layout guard for the upgradeable executors (see layout_compare.py).
#
#   script/check_layout.sh           check against layout/*.json (CI)
#   script/check_layout.sh --write   regenerate the snapshots — a reviewed commit
#
# Expects a prior `forge build` (CI runs it first); `forge inspect` reuses the cache.
set -euo pipefail
cd "$(dirname "$0")/.."

layout() {
  forge inspect "$1" storageLayout --json 2>/dev/null
}

if [ "${1:-}" = "--write" ]; then
  layout ArbExecutor | python3 script/layout_compare.py layout/ArbExecutor.json ArbExecutor --write
  layout LiquidationExecutor | python3 script/layout_compare.py layout/LiquidationExecutor.json LiquidationExecutor --write
  exit 0
fi

status=0
layout ArbExecutor | python3 script/layout_compare.py layout/ArbExecutor.json ArbExecutor || status=1
layout LiquidationExecutor | python3 script/layout_compare.py layout/LiquidationExecutor.json LiquidationExecutor || status=1
exit $status
```

Run: `chmod +x script/check_layout.sh script/layout_compare.py && mkdir -p layout`

- [ ] **Step 3: Generate the snapshots from the unchanged code**

Run: `nice -n 19 forge build && script/check_layout.sh --write`
Expected:
```
wrote layout/ArbExecutor.json: 7 entries from ArbExecutor
wrote layout/LiquidationExecutor.json: 8 entries from LiquidationExecutor
```

- [ ] **Step 4: Verify the snapshots are the pinned layout**

Run: `cat layout/ArbExecutor.json`
Expected (exactly):
```json
[
  {
    "slot": "0",
    "offset": 0,
    "label": "_owner",
    "type": "address"
  },
  {
    "slot": "1",
    "offset": 0,
    "label": "_pendingOwner",
    "type": "address"
  },
  {
    "slot": "1",
    "offset": 20,
    "label": "_paused",
    "type": "bool"
  },
  {
    "slot": "2",
    "offset": 0,
    "label": "allowedFlashProviders",
    "type": "mapping(uint8 => address)"
  },
  {
    "slot": "3",
    "offset": 0,
    "label": "allowedTargets",
    "type": "mapping(address => bool)"
  },
  {
    "slot": "4",
    "offset": 0,
    "label": "blockedV4Hooks",
    "type": "mapping(address => bool)"
  },
  {
    "slot": "5",
    "offset": 0,
    "label": "operators",
    "type": "mapping(address => bool)"
  }
]
```
Run: `python3 -c "import json; print([(e['slot'], e['offset'], e['label']) for e in json.load(open('layout/LiquidationExecutor.json'))])"`
Expected: `[('0', 0, '_owner'), ('1', 0, '_pendingOwner'), ('1', 20, '_paused'), ('2', 0, 'aaveV2LendingPool'), ('3', 0, 'allowedFlashProviders'), ('4', 0, 'allowedTargets'), ('5', 0, 'blockedV4Hooks'), ('6', 0, 'operators')]`

- [ ] **Step 5: Check passes on unchanged code**

Run: `script/check_layout.sh; echo exit=$?`
Expected:
```
ok ArbExecutor: 7 entries match layout/ArbExecutor.json
ok LiquidationExecutor: 8 entries match layout/LiquidationExecutor.json
exit=0
```

- [ ] **Step 6: Prove the check fails on a moved variable**

Run:
```bash
python3 -c "import json; d=json.load(open('layout/ArbExecutor.json')); d[3], d[4] = d[4], d[3]; json.dump(d, open('/tmp/layout_swapped.json', 'w'))"
forge inspect ArbExecutor storageLayout --json 2>/dev/null | python3 script/layout_compare.py /tmp/layout_swapped.json ArbExecutor; echo exit=$?
```
Expected: two lines starting `!! ArbExecutor: entry 3` and `!! ArbExecutor: entry 4`, then `exit=1`.

- [ ] **Step 7: Run it in CI**

In `.github/workflows/test.yml`, directly after

```yaml
      - name: Check executor sizes against the EIP-170 threshold
        run: script/check_sizes.sh 24200
```

insert

```yaml

      - name: Check executor storage layouts against the committed snapshots
        run: script/check_layout.sh
```

- [ ] **Step 8: Commit**

```bash
git add script/layout_compare.py script/check_layout.sh layout/ArbExecutor.json layout/LiquidationExecutor.json .github/workflows/test.yml
git commit -m "ci: pin the executors' storage layout before they go behind a proxy" -m "$TRAILER"
```

---

### Task 2: Extract storage base contracts (pure refactor)

**Files:**
- Create: `src/storage/ArbExecutorStorage.sol`
- Create: `src/storage/LiquidationExecutorStorage.sol`
- Modify: `src/ArbExecutor.sol` (imports; contract header; `// ─── Storage ───` block, today lines 158–203)
- Modify: `src/LiquidationExecutor.sol` (imports; contract header; `// ─── State ───` block, today lines 230–265)

**Interfaces:**
- Produces: `abstract contract ArbExecutorStorage is Ownable2Step, Pausable, ReentrancyGuardTransient, Initializable` with `allowedFlashProviders`, `allowedTargets`, `blockedV4Hooks`, `operators` (all `public`). `abstract contract LiquidationExecutorStorage` with the same bases and `aaveV2LendingPool` first, then the four mappings. Neither has a constructor; inheritors pass `Ownable(...)`.

- [ ] **Step 1: Create `src/storage/ArbExecutorStorage.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title ArbExecutor persistent storage
/// @notice Every persistent variable an arb executor proxy holds, in the order
/// `layout/ArbExecutor.json` pins. `ArbExecutor` and `ArbExecutorGenesis` both
/// inherit it, so the implementation and its initializer cannot disagree about
/// a slot. APPEND ONLY: `script/check_layout.sh` fails CI on any other change.
/// `Initializable` keeps its state in an ERC-7201 namespace and adds no
/// sequential slot; `ReentrancyGuardTransient` uses transient storage.
abstract contract ArbExecutorStorage is Ownable2Step, Pausable, ReentrancyGuardTransient, Initializable {
    mapping(uint8 => address) public allowedFlashProviders;
    /// @dev Generic allowlist for Bebop settlement / future protocol
    /// targets that need owner-curated trust. Uni V2/V3 routers are
    /// constructor-immutable; Curve / Balancer pool addresses are
    /// trusted from the bot (sanity-gated inside their libraries).
    mapping(address => bool) public allowedTargets;
    /// @dev V4 hook BLOCKlist (parity with LiquidationExecutor). Any hook is
    /// accepted unless the owner has blocked it; `unlockCallback` re-checks.
    ///
    /// This used to be an ALLOWlist, curated one owner transaction per hook.
    /// It was dropped for the reason the Curve/Balancer target allowlist was
    /// dropped before it (see LiquidationExecutor's `allowedTargets` notes):
    /// the bot is the trusted source of pools, and a hostile hook can only
    /// make the transaction revert, not take standing funds. What bounds it:
    /// v4-core caps a `beforeSwap` delta at the swap's own amount
    /// (`HookDeltaExceedsSwapAmount`), `runV4UnlockSwap` reverts on any
    /// delta with the wrong sign, `owedIn` is read from the delta rather
    /// than the plan, and `runArb` ends in `checkProfitStrict`, which
    /// refuses a cycle that ended below where it started whatever the
    /// plan's floor says (a zero floor included). The blocklist remains for
    /// a hook that reverts on us on purpose (gas griefing), which no floor
    /// can see.
    mapping(address => bool) public blockedV4Hooks;
    /// @dev Operator allowlist. Several operator EOAs may drive ONE executor
    /// so sends spread over independent nonce streams — one stuck tx then
    /// cannot jam the others, and same-nonce bid fan-out does not have to
    /// fight its own replacements. Owner-curated: an operator key is hot, so
    /// it may only SPEND under the containment caps, never move standing
    /// funds (`withdraw` is onlyOwner).
    mapping(address => bool) public operators;
}
```

- [ ] **Step 2: Create `src/storage/LiquidationExecutorStorage.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title LiquidationExecutor persistent storage
/// @notice Every persistent variable a liquidation executor proxy holds, in the
/// order `layout/LiquidationExecutor.json` pins. `LiquidationExecutor` and
/// `LiquidationExecutorGenesis` both inherit it. APPEND ONLY:
/// `script/check_layout.sh` fails CI on any other change. `Initializable` keeps
/// its state in an ERC-7201 namespace and adds no sequential slot.
abstract contract LiquidationExecutorStorage is Ownable2Step, Pausable, ReentrancyGuardTransient, Initializable {
    address public aaveV2LendingPool;
    mapping(uint8 => address) public allowedFlashProviders;
    mapping(address => bool) public allowedTargets;
    /// @dev Owner-curated V4 hook blocklist. Hooks run arbitrary code inside
    /// `beforeSwap`/`afterSwap`; a blocked hook makes a V4 leg revert.
    mapping(address => bool) public blockedV4Hooks;
    /// @dev Operator allowlist. Several operator EOAs may drive ONE executor
    /// so sends spread over independent nonce streams — one stuck tx then
    /// cannot jam the others, and same-nonce bid fan-out does not have to
    /// fight its own replacements. Owner-curated: an operator key is hot, so
    /// it may only SPEND under the containment caps, never move standing
    /// funds.
    mapping(address => bool) public operators;
}
```

- [ ] **Step 3: Rewire `ArbExecutor`**

Add after `import {Op} from "./types/SwapTypes.sol";`:

```solidity
import {ArbExecutorStorage} from "./storage/ArbExecutorStorage.sol";
```

Replace the contract header

```solidity
contract ArbExecutor is
    Ownable2Step,
    Pausable,
    ReentrancyGuardTransient,
    IFlashLoanRecipient,
    IMorphoFlashLoanCallback,
    IUnlockCallback
{
```

with

```solidity
contract ArbExecutor is ArbExecutorStorage, IFlashLoanRecipient, IMorphoFlashLoanCallback, IUnlockCallback {
```

Replace the whole block from the line `    // ─── Storage ─────────────────────────────────────────────────────` through the line `    mapping(address => bool) public operators;` (inclusive) with:

```solidity
    // ─── Storage ─────────────────────────────────────────────────────
    // Persistent state lives in `ArbExecutorStorage`; this contract adds none.
    /// @dev The two flash providers are constructor-pinned and read on the
    /// hot path (provider dispatch, callback caller checks): immutables cost
    /// nothing to read where a storage slot costs 2.1k cold. The
    /// `allowedFlashProviders` mapping stays for the ABI (getter, deploy
    /// read-backs) and is written once, at initialization.
    address public immutable morphoBlue;
    address public immutable balancerVault;
```

Leave the `Ownable2Step, Ownable`, `Pausable` and `ReentrancyGuardTransient` imports in place (`Ownable` is still named by the constructor).

- [ ] **Step 4: Rewire `LiquidationExecutor`**

Add next to the other `./` imports:

```solidity
import {LiquidationExecutorStorage} from "./storage/LiquidationExecutorStorage.sol";
```

In the contract header replace the three bases `Ownable2Step`, `Pausable`, `ReentrancyGuardTransient` with the single base `LiquidationExecutorStorage`, keeping `IFlashLoanRecipient, IMorphoFlashLoanCallback, IUnlockCallback` after it:

```solidity
contract LiquidationExecutor is
    LiquidationExecutorStorage,
    IFlashLoanRecipient,
    IMorphoFlashLoanCallback,
    IUnlockCallback
{
```

Replace the whole block from `    // ─── State ───────────────────────────────────────────────────────` through `    mapping(address => bool) public operators;` (inclusive) with:

```solidity
    // ─── State ───────────────────────────────────────────────────────
    // Persistent state lives in `LiquidationExecutorStorage`; this contract
    // adds none.
    address public immutable weth;
    /// @dev Constructor-pinned (no setters): immutables read for free where a
    /// storage slot cost 2.1k cold on every liquidation / repayment / swap.
    address public immutable aavePool;
    address public immutable morphoBlue;
    address public immutable paraswapAugustusV6;
    /// @dev Immutable — canonical Uniswap V2 Router02 (mainnet
    /// 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D). Rotating requires an
    /// upgrade.
    address public immutable uniV2Router;
    /// @dev Immutable — canonical Uniswap V3 SwapRouter02 (mainnet
    /// 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45). SwapRouter02 struct omits
    /// deadline; the executor enforces its own via the per-leg `leg.deadline`
    /// field on `SwapLeg`.
    address public immutable uniV3Router;
```

- [ ] **Step 5: Build, format, check layout and sizes**

Run: `forge fmt && nice -n 19 forge build --sizes 2>&1 | grep -E '^\| (ArbExecutor|LiquidationExecutor) ' && script/check_sizes.sh 24200 && script/check_layout.sh`
Expected:
```
| ArbExecutor                                            | 14,128 | ...
| LiquidationExecutor                                    | 24,196 | ...
ok LiquidationExecutor: 24196 bytes runtime, 380 under EIP-170, threshold 24200
ok ArbExecutor: 14128 bytes runtime, 10448 under EIP-170, threshold 24200
ok ArbExecutor: 7 entries match layout/ArbExecutor.json
ok LiquidationExecutor: 8 entries match layout/LiquidationExecutor.json
```
If a size differs from 14128 / 24196, or any layout line starts with `!!`, stop: the refactor moved something.

- [ ] **Step 6: Full suite unchanged**

Run: `nice -n 19 forge test 2>&1 | tail -3`
Expected: `... tests passed, 0 failed ...` with the same passed count as `origin/main`'s CI.

- [ ] **Step 7: Commit**

```bash
git add src/storage src/ArbExecutor.sol src/LiquidationExecutor.sol
git commit -m "refactor: move the executors' persistent state into storage base contracts" -m "Layout and runtime size are unchanged (check_layout.sh, check_sizes.sh)." -m "$TRAILER"
```

---

### Task 3: `ExecutorProxy`, the Genesis contracts, and the test helper

**Files:**
- Create: `src/proxy/ExecutorProxy.sol`
- Create: `src/proxy/ArbExecutorGenesis.sol`
- Create: `src/proxy/LiquidationExecutorGenesis.sol`
- Create: `test/support/ExecutorDeploy.sol`
- Create: `test/ExecutorProxy.t.sol`
- Modify: `script/check_layout.sh`

**Interfaces:**
- Consumes: `ArbExecutorStorage`, `LiquidationExecutorStorage` (Task 2).
- Produces:
  - `contract ExecutorProxy is TransparentUpgradeableProxy` — `constructor(address genesis, address initialOwner, bytes memory initData)`; `receive() external payable`.
  - `contract ArbExecutorGenesis is ArbExecutorStorage` — `function initialize(address owner_, address[] memory operators_, address[] memory allowedTargets_, address[] memory blockedV4Hooks_, address implementation) external`; errors `ZeroAddress()`, `NoOperators()`.
  - `contract LiquidationExecutorGenesis is LiquidationExecutorStorage` — `function initialize(address owner_, address[] memory operators_, address[] memory allowedTargets_, address[] memory blockedV4Hooks_, address balancerVault_, address aaveV2LendingPool_, address implementation) external`; errors `ZeroAddress()`, `NoOperators()`, `TargetNotAllowed()`.
  - `library ExecutorDeploy` — `arb(owner_, operator_, weth_, balancerVault_, morpho_, paraswapAugustus_, uniV2Router_, uniV3Router_, address[] allowedTargets_) returns (ArbExecutor)`; `arbProxy(address implementation, address owner_, address operator_, address[] allowedTargets_) returns (ArbExecutor)`; `liquidation(owner_, operator_, weth_, aavePool_, balancerVault_, morpho_, paraswapAugustus_, uniV2Router_, uniV3Router_, address[] allowedTargets_) returns (LiquidationExecutor)`; `liquidationHarness(...same...) returns (LiquidationExecutorHarness)`; `liquidationProxy(address implementation, address owner_, address operator_, address balancerVault_, address[] allowedTargets_) returns (address)`.

- [ ] **Step 1: Write the failing unit tests**

`test/ExecutorProxy.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ArbExecutor} from "../src/ArbExecutor.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {ArbExecutorGenesis} from "../src/proxy/ArbExecutorGenesis.sol";
import {LiquidationExecutorGenesis} from "../src/proxy/LiquidationExecutorGenesis.sol";
import {ExecutorProxy} from "../src/proxy/ExecutorProxy.sol";
import {ExecutorDeploy} from "./support/ExecutorDeploy.sol";

contract ExecutorProxyTest is Test {
    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address weth = makeAddr("weth");
    address balancer = makeAddr("balancer");
    address morpho = makeAddr("morpho");
    address paraswap = makeAddr("paraswap");
    address v2 = makeAddr("v2");
    address v3 = makeAddr("v3");
    address aave = makeAddr("aave");
    address venue = makeAddr("venue");

    // ─── helpers ──────────────────────────────────────────────────────

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    /// Changes shape in Task 5 (immutables-only constructor).
    function _arbImpl() internal returns (ArbExecutor) {
        return new ArbExecutor(owner, operator, weth, balancer, morpho, paraswap, v2, v3, new address[](0));
    }

    /// Changes shape in Task 5 (immutables-only constructor).
    function _liqImpl() internal returns (LiquidationExecutor) {
        return new LiquidationExecutor(owner, operator, weth, aave, balancer, morpho, paraswap, v2, v3, new address[](0));
    }

    function _arb() internal returns (ArbExecutor) {
        return ExecutorDeploy.arbProxy(address(_arbImpl()), owner, operator, _one(venue));
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _adminOf(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT)))));
    }

    // ─── arb ──────────────────────────────────────────────────────────

    function test_arbGenesis_seedsTheProxyAndHandsItToTheImplementation() public {
        ArbExecutor exec = _arb();
        assertEq(exec.owner(), owner);
        assertTrue(exec.operators(operator));
        assertTrue(exec.allowedTargets(venue));
        assertTrue(exec.allowedTargets(balancer));
        assertTrue(exec.allowedTargets(paraswap));
        assertTrue(exec.allowedTargets(v2));
        assertTrue(exec.allowedTargets(v3));
        assertFalse(exec.allowedTargets(morpho), "the arb executor never allowlists Morpho as a target");
        assertEq(exec.allowedFlashProviders(2), balancer);
        assertEq(exec.allowedFlashProviders(3), morpho);
        assertEq(exec.weth(), weth, "immutables come from the implementation");
        assertEq(_adminOf(address(exec)).owner(), owner, "ProxyAdmin belongs to the executor owner");
        address impl = _implementationOf(address(exec));
        assertEq(ArbExecutor(payable(impl)).balancerVault(), balancer, "the slot holds the implementation, not Genesis");
    }

    function test_genesis_isOneShot() public {
        ArbExecutor exec = _arb();
        address impl = _implementationOf(address(exec));
        // Through the proxy there is no initializer left: it runs the implementation.
        vm.expectRevert();
        ArbExecutorGenesis(address(exec)).initialize(owner, _one(operator), new address[](0), new address[](0), impl);
        // A Genesis contract used directly is locked.
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        genesis.initialize(owner, _one(operator), new address[](0), new address[](0), impl);
    }

    function test_arbGenesis_refusesAZeroOwner() public {
        ArbExecutor impl = _arbImpl();
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        bytes memory init = abi.encodeCall(
            ArbExecutorGenesis.initialize, (address(0), _one(operator), new address[](0), new address[](0), address(impl))
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ExecutorProxy(address(genesis), owner, init);
    }

    function test_arbGenesis_refusesNoOperators() public {
        ArbExecutor impl = _arbImpl();
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        bytes memory init = abi.encodeCall(
            ArbExecutorGenesis.initialize, (owner, new address[](0), new address[](0), new address[](0), address(impl))
        );
        vm.expectRevert(ArbExecutorGenesis.NoOperators.selector);
        new ExecutorProxy(address(genesis), owner, init);
    }

    function test_proxy_acceptsEthWithinTheTransferStipend() public {
        ArbExecutor exec = _arb();
        vm.deal(address(this), 1 ether);
        // `transfer` forwards 2300 gas — exactly what WETH9.withdraw pays with.
        payable(address(exec)).transfer(1 ether);
        assertEq(address(exec).balance, 1 ether);
    }

    function test_onlyTheProxyAdminOwnerUpgrades() public {
        ArbExecutor exec = _arb();
        address before = _implementationOf(address(exec));
        ArbExecutor next = _arbImpl();
        ProxyAdmin admin = _adminOf(address(exec));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(exec)), address(next), "");

        // The owner calling the proxy directly reaches the implementation, which has no upgrade entry point.
        vm.prank(owner);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(exec)).upgradeToAndCall(address(next), "");

        assertEq(_implementationOf(address(exec)), before);
    }

    function test_upgradeKeepsStateAndRollsBack() public {
        ArbExecutor exec = _arb();
        address first = _implementationOf(address(exec));
        ArbExecutor next = _arbImpl();
        ProxyAdmin admin = _adminOf(address(exec));

        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(exec)), address(next), "");
        assertEq(_implementationOf(address(exec)), address(next));
        assertEq(exec.owner(), owner);
        assertTrue(exec.operators(operator));
        assertTrue(exec.allowedTargets(venue));

        address added = makeAddr("added");
        vm.prank(owner);
        exec.setAllowedTarget(added, true);

        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(exec)), first, "");
        assertEq(_implementationOf(address(exec)), first);
        assertTrue(exec.allowedTargets(added), "state written under one implementation survives the rollback");
    }

    function test_proxyAdminCannotReachTheExecutor() public {
        ArbExecutor exec = _arb();
        vm.prank(address(_adminOf(address(exec))));
        vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
        exec.owner();
    }

    // ─── liquidation ──────────────────────────────────────────────────

    function test_liqGenesis_seedsTheProxy() public {
        LiquidationExecutor exec = LiquidationExecutor(
            payable(ExecutorDeploy.liquidationProxy(address(_liqImpl()), owner, operator, balancer, _one(venue)))
        );
        assertEq(exec.owner(), owner);
        assertTrue(exec.operators(operator));
        assertTrue(exec.allowedTargets(venue));
        assertTrue(exec.allowedTargets(aave));
        assertTrue(exec.allowedTargets(balancer));
        assertTrue(exec.allowedTargets(morpho), "the liquidator allowlists Morpho, as it always did");
        assertTrue(exec.allowedTargets(paraswap));
        assertTrue(exec.allowedTargets(v2));
        assertTrue(exec.allowedTargets(v3));
        assertEq(exec.allowedFlashProviders(2), balancer);
        assertEq(exec.allowedFlashProviders(3), morpho);
        assertEq(exec.aaveV2LendingPool(), address(0));
        assertEq(exec.aavePool(), aave);
        assertEq(_adminOf(address(exec)).owner(), owner);
    }

    function test_liqGenesis_setsAnAllowlistedAaveV2Pool() public {
        address v2Pool = makeAddr("aaveV2");
        LiquidationExecutor impl = _liqImpl();
        bytes memory init = abi.encodeCall(
            LiquidationExecutorGenesis.initialize,
            (owner, _one(operator), _one(v2Pool), new address[](0), balancer, v2Pool, address(impl))
        );
        LiquidationExecutor exec = LiquidationExecutor(
            payable(address(new ExecutorProxy(address(new LiquidationExecutorGenesis()), owner, init)))
        );
        assertEq(exec.aaveV2LendingPool(), v2Pool);
    }

    function test_liqGenesis_refusesAnAaveV2PoolThatIsNotATarget() public {
        address v2Pool = makeAddr("aaveV2");
        LiquidationExecutor impl = _liqImpl();
        LiquidationExecutorGenesis genesis = new LiquidationExecutorGenesis();
        bytes memory init = abi.encodeCall(
            LiquidationExecutorGenesis.initialize,
            (owner, _one(operator), new address[](0), new address[](0), balancer, v2Pool, address(impl))
        );
        vm.expectRevert(LiquidationExecutorGenesis.TargetNotAllowed.selector);
        new ExecutorProxy(address(genesis), owner, init);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 19 forge test --match-path test/ExecutorProxy.t.sol 2>&1 | tail -5`
Expected: compilation error — `Source "src/proxy/ArbExecutorGenesis.sol" not found` (or equivalent for the other new files).

- [ ] **Step 3: Create `src/proxy/ExecutorProxy.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title The permanent address of an executor
/// @notice OpenZeppelin's transparent proxy — the upgrade logic lives here, so
/// the implementation's EIP-170 budget is untouched, and the constructor
/// deploys a `ProxyAdmin` owned by `initialOwner` — plus a `receive` that
/// accepts ETH without delegating.
/// @dev WETH9.withdraw pays with `transfer`, which forwards 2300 gas. Accepting
/// plain ETH here keeps every unwrap independent of what a delegatecall costs.
/// Nothing is lost today: both executors' own `receive` is empty. The trade is
/// that no future implementation can run logic on plain ETH receipt.
///
/// `genesis` must be an `*ExecutorGenesis` and `initData` a call to its
/// `initialize`, which seeds this proxy's storage and switches it to the real
/// implementation before this constructor returns.
contract ExecutorProxy is TransparentUpgradeableProxy {
    constructor(address genesis, address initialOwner, bytes memory initData)
        TransparentUpgradeableProxy(genesis, initialOwner, initData)
    {}

    receive() external payable {}
}
```

- [ ] **Step 4: Create `src/proxy/ArbExecutorGenesis.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ArbExecutorStorage} from "../storage/ArbExecutorStorage.sol";

/// The immutables an arb implementation exposes; Genesis seeds from them so the
/// allowlist cannot drift from the code it sits behind.
interface IArbExecutorImmutables {
    function balancerVault() external view returns (address);
    function morphoBlue() external view returns (address);
    function paraswapAugustusV6() external view returns (address);
    function uniV2Router() external view returns (address);
    function uniV3Router() external view returns (address);
    function FLASH_PROVIDER_BALANCER() external view returns (uint8);
    function FLASH_PROVIDER_MORPHO() external view returns (uint8);
}

/// @title One-shot first implementation of an arb executor proxy
/// @notice `ExecutorProxy` is constructed pointing here with a call to
/// `initialize`. Running inside the proxy's constructor, `initialize` seeds the
/// proxy's storage — what `ArbExecutor`'s constructor and `ArbExecutorSeeded`
/// used to write — and, as its last step, points the proxy at the real
/// implementation. The proxy never serves a call while on Genesis.
/// @dev Errors and events repeat the executor's signatures, so selectors and
/// topics match what the executor and its tests already use.
contract ArbExecutorGenesis is ArbExecutorStorage {
    error ZeroAddress();
    error NoOperators();

    event OperatorUpdated(address indexed operator, bool allowed);
    event V4HookBlockedUpdated(address indexed hook, bool blocked);

    /// This contract's own storage is never used.
    constructor() Ownable(address(0xdEaD)) {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address[] memory operators_,
        address[] memory allowedTargets_,
        address[] memory blockedV4Hooks_,
        address implementation
    ) external initializer {
        if (owner_ == address(0)) revert OwnableInvalidOwner(address(0));
        if (operators_.length == 0) revert NoOperators();
        _transferOwnership(owner_);

        for (uint256 i = 0; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
            operators[operators_[i]] = true;
            emit OperatorUpdated(operators_[i], true);
        }

        IArbExecutorImmutables impl = IArbExecutorImmutables(implementation);
        address balancerVault_ = impl.balancerVault();
        allowedFlashProviders[impl.FLASH_PROVIDER_BALANCER()] = balancerVault_;
        allowedFlashProviders[impl.FLASH_PROVIDER_MORPHO()] = impl.morphoBlue();
        // Balancer Vault doubles as a swap venue in cross-venue routing, so a
        // generic `Op` may target it. Morpho Blue is deliberately NOT a target:
        // the flash-repay path reaches it only through `allowedFlashProviders`,
        // and allowlisting it would expose its whole surface as an `Op` target.
        allowedTargets[balancerVault_] = true;
        allowedTargets[impl.paraswapAugustusV6()] = true;
        allowedTargets[impl.uniV2Router()] = true;
        allowedTargets[impl.uniV3Router()] = true;

        for (uint256 i = 0; i < allowedTargets_.length; ++i) {
            if (allowedTargets_[i] == address(0)) revert ZeroAddress();
            allowedTargets[allowedTargets_[i]] = true;
        }
        for (uint256 i = 0; i < blockedV4Hooks_.length; ++i) {
            if (blockedV4Hooks_[i] == address(0)) revert ZeroAddress();
            blockedV4Hooks[blockedV4Hooks_[i]] = true;
            emit V4HookBlockedUpdated(blockedV4Hooks_[i], true);
        }

        ERC1967Utils.upgradeToAndCall(implementation, "");
    }
}
```

- [ ] **Step 5: Create `src/proxy/LiquidationExecutorGenesis.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {LiquidationExecutorStorage} from "../storage/LiquidationExecutorStorage.sol";

/// The immutables a liquidation implementation exposes. It keeps no Balancer
/// immutable, so the vault is an `initialize` parameter.
interface ILiquidationExecutorImmutables {
    function aavePool() external view returns (address);
    function morphoBlue() external view returns (address);
    function paraswapAugustusV6() external view returns (address);
    function uniV2Router() external view returns (address);
    function uniV3Router() external view returns (address);
    function FLASH_PROVIDER_BALANCER() external view returns (uint8);
    function FLASH_PROVIDER_MORPHO() external view returns (uint8);
}

/// @title One-shot first implementation of a liquidation executor proxy
/// @notice Same shape as `ArbExecutorGenesis`: seeds the proxy's storage inside
/// its constructor — what `LiquidationExecutor`'s constructor and
/// `LiquidationExecutorSeeded` used to write — then points it at the real
/// implementation.
contract LiquidationExecutorGenesis is LiquidationExecutorStorage {
    error ZeroAddress();
    error NoOperators();
    error TargetNotAllowed();

    event OperatorUpdated(address indexed operator, bool allowed);
    event V4HookBlockedUpdated(address indexed hook, bool blocked);
    event ConfigUpdated(bytes32 indexed key, address indexed oldValue, address indexed newValue);

    /// This contract's own storage is never used.
    constructor() Ownable(address(0xdEaD)) {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address[] memory operators_,
        address[] memory allowedTargets_,
        address[] memory blockedV4Hooks_,
        address balancerVault_,
        address aaveV2LendingPool_,
        address implementation
    ) external initializer {
        if (owner_ == address(0)) revert OwnableInvalidOwner(address(0));
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (operators_.length == 0) revert NoOperators();
        _transferOwnership(owner_);

        for (uint256 i = 0; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
            operators[operators_[i]] = true;
            emit OperatorUpdated(operators_[i], true);
        }

        ILiquidationExecutorImmutables impl = ILiquidationExecutorImmutables(implementation);
        address morpho = impl.morphoBlue();
        allowedFlashProviders[impl.FLASH_PROVIDER_BALANCER()] = balancerVault_;
        allowedFlashProviders[impl.FLASH_PROVIDER_MORPHO()] = morpho;
        allowedTargets[impl.aavePool()] = true;
        allowedTargets[balancerVault_] = true;
        allowedTargets[morpho] = true;
        allowedTargets[impl.paraswapAugustusV6()] = true;
        allowedTargets[impl.uniV2Router()] = true;
        allowedTargets[impl.uniV3Router()] = true;

        for (uint256 i = 0; i < allowedTargets_.length; ++i) {
            if (allowedTargets_[i] == address(0)) revert ZeroAddress();
            allowedTargets[allowedTargets_[i]] = true;
        }
        for (uint256 i = 0; i < blockedV4Hooks_.length; ++i) {
            if (blockedV4Hooks_[i] == address(0)) revert ZeroAddress();
            blockedV4Hooks[blockedV4Hooks_[i]] = true;
            emit V4HookBlockedUpdated(blockedV4Hooks_[i], true);
        }
        if (aaveV2LendingPool_ != address(0)) {
            // Same rule as `setAaveV2LendingPool`: the pool must be an allowlisted target.
            if (!allowedTargets[aaveV2LendingPool_]) revert TargetNotAllowed();
            aaveV2LendingPool = aaveV2LendingPool_;
            emit ConfigUpdated("aaveV2Pool", address(0), aaveV2LendingPool_);
        }

        ERC1967Utils.upgradeToAndCall(implementation, "");
    }
}
```

- [ ] **Step 6: Create `test/support/ExecutorDeploy.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArbExecutor} from "../../src/ArbExecutor.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";
import {ArbExecutorGenesis} from "../../src/proxy/ArbExecutorGenesis.sol";
import {LiquidationExecutorGenesis} from "../../src/proxy/LiquidationExecutorGenesis.sol";
import {ExecutorProxy} from "../../src/proxy/ExecutorProxy.sol";
import {LiquidationExecutorHarness} from "./LiquidationExecutorHarness.sol";

/// Test-only: deploy executors the way production does — implementation,
/// Genesis, proxy — behind the argument lists the old constructors took, so
/// every existing test runs through the proxy without rewriting its call site.
/// The ProxyAdmin owner is the executor owner, as on mainnet.
///
/// The implementation is always the FIRST contract created, so a test that
/// expects an implementation-constructor revert (`vm.expectRevert` then one of
/// these calls) still sees it.
library ExecutorDeploy {
    function arb(
        address owner_,
        address operator_,
        address weth_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    ) internal returns (ArbExecutor) {
        ArbExecutor impl = new ArbExecutor(
            owner_,
            operator_,
            weth_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            new address[](0)
        );
        return arbProxy(address(impl), owner_, operator_, allowedTargets_);
    }

    function arbProxy(address implementation, address owner_, address operator_, address[] memory allowedTargets_)
        internal
        returns (ArbExecutor)
    {
        bytes memory init = abi.encodeCall(
            ArbExecutorGenesis.initialize, (owner_, _one(operator_), allowedTargets_, new address[](0), implementation)
        );
        return ArbExecutor(payable(address(new ExecutorProxy(address(new ArbExecutorGenesis()), owner_, init))));
    }

    function liquidation(
        address owner_,
        address operator_,
        address weth_,
        address aavePool_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    ) internal returns (LiquidationExecutor) {
        LiquidationExecutor impl = new LiquidationExecutor(
            owner_,
            operator_,
            weth_,
            aavePool_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            new address[](0)
        );
        return LiquidationExecutor(
            payable(liquidationProxy(address(impl), owner_, operator_, balancerVault_, allowedTargets_))
        );
    }

    function liquidationHarness(
        address owner_,
        address operator_,
        address weth_,
        address aavePool_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    ) internal returns (LiquidationExecutorHarness) {
        LiquidationExecutorHarness impl = new LiquidationExecutorHarness(
            owner_,
            operator_,
            weth_,
            aavePool_,
            balancerVault_,
            morpho_,
            paraswapAugustus_,
            uniV2Router_,
            uniV3Router_,
            new address[](0)
        );
        return LiquidationExecutorHarness(
            payable(liquidationProxy(address(impl), owner_, operator_, balancerVault_, allowedTargets_))
        );
    }

    function liquidationProxy(
        address implementation,
        address owner_,
        address operator_,
        address balancerVault_,
        address[] memory allowedTargets_
    ) internal returns (address) {
        bytes memory init = abi.encodeCall(
            LiquidationExecutorGenesis.initialize,
            (owner_, _one(operator_), allowedTargets_, new address[](0), balancerVault_, address(0), implementation)
        );
        return address(new ExecutorProxy(address(new LiquidationExecutorGenesis()), owner_, init));
    }

    function _one(address a) private pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }
}
```

- [ ] **Step 7: Check both Genesis layouts in `script/check_layout.sh`**

Replace the last three lines

```bash
layout LiquidationExecutor | python3 script/layout_compare.py layout/LiquidationExecutor.json LiquidationExecutor || status=1
exit $status
```

with

```bash
layout LiquidationExecutor | python3 script/layout_compare.py layout/LiquidationExecutor.json LiquidationExecutor || status=1
# A Genesis writes the proxy's storage before the implementation reads it: it must match EXACTLY.
layout ArbExecutorGenesis | python3 script/layout_compare.py layout/ArbExecutor.json ArbExecutorGenesis --exact || status=1
layout LiquidationExecutorGenesis | python3 script/layout_compare.py layout/LiquidationExecutor.json LiquidationExecutorGenesis --exact || status=1
exit $status
```

- [ ] **Step 8: Run the new tests**

Run: `forge fmt && nice -n 19 forge test --match-path test/ExecutorProxy.t.sol -vv 2>&1 | tail -20`
Expected: `Suite result: ok. 11 passed; 0 failed`.

- [ ] **Step 9: Layout, sizes, full suite**

Run: `nice -n 19 forge build --sizes >/dev/null && script/check_sizes.sh 24200 && script/check_layout.sh && nice -n 19 forge test 2>&1 | tail -2`
Expected: sizes 24196 / 14128; four `ok` layout lines (ArbExecutor, LiquidationExecutor, ArbExecutorGenesis, LiquidationExecutorGenesis); `0 failed`, passed = previous count + 11.

- [ ] **Step 10: Commit**

```bash
git add src/proxy test/support/ExecutorDeploy.sol test/ExecutorProxy.t.sol script/check_layout.sh
git commit -m "feat: an executor proxy whose Genesis seeds it and hands it to the implementation" -m "$TRAILER"
```

---

### Task 4: Run the existing suites through the proxy

**Files:**
- Modify: `test/ArbExecutor.t.sol`, `test/ArbExecutorFork.t.sol`, `test/ArbExecutorSecurity.t.sol`, `test/Executor.t.sol`, `test/fork/ExecutorForkV4.t.sol`

**Interfaces:**
- Consumes: `ExecutorDeploy.arb`, `ExecutorDeploy.liquidation`, `ExecutorDeploy.liquidationHarness` (Task 3) — same argument lists as the constructors they replace.

- [ ] **Step 1: Replace every executor construction in tests**

Run:
```bash
perl -pi -e 's/\bnew ArbExecutor\(/ExecutorDeploy.arb(/g; s/\bnew LiquidationExecutorHarness\(/ExecutorDeploy.liquidationHarness(/g; s/\bnew LiquidationExecutor\(/ExecutorDeploy.liquidation(/g; s|^(import \{Test\} from "forge-std/Test.sol";)$|$1\nimport {ExecutorDeploy} from "./support/ExecutorDeploy.sol";|' test/ArbExecutor.t.sol test/ArbExecutorFork.t.sol test/ArbExecutorSecurity.t.sol test/Executor.t.sol
perl -pi -e 's/\bnew LiquidationExecutor\(/ExecutorDeploy.liquidation(/g; s|^(import \{Test\} from "forge-std/Test.sol";)$|$1\nimport {ExecutorDeploy} from "../support/ExecutorDeploy.sol";|' test/fork/ExecutorForkV4.t.sol
```

- [ ] **Step 2: Verify nothing constructs an executor directly any more**

Run: `grep -rn -E 'new (ArbExecutor|LiquidationExecutor|LiquidationExecutorHarness)\(' test --include='*.t.sol'; echo exit=$?`
Expected: no lines, `exit=1`.
Run: `grep -c 'import {ExecutorDeploy}' test/ArbExecutor.t.sol test/ArbExecutorFork.t.sol test/ArbExecutorSecurity.t.sol test/Executor.t.sol test/fork/ExecutorForkV4.t.sol`
Expected: `1` for each file.

- [ ] **Step 3: Format and run the full suite**

Run: `forge fmt && nice -n 19 forge test 2>&1 | tail -3`
Expected: `0 failed`, same passed count as after Task 3. The four constructor-revert tests in `test/Executor.t.sol` (`test_constructorRevertsOnZeroOwner`, `test_constructorRejectsZeroMorpho`, `test_constructor_rejectsZeroV2Router`, `test_constructor_rejectsZeroV3Router`) still pass: the implementation is the first contract the helper creates, and its constructor still takes and checks those arguments.
If any other test fails, stop and report it with its output — do not adjust assertions to make it pass.

- [ ] **Step 4: Commit**

```bash
git add test/ArbExecutor.t.sol test/ArbExecutorFork.t.sol test/ArbExecutorSecurity.t.sol test/Executor.t.sol test/fork/ExecutorForkV4.t.sol
git commit -m "test: construct every executor through its proxy" -m "$TRAILER"
```

---

### Task 5: Immutables-only, locked implementation constructors

**Files:**
- Modify: `src/ArbExecutor.sol` (the constructor)
- Modify: `src/LiquidationExecutor.sol` (the constructor)
- Modify: `test/support/LiquidationExecutorHarness.sol` (constructor)
- Modify: `test/support/ExecutorDeploy.sol` (the three implementation constructions)
- Modify: `test/ExecutorProxy.t.sol` (`_arbImpl`, `_liqImpl`, new test)
- Modify: `test/Executor.t.sol` (`test_constructorRevertsOnZeroOwner`)

**Interfaces:**
- Produces: `ArbExecutor(address weth_, address balancerVault_, address morpho_, address paraswapAugustus_, address uniV2Router_, address uniV3Router_)`; `LiquidationExecutor(address weth_, address aavePool_, address morpho_, address paraswapAugustus_, address uniV2Router_, address uniV3Router_)`; `LiquidationExecutorHarness` with the same six parameters. `ExecutorDeploy` signatures unchanged.

- [ ] **Step 1: Write the failing lock test**

Add to `test/ExecutorProxy.t.sol`, in the arb section:

```solidity
    function test_implementationsAreOwnerlessAndLocked() public {
        ArbExecutor arbImpl = _arbImpl();
        assertEq(arbImpl.owner(), address(0xdEaD), "an implementation's own storage is never used");
        assertFalse(arbImpl.operators(operator));
        assertFalse(arbImpl.allowedTargets(balancer));

        LiquidationExecutor liqImpl = _liqImpl();
        assertEq(liqImpl.owner(), address(0xdEaD));
        assertFalse(liqImpl.operators(operator));
        assertFalse(liqImpl.allowedTargets(aave));
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 19 forge test --match-test test_implementationsAreOwnerlessAndLocked 2>&1 | tail -5`
Expected: FAIL, reporting `an implementation's own storage is never used` — the old constructor still makes `owner` the owner.

- [ ] **Step 3: Replace the `ArbExecutor` constructor**

Replace everything from `    constructor(` through the constructor's closing `    }` (the line before `    // ─── Modifiers ───`) with:

```solidity
    /// Immutables only. Persistent state belongs to the proxy and is seeded by
    /// `ArbExecutorGenesis`; this contract's own storage is never used, so it
    /// is left ownerless and its initializers are disabled.
    constructor(
        address weth_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_
    ) Ownable(address(0xdEaD)) {
        if (weth_ == address(0)) revert ZeroAddress();
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (morpho_ == address(0)) revert ZeroAddress();
        if (paraswapAugustus_ == address(0)) revert ZeroAddress();
        if (uniV2Router_ == address(0)) revert ZeroAddress();
        if (uniV3Router_ == address(0)) revert ZeroAddress();

        weth = weth_;
        paraswapAugustusV6 = paraswapAugustus_;
        uniV2Router = uniV2Router_;
        uniV3Router = uniV3Router_;
        morphoBlue = morpho_;
        balancerVault = balancerVault_;

        _disableInitializers();
    }
```

- [ ] **Step 4: Replace the `LiquidationExecutor` constructor**

Replace everything from `    constructor(` through the constructor's closing `    }` (the line before `    // ─── Modifiers ───`) with:

```solidity
    /// Immutables only. Persistent state belongs to the proxy and is seeded by
    /// `LiquidationExecutorGenesis` (which also takes the Balancer vault this
    /// contract never stored); this contract's own storage is never used, so
    /// it is left ownerless and its initializers are disabled.
    constructor(
        address weth_,
        address aavePool_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_
    ) Ownable(address(0xdEaD)) {
        if (weth_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (morpho_ == address(0)) revert ZeroAddress();
        if (paraswapAugustus_ == address(0)) revert ZeroAddress();
        if (uniV2Router_ == address(0)) revert ZeroAddress();
        if (uniV3Router_ == address(0)) revert ZeroAddress();

        weth = weth_;
        uniV2Router = uniV2Router_;
        uniV3Router = uniV3Router_;
        aavePool = aavePool_;
        paraswapAugustusV6 = paraswapAugustus_;
        morphoBlue = morpho_;

        _disableInitializers();
    }
```

- [ ] **Step 5: Follow in the harness**

In `test/support/LiquidationExecutorHarness.sol` replace the constructor with:

```solidity
    constructor(
        address weth_,
        address aavePool_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_
    ) LiquidationExecutor(weth_, aavePool_, morpho_, paraswapAugustus_, uniV2Router_, uniV3Router_) {}
```

- [ ] **Step 6: Follow in the helpers**

In `test/support/ExecutorDeploy.sol`:
- in `arb`, replace the `new ArbExecutor(...)` expression with `new ArbExecutor(weth_, balancerVault_, morpho_, paraswapAugustus_, uniV2Router_, uniV3Router_)`;
- in `liquidation`, replace the `new LiquidationExecutor(...)` expression with `new LiquidationExecutor(weth_, aavePool_, morpho_, paraswapAugustus_, uniV2Router_, uniV3Router_)`;
- in `liquidationHarness`, replace the `new LiquidationExecutorHarness(...)` expression with `new LiquidationExecutorHarness(weth_, aavePool_, morpho_, paraswapAugustus_, uniV2Router_, uniV3Router_)`.

In `test/ExecutorProxy.t.sol`:

```solidity
    function _arbImpl() internal returns (ArbExecutor) {
        return new ArbExecutor(weth, balancer, morpho, paraswap, v2, v3);
    }

    function _liqImpl() internal returns (LiquidationExecutor) {
        return new LiquidationExecutor(weth, aave, morpho, paraswap, v2, v3);
    }
```

(drop the "Changes shape in Task 5" comments).

- [ ] **Step 7: Move the zero-owner test to where ownership lives**

In `test/Executor.t.sol` add imports next to the `LiquidationExecutorHarness` import:

```solidity
import {LiquidationExecutorGenesis} from "../src/proxy/LiquidationExecutorGenesis.sol";
import {ExecutorProxy} from "../src/proxy/ExecutorProxy.sol";
```

Replace the whole `test_constructorRevertsOnZeroOwner` function with:

```solidity
    function test_constructorRevertsOnZeroOwner() public {
        // Ownership lives in the proxy: Genesis refuses a zero owner while the
        // proxy is being constructed.
        LiquidationExecutor impl =
            new LiquidationExecutor(address(2), address(3), address(5), address(6), address(7), address(8));
        LiquidationExecutorGenesis genesis = new LiquidationExecutorGenesis();
        address[] memory operators = new address[](1);
        operators[0] = address(1);
        bytes memory init = abi.encodeCall(
            LiquidationExecutorGenesis.initialize,
            (address(0), operators, new address[](0), new address[](0), address(4), address(0), address(impl))
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ExecutorProxy(address(genesis), address(9), init);
    }
```

- [ ] **Step 8: Run the lock test and the full suite**

Run: `forge fmt && nice -n 19 forge test 2>&1 | tail -3`
Expected: `0 failed`, passed = Task 4 count + 1.
If a constructor test other than the four named in Task 4 fails, it checks a zero argument that moved into Genesis (owner, operator or Balancer vault): rewrite it in the shape of `test_constructorRevertsOnZeroOwner` above, expecting `LiquidationExecutorGenesis.ZeroAddress.selector` or `NoOperators.selector`. Any other failure: stop and report.

- [ ] **Step 9: Layout and sizes unchanged**

Run: `nice -n 19 forge build --sizes >/dev/null && script/check_sizes.sh 24200 && script/check_layout.sh`
Expected: sizes 24196 / 14128; four `ok` layout lines.

- [ ] **Step 10: Commit**

```bash
git add src/ArbExecutor.sol src/LiquidationExecutor.sol test/support test/ExecutorProxy.t.sol test/Executor.t.sol
git commit -m "feat: implementations take immutables only and lock themselves" -m "$TRAILER"
```

---

### Task 6: Fork gate — a real landing through the proxy

**Files:**
- Modify: `foundry.toml`
- Create: `test/fixtures/landing_c444fb52.hex`
- Create: `test/support/ProxyEtch.sol`
- Create: `test/fork/ProxyReplay.t.sol`
- Modify: `test/ForkDirectV2K.t.sol`

**Interfaces:**
- Consumes: `ExecutorDeploy.arbProxy` (Task 3), the Task 5 `ArbExecutor` constructor.
- Produces: `library ProxyEtch` — `arbImplementationLike(address live) returns (ArbExecutor)`; `etchArbProxy(address live, address implementation)`.

- [ ] **Step 1: Allow tests to read fixtures**

In `foundry.toml`, under `[profile.default]`, after `via_ir = true`, add:

```toml
fs_permissions = [{ access = "read", path = "./test/fixtures" }]
```

- [ ] **Step 2: Record the landing's calldata**

Run:
```bash
mkdir -p test/fixtures
cast tx 0xc444fb52c2a1db3bb4df85cf6f73627a6dc0768beb5dffeff81a7f8605cd9889 input --rpc-url https://rpc-eth.blockmachine.io > test/fixtures/landing_c444fb52.hex
python3 -c "s=open('test/fixtures/landing_c444fb52.hex').read().strip(); print(len(s), s[:10])"
```
Expected: `4298 0x09c5eabe` (`execute(bytes)`, 2148 bytes).

- [ ] **Step 3: Create `test/support/ProxyEtch.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ArbExecutor} from "../../src/ArbExecutor.sol";
import {ExecutorDeploy} from "./ExecutorDeploy.sol";

/// Fork-gate helper: turn a LIVE arb executor into a proxy in place.
///
/// The live contract's storage already has the proxy's layout (the storage
/// bases were extracted without moving a slot — `script/check_layout.sh`), so
/// proxy code at the same address with the ERC-1967 slot pointing at a fresh
/// implementation reproduces the address after the migration: the same owner,
/// operators, allowlists and balances, and the same address that signed RFQ
/// quotes and the 1inch access token are bound to.
library ProxyEtch {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// A new implementation built with the live contract's own immutables.
    function arbImplementationLike(address live) internal returns (ArbExecutor) {
        ArbExecutor l = ArbExecutor(payable(live));
        return new ArbExecutor(
            l.weth(), l.balancerVault(), l.morphoBlue(), l.paraswapAugustusV6(), l.uniV2Router(), l.uniV3Router()
        );
    }

    /// Put `ExecutorProxy` runtime at `live`, delegating to `implementation`.
    function etchArbProxy(address live, address implementation) internal {
        ArbExecutor model = ExecutorDeploy.arbProxy(implementation, address(0xA11CE), address(0xB0B), new address[](0));
        VM.etch(live, address(model).code);
        VM.store(live, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
    }
}
```

- [ ] **Step 4: Write the landing replay**

`test/fork/ProxyReplay.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbExecutor} from "../../src/ArbExecutor.sol";
import {ProxyEtch} from "../support/ProxyEtch.sol";

/// Fork gate: a real production landing, replayed through the proxy.
///
/// tx 0xc444fb52… (block 25_974_940, index 17), route v4>hashflow, sent by
/// operator 0xf4Bb8842 with a 5000-wei bid to the live ArbExecutor 0x4d3AbD5d.
/// Its receipt holds a Uniswap V4 swap (the PoolManager calls the executor's
/// `unlockCallback`) and two WETH `Withdrawal`s to the executor (ETH arriving
/// under WETH9's 2300-gas `transfer`) — the two things a proxy could break.
///
/// The calldata runs twice from the pre-transaction state: once with the new
/// implementation's code etched straight onto the address (bare), once with
/// proxy code there delegating to that implementation. Both must succeed and
/// keep the same balances; the gas difference is the proxy's overhead.
///
/// Run: MAINNET_RPC_URL=https://rpc-eth.blockmachine.io forge test --match-path test/fork/ProxyReplay.t.sol -vv
contract ProxyReplayTest is Test {
    address constant EXEC = 0x4d3AbD5dC3ae7863470bB9e70949e2AC45d68731;
    address constant OPERATOR = 0xf4Bb8842dd662c8edDed051e66376937E308B905;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 constant LANDING_TX = 0xc444fb52c2a1db3bb4df85cf6f73627a6dc0768beb5dffeff81a7f8605cd9889;
    uint256 constant BID_WEI = 5000;
    /// 1% of the bot's `ARB_GAS_UNITS` (500_000, src/arbitrage/detector.rs in
    /// the bot repo). Above it, the bot's gas constants move in the same change.
    uint256 constant MAX_PROXY_OVERHEAD_GAS = 5_000;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, LANDING_TX);
        forked = true;
    }

    function _replay() internal returns (bool ok, uint256 gasUsed, uint256 wethKept, uint256 ethKept) {
        bytes memory data = vm.parseBytes(vm.trim(vm.readFile("test/fixtures/landing_c444fb52.hex")));
        vm.deal(OPERATOR, 1 ether);
        vm.prank(OPERATOR, OPERATOR);
        uint256 before = gasleft();
        (ok,) = EXEC.call{value: BID_WEI}(data);
        gasUsed = before - gasleft();
        wethKept = IERC20(WETH).balanceOf(EXEC);
        ethKept = EXEC.balance;
    }

    function test_fork_landing_replays_through_the_proxy() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        ArbExecutor impl = ProxyEtch.arbImplementationLike(EXEC);
        uint256 snap = vm.snapshotState();

        vm.etch(EXEC, address(impl).code);
        (bool okBare, uint256 gasBare, uint256 wethBare, uint256 ethBare) = _replay();
        assertTrue(okBare, "the landing must replay on the bare implementation");

        vm.revertToState(snap);
        ProxyEtch.etchArbProxy(EXEC, address(impl));
        (bool okProxy, uint256 gasProxy, uint256 wethProxy, uint256 ethProxy) = _replay();
        assertTrue(okProxy, "the landing must replay through the proxy");

        assertEq(wethProxy, wethBare, "same WETH kept");
        assertEq(ethProxy, ethBare, "same ETH kept");
        emit log_named_uint("gas bare", gasBare);
        emit log_named_uint("gas proxy", gasProxy);
        emit log_named_uint("proxy overhead", gasProxy - gasBare);
        assertLt(gasProxy - gasBare, MAX_PROXY_OVERHEAD_GAS, "proxy overhead above 1% of ARB_GAS_UNITS");
    }
}
```

- [ ] **Step 5: Run it without an RPC (CI shape)**

Run: `nice -n 19 forge test --match-path test/fork/ProxyReplay.t.sol 2>&1 | tail -3`
Expected: `0 passed; 0 failed; 1 skipped`.

- [ ] **Step 6: Run it on the fork**

Run: `MAINNET_RPC_URL=https://rpc-eth.blockmachine.io nice -n 19 forge test --match-path test/fork/ProxyReplay.t.sol -vv 2>&1 | tee /tmp/proxy_replay.log | tail -12`
Expected: `[PASS] test_fork_landing_replays_through_the_proxy()` with `gas bare`, `gas proxy` and `proxy overhead` logged, overhead below 5000.
If the bare replay fails, the fixture or fork point is wrong — check Step 2's output and that `createSelectFork` received the transaction hash. If only the proxy replay fails, that is a real finding: stop and report with the `-vvvv` trace.

- [ ] **Step 7: Add the FLOKI plan through the proxy**

In `test/ForkDirectV2K.t.sol`, add imports after `import {Test} from "forge-std/Test.sol";`:

```solidity
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {ProxyEtch} from "./support/ProxyEtch.sol";
```

and add, after `test_fork_the_pair_accepts_the_swap_after_the_fix`:

```solidity
    /// The same plan through the migration's proxy: proxy code at the live
    /// address, delegating to a new implementation, which carries #45 and #46.
    /// `K_CALLDATA` is not in the repository; without it this skips.
    function test_fork_the_pair_accepts_the_swap_through_the_proxy() public forkOnly {
        if (vm.envOr("K_CALLDATA", bytes("")).length == 0) {
            vm.skip(true);
            return;
        }
        ArbExecutor impl = ProxyEtch.arbImplementationLike(EXEC);
        ProxyEtch.etchArbProxy(EXEC, address(impl));
        (bool ok, bytes memory ret) = _run(true);
        emit log_named_bytes("ret", ret);
        assertFalse(_isK(ret), "the pair must no longer reject on K");
        assertFalse(ok, "this particular cycle is unprofitable and must be refused");
        assertEq(bytes4(ret), bytes4(0x75ce3dc6), "expected the flash-repay gate");
        (uint256 got, uint256 needed) = abi.decode(_args(ret), (uint256, uint256));
        assertEq(needed, 0.25 ether, "the flash principal");
        assertEq(got, 249_869_766_973_738_772, "what the cycle returned");
    }
```

- [ ] **Step 8: Run the liquidation gate and the new K test**

Run: `MAINNET_RPC_URL=https://rpc-eth.blockmachine.io nice -n 19 forge test --match-test 'test_fork_jackpot_unwrap_v4_curve_liquidate|test_fork_the_pair_accepts_the_swap_through_the_proxy' -vv 2>&1 | tail -8`
Expected: `[PASS] test_fork_jackpot_unwrap_v4_curve_liquidate()` (now through the proxy, from Task 4) and `test_fork_the_pair_accepts_the_swap_through_the_proxy` reported as skipped unless `K_CALLDATA` is set.

- [ ] **Step 9: Full gate without an RPC**

Run: `forge fmt --check && nice -n 19 forge test 2>&1 | tail -2`
Expected: `0 failed`; the two new fork tests counted as skipped.

- [ ] **Step 10: Commit**

```bash
git add foundry.toml test/fixtures/landing_c444fb52.hex test/support/ProxyEtch.sol test/fork/ProxyReplay.t.sol test/ForkDirectV2K.t.sol
OVERHEAD=$(awk '/proxy overhead/ {print $NF}' /tmp/proxy_replay.log)
git commit -m "test: fork gate — a real v4>hashflow landing replayed through the proxy" -m "Proxy overhead on the replay: $OVERHEAD gas." -m "$TRAILER"
```

---

### Task 7: Deploy and upgrade scripts

**Files:**
- Modify: `script/DeployArb.s.sol`
- Modify: `script/Deploy.s.sol`
- Create: `script/PrepareUpgrade.s.sol`
- Delete: `src/deploy/SeededExecutors.sol`

**Interfaces:**
- Consumes: `ExecutorProxy`, `ArbExecutorGenesis`, `LiquidationExecutorGenesis` (Task 3); Task 5 constructors.

- [ ] **Step 1: Rewrite the arb deploy**

In `script/DeployArb.s.sol` replace the imports

```solidity
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {ArbExecutorSeeded} from "../src/deploy/SeededExecutors.sol";
```

with

```solidity
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {ArbExecutorGenesis} from "../src/proxy/ArbExecutorGenesis.sol";
import {ExecutorProxy} from "../src/proxy/ExecutorProxy.sol";
```

Replace everything from `        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));` through `        vm.stopBroadcast();` (inclusive) with:

```solidity
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address[] memory operators = new address[](3);
        operators[0] = OPERATOR;
        operators[1] = OPERATOR_2;
        operators[2] = OPERATOR_3;
        // V4 hooks are accepted by default now (blocklist, not allowlist);
        // nothing to seed. The two hooks that used to be allowed here are
        // kept as constants only for the read-back below.
        address[] memory hooks = new address[](0);
        ArbExecutor impl =
            new ArbExecutor(WETH, BALANCER_VAULT, MORPHO_BLUE, PARASWAP_AUGUSTUS, UNI_V2_ROUTER, UNI_V3_ROUTER);
        ArbExecutorGenesis genesis = new ArbExecutorGenesis();
        ExecutorProxy proxy = new ExecutorProxy(
            address(genesis),
            OWNER,
            abi.encodeCall(ArbExecutorGenesis.initialize, (OWNER, operators, allowed, hooks, address(impl)))
        );
        vm.stopBroadcast();
        ArbExecutor exec = ArbExecutor(payable(address(proxy)));
```

Before `        require(exec.owner() == OWNER, "readback: owner");` add:

```solidity
        require(
            address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.IMPLEMENTATION_SLOT)))) == address(impl),
            "readback: implementation"
        );
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        require(admin.owner() == OWNER, "readback: ProxyAdmin owner");
        require(exec.weth() == WETH, "readback: weth");
        require(exec.balancerVault() == BALANCER_VAULT, "readback: balancer vault immutable");
        require(exec.morphoBlue() == MORPHO_BLUE, "readback: morpho immutable");
        require(exec.allowedFlashProviders(2) == BALANCER_VAULT, "readback: balancer flash provider");
        require(exec.allowedFlashProviders(3) == MORPHO_BLUE, "readback: morpho flash provider");
        require(!exec.allowedTargets(MORPHO_BLUE), "readback: Morpho must NOT be a target");
```

Replace the tail

```solidity
        console2.log("ArbExecutor:", address(exec));
        console2.log("allowlisted targets:", allowed.length + 4);
        return address(exec);
```

with

```solidity
        console2.log("ArbExecutor proxy (permanent address):", address(exec));
        console2.log("implementation:", address(impl));
        console2.log("ProxyAdmin (upgrade target for the Safe):", address(admin));
        console2.log("allowlisted targets:", allowed.length + 4);
        return address(exec);
```

- [ ] **Step 2: Rewrite the liquidation deploy**

In `script/Deploy.s.sol` replace the imports

```solidity
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {LiquidationExecutorSeeded} from "../src/deploy/SeededExecutors.sol";
```

with

```solidity
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {LiquidationExecutorGenesis} from "../src/proxy/LiquidationExecutorGenesis.sol";
import {ExecutorProxy} from "../src/proxy/ExecutorProxy.sol";
```

Replace the operators block and everything through `        vm.stopBroadcast();` — i.e. from `        address[] memory operators = new address[](2);` through `        vm.stopBroadcast();` (inclusive) — with:

```solidity
        address[] memory operators = new address[](3);
        operators[0] = OPERATOR;
        operators[1] = OPERATOR_2;
        operators[2] = OPERATOR_3;
        // V4 hooks are accepted by default now (blocklist, not allowlist);
        // nothing to seed. The two hooks that used to be allowed here are
        // kept as constants only for the read-back below.
        address[] memory hooks = new address[](0);

        // Broadcast with the key from the environment; a bare
        // `vm.startBroadcast()` falls back to Foundry's default sender.
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        LiquidationExecutor impl = new LiquidationExecutor(
            WETH, AAVE_V3_POOL, MORPHO_BLUE, PARASWAP_AUGUSTUS, UNI_V2_ROUTER, UNI_V3_ROUTER
        );
        LiquidationExecutorGenesis genesis = new LiquidationExecutorGenesis();
        ExecutorProxy proxy = new ExecutorProxy(
            address(genesis),
            OWNER,
            abi.encodeCall(
                LiquidationExecutorGenesis.initialize,
                // The live liquidator never set its Aave V2 lending pool (no
                // event); leave it unset. Pass AAVE_V2_POOL to enable V2.
                (OWNER, operators, liqAllowed, hooks, BALANCER_VAULT, address(0), address(impl))
            )
        );
        vm.stopBroadcast();
        liqExecutor = address(proxy);
```

Before `        require(ex.owner() == OWNER, "readback: owner");` add:

```solidity
        require(
            address(uint160(uint256(vm.load(liqExecutor, ERC1967Utils.IMPLEMENTATION_SLOT)))) == address(impl),
            "readback: implementation"
        );
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(liqExecutor, ERC1967Utils.ADMIN_SLOT)))));
        require(admin.owner() == OWNER, "readback: ProxyAdmin owner");
        require(ex.allowedFlashProviders(2) == BALANCER_VAULT, "readback: balancer flash provider");
        require(ex.allowedFlashProviders(3) == MORPHO_BLUE, "readback: morpho flash provider");
        require(ex.allowedTargets(AAVE_V3_POOL), "readback: aave v3 allowed");
        require(ex.allowedTargets(MORPHO_BLUE), "readback: morpho allowed");
        require(ex.allowedTargets(PARASWAP_AUGUSTUS), "readback: paraswap allowed");
        require(ex.allowedTargets(UNI_V3_ROUTER), "readback: v3 router allowed");
        require(ex.aaveV2LendingPool() == address(0), "readback: aave v2 pool unset");
```

Replace `        console2.log("LiquidationExecutor V10:", liqExecutor);` with:

```solidity
        console2.log("LiquidationExecutor proxy (permanent address):", liqExecutor);
        console2.log("implementation:", address(impl));
        console2.log("ProxyAdmin (upgrade target for the Safe):", address(admin));
```

- [ ] **Step 3: Create `script/PrepareUpgrade.s.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";

/// Deploy a new implementation for an existing executor proxy, built with the
/// immutables the proxy runs with today, and print the Safe transaction that
/// switches to it. The script never upgrades anything itself: the ProxyAdmin
/// belongs to the Safe.
///
///   arb:          FOUNDRY_PROFILE=arb PROXY=0x… EXECUTOR_KIND=arb \
///                   forge script script/PrepareUpgrade.s.sol --rpc-url $RPC --broadcast
///   liquidation:  PROXY=0x… EXECUTOR_KIND=liquidation \
///                   forge script script/PrepareUpgrade.s.sol --rpc-url $RPC --broadcast
///
/// Before the Safe signs: run the fork gate (test/fork/ProxyReplay.t.sol and
/// the liquidation fork test) against the new implementation.
contract PrepareUpgrade is Script {
    function run() external returns (address implementation) {
        address proxy = vm.envAddress("PROXY");
        bytes32 kind = keccak256(bytes(vm.envString("EXECUTOR_KIND")));
        address admin = address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));
        address current = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(admin != address(0) && current != address(0), "PROXY is not an ERC-1967 proxy");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        if (kind == keccak256("arb")) {
            ArbExecutor p = ArbExecutor(payable(proxy));
            implementation = address(
                new ArbExecutor(
                    p.weth(), p.balancerVault(), p.morphoBlue(), p.paraswapAugustusV6(), p.uniV2Router(), p.uniV3Router()
                )
            );
        } else if (kind == keccak256("liquidation")) {
            LiquidationExecutor p = LiquidationExecutor(payable(proxy));
            implementation = address(
                new LiquidationExecutor(
                    p.weth(), p.aavePool(), p.morphoBlue(), p.paraswapAugustusV6(), p.uniV2Router(), p.uniV3Router()
                )
            );
        } else {
            revert("EXECUTOR_KIND must be arb or liquidation");
        }
        vm.stopBroadcast();

        console2.log("proxy:", proxy);
        console2.log("ProxyAdmin (Safe transaction target):", admin);
        console2.log("current implementation (rollback target):", current);
        console2.log("new implementation:", implementation);
        console2.log("Safe transaction calldata (value 0):");
        console2.logBytes(
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), implementation, ""))
        );
    }
}
```

- [ ] **Step 4: Delete the seeded executors**

Run: `git rm src/deploy/SeededExecutors.sol && grep -rn 'SeededExecutors\|ExecutorSeeded' src script test; echo exit=$?`
Expected: no lines, `exit=1`.

- [ ] **Step 5: Build**

Run: `forge fmt && nice -n 19 forge build --sizes >/dev/null && script/check_sizes.sh 24200 && script/check_layout.sh`
Expected: sizes 24196 / 14128; four `ok` layout lines.

- [ ] **Step 6: Dry-run both deploys and an upgrade on a local mainnet fork**

Nothing here reaches mainnet: anvil forks it locally and funds its account 0. The `arb` profile recompiles everything (another full `via_ir` build).

```bash
anvil --fork-url https://rpc-eth.blockmachine.io --port 8546 --silent & ANVIL=$!
sleep 5
RPC=http://127.0.0.1:8546
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
FOUNDRY_PROFILE=arb nice -n 19 forge script script/DeployArb.s.sol --rpc-url $RPC --broadcast 2>&1 | tee /tmp/deploy_arb.log | grep -E 'permanent address|implementation:|ProxyAdmin|Error|revert'
nice -n 19 forge script script/Deploy.s.sol --rpc-url $RPC --broadcast 2>&1 | tee /tmp/deploy_liq.log | grep -E 'permanent address|implementation:|ProxyAdmin|Error|revert'
```
Expected: each prints `... proxy (permanent address): 0x…`, `implementation: 0x…`, `ProxyAdmin (upgrade target for the Safe): 0x…`, and no `Error` or `revert` — every read-back `require` passed.

```bash
ARB_PROXY=$(awk '/permanent address/ {print $NF}' /tmp/deploy_arb.log)
ARB_ADMIN=$(awk '/upgrade target for the Safe/ {print $NF}' /tmp/deploy_arb.log)
PROXY=$ARB_PROXY EXECUTOR_KIND=arb FOUNDRY_PROFILE=arb nice -n 19 forge script script/PrepareUpgrade.s.sol --rpc-url $RPC --broadcast 2>&1 | tee /tmp/prepare.log | grep -E 'new implementation|Error|revert'
NEW_IMPL=$(awk '/new implementation:/ {print $NF}' /tmp/prepare.log)
SAFE=0xC338094Bb79AA610E9c57166fc4FA959db6234Ab
cast rpc anvil_impersonateAccount $SAFE --rpc-url $RPC >/dev/null
cast rpc anvil_setBalance $SAFE 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null
cast send $ARB_ADMIN "upgradeAndCall(address,address,bytes)" $ARB_PROXY $NEW_IMPL 0x --from $SAFE --unlocked --rpc-url $RPC >/dev/null
cast storage $ARB_PROXY 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC
echo "expected implementation: $NEW_IMPL"
cast call $ARB_PROXY "operators(address)(bool)" 0xf4Bb8842dd662c8edDed051e66376937E308B905 --rpc-url $RPC
kill $ANVIL
```
Expected: the storage word ends in `NEW_IMPL` (lowercase, left-padded with zeros) and `operators(...)` prints `true` — the upgrade kept state.

- [ ] **Step 7: Commit**

```bash
git add script/DeployArb.s.sol script/Deploy.s.sol script/PrepareUpgrade.s.sol
git commit -m "feat(script): deploy executors behind proxies; prepare upgrades for the Safe" -m "SeededExecutors is gone: Genesis seeds the proxy." -m "$TRAILER"
```

---

### Task 8: Process guard and the pull request

**Files:**
- Create: `.github/pull_request_template.md`

- [ ] **Step 1: Create the PR template**

`.github/pull_request_template.md`:

```markdown
## What

## Needs upgrade

- [ ] **No** — tests, scripts or docs only.
- [ ] **Yes** — it unblocks:

Upgrades are batched and go out on the owner's word, as a Safe transaction
prepared by `script/PrepareUpgrade.s.sol`, and only after the fork gate is green
against the new implementation:

    MAINNET_RPC_URL=… forge test --match-path test/fork/ProxyReplay.t.sol -vv
    MAINNET_RPC_URL=… forge test --match-test test_fork_jackpot_unwrap_v4_curve_liquidate -vv

## Local gate

    forge fmt --check
    forge build --sizes
    script/check_sizes.sh 24200
    script/check_layout.sh
    forge test -vvv
```

- [ ] **Step 2: Full local gate**

Run:
```bash
{ forge fmt --check && nice -n 19 forge build --sizes >/dev/null && script/check_sizes.sh 24200 && script/check_layout.sh && nice -n 19 forge test 2>&1 | tail -2; } 2>&1 | tee /tmp/gate_local.log
{ MAINNET_RPC_URL=https://rpc-eth.blockmachine.io nice -n 19 forge test --match-path test/fork/ProxyReplay.t.sol -vv 2>&1 | grep -E 'PASS|FAIL|gas bare|gas proxy|overhead'
  MAINNET_RPC_URL=https://rpc-eth.blockmachine.io nice -n 19 forge test --match-test test_fork_jackpot_unwrap_v4_curve_liquidate 2>&1 | grep -E 'PASS|FAIL'; } | tee /tmp/gate_fork.log
```
Expected: sizes 24196 / 14128, four `ok` layout lines, `0 failed`; `[PASS]` for both fork tests with the overhead logged.

- [ ] **Step 3: Commit**

```bash
git add .github/pull_request_template.md
git commit -m "chore: every contract PR says whether it needs an upgrade" -m "$TRAILER"
```

- [ ] **Step 4: Push and open the PR — only after the owner says so**

```bash
cat > /tmp/pr_body.md <<EOF
## What

Both executors move behind permanent ERC-1967 transparent proxies, so a code change ships as one Safe transaction to the proxy's ProxyAdmin instead of a new address. Design: \`docs/superpowers/specs/2026-09-14-upgradeable-executors-design.md\`.

- Persistent state in \`ArbExecutorStorage\` / \`LiquidationExecutorStorage\`; layout pinned by \`layout/*.json\` and \`script/check_layout.sh\` (CI).
- \`ExecutorProxy\` = OZ \`TransparentUpgradeableProxy\` + a non-delegating \`receive\`, so WETH9 unwraps stay inside the 2300-gas stipend.
- \`*ExecutorGenesis\` seeds the proxy inside its constructor and switches it to the implementation: one deploy transaction, no uninitialised window, ProxyAdmin owned by the Safe from the start.
- Implementations take immutables only and are locked; \`SeededExecutors\` is removed.
- Every existing test runs through the proxy.
- Fork gate: the v4>hashflow landing \`0xc444fb52…\` replayed through the proxy against the bare implementation, and the Aave liquidation fork test through the proxy.
- \`script/PrepareUpgrade.s.sol\` deploys a new implementation with the live immutables and prints the Safe calldata.

## Needs upgrade

Yes — this is the migration itself (spec §3), and it carries #45 and #46. Deploy only on the owner's word.

## Local gate

\`\`\`
$(cat /tmp/gate_local.log)
\`\`\`

## Fork gate

\`\`\`
$(cat /tmp/gate_fork.log)
\`\`\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01PJjQdQZ9GedsSqtexqqWAX
EOF
git push -u origin HEAD
gh pr create -R aburkut/liquidation-executor-contract --title "feat: upgradeable executors behind transparent proxies" --body-file /tmp/pr_body.md
```
