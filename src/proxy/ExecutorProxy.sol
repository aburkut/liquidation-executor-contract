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
