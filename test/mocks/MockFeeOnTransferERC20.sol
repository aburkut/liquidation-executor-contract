// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

/// @notice An ERC20 that delivers LESS than it is sent — the FLOKI shape.
///
/// Production 2026-09-11: a `hashflow>v2` FLOKI leg reverted `UniswapV2: K` on
/// 4 of 6 sends once direct pair swaps were enabled, because `DirectSwapLib`
/// priced the output from the pair's reserves BEFORE transferring and the pair
/// then received less than it was sent. Nothing in the suite could reproduce
/// that: every token mock delivers exactly what it is given.
///
/// The tax is applied ONLY to ordinary transfers. Mint (`from == 0`) and burn
/// (`to == 0`) pass through untouched, so a harness that funds an account with
/// `mint` still gets the amount it asked for — otherwise the test would be
/// measuring the funding, not the swap.
contract MockFeeOnTransferERC20 is MockERC20 {
    /// Basis points withheld on every ordinary transfer, out of 10_000.
    uint256 public taxBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 taxBps_)
        MockERC20(name_, symbol_, decimals_)
    {
        require(taxBps_ < 10_000, "mock: tax must leave something");
        taxBps = taxBps_;
    }

    /// OpenZeppelin 5.x routes mint, burn and transfer through `_update`.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || taxBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 tax = (value * taxBps) / 10_000;
        // Burn the withheld share rather than routing it anywhere: the point
        // is only that the recipient receives less than the sender sent.
        super._update(from, to, value - tax);
        super._update(from, address(0), tax);
    }
}
