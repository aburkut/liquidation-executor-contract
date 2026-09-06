// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @dev V3-style pool mock: pays `amountIn * rate / 1e18` of the other token
/// and asks the caller for the input through the canonical callback. Token
/// order (token0 < token1) is whatever the constructor says, as on-chain.
contract MockUniV3Pool {
    address public token0;
    address public token1;
    uint256 public rate; // 1e18 == 1:1
    // Test knobs: ask for more than the swap needs, or call back twice.
    uint256 public overpullBps;
    bool public doubleCallback;

    constructor(address _token0, address _token1, uint256 _rate) {
        token0 = _token0;
        token1 = _token1;
        rate = _rate;
    }

    function setOverpullBps(uint256 bps) external {
        overpullBps = bps;
    }

    function setDoubleCallback(bool on) external {
        doubleCallback = on;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "mock: exact-in only");
        uint256 amountIn = uint256(amountSpecified);
        uint256 amountOut = amountIn * rate / 1e18;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);

        IERC20(tokenOut).transfer(recipient, amountOut);

        uint256 ask = amountIn + amountIn * overpullBps / 10_000;
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        if (zeroForOne) {
            IV3SwapCallback(msg.sender).uniswapV3SwapCallback(int256(ask), -int256(amountOut), data);
            if (doubleCallback) {
                IV3SwapCallback(msg.sender).uniswapV3SwapCallback(int256(ask), -int256(amountOut), data);
            }
        } else {
            IV3SwapCallback(msg.sender).uniswapV3SwapCallback(-int256(amountOut), int256(ask), data);
            if (doubleCallback) {
                IV3SwapCallback(msg.sender).uniswapV3SwapCallback(-int256(amountOut), int256(ask), data);
            }
        }
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + ask, "mock: input not paid");
        return zeroForOne ? (int256(ask), -int256(amountOut)) : (-int256(amountOut), int256(ask));
    }

    /// A stray callback from a pool that is NOT mid-swap, or an impostor.
    function strayCallback(address exec, int256 a0, int256 a1) external {
        IV3SwapCallback(exec).uniswapV3SwapCallback(a0, a1, "");
    }
}

/// @dev V2-style pair mock with real constant-product reserves and the
/// standard 0.3% (or any) fee check, so the executor's on-chain output
/// formula is exercised for real.
contract MockUniV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint256 public feeNumerator; // surviving share of the input, out of 1000

    constructor(address _token0, address _token1, uint256 _feeNumerator) {
        token0 = _token0;
        token1 = _token1;
        feeNumerator = _feeNumerator;
    }

    /// Reserves follow the balances (call after funding the pair).
    function sync() external {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "mock: no output");
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "mock: no input");
        uint256 adj0 = balance0 * 1000 - amount0In * (1000 - feeNumerator);
        uint256 adj1 = balance1 * 1000 - amount1In * (1000 - feeNumerator);
        require(adj0 * adj1 >= uint256(reserve0) * uint256(reserve1) * 1000 ** 2, "mock: K");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
}
