// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Adversarial Aave-pool mock for the `_verifyATokenAddress`
/// returndatasize defense-in-depth test. Implements `liquidationCall` and
/// `withdraw` enough to drive the executor's main path, but its
/// `getReserveData` returns just 32 bytes (one slot of an attacker-controlled
/// address). Without the returndatasize length check the executor's
/// assembly `mload(add(ptr, 256))` reads stale memory at offset 256 and
/// the `suppliedAToken == canonical` comparison becomes meaningless.
contract ShortReturndataAavePool {
    using SafeERC20 for IERC20;

    uint256 public collateralReward;

    constructor(uint256 _reward) {
        collateralReward = _reward;
    }

    function setCollateralReward(uint256 r) external {
        collateralReward = r;
    }

    function liquidationCall(
        address collateral,
        address debt,
        address,
        uint256 debtToCover,
        bool /*recvAToken*/
    )
        external
    {
        IERC20(debt).safeTransferFrom(msg.sender, address(this), debtToCover);
        IERC20(collateral).safeTransfer(msg.sender, collateralReward);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    /// @dev Returns ONLY 32 bytes — one slot — for the getReserveData
    /// (selector 0x35ea6a75) call. A correct Aave V3 pool returns 480
    /// bytes (15 slots). The contract MUST detect the short return and
    /// reject rather than read garbage at offset 256.
    fallback() external {
        bytes4 sig;
        assembly {
            sig := calldataload(0)
        }
        if (sig == bytes4(0x35ea6a75)) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, 0)
                return(ptr, 32)
            }
        }
    }
}
