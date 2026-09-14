// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title ArbExecutor persistent storage
/// @notice Every persistent variable an arb executor proxy holds, in the order
/// `layout/ArbExecutor.json` pins. `ArbExecutor` and `ArbExecutorGenesis` both
/// inherit it, so the implementation and its initializer cannot disagree about
/// a slot. APPEND ONLY: `script/check_layout.sh` fails CI on any other change.
/// `Initializable` keeps its state in an ERC-7201 namespace and adds no
/// sequential slot; `ReentrancyGuardTransient` uses transient storage.
abstract contract ArbExecutorStorage is Ownable2Step, Pausable, ReentrancyGuardTransient, Initializable {
    mapping(uint8 => address) public allowedFlashProviders;
    /// @dev Generic allowlist for Bebop settlement / future protocol
    /// targets that need owner-curated trust. Uni V2/V3 routers are
    /// constructor-immutable; Curve / Balancer pool addresses are
    /// trusted from the bot (sanity-gated inside their libraries).
    mapping(address => bool) public allowedTargets;
    /// @dev V4 hook BLOCKlist (parity with LiquidationExecutor). Any hook is
    /// accepted unless the owner has blocked it; `unlockCallback` re-checks.
    ///
    /// This used to be an ALLOWlist, curated one owner transaction per hook.
    /// It was dropped for the reason the Curve/Balancer target allowlist was
    /// dropped before it (see LiquidationExecutor's `allowedTargets` notes):
    /// the bot is the trusted source of pools, and a hostile hook can only
    /// make the transaction revert, not take standing funds. What bounds it:
    /// v4-core caps a `beforeSwap` delta at the swap's own amount
    /// (`HookDeltaExceedsSwapAmount`), `runV4UnlockSwap` reverts on any
    /// delta with the wrong sign, `owedIn` is read from the delta rather
    /// than the plan, and `runArb` ends in `checkProfitStrict`, which
    /// refuses a cycle that ended below where it started whatever the
    /// plan's floor says (a zero floor included). The blocklist remains for
    /// a hook that reverts on us on purpose (gas griefing), which no floor
    /// can see.
    mapping(address => bool) public blockedV4Hooks;
    /// @dev Operator allowlist. Several operator EOAs may drive ONE executor
    /// so sends spread over independent nonce streams — one stuck tx then
    /// cannot jam the others, and same-nonce bid fan-out does not have to
    /// fight its own replacements. Owner-curated: an operator key is hot, so
    /// it may only SPEND under the containment caps, never move standing
    /// funds (`withdraw` is onlyOwner).
    mapping(address => bool) public operators;
}
