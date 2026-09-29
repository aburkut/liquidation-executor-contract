// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./MockERC20.sol";

interface IMockV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice An ERC20 whose transfer TRADES THE PAIR it is being sent to — the
/// FLOKI shape, which `MockFeeOnTransferERC20` does not cover.
///
/// FLOKI's `_transfer` calls `treasuryHandler.beforeTransferHandler(from, to,
/// amount)` BEFORE it moves any balance. On a sell (the recipient is one of the
/// handler's exchange pools) with any accumulated tax on the handler, the
/// handler sells that tax into the primary pool through Uniswap's router — a
/// `swap` on the very pair we are paying — and then FLOKI credits our transfer
/// minus a 0.3% tax, which it books to the handler. Read on chain 2026-09-29
/// (block 26_081_000): the handler held 653 106 FLOKI, so every sell into
/// 0xca7c2771 ran the swap-back first.
///
/// MEASURED 2026-09-14 with `ARB_DIRECT_V2_SWAPS=1`: 52 of 54 `hashflow>v2`
/// sims closing through that pair reverted `UniswapV2: K`. A plain fee-on-
/// transfer mock only shrinks what the pair receives; this one also MOVES THE
/// RESERVES between a pre-transfer read and the swap, which is what #45 fixed.
///
/// Mint (`from == 0`) and burn (`to == 0`) are untouched so a harness funds
/// accounts with exactly what it asks for. The swap-back and the tax are
/// skipped for the token's own transfers, as FLOKI exempts its handler.
contract MockSwapBackERC20 is MockERC20 {
    /// Basis points withheld on every ordinary transfer and booked to the
    /// token itself, which plays FLOKI's treasury handler.
    uint256 public taxBps;
    /// The pair the handler sells into — FLOKI's `primaryPool`.
    address public pool;
    /// Where the swap-back's proceeds go — FLOKI's treasury.
    address public treasury;
    /// Surviving share of the swap-back input, out of 10_000 (the pair's fee).
    uint256 public poolFeeNumerator;
    /// How many swap-backs ran, so a test can prove the hook fired.
    uint256 public swapBacks;

    bool private _inSwapBack;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 taxBps_)
        MockERC20(name_, symbol_, decimals_)
    {
        require(taxBps_ < 10_000, "mock: tax must leave something");
        taxBps = taxBps_;
    }

    function setPool(address pool_, uint256 feeNumerator_, address treasury_) external {
        pool = pool_;
        poolFeeNumerator = feeNumerator_;
        treasury = treasury_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || from == address(this) || _inSwapBack) {
            super._update(from, to, value);
            return;
        }
        // beforeTransferHandler: a sell into the pool with tax on hand trades
        // the pool BEFORE this transfer is credited.
        if (to == pool && balanceOf(address(this)) > 0) _swapBack();

        uint256 tax = (value * taxBps) / 10_000;
        super._update(from, to, value - tax);
        if (tax > 0) super._update(from, address(this), tax);
    }

    /// Router-style sale of the accumulated tax: send, measure what the pair
    /// holds above its reserve, ask for the reserve-formula output.
    function _swapBack() private {
        _inSwapBack = true;
        uint256 amount = balanceOf(address(this));
        bool tokenIs0 = IMockV2Pair(pool).token0() == address(this);
        (uint112 r0, uint112 r1,) = IMockV2Pair(pool).getReserves();
        (uint256 rIn, uint256 rOut) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        super._update(address(this), pool, amount);
        uint256 amountIn = IERC20(address(this)).balanceOf(pool) - rIn;
        uint256 inWithFee = amountIn * poolFeeNumerator;
        uint256 out = (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
        if (tokenIs0) {
            IMockV2Pair(pool).swap(0, out, treasury, "");
        } else {
            IMockV2Pair(pool).swap(out, 0, treasury, "");
        }
        ++swapBacks;
        _inSwapBack = false;
    }
}
