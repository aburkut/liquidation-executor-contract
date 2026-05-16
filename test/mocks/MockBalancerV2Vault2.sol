// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock Balancer V2 Vault — implements `swap(SingleSwap, FundManagement,
/// limit, deadline)` against a deterministic rate. The first mock in the
/// repo (`MockBalancerVault.sol`) covers only the flashLoan path; this
/// one fills the SwapKind.GIVEN_IN / GIVEN_OUT swap path needed for the
/// new BalancerV2Lib dispatcher.
///
/// poolId is ignored by the mock (one pool per Vault instance). Set
/// `setRate` to flex price; `setRevertNext` to arm a one-shot revert.
contract MockBalancerV2Vault2 {
    using SafeERC20 for IERC20;

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    uint256 public rate; // 1e18 == 1:1
    bool public revertNext;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setRevertNext(bool _r) external {
        revertNext = _r;
    }

    function swap(
        SingleSwap memory s,
        FundManagement memory f,
        uint256 limit,
        uint256 /* deadline */
    )
        external
        payable
        returns (uint256 amountCalculated)
    {
        if (revertNext) {
            revertNext = false;
            revert("MockBalancerV2Vault: forced revert");
        }

        if (s.kind == SwapKind.GIVEN_IN) {
            // SELL: amount = amountIn, limit = amountOutMin
            uint256 amountOut = s.amount * rate / 1e18;
            require(amountOut >= limit, "MockBalancerV2Vault: amountOut < limit");
            IERC20(s.assetIn).safeTransferFrom(f.sender, address(this), s.amount);
            IERC20(s.assetOut).safeTransfer(f.recipient, amountOut);
            return amountOut;
        } else {
            // BUY: amount = amountOut (target), limit = amountInMax
            require(rate > 0, "MockBalancerV2Vault: zero rate");
            uint256 amountIn = (s.amount * 1e18 + rate - 1) / rate; // ceil
            require(amountIn <= limit, "MockBalancerV2Vault: amountIn > limit");
            IERC20(s.assetIn).safeTransferFrom(f.sender, address(this), amountIn);
            IERC20(s.assetOut).safeTransfer(f.recipient, s.amount);
            return amountIn;
        }
    }
}
