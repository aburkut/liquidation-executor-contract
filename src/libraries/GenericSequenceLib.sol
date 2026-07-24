// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Op} from "../types/SwapTypes.sol";

/// @dev Subset of WETH9 used by the `FLAG_WETH_UNWRAP` op — the same one-method
/// shape `CoinbasePaymentLib` duplicates. Only `withdraw` is needed; it burns
/// the executor's WETH and forwards native ETH to its `receive()`.
interface IWETH {
    function withdraw(uint256 amount) external;
}

/// @title GenericSequenceLib
/// @notice DELEGATECALL library holding the GENERIC_SEQUENCE op executor,
/// split out of `LiquidationExecutor` to stay under the EIP-170 runtime
/// code-size limit. It runs in the executor's storage/balance context
/// (delegatecall), so `address(this)` is the executor and the token balances
/// read here are the executor's. Only DIRECT-CALL routing ops are supported —
/// ops target allowlisted routers/aggregators (Uni V3 SwapRouter, Curve /
/// Balancer routers) whose calldata is built offchain. The caller
/// (`LiquidationExecutor._runGenericSequence`) pre-validates that every
/// `op.target` is allowlisted before delegating here.
///
/// Errors are duplicated from `LiquidationExecutor` so the DELEGATECALL revert
/// selectors match — the same intentional pattern the sister swap libraries
/// use.
library GenericSequenceLib {
    using SafeERC20 for IERC20;

    /// @dev Selects how the post-sequence repay assertion compares the
    /// executor's loanToken balance against `flashRepayAmount`.
    ///   * Delta    — liquidation: loanToken was SPENT before the sequence
    ///                (on liquidationCall), so the sequence must REPRODUCE
    ///                `flashRepay`; assert `loanAfter - loanBefore >= flashRepay`.
    ///   * Absolute — arbitrage: the flash principal is present at entry and
    ///                the sequence both spends AND reproduces loanToken, so the
    ///                delta gate is short by `loanAmount`; assert the absolute
    ///                `loanAfter >= flashRepay`.
    enum RepayGate {
        Delta,
        Absolute
    }

    error EmptyOps();
    error TooManyOps();
    error InvalidPlan();
    error CalldataPatchOOB();
    error OpCallFailed(uint256 opIndex);
    error OpOutputNotReceived(uint256 opIndex);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error CollateralOverspent(uint256 spent, uint256 allowed);
    error V4InputOverspent(uint256 consumed, uint256 amount);

    /// GENERIC_SEQUENCE op flags — direct-call routing only.
    uint32 internal constant FLAG_USE_FULL_BALANCE = 1 << 0; // inject balanceOf(srcToken) at fromAmountPos
    uint32 internal constant FLAG_USE_PREV_RETURN = 1 << 1; // inject previous op output at fromAmountPos
    /// V4 single-hop exact-out via the PoolManager unlock-callback pattern.
    /// The op's fields are reinterpreted:
    ///   * `target`    = the V4 PoolManager (allowlist-checked by the caller
    ///                   like every op target);
    ///   * `amountIn`  = the EXACT-OUT amount (positive `amountSpec` — the
    ///                   knapsack repay slices are exact-out BUYs);
    ///   * `callData`  = the raw 160-byte single-hop v4SwapData 5-tuple
    ///                   `(tokenIn, tokenOut, fee, tickSpacing, hook)` — NOT
    ///                   selector-prefixed calldata. The lib wraps it into
    ///                   `unlock(abi.encode(inner, int256(amountIn)))` itself,
    ///                   so the unlock-payload shape is correct BY CONSTRUCTION
    ///                   and the executor's `unlockCallback` single-hop branch
    ///                   (with its callback-time hook-allowlist re-check)
    ///                   handles the swap exactly as for structured V4 legs.
    /// Multihop v4SwapData is intentionally NOT accepted here: its hook
    /// allowlist walk lives in the structured-leg pre-flashloan validator,
    /// which generic ops bypass — the strict 160-byte shape keeps the
    /// callback-time hook re-check authoritative.
    uint32 internal constant FLAG_V4_UNLOCK = 1 << 2;
    /// WETH→native-ETH unwrap. The op spends its `srcToken` (which MUST equal
    /// the executor's constructor-pinned `weth`) by calling
    /// `IWETH(weth).withdraw(amountIn)`, converting that WETH to native ETH held
    /// by the executor (its `receive()` accepts the transfer). It funds a
    /// downstream native-ETH V4 leg whose deep pool wants raw ETH, not WETH.
    /// Deliberately a dedicated flag rather than allowlisting WETH: allowlisting
    /// would open WETH's deposit/transfer/withdraw as a general op call surface,
    /// whereas this flag can ONLY invoke `withdraw` on the pinned `weth`. The op
    /// carries no external `target` (the caller's pre-flashloan allowlist walk
    /// exempts unwrap ops for that reason) and produces no ERC20 output, so the
    /// approve/external-call and outToken-delta machinery is skipped. The WETH
    /// spend is still snapshotted and bounded by the per-srcToken containment
    /// cap exactly like any ERC20 op.
    uint32 internal constant FLAG_WETH_UNWRAP = 1 << 3;
    /// V4 EXACT-IN modifier for a `FLAG_V4_UNLOCK` op: pass a NEGATIVE
    /// `amountSpec` so `amountIn` is the exact INPUT sold (not the exact output
    /// bought). Output is whatever the pool gives — the post-op outToken delta
    /// check requires only a positive delta (never `>= amountIn`), and
    /// settle/take use the realized swap delta, so the callback needs no change.
    /// Used by the crash-whale SELL route: sell a fixed unwrapped-ETH amount
    /// through the deep native pool (no exact-out depth cap), then bridge to the
    /// debt token. Only meaningful alongside FLAG_V4_UNLOCK.
    uint32 internal constant FLAG_V4_EXACT_IN = 1 << 4;
    uint32 internal constant FLAG_KNOWN_MASK =
        FLAG_USE_FULL_BALANCE | FLAG_USE_PREV_RETURN | FLAG_V4_UNLOCK | FLAG_WETH_UNWRAP | FLAG_V4_EXACT_IN;
    uint16 internal constant MAX_OPS = 32; // gas-grief bound on sequence length

    /// @dev `LiquidationExecutor` storage slots for the V4 unlock arming
    /// fields. This lib runs via DELEGATECALL, so `sstore` writes the
    /// executor's storage. Slot numbers are pinned against
    /// `forge inspect storageLayout` by `test_v4SlotConstantsMatchLayout`
    /// (same pattern as the replay CLI's allowlist slot constants); any
    /// layout drift fails the suite instead of silently mis-arming.
    /// Slot 10 packs `_activeV4PoolManager` (bytes 0..19) WITH
    /// `_executionPhase` (byte 20) — arming must preserve the high bytes.
    /// Slot 11 packs `_activeV4TokenIn` (bytes 0..19) WITH `_v4Armed`
    /// (byte 20, the re-entry sentinel `unlockCallback` actually gates
    /// on — tokenIn alone can be zero for a native-ETH leg, so this lib
    /// must set the armed bit too, not just tokenIn).
    uint256 private constant V4_PM_SLOT = 10;
    uint256 private constant V4_TOKENIN_SLOT = 11;
    uint256 private constant V4_ARMED_BIT = 1 << 160;

    /// @dev `IPoolManager.unlock(bytes)` selector, pinned by
    /// `test_v4UnlockSelectorPin` (keccak("unlock(bytes)")[..4]) — the same
    /// hardcoded-selector idiom the Curve RouterNG dispatcher uses.
    bytes4 private constant V4_UNLOCK_SELECTOR = 0x48c89491;

    /// @dev Strict size of a single-hop v4SwapData tuple — 5 × 32-byte words.
    /// Mirrors `LiquidationExecutor.V4_SWAP_DATA_LENGTH`.
    uint256 private constant V4_SWAP_DATA_LENGTH = 160;

    /// @notice Execute a flat `Op[]` sequence with per-srcToken containment
    /// (liquidation semantics: cap = collateral, delta repay gate). MUST be
    /// invoked via DELEGATECALL so it shares the executor's storage/balances.
    /// @dev SECURITY NOTE (Task 8 fix 3, accepted-risk — documented, not
    /// code-changed): nothing in this `external` function enforces that it
    /// is reached via DELEGATECALL. A direct CALL to this library's own
    /// deployed address executes the identical logic against the LIBRARY'S
    /// OWN storage/balances instead of a caller's. This is PRE-EXISTING
    /// (shared by `LiquidationExecutor.run` + `ArbExecutor.runArb` + the
    /// `GenericSequenceLibWrapper` test harness, all of which reach this lib
    /// via DELEGATECALL, where `address(this)` is the CALLER, not the
    /// library) and NOT introduced by the arb-parity change.
    /// Harm precondition: tokens must be resting AT THE LIBRARY'S OWN
    /// ADDRESS — abnormal by design, since normal operation only ever moves
    /// funds through an executor's delegatecall context and the library
    /// itself is never a flashloan/liquidation recipient, never holds an
    /// allowance, and is never the `to` of any transfer in this codebase.
    /// No standing balance is expected to accumulate there.
    /// Why no code-level guard: Solidity libraries are STATELESS — no
    /// constructor, no immutable, no state variable — so the usual
    /// `require(address(this) != __self)` anti-direct-call pattern (e.g.
    /// UUPSUpgradeable's `notDelegated`, which relies on a CONTRACT's
    /// immutable self-address set in a constructor) is not directly
    /// expressible here. The alternatives considered were rejected as
    /// riskier than the accepted gap:
    ///   * Embedding this library's own runtime codehash as a hardcoded
    ///     constant and comparing `address(this).codehash` against it is
    ///     self-referential (the constant would need to be computed from a
    ///     build that already includes the constant) — it requires a
    ///     fragile two-pass build/CI step where a mismatch would SILENTLY
    ///     brick the legitimate delegatecall path (false positive), which
    ///     is a worse outcome than the pre-existing gap on a money contract.
    ///   * Any check that inspects the caller's storage/interface (e.g.
    ///     probing for an `owner()`/Ownable slot) couples this SHARED
    ///     library to assumptions about specific callers' storage layout
    ///     across two different executor contracts, and a bug in that probe
    ///     could break the delegatecall path itself.
    /// If a caller ever needs to hold a standing token balance at rest,
    /// revisit this note first — reject the funds settling at the library
    /// address instead of adding the guard here.
    function run(
        Op[] memory ops,
        address loanToken,
        uint256 flashRepayAmount,
        address collateralAsset,
        uint256 collateralDelta,
        address weth
    ) external {
        _executeOps(ops, loanToken, flashRepayAmount, collateralAsset, collateralDelta, weth, RepayGate.Delta);
    }

    /// @notice Execute a flat `Op[]` sequence for ARBITRAGE: the flash
    /// principal `loanAmount` of `loanToken` is present at entry, so the cap
    /// token is `loanToken` (allowed spend = `loanAmount`) and the repay gate
    /// is ABSOLUTE. Every other token keeps allowed-spend 0 (no standing
    /// balance may leave). MUST be invoked via DELEGATECALL.
    /// @dev SECURITY NOTE (Task 8 fix 3, accepted-risk — documented, not
    /// code-changed): see the identical note on `run` above — this function
    /// shares the same unenforced DELEGATECALL-only precondition and the
    /// same rationale for not adding a guard (libraries are stateless; no
    /// clean anti-direct-call mechanic is available that doesn't risk the
    /// `ArbExecutor.execute()` flash pipeline).
    function runArb(Op[] memory ops, address loanToken, uint256 flashRepayAmount, uint256 loanAmount, address weth)
        external
    {
        _executeOps(ops, loanToken, flashRepayAmount, loanToken, loanAmount, weth, RepayGate.Absolute);
    }

    /// @notice Execute a flat `Op[]` sequence with per-srcToken containment.
    /// @dev MUST be invoked via DELEGATECALL (as `GenericSequenceLib.run(...)`)
    /// so it shares the executor's storage and balances. Targets are assumed
    /// pre-validated as allowlisted by the caller.
    function _executeOps(
        Op[] memory ops,
        address loanToken,
        uint256 flashRepayAmount,
        address capToken,
        uint256 capAmount,
        address weth,
        RepayGate repayGate
    ) internal {
        uint256 n = ops.length;
        if (n == 0) revert EmptyOps();
        if (n > MAX_OPS) revert TooManyOps();

        uint256 loanBefore = IERC20(loanToken).balanceOf(address(this));

        // Per-srcToken containment. Snapshot every DISTINCT token any op will
        // spend so the post-check can bound each token's net spend to what THIS
        // tx produced — collateralDelta for the collateral asset, ZERO for
        // everything else. This keeps a compromised operator from routing out a
        // standing/pre-existing balance of ANY token (accumulated profit
        // awaiting owner rescue, aToken residue, donations). Native ETH
        // (srcToken == address(0), a FLAG_V4_UNLOCK leg settling raw ETH) is
        // snapshotted too, via `_balOf` = `address(this).balance` — it gets
        // its own bucket with allowed spend ZERO (see the post-loop cap for
        // why zero is exact, not conservative).
        address[] memory snapTok = new address[](n);
        uint256[] memory snapBal = new uint256[](n);
        uint256 nSnap = 0;
        for (uint256 i = 0; i < n; ++i) {
            address t = ops[i].srcToken;
            bool seen = false;
            for (uint256 j = 0; j < nSnap; ++j) {
                if (snapTok[j] == t) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                snapTok[nSnap] = t;
                snapBal[nSnap] = _balOf(t);
                ++nSnap;
            }
        }

        uint256 prevReturn = 0;

        for (uint256 i = 0; i < n; ++i) {
            Op memory op = ops[i];
            // No native value is ever needed to swap tokens; forbid it so an op
            // cannot push the executor's ETH to an arbitrary target.
            if (op.value != 0) revert InvalidPlan();
            // Every op must declare the token it spends, so the per-srcToken cap
            // snapshots it. srcToken == address(0) means NATIVE ETH and is only
            // meaningful on a native-aware op — a V4 unlock leg, whose callback
            // settles raw ETH via `settle{value}`. On any other op shape 0x0
            // would just mean "unset" (and the direct-call branch would try to
            // forceApprove address(0)), so it stays rejected. A
            // FLAG_WETH_UNWRAP op can never ride this exemption: its branch
            // requires srcToken == weth (nonzero) explicitly.
            if (op.srcToken == address(0) && op.flags & FLAG_V4_UNLOCK == 0) revert InvalidPlan();
            // Only the direct-call routing flags are supported; any other bit is
            // rejected so a stale plan can never silently mis-execute.
            if (op.flags & ~FLAG_KNOWN_MASK != 0) revert InvalidPlan();

            if (op.flags & FLAG_WETH_UNWRAP != 0) {
                // ── WETH → native-ETH unwrap ──
                // An unwrap op does exactly one thing: burn `amountIn` WETH for
                // native ETH. It combines with no other flag (`amountIn` is an
                // explicit literal — FULL_BALANCE / PREV_RETURN would reinterpret
                // it as a derived input, and V4_UNLOCK reinterprets it as an
                // exact-out spec), so require the flag word to be EXACTLY this
                // bit. `srcToken` MUST be the executor's own `weth` — this is
                // what keeps the flag from being a general `withdraw(uint256)`
                // call surface onto any operator-chosen address. The withdrawn
                // WETH is snapshotted in the per-srcToken cap above, so the
                // containment post-check bounds it like any other spend.
                if (op.flags != FLAG_WETH_UNWRAP) revert InvalidPlan();
                if (op.srcToken != weth) revert InvalidPlan();
                if (op.amountIn == 0) revert InvalidPlan();

                IWETH(weth).withdraw(op.amountIn);

                // No ERC20 output to delta-check (native ETH lands in the
                // executor's balance, not an ERC20 balance). Surface the
                // unwrapped amount as the chainable prev-return so a following
                // op can size off it if the plan wants.
                prevReturn = op.amountIn;
                continue;
            }

            // Resolve the input amount. FULL_BALANCE is restricted to the
            // collateral asset (capped at collateralDelta); other inputs come
            // from the previous op's output (chained) or an explicit literal.
            // The per-srcToken cap below is the real backstop.
            uint256 amount = op.amountIn;
            if (op.flags & FLAG_USE_FULL_BALANCE != 0) {
                if (capToken == address(0) || op.srcToken != capToken) revert InvalidPlan();
                uint256 bal = IERC20(capToken).balanceOf(address(this));
                amount = bal < capAmount ? bal : capAmount;
            } else if (op.flags & FLAG_USE_PREV_RETURN != 0) {
                amount = prevReturn;
            }

            uint256 outBefore = _balOf(op.outToken);

            if (op.flags & FLAG_V4_UNLOCK != 0) {
                // ── V4 single-hop exact-out via PoolManager unlock ──
                // The executor's `unlockCallback` (audited for structured V4
                // legs) performs the swap; this branch only arms the two
                // storage fields its guards read (`_activeV4PoolManager`,
                // `_activeV4TokenIn`) and wraps the 160-byte tuple into the
                // canonical unlock payload. Token movement happens inside the
                // callback (settle/take) — no allowance is granted, so the
                // approve/reset pair is skipped. The shared outToken delta
                // check below still pins the swap output to the executor, and
                // the per-srcToken containment cap bounds what the op spends.
                if (op.callData.length != V4_SWAP_DATA_LENGTH) revert InvalidPlan();
                // FULL_BALANCE / PREV_RETURN would make `amount` an INPUT
                // amount, but a V4 op's `amount` is the exact-OUT spec —
                // reject the combination instead of mis-signing the swap.
                if (op.flags & (FLAG_USE_FULL_BALANCE | FLAG_USE_PREV_RETURN) != 0) revert InvalidPlan();
                // Positive int256 discriminates exact-out in the callback;
                // bound the cast so the sign can never flip (mirrors
                // `_executeUniV4Leg`).
                if (amount == 0 || amount > uint256(type(int256).max)) revert InvalidPlan();

                // Arm. Slot 10 packs `_executionPhase` in byte 20 — preserve
                // everything above the address. Slot 11 packs `_v4Armed` in
                // byte 20 — that bit, not tokenIn, is what `unlockCallback`
                // actually gates on, so set it alongside tokenIn.
                uint256 pmSlot = V4_PM_SLOT;
                uint256 tokenInSlot = V4_TOKENIN_SLOT;
                uint256 armedBit = V4_ARMED_BIT;
                address pm = op.target;
                address tokenIn = op.srcToken;
                assembly {
                    let cur := sload(pmSlot)
                    sstore(pmSlot, or(and(cur, not(0xffffffffffffffffffffffffffffffffffffffff)), pm))
                    sstore(tokenInSlot, or(tokenIn, armedBit))
                }

                // Positive amountSpec = exact-out (buy `amount`); negative =
                // exact-in (sell `amount`). Cast is bounded above.
                bool exactInV4 = op.flags & FLAG_V4_EXACT_IN != 0;
                // Per-op input ceiling (parity with `_executeUniV4Leg`'s
                // `consumed <= amountIn`). For exact-IN, the settle must pull
                // no more of the input than `amount`; snapshot the input token
                // (native ETH via `_balOf` = `address(this).balance`, else the
                // ERC20 balance) to bound a settle over-pull per-op instead of
                // relying solely on the end-of-sequence containment cap. Skipped
                // for exact-OUT, where the pool-demanded input legitimately
                // differs from `amount` (the output) — the containment cap
                // governs that direction.
                uint256 v4InBefore = exactInV4 ? _balOf(op.srcToken) : 0;
                int256 amountSpec = exactInV4 ? -int256(amount) : int256(amount);
                (bool okV4, bytes memory retV4) =
                    op.target.call(abi.encodeWithSelector(V4_UNLOCK_SELECTOR, abi.encode(op.callData, amountSpec)));

                // Disarm — the callback CLAIMs tokenIn + the armed bit
                // itself, but clear both defensively (an unlock that never
                // reached our callback must not leave the executor armed
                // for a later stray callback).
                assembly {
                    let cur := sload(pmSlot)
                    sstore(pmSlot, and(cur, not(0xffffffffffffffffffffffffffffffffffffffff)))
                    sstore(tokenInSlot, 0)
                }

                if (!okV4) {
                    if (retV4.length > 0) {
                        assembly {
                            revert(add(retV4, 0x20), mload(retV4))
                        }
                    }
                    revert OpCallFailed(i);
                }

                // Enforce the exact-in input ceiling: consumed input <= amount.
                // A well-formed exact-in settle pulls exactly `amount`, so this
                // is tight; anything above (a settle over-pull dipping standing
                // funds) reverts here rather than only at the containment cap.
                if (exactInV4) {
                    uint256 v4InAfter = _balOf(op.srcToken);
                    uint256 v4Consumed = v4InBefore > v4InAfter ? v4InBefore - v4InAfter : 0;
                    if (v4Consumed > amount) revert V4InputOverspent(v4Consumed, amount);
                }
            } else {
                // Direct call into an allowlisted router/aggregator whose calldata
                // was built offchain. Patch runtime values into the pre-built
                // calldata (bounds-checked), approve exact input, call, then reset.
                // srcToken is provably nonzero here (native srcToken == 0x0 is
                // only admitted with FLAG_V4_UNLOCK, which takes the branch
                // above), so the forceApprove below never targets address(0) —
                // native ETH moves exclusively via `settle{value}` inside the
                // V4 callback, never via allowance.
                bytes memory data = op.callData;
                if (op.fromAmountPos != 0) {
                    _patchWord(data, op.fromAmountPos, amount);
                }
                if (op.returnAmountPos != 0) {
                    _patchWord(data, op.returnAmountPos, prevReturn);
                }
                if (amount != 0) {
                    IERC20(op.srcToken).forceApprove(op.target, amount);
                }

                (bool ok, bytes memory ret) = op.target.call(data); // op.value == 0 (checked above)
                if (!ok) {
                    if (ret.length > 0) {
                        assembly {
                            revert(add(ret, 0x20), mload(ret))
                        }
                    }
                    revert OpCallFailed(i);
                }

                IERC20(op.srcToken).forceApprove(op.target, 0);
            }

            // Output MUST accrue to the executor — pins the swap recipient to
            // this contract. An op whose raw calldata routed output elsewhere
            // produces a zero delta and is rejected. Saturating delta matches
            // the codebase idiom (clean revert instead of a Panic underflow).
            uint256 outBal = _balOf(op.outToken);
            uint256 outDelta = outBal > outBefore ? outBal - outBefore : 0;
            if (outDelta == 0) revert OpOutputNotReceived(i);
            prevReturn = outDelta;
        }

        // Repay leg gate (mirrors the split/mixed-split repay assertion).
        uint256 loanAfter = IERC20(loanToken).balanceOf(address(this));
        if (repayGate == RepayGate.Delta) {
            uint256 repayDelta = loanAfter > loanBefore ? loanAfter - loanBefore : 0;
            if (repayDelta < flashRepayAmount) revert InsufficientRepayOutput(repayDelta, flashRepayAmount);
        } else {
            if (loanAfter < flashRepayAmount) revert InsufficientRepayOutput(loanAfter, flashRepayAmount);
        }

        // Per-srcToken containment cap: no token may be net-spent past what this
        // tx produced (collateralDelta for the collateral asset, 0 otherwise).
        //
        // NATIVE ETH (snapTok == address(0)): allowed is ZERO, and zero is the
        // EXACT bound, not a conservative one. The only ETH this tx
        // legitimately produces is FLAG_WETH_UNWRAP converting THIS tx's
        // seized WETH collateral — and that credit lands AFTER the snapshot
        // above, so a legit unwrap-funded native leg nets >= 0 against the
        // snapshot and passes with allowed = 0. Any net dip below the
        // snapshot is, by construction, STANDING/DONATED ETH leaving the
        // contract (there is no other pre-snapshot ETH source: Aave
        // collateral is always ERC20, never native) and must revert.
        // Deliberately NOT `collateralDelta` when collateralAsset == weth:
        // the WETH bucket already grants collateralDelta to the unwrap spend,
        // so a second collateralDelta grant on the ETH bucket would
        // double-count and let a compromised operator burn up to
        // collateralDelta of standing ETH per tx through a crafted V4 pool
        // (pinned by test_nativeEth_standingSpend_withoutUnwrap_reverts).
        // The `t != address(0)` guard also keeps a zero collateralAsset from
        // ever matching the ETH bucket.
        // @dev Task 8 fix 4 — accepted rationale for the loanToken cap
        // (owner-accepted option (a), NO code change): for `runArb`,
        // `capToken == loanToken` and `capAmount == loanAmount`, so the
        // loanToken bucket's allowed spend below is `loanAmount`, NOT zero —
        // a WEAKER invariant than "no standing loanToken may leave at all"
        // (which is what every other token bucket enforces). A compromised
        // operator could in principle route up to `loanAmount` of a
        // PRE-EXISTING standing loanToken balance out through an op, on top
        // of the legitimate flash principal, without tripping this cap.
        // Accepted because:
        //   (i)   every op `target` is owner-allowlisted (constructor-pinned
        //         routers + `setAllowedTarget`) — honest routers move funds
        //         only to the executor per the outToken-delta check, so a
        //         compromised OPERATOR (not owner) cannot pull-and-return
        //         dust to an attacker-controlled address through this cap;
        //   (ii)  the only path that actually extracts value to outside the
        //         contract at all is the coinbase bribe, which requires the
        //         operator to ALSO control the block builder receiving
        //         `block.coinbase` — i.e. builder collusion, not an
        //         unprivileged operator-only exploit;
        //   (iii) profit is withdrawn PROMPTLY by the owner in normal
        //         operation (see `ArbExecutor.withdraw`), so no large
        //         standing loanToken residual is expected to accumulate and
        //         sit exposed to this weaker cap for long.
        // This is an accepted trade-off, not an oversight — do not tighten
        // the loanToken cap to 0 without re-deriving the repay-gate math
        // (the flash principal MUST be spendable up to `loanAmount`, or
        // `runArb`'s own op sequence could never spend the borrowed funds).
        for (uint256 k = 0; k < nSnap; ++k) {
            address t = snapTok[k];
            uint256 allowed = (t != address(0) && t == capToken) ? capAmount : 0;
            uint256 balAfter = _balOf(t);
            uint256 spent = snapBal[k] > balAfter ? snapBal[k] - balAfter : 0;
            if (spent > allowed) revert CollateralOverspent(spent, allowed);
        }
    }

    /// @dev Balance of `token` held by the executor, treating address(0) as
    /// native ETH — the containment snapshot/cap must see ETH like any other
    /// spendable asset.
    function _balOf(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev Write a 32-byte `value` into `data` at byte offset `pos`, reverting
    /// if the write would read/overwrite out of bounds.
    function _patchWord(bytes memory data, uint256 pos, uint256 value) private pure {
        if (pos + 32 > data.length) revert CalldataPatchOOB();
        assembly {
            mstore(add(add(data, 0x20), pos), value)
        }
    }
}
