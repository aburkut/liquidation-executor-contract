// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev The one V3 pool entrypoint a direct exact-input swap needs. Uniswap
/// V3, Sushi V3 and Pancake V3 pools share it (Pancake's callback is named
/// `pancakeV3SwapCallback`; the swap itself is identical).
interface IUniV3PoolMinimal {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @dev The two V2 pair entrypoints a direct swap needs (Uniswap V2, Sushi,
/// Pancake V2 pairs share them).
interface IUniV2PairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
