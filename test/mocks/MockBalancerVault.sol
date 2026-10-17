// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlashLoanRecipient} from "../../src/interfaces/IBalancerVault.sol";

contract MockBalancerVault {
    using SafeERC20 for IERC20;

    uint256 public flashFee;

    constructor(uint256 _flashFee) {
        flashFee = _flashFee;
    }

    function setFlashFee(uint256 _fee) external {
        flashFee = _fee;
    }

    function flashLoan(address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external
    {
        uint256[] memory feeAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            feeAmounts[i] = flashFee;
            tokens[i].safeTransfer(recipient, amounts[i]);
        }

        IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, amounts, feeAmounts, userData);

        // Balancer expects funds returned by end of callback
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 expected = amounts[i] + feeAmounts[i];
            uint256 bal = tokens[i].balanceOf(address(this));
            require(bal >= expected, "MockBalancerVault: insufficient repayment");
        }
    }

    // ─── The vault as a swap venue ───────────────────────────────────
    // Same ABI as Vault.swap (selector 0x52bbbe29; `kind` is the SwapKind
    // enum, a uint8 on the wire). GIVEN_IN only: pulls `amount` of `assetIn`
    // from `funds.sender`, pays `amount * swapRate / 1e18` of `assetOut` to
    // `funds.recipient`.
    struct SingleSwap {
        bytes32 poolId;
        uint8 kind;
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

    uint256 public swapRate = 1.1e18;
    uint256 public swapCalls;

    function setSwapRate(uint256 rate) external {
        swapRate = rate;
    }

    function swap(SingleSwap memory singleSwap, FundManagement memory funds, uint256 limit, uint256)
        external
        payable
        returns (uint256 out)
    {
        swapCalls++;
        IERC20(singleSwap.assetIn).safeTransferFrom(funds.sender, address(this), singleSwap.amount);
        out = (singleSwap.amount * swapRate) / 1e18;
        require(out >= limit, "MockBalancerVault: limit");
        IERC20(singleSwap.assetOut).safeTransfer(funds.recipient, out);
    }
}
