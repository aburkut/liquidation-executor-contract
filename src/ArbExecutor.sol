// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancerVault.sol";
import {IMorphoBlue, IMorphoFlashLoanCallback} from "./interfaces/IMorphoBlue.sol";
import {IPoolManager, IUnlockCallback} from "./interfaces/IPoolManager.sol";
import {AllowanceLib} from "./libraries/AllowanceLib.sol";
import {DirectSwapLib} from "./libraries/DirectSwapLib.sol";
import {UniswapLib} from "./libraries/UniswapLib.sol";
import {GenericSequenceLib} from "./libraries/GenericSequenceLib.sol";
import {CoinbasePaymentLib} from "./libraries/CoinbasePaymentLib.sol";
import {Op} from "./types/SwapTypes.sol";

/// @title ArbExecutor
/// @notice Flashloan-driven N-hop atomic arbitrage executor. Sister
/// contract to `LiquidationExecutor`; shares its `Op` / `GenericSequenceLib`
/// / `CoinbasePaymentLib` infrastructure.
///
/// SCOPE — pure DEX arbitrage:
///   * Flashloan principal from Morpho (fee=0) or Balancer.
///   * Run a flat `Op[]` generic sequence (shared with
///     `LiquidationExecutor` via `GenericSequenceLib`): op1 consumes the
///     loaned principal; subsequent ops chain off the previous op's
///     output via `FLAG_USE_PREV_RETURN` (the typical chain shape) or
///     carry an explicit `amountIn`.
///   * The sequence must reproduce `loanToken` so the contract can
///     settle the flashloan — enforced at runtime by
///     `GenericSequenceLib.runArb`'s ABSOLUTE repay gate
///     (`loanAfter >= flashRepay`), not by static leg-chain validation.
///   * Optional `coinbaseBps` slice of realized profit → `block.coinbase`
///     as a builder bribe (only valid when `loanToken == weth`).
///   * Remaining loan-token balance stays on the contract until the
///     owner calls `withdraw(...)`.
///
/// Out of scope (vs. `LiquidationExecutor`):
///   * No Aave V3 / V2 / Morpho liquidation actions — `ops[]` is the
///     entire payload, no `actions[]` array.
library ArbTypes {
    /// @dev Operator-supplied plan for one arb execution.
    ///
    /// `flashProviderId` selects between Morpho (3, fee=0, preferred)
    /// and Balancer (2, has a `maxFlashFee` cap on the protocol fee).
    ///
    /// Invariants enforced in `execute(...)`:
    ///   * `1 <= ops.length <= GenericSequenceLib.MAX_OPS`
    ///   * every `ops[i].target` is in `allowedTargets`, UNLESS
    ///     `ops[i].flags & GenericSequenceLib.FLAG_WETH_UNWRAP != 0`
    ///     (unwrap ops carry no external target).
    /// Everything else (per-op containment, chaining, the repay gate)
    /// is enforced at runtime inside `GenericSequenceLib.runArb`, which
    /// runs the sequence via DELEGATECALL from the flash callback.
    ///
    /// Coinbase bribe: NOT a plan field. The bid rides in `msg.value`
    /// (wei == basis points) — see `ArbExecutor.execute`. Keeping it out of
    /// the plan is the point: identical plan bytes, and therefore an
    /// identical plan hash, can be re-bid by patching only the tx value.
    /// The bid still requires `loanToken == weth` (the chain must land in
    /// WETH for the coinbase auto-unwrap to have something to convert).
    struct ArbPlan {
        uint8 flashProviderId;
        address loanToken;
        uint256 loanAmount;
        uint256 maxFlashFee;
        Op[] ops;
        uint256 minProfitAmount;
    }
}

contract ArbExecutor is
    Ownable2Step,
    Pausable,
    ReentrancyGuardTransient,
    IFlashLoanRecipient,
    IMorphoFlashLoanCallback,
    IUnlockCallback
{
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidPlan();
    error InvalidFlashProvider(uint8 providerId);
    error InvalidCallbackCaller();
    error InvalidExecutionPhase();
    error NoActivePlan();
    error CallbackAssetMismatch();
    error CallbackAmountMismatch();
    error FlashFeeExceeded(uint256 actual, uint256 maximum);
    error BalancerSingleTokenOnly();
    error InvalidFlashLoan();
    error InsufficientRepayBalance(uint256 required, uint256 available);
    error TargetNotAllowed();
    error UnauthorizedOperator();
    error CoinbaseRequiresWethLoan();
    // Coinbase errors duplicated for ABI compat (selectors match
    // CoinbasePaymentLib by signature).
    error InvalidCoinbase();
    error InsufficientEth(uint256 required, uint256 available);
    error CoinbasePaymentFailed();
    error CoinbaseExceedsProfit(uint256 coinbase, uint256 profit);
    error InsufficientProfit(uint256 realized, uint256 min);
    error InvalidV4CallbackHook();

    // ─── Events ──────────────────────────────────────────────────────
    event ArbExecuted(
        bytes32 indexed planHash, address indexed loanToken, uint256 realizedProfit, uint256 coinbasePaid
    );
    event AllowedTargetUpdated(address indexed target, bool allowed);
    // V10+: FlashProviderUpdated dropped — both providers constructor-pinned.
    event Withdraw(address indexed token, address indexed to, uint256 amount);
    event V4HookAllowedUpdated(address indexed hook, bool allowed);
    event OperatorUpdated(address indexed operator, bool allowed);

    // ─── Constants ───────────────────────────────────────────────────
    uint8 public constant FLASH_PROVIDER_BALANCER = 2;
    uint8 public constant FLASH_PROVIDER_MORPHO = 3;
    uint256 private constant V4_SWAP_DATA_LENGTH = 160;
    /// @dev TRANSIENT-storage slot (EIP-1153) holding this tx's coinbase bid
    /// in basis points, captured from `msg.value` in `execute` and read back
    /// inside the flash callback. Transient, not storage, for two reasons: a
    /// real slot would shift the V4 arming fields `GenericSequenceLib`
    /// raw-`sstore`s at pinned numbers, and transient storage self-clears at
    /// end of tx so a stale bid can never leak into a later one. Transient
    /// and persistent storage have SEPARATE address spaces — slot 0 here does
    /// not alias `_owner`.
    uint256 private constant BID_BPS_TSLOT = 0;
    /// @dev TRANSIENT slots for the per-transaction execution state the
    /// callbacks gate on: the hash of the plan being executed and whether an
    /// `execute` is in flight. These used to be persistent storage
    /// (`_activePlanHash`, `_executionPhase`), written at entry and cleared
    /// at exit: two SSTOREs from zero and two clears per transaction, about
    /// 30k gas net of refunds, for state that by construction never outlives
    /// the transaction. Transient storage costs 100 gas a write, self-clears,
    /// and keeps the same guard semantics inside the transaction — a callback
    /// that arrives outside `execute` still finds the phase unset.
    uint256 private constant PLAN_HASH_TSLOT = 1;
    uint256 private constant PHASE_TSLOT = 2;
    /// @dev TRANSIENT slots `GenericSequenceLib.runArb*` arms for a V4 leg
    /// (same numbers as its persistent `V4_PM_SLOT`/`V4_TOKENIN_SLOT`, other
    /// address space): word 11 = the PoolManager mid-unlock, word 12 = the
    /// input token in the low 160 bits with the armed bit at 160.
    uint256 private constant V4_PM_TSLOT = 11;
    uint256 private constant V4_TOKENIN_TSLOT = 12;
    uint256 private constant V4_ARMED_BIT = 1 << 160;

    // ─── Immutables (constructor-pinned) ─────────────────────────────
    address public immutable weth;
    address public immutable paraswapAugustusV6;
    address public immutable uniV2Router;
    address public immutable uniV3Router;

    // ─── Storage ─────────────────────────────────────────────────────
    // Layout NOTE: the V4 arming fields MUST land at slots 11/12 to match
    // GenericSequenceLib's pinned V4_PM_SLOT/V4_TOKENIN_SLOT constants (the
    // lib sstores into them via DELEGATECALL). test_v4SlotConstantsMatchLayout
    // is the authority — if it fails, adjust the field order/padding below.
    /// @dev The two flash providers are constructor-pinned and read on the
    /// hot path (provider dispatch, callback caller checks): immutables cost
    /// nothing to read where a storage slot costs 2.1k cold. The
    /// `allowedFlashProviders` mapping stays for the ABI (getter, deploy
    /// read-backs) and is written once, in the constructor.
    address public immutable morphoBlue;
    address public immutable balancerVault;
    mapping(uint8 => address) public allowedFlashProviders;
    /// @dev Generic allowlist for Bebop settlement / future protocol
    /// targets that need owner-curated trust. Uni V2/V3 routers are
    /// constructor-immutable; Curve / Balancer pool addresses are
    /// trusted from the bot (sanity-gated inside their libraries).
    mapping(address => bool) public allowedTargets;
    /// @dev V4 hook allowlist (parity with LiquidationExecutor). Owner-curated;
    /// the unlockCallback single-hop branch re-checks `allowedV4Hooks[hook]`.
    mapping(address => bool) public allowedV4Hooks;
    /// @dev Operator allowlist. Several operator EOAs may drive ONE executor
    /// so sends spread over independent nonce streams — one stuck tx then
    /// cannot jam the others, and same-nonce bid fan-out does not have to
    /// fight its own replacements. Seeded with the constructor's `operator_`.
    /// Owner-curated: an operator key is hot, so it may only SPEND under the
    /// containment caps, never move standing funds (`withdraw` is onlyOwner).
    mapping(address => bool) public operators;

    // No per-transaction execution state lives in persistent storage any
    // more: the plan hash, the phase and the V4 arming words (`V4_PM_TSLOT`,
    // `V4_TOKENIN_TSLOT`, written by `GenericSequenceLib.runArb*`) are all
    // transient. The padding that once aligned V4 fields to slots 11/12 is
    // gone with them — nothing raw-`sstore`s into this contract.

    // ─── Constructor ─────────────────────────────────────────────────
    /// @dev Both flash providers (Balancer Vault + Morpho Blue) are
    /// constructor-pinned. Mainnet addresses (`0xBA12…BF2C8`,
    /// `0xBBBB…EEFFCb`) have been stable since launch; rotation
    /// requires redeploy. Eliminates the "did you call
    /// configureMorpho?" post-deploy footgun.
    constructor(
        address owner_,
        address operator_,
        address weth_,
        address balancerVault_,
        address morpho_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    ) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (morpho_ == address(0)) revert ZeroAddress();
        if (paraswapAugustus_ == address(0)) revert ZeroAddress();
        if (uniV2Router_ == address(0)) revert ZeroAddress();
        if (uniV3Router_ == address(0)) revert ZeroAddress();

        operators[operator_] = true;
        emit OperatorUpdated(operator_, true);
        weth = weth_;
        paraswapAugustusV6 = paraswapAugustus_;
        uniV2Router = uniV2Router_;
        uniV3Router = uniV3Router_;
        morphoBlue = morpho_;
        balancerVault = balancerVault_;

        allowedFlashProviders[FLASH_PROVIDER_BALANCER] = balancerVault_;
        allowedFlashProviders[FLASH_PROVIDER_MORPHO] = morpho_;
        // Seed allowedTargets with the routers + Paraswap so Bebop
        // dispatch can re-check `allowedTargets[bebopTarget]` if used.
        // Balancer Vault is ALSO seeded here because it doubles as a
        // legitimate swap venue in the cross-venue routing (not just a
        // flash-loan source), so a generic `Op` may legitimately target it.
        // Morpho Blue is deliberately NOT seeded here (audit fix, N-Task 5
        // fix 1): the flash-repay path never needs `allowedTargets` — it is
        // reached exclusively via `allowedFlashProviders[FLASH_PROVIDER_MORPHO]`,
        // and repayment is a `forceApprove(msg.sender=Morpho, flashRepay)`
        // that bypasses this mapping entirely. Seeding it here would only
        // expose Morpho Blue's full function surface as a generic `Op`
        // target, contradicting this contract's own "no liquidation
        // actions" scope (see the contract NatSpec above).
        allowedTargets[balancerVault_] = true;
        allowedTargets[paraswapAugustus_] = true;
        allowedTargets[uniV2Router_] = true;
        allowedTargets[uniV3Router_] = true;

        for (uint256 i = 0; i < allowedTargets_.length; ++i) {
            if (allowedTargets_[i] == address(0)) revert ZeroAddress();
            allowedTargets[allowedTargets_[i]] = true;
        }
    }

    // ─── Modifiers ───────────────────────────────────────────────────
    modifier onlyOperator() {
        if (!operators[msg.sender]) revert UnauthorizedOperator();
        _;
    }

    // ─── Owner: admin ────────────────────────────────────────────────
    // V10+: `configureMorpho` and `setFlashProvider` removed. Both
    // flash providers are constructor-pinned; rotation requires
    // redeploy.

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = allowed;
        emit AllowedTargetUpdated(target, allowed);
    }

    /// @notice Take back a spender's allowance on `token`.
    ///
    /// AUDITED 2026-09-08: `setAllowedTarget(t, false)`, `setOperator(op,
    /// false)` and `pause()` are the documented kill-switches for a leaked hot
    /// key, and none of them can touch an ERC20 allowance — `withdraw` and the
    /// `rescue*` family only move tokens this contract still holds. So a
    /// spender's power over future balances outlived every revocation the
    /// owner had. This is the missing half.
    function revokeAllowance(address token, address spender) external onlyOwner {
        if (token == address(0) || spender == address(0)) revert ZeroAddress();
        IERC20(token).forceApprove(spender, 0);
    }

    /// @notice Add or remove an operator EOA authorised to call `execute`.
    /// @dev Deliberately NOT self-service: only the owner may rotate keys.
    /// Revoking is immediate, which is the kill-switch for a leaked hot key
    /// (`pause()` remains the blanket stop). The owner can revoke every
    /// operator, leaving the executor callable by nobody — intended, and
    /// symmetric with `pause()`.
    function setOperator(address operator_, bool allowed) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operators[operator_] = allowed;
        emit OperatorUpdated(operator_, allowed);
    }

    /// @notice Flag a Uniswap V4 hook contract as allowed inside V4 swaps.
    /// @dev Hooks execute arbitrary logic during `beforeSwap`/`afterSwap` on the
    /// PoolManager; any non-zero hook that is NOT in this whitelist causes the
    /// V4 path to revert with `InvalidPlan`. Default is empty — operator
    /// routes MUST stay on hook-less pools unless the owner explicitly enables
    /// a hook after review.
    function setV4HookAllowed(address hook, bool allowed) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        allowedV4Hooks[hook] = allowed;
        emit V4HookAllowedUpdated(hook, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Owner: profit withdrawal ────────────────────────────────────
    /// @dev Sweep accumulated arb profit (or any other token sitting on
    /// the contract). Profit by design stays here until owner withdraws.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert CoinbasePaymentFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdraw(token, to, amount);
    }

    receive() external payable {}

    // ─── Core entry point ────────────────────────────────────────────
    /// @notice Operator-only. Decode + validate the arb plan, then
    /// borrow `loanAmount` of `loanToken` from the chosen flash
    /// provider. Chain execution + repay + coinbase + profit guard run
    /// inside the provider's callback.
    /// @notice Execute an arb plan. **The coinbase bid rides in `msg.value`**,
    /// denominated in BASIS POINTS (wei == bps, so 9_850 wei ⇒ 98.50% of
    /// realized profit to `block.coinbase`); the wei itself is dust that stays
    /// on the contract, it is a parameter and not the payment.
    ///
    /// Why not a calldata field: the bid is then OUTSIDE the ABI-encoded plan
    /// and outside its hash, so one pre-built plan blob can be re-bid by
    /// patching only the 32-byte value field — no re-encoding of a large
    /// `Op[]` to change aggression. (Saving ~500 gas of calldata is the minor
    /// benefit; not re-encoding on the hot path is the real one.) Copied from
    /// the top competitor's executor, which encodes the same thing in permille
    /// — we keep the 10_000 scale for the finer resolution.
    ///
    /// The bid is stashed in TRANSIENT storage because it must survive into
    /// the flash-callback frame, where `msg.value` is 0 (the callback is a
    /// fresh call from the flash provider, not from the operator).
    function execute(bytes calldata planData) external payable onlyOperator whenNotPaused nonReentrant {
        _execute(abi.decode(planData, (ArbTypes.ArbPlan)), planData);
    }

    /// @notice `execute` for a PACKED plan. ABI encoding of an `ArbPlan`
    /// costs 2.2-2.6 KB of calldata for a two- or three-op cycle (a 32-byte
    /// word per field, offsets, padding — half of it zero bytes), i.e.
    /// 37-39k of intrinsic gas against the competitor's 24-32k. The packed
    /// form below is ~100 bytes per op. It is decoded once into the same
    /// `ArbPlan` and takes the same path as `execute`; the plan hash the
    /// callbacks gate on and the event carries is over the ABI re-encoding,
    /// so it is the same hash `execute` would have used for this plan.
    ///
    /// Layout (big-endian, no padding):
    ///   u8 version (1) | u8 flashProviderId | address loanToken |
    ///   u128 loanAmount | u128 minProfitAmount | u128 maxFlashFee | u8 nOps
    ///   then per op:
    ///   address target | u16 flags | u128 amountIn | u16 fromAmountPos |
    ///   u16 returnAmountPos | address srcToken | address outToken |
    ///   callData: V3 direct/flash → u8 zeroForOne, u160 sqrtPriceLimitX96;
    ///             V2 direct/flash → u8 zeroForOne, u16 feeNumerator;
    ///             otherwise       → u16 len, len bytes.
    function executePacked(bytes calldata packed) external payable onlyOperator whenNotPaused nonReentrant {
        ArbTypes.ArbPlan memory plan = _decodePacked(packed);
        _execute(plan, abi.encode(plan));
    }

    uint8 private constant PACKED_VERSION = 1;

    error PackedPlanMalformed();

    function _decodePacked(bytes calldata p) private pure returns (ArbTypes.ArbPlan memory plan) {
        if (p.length < 71 || uint8(p[0]) != PACKED_VERSION) revert PackedPlanMalformed();
        plan.flashProviderId = uint8(p[1]);
        plan.loanToken = address(bytes20(p[2:22]));
        plan.loanAmount = uint128(bytes16(p[22:38]));
        plan.minProfitAmount = uint128(bytes16(p[38:54]));
        plan.maxFlashFee = uint128(bytes16(p[54:70]));
        uint256 n = uint8(p[70]);
        plan.ops = new Op[](n);
        uint256 o = 71;
        for (uint256 i = 0; i < n; ++i) {
            if (p.length < o + 82) revert PackedPlanMalformed();
            Op memory op = plan.ops[i];
            op.target = address(bytes20(p[o:o + 20]));
            op.flags = uint16(bytes2(p[o + 20:o + 22]));
            op.amountIn = uint128(bytes16(p[o + 22:o + 38]));
            op.fromAmountPos = uint16(bytes2(p[o + 38:o + 40]));
            op.returnAmountPos = uint16(bytes2(p[o + 40:o + 42]));
            op.srcToken = address(bytes20(p[o + 42:o + 62]));
            op.outToken = address(bytes20(p[o + 62:o + 82]));
            o += 82;
            if (op.flags & (GenericSequenceLib.FLAG_V3_DIRECT | GenericSequenceLib.FLAG_V3_FLASH) != 0) {
                if (p.length < o + 21) revert PackedPlanMalformed();
                op.callData = abi.encode(uint8(p[o]) != 0, uint160(bytes20(p[o + 1:o + 21])));
                o += 21;
            } else if (op.flags & (GenericSequenceLib.FLAG_V2_DIRECT | GenericSequenceLib.FLAG_V2_FLASH) != 0) {
                if (p.length < o + 3) revert PackedPlanMalformed();
                op.callData = abi.encode(uint8(p[o]) != 0, uint16(bytes2(p[o + 1:o + 3])));
                o += 3;
            } else {
                if (p.length < o + 2) revert PackedPlanMalformed();
                uint256 len = uint16(bytes2(p[o:o + 2]));
                o += 2;
                if (p.length < o + len) revert PackedPlanMalformed();
                op.callData = p[o:o + len];
                o += len;
            }
        }
        if (o != p.length) revert PackedPlanMalformed();
    }

    function _execute(ArbTypes.ArbPlan memory plan, bytes memory planData) private {
        // Plan invariants — fail fast pre-flashloan.
        if (plan.loanToken == address(0)) revert ZeroAddress();
        if (plan.loanAmount == 0) revert InvalidPlan();
        if (plan.ops.length == 0 || plan.ops.length > GenericSequenceLib.MAX_OPS) revert InvalidPlan();

        uint256 bidBps = msg.value;
        if (bidBps > 10_000) revert InvalidPlan();
        if (bidBps > 0 && plan.loanToken != weth) revert CoinbaseRequiresWethLoan();
        // Written UNCONDITIONALLY, zero included: transient storage lives for
        // the whole TRANSACTION, not one call frame, so a second `execute` in
        // the same tx would otherwise inherit the previous call's bid.
        assembly ("memory-safe") {
            tstore(BID_BPS_TSLOT, bidBps)
        }

        // Pre-flashloan allowlist walk: every op target must be allowlisted.
        // FLAG_WETH_UNWRAP ops carry no external target (they call the pinned
        // weth.withdraw), so they are exempt. EXACT-equality, not
        // bit-presence: a combined-flag op (e.g. FLAG_WETH_UNWRAP |
        // FLAG_V4_UNLOCK) DOES carry an external target (`op.target`, reused
        // as the V4 leg's PoolManager under the other flag), so bit-presence
        // would wrongly skip the allowlist check for it. Mirrors
        // GenericSequenceLib's own runtime guard (`op.flags !=
        // FLAG_WETH_UNWRAP` → InvalidPlan), which already only treats a
        // flags word EXACTLY equal to FLAG_WETH_UNWRAP as a real unwrap —
        // this keeps the pre-flight walk in lockstep with that authority
        // instead of relying on it as the sole backstop.
        for (uint256 i = 0; i < plan.ops.length; ++i) {
            if (plan.ops[i].flags == GenericSequenceLib.FLAG_WETH_UNWRAP) continue;
            // Direct pool swaps name the pool itself as the target: pools are
            // permissionless and bounded by construction (the op spends at
            // most its own `amount`, see DirectSwapLib), so they are not
            // allowlisted — exactly the exposure of an allowlisted router
            // routing into an arbitrary pool.
            if (plan.ops[i].flags & GenericSequenceLib.FLAG_DIRECT_ANY != 0) {
                continue;
            }
            if (!allowedTargets[plan.ops[i].target]) revert TargetNotAllowed();
        }

        // INVENTORY path: when the contract already holds the principal, the
        // flash loan is pure overhead — provider call, transfer in, callback,
        // second decode of the plan, transfer back: about 55k gas on a Morpho
        // cycle. Run the sequence straight off the standing balance instead.
        // The containment cap is the same (`loanAmount` of `loanToken` may be
        // spent, nothing else), and the pipeline requires the balance not to
        // shrink, so a losing cycle reverts exactly as an unrepayable flash
        // would. The bot needs no new field: a plan naming a flash provider
        // simply does not use it when the inventory covers it.
        //
        // SECURITY: a standing balance is exposed to the accepted operator-key
        // risk documented on the loanToken cap in `GenericSequenceLib`
        // (up to `loanAmount` per tx through an adversarial pool). The owner
        // sizes the inventory with that in mind; `withdraw` drains it.
        // SELF-FUNDED path: a sequence whose first op is a FLASH swap gets its
        // principal from that pool (paid back at the end of the sequence out
        // of the cycle's proceeds), so neither a loan nor inventory is needed.
        bool selfFunded = plan.ops[0].flags & (GenericSequenceLib.FLAG_V3_FLASH | GenericSequenceLib.FLAG_V2_FLASH) != 0;
        if (selfFunded || IERC20(plan.loanToken).balanceOf(address(this)) >= plan.loanAmount) {
            _setPhase(true);
            _runArbPipeline(plan, 0, address(this), keccak256(planData));
            _setPhase(false);
            return;
        }

        address provider = plan.flashProviderId == FLASH_PROVIDER_MORPHO
            ? morphoBlue
            : (plan.flashProviderId == FLASH_PROVIDER_BALANCER ? balancerVault : address(0));
        if (provider == address(0)) revert InvalidFlashProvider(plan.flashProviderId);

        // Pin plan hash for the callback gate. The phase + hash pair
        // is the only thing standing between a hostile caller and the
        // flashloan-borrowed funds; both MUST be set BEFORE the
        // external flash call.
        _setPlanHash(keccak256(planData));
        _setPhase(true);

        if (plan.flashProviderId == FLASH_PROVIDER_MORPHO) {
            IMorphoBlue(provider).flashLoan(plan.loanToken, plan.loanAmount, planData);
        } else if (plan.flashProviderId == FLASH_PROVIDER_BALANCER) {
            IERC20[] memory tokens = new IERC20[](1);
            tokens[0] = IERC20(plan.loanToken);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = plan.loanAmount;
            IBalancerVault(provider).flashLoan(address(this), tokens, amounts, planData);
        } else {
            revert InvalidFlashProvider(plan.flashProviderId);
        }

        _setPlanHash(bytes32(0));
        _setPhase(false);
    }

    // ─── Transient execution state ───────────────────────────────────
    function _planHash() private view returns (bytes32 h) {
        assembly ("memory-safe") {
            h := tload(PLAN_HASH_TSLOT)
        }
    }

    function _setPlanHash(bytes32 h) private {
        assembly ("memory-safe") {
            tstore(PLAN_HASH_TSLOT, h)
        }
    }

    function _phaseActive() private view returns (bool active) {
        assembly ("memory-safe") {
            active := tload(PHASE_TSLOT)
        }
    }

    function _setPhase(bool active) private {
        assembly ("memory-safe") {
            tstore(PHASE_TSLOT, active)
        }
    }

    // ─── Flashloan callbacks ─────────────────────────────────────────
    /// @dev Balancer V2 Vault calls back here mid-flashLoan. We must
    /// transfer `amounts[i] + feeAmounts[i]` back to msg.sender (=vault)
    /// before this function returns.
    function receiveFlashLoan(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external override {
        if (!_phaseActive()) revert InvalidExecutionPhase();
        bytes32 planHash = _planHash();
        if (planHash == bytes32(0)) revert NoActivePlan();
        if (msg.sender != balancerVault) revert InvalidCallbackCaller();
        if (keccak256(userData) != planHash) revert InvalidPlan();
        // V10 audit fix: clear plan hash to block callback re-entry
        // within the same flash. The triple-gate (phase + hash + caller)
        // is otherwise stable for the entire flash window — a hostile
        // or buggy flash provider invoking the callback twice would pass
        // all three checks without this clear.
        _setPlanHash(bytes32(0));
        if (tokens.length != 1) revert BalancerSingleTokenOnly();

        ArbTypes.ArbPlan memory plan = abi.decode(userData, (ArbTypes.ArbPlan));

        if (address(tokens[0]) != plan.loanToken) revert CallbackAssetMismatch();
        if (amounts[0] != plan.loanAmount) revert CallbackAmountMismatch();
        if (feeAmounts[0] > plan.maxFlashFee) revert FlashFeeExceeded(feeAmounts[0], plan.maxFlashFee);

        uint256 flashRepay = amounts[0] + feeAmounts[0];
        _runArbPipeline(plan, flashRepay, msg.sender, planHash);
    }

    /// @dev Morpho Blue flashloan callback. Morpho is fee-free; it pulls
    /// repayment via `safeTransferFrom` AFTER this returns, so we
    /// approve `msg.sender` (the Morpho contract) for `amount` rather
    /// than transferring out.
    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external override {
        if (!_phaseActive()) revert InvalidExecutionPhase();
        bytes32 planHash = _planHash();
        if (planHash == bytes32(0)) revert NoActivePlan();
        if (msg.sender != morphoBlue) revert InvalidCallbackCaller();
        if (keccak256(data) != planHash) revert InvalidPlan();
        // V10 audit fix: clear plan hash to block callback re-entry.
        // Mirror of `receiveFlashLoan`.
        _setPlanHash(bytes32(0));

        ArbTypes.ArbPlan memory plan = abi.decode(data, (ArbTypes.ArbPlan));
        if (amount != plan.loanAmount) revert CallbackAmountMismatch();

        // Morpho fee = 0
        _runArbPipeline(plan, amount, address(0), planHash);
    }

    /// @inheritdoc IUnlockCallback
    /// @notice PRODUCTION SCOPE — this callback implements exactly ONE shape:
    ///   exact-input single-hop ERC20→ERC20 swap inside the flashloan pipeline.
    /// @dev Three layers of protection against stray or adversarial calls:
    ///   1. the transient phase flag        — only valid inside execute()
    ///   2. the transient armed bit         — only while a V4 leg is mid-unlock
    ///   3. `msg.sender` == the transient PoolManager word — only the pinned PoolManager
    /// Verbatim port of `LiquidationExecutor.unlockCallback` (line 1509) —
    /// same guards, same re-entry CLAIM-on-entry discipline, same
    /// single-hop/multihop dispatch on `inner.length`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (!_phaseActive()) revert InvalidExecutionPhase();
        // tokenIn is read from the transient arming word (pinned by the V4
        // leg arming path in `GenericSequenceLib.runArb*`) rather than from
        // `data` — the PM controls the data, not our transient storage, so
        // substitution is impossible by construction. The re-entry guard is
        // the armed bit (NOT tokenIn != 0 — that collided with native-ETH
        // legs, where tokenIn == address(0) by design): claiming it (clearing
        // the word) on entry means a nested unlockCallback from inside swap()
        // finds it unarmed and the combined check below fails closed,
        // regardless of what tokenIn is. The msg.sender check covers the
        // not-in-flow case (PM word == 0 → msg.sender != 0 = always true).
        address tokenIn;
        bool armed;
        address pm;
        assembly ("memory-safe") {
            let w := tload(V4_TOKENIN_TSLOT)
            tokenIn := and(w, 0xffffffffffffffffffffffffffffffffffffffff)
            armed := gt(and(w, V4_ARMED_BIT), 0)
            pm := tload(V4_PM_TSLOT)
            // CLAIM — a nested unlockCallback finds the word cleared and fails closed.
            tstore(V4_TOKENIN_TSLOT, 0)
        }
        if (!armed || msg.sender != pm) revert InvalidCallbackCaller();

        // Uniform unlock-data shape for single-hop AND multihop:
        //   abi.encode(bytes inner, int256 amountSpec)
        // where `inner` is the leg's `v4SwapData` passed verbatim by the
        // arming path. inner.length distinguishes the modes:
        //   == V4_SWAP_DATA_LENGTH (160) → single-hop 5-tuple inside
        //   >  V4_SWAP_DATA_LENGTH       → multihop V4Hop[] inside
        (bytes memory inner, int256 amountSpec) = abi.decode(data, (bytes, int256));
        if (inner.length == V4_SWAP_DATA_LENGTH) {
            (, address tokenOut, uint24 fee, int24 tickSpacing, address hook) =
                abi.decode(inner, (address, address, uint24, int24, address));
            if (hook != address(0) && !allowedV4Hooks[hook]) revert InvalidV4CallbackHook();
            UniswapLib.runV4UnlockSwap(IPoolManager(msg.sender), tokenIn, tokenOut, fee, tickSpacing, hook, amountSpec);
        } else {
            UniswapLib.runV4UnlockMultihop(IPoolManager(msg.sender), tokenIn, data);
        }
        return "";
    }

    // ─── Direct / flash pool swaps: the pool pulls its input through here ───
    /// @dev Called by a V3-style pool mid-`swap`. Empty data = a
    /// `FLAG_V3_DIRECT` op: pay now, only the armed pool, never more than the
    /// op's amount. Non-empty data = a `FLAG_V3_FLASH` op: the data is the
    /// rest of the sequence (verified by hash), which runs HERE, and the pool
    /// is paid last out of what it produced (DirectSwapLib). Pancake V3
    /// pools use the second name.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _v3Callback(amount0Delta, amount1Delta, data);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _v3Callback(amount0Delta, amount1Delta, data);
    }

    function _v3Callback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) private {
        if (data.length == 0) {
            DirectSwapLib.payV3Callback(amount0Delta, amount1Delta);
            return;
        }
        (address tokenIn, uint256 maxOwed) = DirectSwapLib.beginContinuation(data);
        address pool = msg.sender;
        GenericSequenceLib.continueOps(data, DirectSwapLib.receivedV3(amount0Delta, amount1Delta));
        DirectSwapLib.settleV3(pool, amount0Delta, amount1Delta, tokenIn, maxOwed);
    }

    /// @dev Called by a V2-style pair mid-`swap` for a `FLAG_V2_FLASH` op
    /// (pairs only call back when the swap carries data). Same continuation
    /// as V3; the pair is then sent exactly the op's input and applies its
    /// own K check. Pancake V2 pairs use the second name.
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        _v2Callback(sender, amount0, amount1, data);
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        _v2Callback(sender, amount0, amount1, data);
    }

    function _v2Callback(address sender, uint256 amount0, uint256 amount1, bytes calldata data) private {
        if (sender != address(this)) revert InvalidCallbackCaller();
        (address tokenIn, uint256 owed) = DirectSwapLib.beginContinuation(data);
        address pair = msg.sender;
        GenericSequenceLib.continueOps(data, amount0 > 0 ? amount0 : amount1);
        DirectSwapLib.settleV2(pair, tokenIn, owed);
    }

    // ─── Pipeline (inside flash) ─────────────────────────────────────
    /// @dev `vault == address(0)` ⇒ approve-only (Morpho pulls).
    /// `vault != 0` ⇒ push transfer to the vault. `vault == address(this)`
    /// ⇒ the contract's own inventory, nothing to repay. `planHash` is
    /// captured by the caller BEFORE it clears the transient plan hash (the
    /// V10 re-entry guard) — reading the slot from here would always see the
    /// already-cleared bytes32(0) (Task 8 fix 1).
    function _runArbPipeline(ArbTypes.ArbPlan memory plan, uint256 flashRepay, address vault, bytes32 planHash)
        internal
    {
        address loanToken = plan.loanToken;
        // `vault == address(this)` ⇒ the principal is the contract's own
        // inventory: nothing was borrowed, nothing is repaid, and the profit
        // is simply the balance delta.
        bool inventory = vault == address(this);

        // Verify the flash actually arrived. On the inventory path `execute`
        // already saw the balance cover it — or the first op is a flash swap
        // that supplies its own principal — so the check is the loan path's.
        if (!inventory && IERC20(loanToken).balanceOf(address(this)) < plan.loanAmount) revert InvalidFlashLoan();

        // Snapshot loanToken BEFORE the sequence runs. For arb the flash
        // principal has already arrived (checked above), so this baseline
        // equals `plan.loanAmount` (plus any pre-existing residual balance
        // the contract was holding from an earlier arb's retained profit).
        // `computeRealizedProfit` backs `plan.loanAmount` out of this
        // baseline below, so the residual — if any — cancels out on both
        // sides and does not distort `realizedProfit` (traced in
        // task-5-report.md).
        uint256 profitBefore = IERC20(loanToken).balanceOf(address(this));

        // Op targets were validated allowlisted in execute(); the op loop +
        // per-srcToken containment (cap = loanToken/loanAmount, absolute
        // repay gate) run in GenericSequenceLib via DELEGATECALL.
        if (inventory) {
            GenericSequenceLib.runArbFromInventory(plan.ops, loanToken, plan.loanAmount, weth);
        } else {
            GenericSequenceLib.runArb(plan.ops, loanToken, flashRepay, plan.loanAmount, weth);
        }

        // Realized profit (loanToken-denominated, net of flash repay). On the
        // inventory path nothing was borrowed, so principal and repay are
        // both zero and the profit is the plain balance delta.
        (uint256 realizedProfit, bool shortfall) = CoinbasePaymentLib.computeRealizedProfit(
            loanToken, loanToken, profitBefore, inventory ? 0 : plan.loanAmount, flashRepay
        );
        // The inventory must not shrink: the flash path has the repayment
        // gate for this, the inventory path gets the same rule explicitly.
        if (inventory) {
            uint256 held = IERC20(loanToken).balanceOf(address(this));
            if (held < profitBefore) revert InsufficientRepayBalance(profitBefore, held);
        }

        // Coinbase bribe — bid read back from transient storage (`execute`
        // captured `msg.value`; this frame's own `msg.value` is 0, it was
        // entered from the flash provider).
        uint256 bidBps;
        assembly ("memory-safe") {
            bidBps := tload(BID_BPS_TSLOT)
        }
        uint256 coinbasePaid;
        if (bidBps > 0) {
            coinbasePaid = realizedProfit * bidBps / 10_000;
            if (coinbasePaid > 0) {
                CoinbasePaymentLib.payCoinbase(coinbasePaid, weth);
            }
        }

        // Settle flash + verify profit floor.
        uint256 balance = IERC20(loanToken).balanceOf(address(this));
        if (balance < flashRepay) revert InsufficientRepayBalance(flashRepay, balance);

        if (inventory) {
            // Own principal: nothing to repay.
        } else if (vault == address(0)) {
            // Morpho pulls the repayment from us after the callback returns;
            // the provider is constructor-pinned, so the allowance stands
            // (AllowanceLib) instead of being re-written from zero per cycle.
            AllowanceLib.ensure(loanToken, msg.sender, flashRepay);
        } else {
            IERC20(loanToken).safeTransfer(vault, flashRepay);
        }

        CoinbasePaymentLib.checkProfitStrict(realizedProfit, coinbasePaid, plan.minProfitAmount, shortfall);

        emit ArbExecuted(planHash, loanToken, realizedProfit, coinbasePaid);
    }
}
