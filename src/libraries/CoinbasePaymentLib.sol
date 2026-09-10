// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Subset of WETH9 interface used for auto-unwrap when ETH is
/// insufficient. Duplicated from `LiquidationExecutor` to avoid an
/// extra interface file just for one method.
interface IWETHCoinbase {
    function withdraw(uint256 amount) external;
}

/// @title CoinbasePaymentLib
/// @notice Shared coinbase-payment + realized-profit accounting for
/// every flashloan-driven executor (`LiquidationExecutor`,
/// `ArbExecutor`).
///
/// SCOPE: pure profit math + a single ETH transfer to `block.coinbase`
/// with optional WETH auto-unwrap. Called via DELEGATECALL — the
/// executor's storage / balance / event topics are the ones that
/// matter, not the library's.
///
/// `weth` is passed as a parameter because libraries cannot read
/// another contract's immutable variables. The caller (each executor)
/// passes its constructor-pinned `weth` address on every call.
///
/// Error selectors match `LiquidationExecutor` by signature so existing
/// tests pinning `LiquidationExecutor.InvalidCoinbase.selector` keep
/// resolving — Solidity computes selectors from `name + params`, not
/// the declaring contract.
library CoinbasePaymentLib {
    // ─── Errors (mirror LiquidationExecutor signatures) ─────────────
    error InvalidCoinbase();
    error InsufficientEth(uint256 required, uint256 available);
    error CoinbasePaymentFailed();
    error CoinbaseExceedsProfit(uint256 coinbase, uint256 profit);
    error InsufficientProfit(uint256 realized, uint256 min);
    /// The cycle holds less than it began with. Distinct from
    /// `InsufficientProfit`, which is about a floor: this one is about a loss.
    error CycleEndedBelowItsStart();

    // CoinbasePaid event dropped 2026-09-06: unread off-chain (the bribe is
    // measured from the coinbase transfer itself), ~1.5k gas per execution.

    /// @dev Gas limit on coinbase ETH transfers. Small bound keeps a
    /// malicious block.coinbase from grinding gas in the callback. ETH
    /// transfer to any well-behaved EOA or builder contract completes
    /// in < 2300 gas; 10_000 is ample slack.
    uint256 internal constant COINBASE_CALL_GAS = 10_000;

    /// @dev Send `amount` ETH to `block.coinbase`. Auto-unwraps WETH
    /// (via `weth`) if the executor doesn't have enough native ETH on
    /// hand. Caller MUST have verified `profitToken == weth` (or
    /// equivalent constraint) before invocation — the lib does not
    /// re-check.
    function payCoinbase(uint256 amount, address weth) external {
        if (amount == 0) return;
        if (block.coinbase == address(0)) revert InvalidCoinbase();

        if (address(this).balance < amount) {
            if (weth != address(0)) {
                uint256 deficit = amount - address(this).balance;
                uint256 wethBal = IERC20(weth).balanceOf(address(this));
                uint256 toUnwrap = deficit < wethBal ? deficit : wethBal;
                if (toUnwrap > 0) {
                    IWETHCoinbase(weth).withdraw(toUnwrap);
                }
            }
        }

        if (address(this).balance < amount) revert InsufficientEth(amount, address(this).balance);

        (bool success,) = block.coinbase.call{value: amount, gas: COINBASE_CALL_GAS}("");
        if (!success) revert CoinbasePaymentFailed();
    }

    /// @dev Realized on-chain profit net of the flashloan obligation,
    /// but BEFORE any coinbase bid is paid. Used as the base for
    /// bps-sized coinbase payments and for the final
    /// `minProfitAmount` check.
    ///
    /// When `profitTkn == asset` (loanToken == profitToken, e.g. arb
    /// or single-asset liquidation):
    ///   * `profitBefore` was snapshotted AFTER flashloan arrival
    ///     (includes principal)
    ///   * `profitNow` is post-swap, pre-repay, pre-coinbase (still
    ///     includes principal)
    ///   * Realized profit once repay settles:
    ///       `(profitNow - repayAmount) - (profitBefore - principalAmount)`
    /// Saturating subtraction — underflow means the swap under-delivered,
    /// and the second return value says so.
    ///
    /// AUDIT LEAD, closed here: the saturation alone reads a LOSS as zero
    /// profit, so with `minProfitAmount == 0` a cycle that ended below where
    /// it started passed `checkProfit` and settled out of standing inventory.
    /// The inventory path arriving with this branch is exactly what makes that
    /// reachable: before it, a cycle had nothing of its own to lose.
    ///
    /// So the shortfall is reported rather than rounded away, and
    /// [`checkProfit`] refuses it whatever the floor says.
    function computeRealizedProfit(
        address asset,
        address profitTkn,
        uint256 profitBefore,
        uint256 principalAmount,
        uint256 repayAmount
    ) external view returns (uint256 profit, bool shortfall) {
        uint256 profitNow = IERC20(profitTkn).balanceOf(address(this));
        if (profitTkn == asset) {
            uint256 lhs = profitNow + principalAmount;
            uint256 rhs = profitBefore + repayAmount;
            return lhs > rhs ? (lhs - rhs, false) : (0, lhs < rhs);
        }
        return profitNow > profitBefore ? (profitNow - profitBefore, false) : (0, profitNow < profitBefore);
    }

    /// @dev `realizedProfit` already accounts for the flashloan
    /// obligation, and `totalCoinbasePayment` is the on-chain
    /// bps-derived sum already paid. The `> realizedProfit` branch is
    /// defensive against multiple coinbase actions whose bps sum
    /// exceeds 100% (each per-action bps is ≤ 10000, but nothing
    /// blocks operators from stacking them).
    /// A cycle that ended BELOW where it started is refused whatever the floor
    /// says: `minProfitAmount == 0` means "any profit will do", never "a loss
    /// will do". See [`computeRealizedProfit`] for how the shortfall survives
    /// the saturation that used to hide it.
    function checkProfitStrict(
        uint256 realizedProfit,
        uint256 totalCoinbasePayment,
        uint256 minProfitAmount,
        bool shortfall
    ) external pure {
        if (shortfall) revert CycleEndedBelowItsStart();
        _checkProfit(realizedProfit, totalCoinbasePayment, minProfitAmount);
    }

    function checkProfit(uint256 realizedProfit, uint256 totalCoinbasePayment, uint256 minProfitAmount) external pure {
        _checkProfit(realizedProfit, totalCoinbasePayment, minProfitAmount);
    }

    function _checkProfit(uint256 realizedProfit, uint256 totalCoinbasePayment, uint256 minProfitAmount) private pure {
        if (totalCoinbasePayment > realizedProfit) {
            revert CoinbaseExceedsProfit(totalCoinbasePayment, realizedProfit);
        }
        uint256 effectiveProfit;
        unchecked {
            effectiveProfit = realizedProfit - totalCoinbasePayment;
        }
        if (effectiveProfit < minProfitAmount) revert InsufficientProfit(effectiveProfit, minProfitAmount);
    }
}
