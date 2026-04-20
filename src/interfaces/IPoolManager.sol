// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal Uniswap V4 PoolManager surface used by LiquidationExecutor.
/// Intentionally strict — only the four methods needed for a single-hop
/// exact-input swap are exposed. NO generic `modifyLiquidity`, `donate`, or
/// `initialize` surface. NO Currency wrapper type — plain `address` is used
/// because v4-core's `type Currency is address` is ABI-compatible with raw
/// addresses at the call-site.
struct PoolKey {
    /// @dev Currency with the lower address (sorted). Native ETH is address(0).
    address currency0;
    /// @dev Currency with the higher address (sorted).
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    /// @dev Hook contract address or address(0) for no hooks.
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    /// @dev Negative = exact input; positive = exact output. We always use negative.
    int256 amountSpecified;
    /// @dev Price limit as Q64.96. Pass the near-min/max constants to disable.
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    /// @notice Entry point. PoolManager calls back `msg.sender`'s
    /// `unlockCallback(data)` synchronously; control returns here only after.
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Valid only inside an unlockCallback. Returns a BalanceDelta
    /// packed as `int256((int128 amount0 << 128) | int128 amount1)`.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    /// @notice Announce which currency is about to be paid to the manager.
    /// Subsequent `settle()` measures the balance delta since this call.
    function sync(address currency) external;

    /// @notice Reconcile any pending input currency debt with the manager.
    /// Returns the amount accounted for.
    function settle() external payable returns (uint256 paid);

    /// @notice Withdraw an owed output currency from the manager to `to`.
    function take(address currency, address to, uint256 amount) external;
}

/// @notice Implementations receive a synchronous callback from PoolManager
/// during `unlock`. The return value is forwarded by PoolManager back to
/// whoever called `unlock`.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
