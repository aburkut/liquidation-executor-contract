// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title LiquidationExecutor persistent storage
/// @notice Every persistent variable a liquidation executor proxy holds, in the
/// order `layout/LiquidationExecutor.json` pins. `LiquidationExecutor` and
/// `LiquidationExecutorGenesis` both inherit it. APPEND ONLY:
/// `script/check_layout.sh` fails CI on any other change. `Initializable` keeps
/// its state in an ERC-7201 namespace and adds no sequential slot.
abstract contract LiquidationExecutorStorage is Ownable2Step, Pausable, ReentrancyGuardTransient, Initializable {
    address public aaveV2LendingPool;
    mapping(uint8 => address) public allowedFlashProviders;
    mapping(address => bool) public allowedTargets;
    /// @dev Owner-curated V4 hook blocklist. Hooks run arbitrary code inside
    /// `beforeSwap`/`afterSwap`; a blocked hook makes a V4 leg revert.
    mapping(address => bool) public blockedV4Hooks;
    /// @dev Operator allowlist. Several operator EOAs may drive ONE executor
    /// so sends spread over independent nonce streams — one stuck tx then
    /// cannot jam the others, and same-nonce bid fan-out does not have to
    /// fight its own replacements. Owner-curated: an operator key is hot, so
    /// it may only SPEND under the containment caps, never move standing
    /// funds.
    mapping(address => bool) public operators;
}
