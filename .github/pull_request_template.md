## What

## Needs upgrade

- [ ] **No** — tests, scripts or docs only.
- [ ] **Yes** — it unblocks:

Upgrades are batched and go out on the owner's word, as a Safe transaction
prepared by `script/PrepareUpgrade.s.sol`, and only after the fork gate is green
against the new implementation:

    MAINNET_RPC_URL=… FOUNDRY_PROFILE=arb FOUNDRY_OUT=out-arb FOUNDRY_CACHE_PATH=cache-arb forge test --match-path test/fork/ProxyReplay.t.sol -vv
    MAINNET_RPC_URL=… forge test --match-test test_fork_jackpot_unwrap_v4_curve_liquidate -vv

## Local gate

    forge fmt --check
    forge build --sizes
    script/check_sizes.sh 24400
    script/check_layout.sh
    forge test -vvv
