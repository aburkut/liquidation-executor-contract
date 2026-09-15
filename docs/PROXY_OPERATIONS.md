# Executor proxy operations

`ArbExecutor` and `LiquidationExecutor` each sit behind an `ExecutorProxy`
(OpenZeppelin `TransparentUpgradeableProxy`). The proxy address is permanent.
Its constructor creates a `ProxyAdmin` owned by the Safe
`0xC338094Bb79AA610E9c57166fc4FA959db6234Ab`, the same Safe that owns the executor.
A deployer key only pays gas. Every change after deploy is a Safe transaction.

`<rpc>` below is an Ethereum mainnet RPC URL.

## 1. Dry-run a deploy on a local fork

    anvil --fork-url <rpc> --port 8546 --chain-id 31337

Without `--chain-id 31337` the fork keeps chain id 1, and `forge script --broadcast`
overwrites the tracked `broadcast/<script>/1/run-latest.json` records of the real
mainnet deploys.

    FOUNDRY_PROFILE=arb FOUNDRY_OUT=out-arb FOUNDRY_CACHE_PATH=cache-arb PRIVATE_KEY=<anvil key> \
      forge script script/DeployArb.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
    PRIVATE_KEY=<anvil key> forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8546 --broadcast

ArbExecutor ships from the `arb` profile, and LiquidationExecutor from the default
profile. `FOUNDRY_OUT`/`FOUNDRY_CACHE_PATH` keep the arb build from overwriting
the default `out/` and `cache/`. Each script reads back every seeded value and
reverts on a mismatch. Then run step 3's `CheckDeployment` against the anvil
proxies.

## 2. Mainnet deploy (owner's decision only)

    FOUNDRY_PROFILE=arb PRIVATE_KEY=<deployer key> forge script script/DeployArb.s.sol --rpc-url <rpc> --broadcast
    PRIVATE_KEY=<deployer key> forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast

Each run prints the proxy (the permanent address), the implementation and the
ProxyAdmin. No Safe transaction is needed to finish a deploy.

## 3. Verify what was mined

    FOUNDRY_PROFILE=arb forge verify-bytecode <arb implementation> src/ArbExecutor.sol:ArbExecutor \
      --rpc-url <rpc> --verifier etherscan --etherscan-api-key <key>
    forge verify-bytecode <liquidation implementation> src/LiquidationExecutor.sol:LiquidationExecutor \
      --rpc-url <rpc> --verifier etherscan --etherscan-api-key <key>

Flags are from `forge verify-bytecode --help` (forge 1.6.0-nightly):
- `<CONTRACT>` takes the form `<path>:<contractname>`.
- The creation transaction and constructor arguments are fetched from the verifier (default `sourcify`), unless you pass `--constructor-args` / `--encoded-constructor-args`.
- `--block` pins the block.
- `--ignore creation|runtime` skips one comparison.

The tool rebuilds the creation code locally with the project config and runs it
with the constructor arguments at the creation block, so the implementation's
immutables are reproduced rather than masked. The help lists no library flag.
LiquidationExecutor's six external library addresses come from the project
config (`FOUNDRY_LIBRARIES` / `libraries` in foundry.toml). Set them to the
mined library addresses printed in the deploy broadcast. Run it under the same
profile that deployed the contract.

Then check each proxy read-only (no `--broadcast`, no key):

    PROXY=<arb proxy> EXECUTOR_KIND=arb forge script script/CheckDeployment.s.sol --rpc-url <rpc>
    PROXY=<liquidation proxy> EXECUTOR_KIND=liquidation forge script script/CheckDeployment.s.sol --rpc-url <rpc>

Every check prints an `ok …` line. A mismatch reverts with its reason.

## 4. Fork gate before any Safe signature

    MAINNET_RPC_URL=<rpc> FOUNDRY_PROFILE=arb FOUNDRY_OUT=out-arb FOUNDRY_CACHE_PATH=cache-arb \
      forge test --match-path test/fork/ProxyReplay.t.sol -vv
    MAINNET_RPC_URL=<rpc> forge test --match-test test_fork_jackpot_unwrap_v4_curve_liquidate -vv

The replay runs under the `arb` profile because that is the bytecode that ships.
It fails if the proxy overhead (implementation address and slot cold) reaches
10000 gas. No green, no signature.

## 5. Upgrade

    FOUNDRY_PROFILE=arb FOUNDRY_OUT=out-arb FOUNDRY_CACHE_PATH=cache-arb PROXY=<arb proxy> EXECUTOR_KIND=arb \
      PRIVATE_KEY=<deployer key> forge script script/PrepareUpgrade.s.sol --rpc-url <rpc> --broadcast
    PROXY=<liquidation proxy> EXECUTOR_KIND=liquidation PRIVATE_KEY=<deployer key> \
      forge script script/PrepareUpgrade.s.sol --rpc-url <rpc> --broadcast

1. Dry-run on the anvil fork (step 1) first.
2. `script/check_layout.sh` must print four `ok`.
3. PrepareUpgrade deploys the new implementation with the proxy's current immutables. It refuses to continue if the new implementation's flash providers differ from the proxy's (step 6). It prints:
   - the ProxyAdmin (the transaction target),
   - the current implementation,
   - the new implementation,
   - the calldata for `ProxyAdmin.upgradeAndCall(proxy, newImplementation, "")`.
4. Keep the printed **current implementation**: it is the rollback target. Rollback is the same Safe transaction with that address.
5. Run step 3's `verify-bytecode` on the new implementation, then the step 4 fork gate.
6. Safe transaction: to = ProxyAdmin, value 0, data = the printed calldata.
7. Afterwards:

       EXPECTED_IMPLEMENTATION=<new implementation> PROXY=<proxy> EXECUTOR_KIND=<arb|liquidation> \
         forge script script/CheckDeployment.s.sol --rpc-url <rpc>

## 6. Rotating a flash provider

The flash providers live in proxy storage (`allowedFlashProviders`), written
once by Genesis. A plain upgrade does not rewrite them, and PrepareUpgrade
refuses one whose implementation names a different `morphoBlue` (or, for arb,
`balancerVault`). A rotation is a **migrator upgrade**:

- The migrator inherits the executor's storage base and must pass `check_layout.sh --exact` like a Genesis (add it to the script).
- It runs under `reinitializer(2)`; the next migration uses `reinitializer(3)`.
- It rewrites the `allowedFlashProviders` entries.
- It updates the allowlist where needed. The liquidator allowlists Morpho as a target, and both executors allowlist the Balancer vault.
- It revokes standing allowances to the old provider (Morpho repayments leave standing allowances).
- It hands off with `ERC1967Utils.upgradeToAndCall(newImplementation, "")`.
- Safe transaction: `ProxyAdmin.upgradeAndCall(proxy, migrator, abi.encodeCall(Migrator.migrate, (...)))`.
- Update `CheckDeployment.s.sol` in the same change. Its provider constants and its `_initialized == 1` check describe the Genesis state.

## 7. Ownership

`ProxyAdmin` uses **one-step** `Ownable`: `transferOwnership` takes effect
immediately. The executor is `Ownable2Step`: `transferOwnership`, then
`acceptOwnership` from the new owner. Rotate both together:

1. `executor.transferOwnership(new)` from the Safe.
2. `executor.acceptOwnership()` from the new owner. This proves the new owner can sign.
3. `ProxyAdmin.transferOwnership(new)` from the Safe.
4. Update `OWNER` in the deploy scripts and `CheckDeployment.s.sol`.

Never call `renounceOwnership` on the ProxyAdmin. It freezes the implementation
forever: no upgrade, no rollback.
