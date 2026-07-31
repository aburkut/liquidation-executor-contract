// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancerVault.sol";
import {IMorphoBlue, IMorphoFlashLoanCallback} from "./interfaces/IMorphoBlue.sol";
import {IPoolManager, IUnlockCallback} from "./interfaces/IPoolManager.sol";
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
    ReentrancyGuard,
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
    // Mirrors CoinbasePaymentLib.CoinbasePaid for tests that pin the topic.
    event CoinbasePaid(address indexed coinbase, uint256 amount);
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
    address public morphoBlue;
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

    bytes32 private _activePlanHash;
    /// @dev Storage-layout alignment padding (slots 8-10). `ArbExecutor` has
    /// three fewer pre-V4 storage fields than `LiquidationExecutor`
    /// (`aavePool`, `paraswapAugustusV6`, `aaveV2LendingPool` are either
    /// Aave-specific — not applicable to an arb-only executor — or
    /// constructor-`immutable` here, so they consume no storage slot).
    /// Without this padding `_activeV4PoolManager`/`_activeV4TokenIn` would
    /// land at slots 8/9 instead of the 11/12 `GenericSequenceLib` hardcodes
    /// (`V4_PM_SLOT`/`V4_TOKENIN_SLOT`) and shares with `LiquidationExecutor`
    /// via the same DELEGATECALL sstore. Reserved, never read/written by
    /// this contract — `forge inspect ArbExecutor storageLayout` is the
    /// authority that these three slots land the V4 fields correctly.
    bytes32 private __reservedSlot0;
    bytes32 private __reservedSlot1;
    bytes32 private __reservedSlot2;
    /// @dev Slot 11 (bytes 0..19) — armed V4 PoolManager. Packs with
    /// `_executionPhase` (byte 20). Pinned by test_v4SlotConstantsMatchLayout.
    address private _activeV4PoolManager;
    enum ExecutionPhase {
        Idle,
        FlashLoanActive
    }
    ExecutionPhase private _executionPhase;
    /// @dev Slot 12 (bytes 0..19) — armed V4 input token. Packs with
    /// `_v4Armed` (byte 20).
    address private _activeV4TokenIn;
    /// @dev Slot 12 byte 20 — the re-entry sentinel unlockCallback gates on.
    bool private _v4Armed;

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
        ArbTypes.ArbPlan memory plan = abi.decode(planData, (ArbTypes.ArbPlan));

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
            if (!allowedTargets[plan.ops[i].target]) revert TargetNotAllowed();
        }

        address provider = allowedFlashProviders[plan.flashProviderId];
        if (provider == address(0)) revert InvalidFlashProvider(plan.flashProviderId);

        // Pin plan hash for the callback gate. The phase + hash pair
        // is the only thing standing between a hostile caller and the
        // flashloan-borrowed funds; both MUST be set BEFORE the
        // external flash call.
        _activePlanHash = keccak256(planData);
        _executionPhase = ExecutionPhase.FlashLoanActive;

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

        _activePlanHash = bytes32(0);
        _executionPhase = ExecutionPhase.Idle;
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
        if (_executionPhase != ExecutionPhase.FlashLoanActive) {
            revert InvalidExecutionPhase();
        }
        if (_activePlanHash == bytes32(0)) revert NoActivePlan();
        if (msg.sender != allowedFlashProviders[FLASH_PROVIDER_BALANCER]) revert InvalidCallbackCaller();
        if (keccak256(userData) != _activePlanHash) revert InvalidPlan();
        // Capture BEFORE the clear below — the clear zeroes the slot the
        // event emission used to read from, which made every ArbExecuted
        // topic bytes32(0) (Task 8 fix 1).
        bytes32 planHash = _activePlanHash;
        // V10 audit fix: clear plan hash to block callback re-entry
        // within the same flash. The triple-gate (phase + hash + caller)
        // is otherwise stable for the entire flash window — a hostile
        // or buggy flash provider invoking the callback twice would pass
        // all three checks without this clear.
        _activePlanHash = bytes32(0);
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
        if (_executionPhase != ExecutionPhase.FlashLoanActive) revert InvalidExecutionPhase();
        if (_activePlanHash == bytes32(0)) revert NoActivePlan();
        if (msg.sender != allowedFlashProviders[FLASH_PROVIDER_MORPHO]) revert InvalidCallbackCaller();
        if (keccak256(data) != _activePlanHash) revert InvalidPlan();
        // Capture BEFORE the clear below — mirror of `receiveFlashLoan`'s
        // fix (Task 8 fix 1): reading the slot AFTER the clear always
        // produced bytes32(0) in the emitted event.
        bytes32 planHash = _activePlanHash;
        // V10 audit fix: clear plan hash to block callback re-entry.
        // Mirror of `receiveFlashLoan`.
        _activePlanHash = bytes32(0);

        ArbTypes.ArbPlan memory plan = abi.decode(data, (ArbTypes.ArbPlan));
        if (amount != plan.loanAmount) revert CallbackAmountMismatch();

        // Morpho fee = 0
        _runArbPipeline(plan, amount, address(0), planHash);
    }

    /// @inheritdoc IUnlockCallback
    /// @notice PRODUCTION SCOPE — this callback implements exactly ONE shape:
    ///   exact-input single-hop ERC20→ERC20 swap inside the flashloan pipeline.
    /// @dev Three layers of protection against stray or adversarial calls:
    ///   1. `ExecutionPhase.FlashLoanActive` — only valid inside execute()
    ///   2. `_v4Armed`                       — only while a V4 leg is mid-unlock
    ///   3. `msg.sender == _activeV4PoolManager` — only the pinned PoolManager
    /// Verbatim port of `LiquidationExecutor.unlockCallback` (line 1509) —
    /// same guards, same re-entry CLAIM-on-entry discipline, same
    /// single-hop/multihop dispatch on `inner.length`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (_executionPhase != ExecutionPhase.FlashLoanActive) revert InvalidExecutionPhase();
        // tokenIn is read from storage (pinned by the V4 leg arming path)
        // rather than from `data` — PM controls the data, not storage, so
        // substitution is impossible by construction. The re-entry guard
        // is `_v4Armed` (NOT tokenIn != 0 — that collided with native-ETH
        // legs, where tokenIn == address(0) by design): claiming it
        // (clearing to false) on entry means a nested unlockCallback from
        // inside swap() finds `_v4Armed == false` and the combined check
        // below fails closed, regardless of what tokenIn is. The
        // msg.sender check covers the not-in-flow case (_activeV4PoolManager
        // == 0 → msg.sender != 0 = always true).
        address tokenIn = _activeV4TokenIn;
        if (!_v4Armed || msg.sender != _activeV4PoolManager) revert InvalidCallbackCaller();
        _v4Armed = false; // CLAIM — nested unlockCallback finds false and fails closed
        _activeV4TokenIn = address(0); // CLAIM (hygiene only now — see above)

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

    // ─── Pipeline (inside flash) ─────────────────────────────────────
    /// @dev `vault == address(0)` ⇒ approve-only (Morpho pulls).
    /// `vault != 0` ⇒ push transfer to the vault. `planHash` is captured by
    /// the caller BEFORE it clears `_activePlanHash` (the V10 re-entry
    /// guard) — reading the storage slot from here would always see the
    /// already-cleared bytes32(0) (Task 8 fix 1).
    function _runArbPipeline(ArbTypes.ArbPlan memory plan, uint256 flashRepay, address vault, bytes32 planHash)
        internal
    {
        address loanToken = plan.loanToken;

        // Verify the flash actually arrived.
        if (IERC20(loanToken).balanceOf(address(this)) < plan.loanAmount) revert InvalidFlashLoan();

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
        GenericSequenceLib.runArb(plan.ops, loanToken, flashRepay, plan.loanAmount, weth);

        // Realized profit (loanToken-denominated, net of flash repay).
        uint256 realizedProfit =
            CoinbasePaymentLib.computeRealizedProfit(loanToken, loanToken, profitBefore, plan.loanAmount, flashRepay);

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

        if (vault == address(0)) {
            IERC20(loanToken).forceApprove(msg.sender, flashRepay);
        } else {
            IERC20(loanToken).safeTransfer(vault, flashRepay);
        }

        CoinbasePaymentLib.checkProfit(realizedProfit, coinbasePaid, plan.minProfitAmount);

        emit ArbExecuted(planHash, loanToken, realizedProfit, coinbasePaid);
    }
}
