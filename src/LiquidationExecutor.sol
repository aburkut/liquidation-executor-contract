// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancerVault.sol";
import {IAaveV2LendingPool} from "./interfaces/IAaveV2LendingPool.sol";
import {IMorphoBlue, IMorphoFlashLoanCallback, MarketParams} from "./interfaces/IMorphoBlue.sol";
import {IUniV2Router} from "./interfaces/IUniV2Router.sol";
import {IUniV3SwapRouter} from "./interfaces/IUniV3SwapRouter.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "./interfaces/IPoolManager.sol";
import {ParaswapDecoderLib} from "./libraries/ParaswapDecoderLib.sol";
import {SwapLegExecutorLib} from "./libraries/SwapLegExecutorLib.sol";

interface IWETH {
    function withdraw(uint256 amount) external;
}

/// @title LiquidationExecutor
/// @notice Flashloan + multi-swap + liquidation executor.
/// @dev Fail-closed. No upgradeability. External calls restricted to allowedTargets allowlist.
/// Supports Paraswap single swaps, Bebop multi-output swaps, and deterministic
/// on-chain fallback swaps via Uniswap V2, V3 (SwapRouter02), and V4 (PoolManager
/// unlock-callback pattern, strict single-hop exact-input mode only).
contract LiquidationExecutor is
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    IFlashLoanRecipient,
    IMorphoFlashLoanCallback,
    IUnlockCallback
{
    using SafeERC20 for IERC20;

    // ─── Custom Errors ───────────────────────────────────────────────
    error Unauthorized();
    error ZeroAddress();
    error InvalidPlan();
    error FlashProviderNotAllowed();
    error FlashFeeExceeded(uint256 actual, uint256 max);
    error InvalidCallbackCaller();
    error InvalidInitiator();
    error InvalidProtocolId(uint8 id);
    error InvalidAction(uint8 actionType);
    error RescueFailed();
    error CallbackAssetMismatch();
    error CallbackAmountMismatch();
    error BalancerSingleTokenOnly();
    error ZeroBalance();
    error EmptyArray();
    error NoLiquidationAction();
    error NoCollateralReceived();
    error UnsupportedActionType(uint8 actionType);
    error ZeroActionAmount();
    error DebtAssetMismatch(address expected, address actual);
    error CollateralAssetMismatch(address expected, address actual);
    error SrcTokenNotCollateral(address expected, address actual);
    error NoActions();
    error TooManyActions(uint256 count);
    error InvalidFlashLoan();
    error InsufficientEth(uint256 required, uint256 available);
    error CoinbasePaymentFailed();
    error ATokenAddressRequired();
    error InvalidATokenAddress(address provided, address canonical);
    error MixedReceiveAToken();
    error MorphoExecutionFailed();
    error UnwrapFailed();
    error ReceiveATokenV2Unsupported();
    error MorphoInvalidMarketParams();
    error MorphoShareModeUnsupported();
    error InvalidExecutionPhase();
    error InvalidCollateralAsset();
    error NoActivePlan();
    error InvalidCoinbase();
    error MorphoMixedModeUnsupported();

    // Swap errors
    error InvalidSwapMode();
    error SwapDeadlineExpired(uint256 deadline, uint256 current);
    error InsufficientRepayOutput(uint256 actual, uint256 required);
    error RepayTokenMismatch(address expected, address actual);

    // Two-leg errors
    error InvalidLegLink(address leg1Out, address leg2In);
    error Leg2ModeNotAllowed(uint8 mode);
    error Leg2ZeroLeftover();
    error LegUseFullBalanceNotAllowed(uint8 mode);

    // MIXED_SPLIT errors
    /// @dev Only one of {hasLeg2, hasSplit, hasMixedSplit} may be true.
    error PlanShapeConflict();
    /// @dev Raised when leg1 of MIXED_SPLIT consumed >= collateralDelta,
    /// leaving nothing for the profit leg. leg1 over-approved or the
    /// Paraswap /swap calldata was sized larger than the opportunity's
    /// realized collateral — caller must downsize leg1 target.
    error MixedSplitLeg1Overspent(uint256 consumed, uint256 collateralDelta);
    /// @dev Raised when leg1 of MIXED_SPLIT did not consume any collateral
    /// (e.g. Paraswap call failed silently, or srcToken didn't match).
    /// The leg1 executor's own revert path should fire first in practice —
    /// this is a belt-and-suspenders check.
    error MixedSplitLeg1NoConsumption();

    // Paraswap errors
    error InvalidParaswapCalldata();
    error InvalidSwapSelector();
    /// @dev Raised when a Paraswap selector is not in the explicit whitelist.
    /// Reported with the offending 4-byte selector so off-chain operators can either
    /// extend the whitelist deliberately or reject the route at the planning layer.
    error InvalidParaswapSelector(bytes4 selector);
    error SwapRecipientInvalid(address recipient);
    error ParaswapSwapFailed();
    error ZeroSwapOutput();
    error ParaswapSrcTokenMismatch(address expected, address actual);
    error ParaswapAmountInMismatch(uint256 expected, uint256 actual);
    error ParaswapDstTokenUnexpected(address dstToken);

    // Bebop errors
    error InvalidBebopTarget();
    error InvalidBebopCalldata();
    error BebopTargetNotContract();
    error BebopSwapFailed();

    // Uniswap V2 / V3 / V4 swap errors
    error ZeroSwapInput();
    error ZeroAmountIn();
    error ZeroRepayOutput();
    error InvalidV2Path();
    error InvalidV3Fee(uint24 fee);
    error InvalidV4Data();
    error InvalidV4Fee();
    error InvalidV4TokenOut(address expected, address actual);
    error InvalidV4NativeToken();
    error InvalidV4FeeOrSpacing();
    error V4HookNotAllowed(address hook);
    error V4UnexpectedDelta();
    error InvalidV4CallbackHook();

    // Profit / payment errors
    error InsufficientProfit(uint256 actual, uint256 required);
    error CoinbasePaymentRequiresWethProfit();
    error CoinbaseExceedsProfit(uint256 coinbase, uint256 profit);
    error InvalidCoinbaseBps();
    error InsufficientRepayBalance(uint256 required, uint256 available);
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error TargetNotAllowed(address target);

    // ─── Constants ───────────────────────────────────────────────────
    // FLASH_PROVIDER_AAVE_V3 (1) removed — Aave V3 flashloan path deleted.
    // IDs 2 and 3 kept stable for bot integration compatibility.
    uint8 public constant FLASH_PROVIDER_BALANCER = 2;
    uint8 public constant FLASH_PROVIDER_MORPHO = 3;

    uint8 public constant PROTOCOL_AAVE_V3 = 1;
    uint8 public constant PROTOCOL_MORPHO_BLUE = 2;
    uint8 public constant PROTOCOL_AAVE_V2 = 3;
    uint8 public constant PROTOCOL_INTERNAL = 100;

    uint8 public constant ACTION_PAY_COINBASE = 1;

    /// @dev Gas limit on coinbase ETH transfers. Small bound keeps a
    /// malicious block.coinbase from grinding gas in the callback.
    uint256 private constant COINBASE_CALL_GAS = 10_000;

    /// @dev Uniswap V4 sqrt price limits, set one tick inside the allowed
    /// range so the swap is unconstrained by price (slippage is enforced
    /// by the output delta check against the per-leg `leg.minAmountOut`
    /// field on `SwapLeg`).
    /// Reference: v4-core TickMath.MIN_SQRT_PRICE / MAX_SQRT_PRICE.
    uint160 private constant V4_MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 private constant V4_MAX_SQRT_PRICE_LIMIT =
        1_461_446_703_529_909_599_001_367_844_790_673_715_015_930_149_261;

    /// @dev Strict size of encoded v4SwapData: 5 × 32-byte words
    /// (address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hook).
    uint256 private constant V4_SWAP_DATA_LENGTH = 160;

    // Paraswap Augustus V6.2 selector classifier + per-family decoders live
    // in `ParaswapDecoderLib` (external library, DELEGATECALL). Keeps the
    // executor's deployed bytecode under EIP-170. See that file for selector
    // constants, decoder shapes, and bounds-check commentary.

    // ─── State ───────────────────────────────────────────────────────
    address public immutable operator;
    address public immutable weth;
    address public aavePool;
    address public morphoBlue;
    address public balancerVault;
    address public paraswapAugustusV6;
    address public aaveV2LendingPool;
    /// @dev Immutable — canonical Uniswap V2 Router02 (mainnet
    /// 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D). Auto-whitelisted in
    /// allowedTargets at construction. Rotating requires redeployment.
    address public immutable uniV2Router;
    /// @dev Immutable — canonical Uniswap V3 SwapRouter02 (mainnet
    /// 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45). SwapRouter02 struct omits
    /// deadline; the executor enforces its own via the per-leg `leg.deadline`
    /// field on `SwapLeg`.
    address public immutable uniV3Router;

    mapping(uint8 => address) public allowedFlashProviders;
    mapping(address => bool) public allowedTargets;
    /// @dev Owner-curated whitelist of V4 hook contracts. A V4 swap whose
    /// PoolKey references a hook that is neither address(0) nor allow-listed
    /// reverts with `V4HookNotAllowed`. Hooks run arbitrary code inside
    /// `beforeSwap`/`afterSwap` — keeping this list empty unless a specific
    /// hook has been audited is the intended default.
    mapping(address => bool) public allowedV4Hooks;

    bytes32 private _activePlanHash;

    /// @dev PoolManager address currently mid-unlock. Set by `_executeUniV4Leg`
    /// before `unlock()` and cleared on return. `unlockCallback` refuses any
    /// caller that is not this address, so stray `unlockCallback` invocations
    /// from an allow-listed PoolManager acting outside our pipeline revert.
    address private _activeV4PoolManager;

    /// @dev Execution phase guard — prevents unexpected callbacks. Slot
    /// layout note: kept directly after `_activeV4PoolManager` so both
    /// pack into the same storage slot (test_morphoCallbackRejectsCaller
    /// relies on this layout via vm.store at slot 11).
    enum ExecutionPhase {
        Idle,
        FlashLoanActive
    }
    ExecutionPhase private _executionPhase;

    /// @dev tokenIn pinned for the active V4 unlock. Set by
    /// `_executeUniV4Leg` BEFORE `unlock()`, CLEARED to address(0) by
    /// `unlockCallback` on entry. The clear-on-entry semantics double as
    /// a re-entry guard: a nested `unlockCallback` (e.g. from a malicious
    /// hook calling `pm.unlock()` mid-swap) would see `_activeV4TokenIn
    /// == 0` and the entry guard rejects it. Reading tokenIn from
    /// storage (rather than decoding from `data`) also closes the
    /// substitution drain — `pm` cannot influence storage, only the
    /// callback payload. Declared AFTER `_executionPhase` so the legacy
    /// slot 11 packing (read by storage-poking tests) stays untouched.
    address private _activeV4TokenIn;

    // ─── Events ──────────────────────────────────────────────────────
    event ConfigUpdated(bytes32 indexed key, address indexed oldValue, address indexed newValue);
    event FlashProviderUpdated(uint8 indexed providerId, address indexed oldProvider, address indexed newProvider);
    event FlashExecuted(uint8 indexed providerId, address indexed loanToken, uint256 loanAmount);
    event RepayExecuted(
        uint8 indexed protocolId, bytes32 indexed positionKeyHash, address indexed asset, uint256 amount
    );
    event LiquidationExecuted(
        uint8 indexed protocolId, address indexed collateralAsset, address indexed debtAsset, uint256 debtToCover
    );
    event CoinbasePaid(address indexed coinbase, uint256 amount);
    event Rescue(address indexed token, address indexed to, uint256 amount);

    // Swap events
    event ParaswapSwapExecuted(address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut);
    event BebopSwapExecuted(
        address indexed target, address indexed srcToken, uint256 amountIn, uint256 repayDelta, uint256 profitDelta
    );
    event UniV2SwapExecuted(address indexed srcToken, address indexed dstToken, uint256 amountIn, uint256 amountOut);
    event UniV3SwapExecuted(
        address indexed srcToken, address indexed dstToken, uint24 fee, uint256 amountIn, uint256 amountOut
    );
    event UniV4SwapExecuted(
        address indexed srcToken, address indexed dstToken, uint24 fee, uint256 amountIn, uint256 amountOut
    );
    event TwoLegSwapExecuted(
        address indexed intermediateToken,
        uint256 leg1AmountIn,
        uint256 intermediateDelta,
        uint256 leg2AmountIn,
        uint256 finalRepayDelta
    );
    event V4HookAllowedUpdated(address indexed hook, bool allowed);

    // ─── Enums ────────────────────────────────────────────────────────
    enum SwapMode {
        PARASWAP_SINGLE,
        BEBOP_MULTI,
        UNI_V2,
        UNI_V3,
        UNI_V4,
        NO_SWAP // Same-token liquidation: srcToken == repayToken, no DEX call.
    }

    // ─── Plan Structs ─────────────────────────────────────────────────

    /// @dev One leg of a swap plan. The same struct shape is reused for leg1
    /// and leg2; fields irrelevant to the chosen `mode` are ignored (and
    /// must be zero per the validation rules below). See `_executeSwapPlan`
    /// for the two-leg execution flow.
    ///
    /// Invariants (enforced in execute()):
    ///   * leg1 may be any SwapMode.
    ///   * leg2, when present, MUST be one of UNI_V2 / UNI_V3 / UNI_V4.
    ///   * leg2.srcToken MUST equal leg1.repayToken (leg-linking).
    ///   * For PARASWAP_SINGLE / BEBOP_MULTI: useFullBalance MUST be false
    ///     (both modes carry their own amountIn inside calldata — using a
    ///     delta would desync the pre-declared amountIn from reality).
    struct SwapLeg {
        SwapMode mode;
        address srcToken;
        uint256 amountIn;
        bool useFullBalance;
        uint256 deadline;

        // Paraswap (PARASWAP_SINGLE only — leg1 only)
        bytes paraswapCalldata;

        // Bebop (BEBOP_MULTI only — leg1 only)
        address bebopTarget;
        bytes bebopCalldata;

        // Uniswap V2 (UNI_V2 only)
        address[] v2Path;

        // Uniswap V3 (UNI_V3 only)
        uint24 v3Fee;

        // Uniswap V4 (UNI_V4 only)
        address v4PoolManager;
        bytes v4SwapData;

        // Per-leg output binding.
        // For leg1 in a one-leg plan: == outer plan.loanToken.
        // For leg1 in a two-leg plan: == leg2.srcToken (intermediate).
        // For leg2 always:            == outer plan.loanToken.
        address repayToken;
        uint256 minAmountOut;
    }

    /// @dev Plan-shape matrix — EXACTLY ONE of {hasLeg2, hasSplit,
    /// hasMixedSplit} may be true (or all false = single-leg).
    ///
    /// hasSplit (PURE SPLIT) — leg1 + leg2 both Uni, parallel on
    /// collateralDelta with an explicit splitBps partition. Gives
    /// coinbase-capable WETH profit; both legs must accept a runtime
    /// `amountIn` (hence Uni-only).
    ///
    /// hasMixedSplit (MIXED_SPLIT) — leg1 is ANY mode (typical:
    /// Paraswap / Bebop for deep routing on the repay leg), leg2 is
    /// Uni-only (collateral → WETH). leg1's consumption is measured
    /// from the collateral-balance delta during its execution; leg2
    /// swaps whatever collateral is left. splitBps is IGNORED in this
    /// mode. Primary use case: non-WETH / non-WETH pairs where no
    /// direct Uni coll→debt pool exists, so SPLIT's Uni-only
    /// constraint would block the plan — but Paraswap can route
    /// coll→debt via any DEX graph while Uni handles the small
    /// coll→WETH coinbase leg.
    ///
    /// hasLeg2 (SEQUENTIAL) — leg1 → intermediate, leg2 (Uni,
    /// useFullBalance=true) → loanToken. No coinbase (leg2 consumes
    /// the whole intermediate balance). Used for deep-liquidity
    /// routing through WETH bridge when direct coll→debt is thin.
    /// @dev When a liquidation uses `receiveAToken=true`, leg1.srcToken
    /// selects the behaviour: setting it to the underlying collateral
    /// triggers the usual `pool.withdraw(...)` unwrap step, while setting
    /// it to the aToken itself skips the unwrap and lets the swap plan
    /// consume the aToken directly (e.g. via an aToken/underlying peg
    /// pool). Use the aToken path when the reserve's underlying liquidity
    /// is insufficient to satisfy `withdraw` — over-utilized reserves
    /// would otherwise revert with an arithmetic overflow inside
    /// Aave's `calculateInterestRates`.
    struct SwapPlan {
        SwapLeg leg1;
        bool hasLeg2;
        SwapLeg leg2;
        bool hasSplit;
        uint16 splitBps;
        bool hasMixedSplit;
        address profitToken;
        uint256 minProfitAmount;
    }

    struct Action {
        uint8 protocolId;
        bytes data;
    }

    struct Plan {
        uint8 flashProviderId;
        address loanToken;
        uint256 loanAmount;
        uint256 maxFlashFee;
        Action[] actions;
        SwapPlan swapPlan;
    }

    uint8 private constant MAX_ACTIONS = 10;

    // ─── Aave V3 target action ───────────────────────────────────────
    struct AaveV3Action {
        uint8 actionType; // 4 = liquidation (only supported type)
        address asset;
        uint256 amount;
        uint256 interestRateMode;
        address onBehalfOf;
        // Liquidation fields (actionType == 4 only)
        address collateralAsset;
        address debtAsset;
        address user;
        uint256 debtToCover;
        bool receiveAToken;
        address aTokenAddress;
    }

    // ─── Aave V2 liquidation action ──────────────────────────────────
    /// @dev V2 receiveAToken=true is explicitly unsupported (no canonical on-chain verification).
    struct AaveV2Liquidation {
        address collateralAsset;
        address debtAsset;
        address user;
        uint256 debtToCover;
        bool receiveAToken; // must be false — validated in _validateActions
    }

    // ─── Morpho Blue liquidation action ─────────────────────────────
    struct MorphoLiquidation {
        MarketParams marketParams;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
        /// @dev Max loan-token amount to approve for repayment (loan-token units, NOT collateral units).
        /// Must be >= actual assetsRepaid returned by Morpho. Operator computes this off-chain.
        uint256 maxRepayAssets;
    }

    // ─── Constructor ─────────────────────────────────────────────────
    constructor(
        address owner_,
        address operator_,
        address weth_,
        address aavePool_,
        address balancerVault_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    ) Ownable(owner_) {
        if (operator_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (paraswapAugustus_ == address(0)) revert ZeroAddress();
        if (uniV2Router_ == address(0)) revert ZeroAddress();
        if (uniV3Router_ == address(0)) revert ZeroAddress();

        operator = operator_;
        weth = weth_;
        uniV2Router = uniV2Router_;
        uniV3Router = uniV3Router_;
        aavePool = aavePool_;
        balancerVault = balancerVault_;
        paraswapAugustusV6 = paraswapAugustus_;

        allowedFlashProviders[FLASH_PROVIDER_BALANCER] = balancerVault_;

        allowedTargets[aavePool_] = true;
        allowedTargets[balancerVault_] = true;
        allowedTargets[paraswapAugustus_] = true;
        allowedTargets[uniV2Router_] = true;
        allowedTargets[uniV3Router_] = true;

        for (uint256 i = 0; i < allowedTargets_.length; i++) {
            if (allowedTargets_[i] == address(0)) revert ZeroAddress();
            allowedTargets[allowedTargets_[i]] = true;
        }
    }

    // ─── Modifiers ───────────────────────────────────────────────────
    modifier onlyOperator() {
        if (msg.sender != operator) revert Unauthorized();
        _;
    }

    // ─── Owner Config Functions ──────────────────────────────────────
    function setMorphoBlue(address morpho) external onlyOwner {
        if (morpho == address(0)) revert ZeroAddress();
        if (!allowedTargets[morpho]) revert TargetNotAllowed(morpho);
        address old = morphoBlue;
        morphoBlue = morpho;
        emit ConfigUpdated("morphoBlue", old, morpho);
    }

    function setAaveV2LendingPool(address pool) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        if (!allowedTargets[pool]) revert TargetNotAllowed(pool);
        address old = aaveV2LendingPool;
        aaveV2LendingPool = pool;
        emit ConfigUpdated("aaveV2Pool", old, pool);
    }

    function setFlashProvider(uint8 providerId, address provider) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        if (!allowedTargets[provider]) revert TargetNotAllowed(provider);
        address old = allowedFlashProviders[providerId];
        allowedFlashProviders[providerId] = provider;
        emit FlashProviderUpdated(providerId, old, provider);
    }

    /// @notice Atomic config helper that pins both Morpho roles to the same address.
    /// @dev `morphoBlue` (used as liquidation target via PROTOCOL_MORPHO_BLUE) and
    /// `allowedFlashProviders[FLASH_PROVIDER_MORPHO]` (used as the flashloan source +
    /// the only authorized `onMorphoFlashLoan` caller) are independent storage slots.
    /// Setting them via the legacy single-purpose setters in two transactions creates
    /// a window where the two halves disagree. This helper writes both slots in one
    /// call. Validation (zero address, allowedTargets gate) and events
    /// (ConfigUpdated, FlashProviderUpdated) match the legacy setters exactly so that
    /// off-chain consumers see the same signals. Legacy setters remain available for
    /// the rare case the two roles intentionally diverge (testnets, migrations).
    function configureMorpho(address morpho) external onlyOwner {
        if (morpho == address(0)) revert ZeroAddress();
        if (!allowedTargets[morpho]) revert TargetNotAllowed(morpho);

        address oldMorpho = morphoBlue;
        morphoBlue = morpho;
        emit ConfigUpdated("morphoBlue", oldMorpho, morpho);

        address oldProvider = allowedFlashProviders[FLASH_PROVIDER_MORPHO];
        allowedFlashProviders[FLASH_PROVIDER_MORPHO] = morpho;
        emit FlashProviderUpdated(FLASH_PROVIDER_MORPHO, oldProvider, morpho);
    }

    /// @notice Flag a Uniswap V4 hook contract as allowed inside V4 swaps.
    /// @dev Hooks execute arbitrary logic during `beforeSwap`/`afterSwap` on the
    /// PoolManager; any non-zero hook that is NOT in this whitelist causes the
    /// V4 path to revert with `V4HookNotAllowed`. Default is empty — operator
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

    // ─── Internal: Validate Actions ─────────────────────────────────
    /// @dev Validates all liquidation actions share the same debt/collateral assets.
    /// Requires at least one liquidation action. Returns the common collateralAsset
    /// and the trackingToken (aToken when receiveAToken=true, underlying otherwise).
    ///
    /// ┌───────────────────┬──────────────┬────────────────┬──────────────────────────┐
    /// │ Protocol          │ receiveAToken│ Canonical      │ Status                   │
    /// │                   │              │ verification   │                          │
    /// ├───────────────────┼──────────────┼────────────────┼──────────────────────────┤
    /// │ AAVE_V3 (1)       │ false        │ n/a            │ SUPPORTED                │
    /// │ AAVE_V3 (1)       │ true         │ getReserveData │ SUPPORTED (verified)     │
    /// │ AAVE_V2 (3)       │ false        │ n/a            │ SUPPORTED                │
    /// │ AAVE_V2 (3)       │ true         │ —              │ BLOCKED (no on-chain     │
    /// │                   │              │                │ verification available)  │
    /// │ MORPHO_BLUE (2)   │ n/a          │ n/a            │ SUPPORTED                │
    /// │ Other             │ —            │ —              │ REVERTS InvalidProtocolId│
    /// └───────────────────┴──────────────┴────────────────┴──────────────────────────┘
    function _validateActions(Action[] memory actions, address loanToken)
        internal
        pure
        returns (address collateralAsset, address trackingToken)
    {
        uint256 liquidationCount;
        bool receiveATokenSet;
        bool receiveAToken;
        address aTokenAddr;

        for (uint256 i = 0; i < actions.length; ++i) {
            uint8 protocolId = actions[i].protocolId;

            // Internal actions (e.g. coinbase payment) are not liquidation actions
            if (protocolId == PROTOCOL_INTERNAL) continue;

            bytes memory data = actions[i].data;

            address actionDebt;
            address actionCollateral;
            uint256 actionAmount;
            bool actionReceiveAToken;
            address actionATokenAddress;

            if (protocolId == PROTOCOL_AAVE_V3) {
                AaveV3Action memory a = abi.decode(data, (AaveV3Action));
                if (a.actionType != 4) revert UnsupportedActionType(a.actionType);
                if (a.collateralAsset == address(0)) revert InvalidCollateralAsset();
                actionDebt = a.debtAsset;
                actionCollateral = a.collateralAsset;
                actionAmount = a.debtToCover;
                actionReceiveAToken = a.receiveAToken;
                actionATokenAddress = a.aTokenAddress;
            } else if (protocolId == PROTOCOL_AAVE_V2) {
                AaveV2Liquidation memory a = abi.decode(data, (AaveV2Liquidation));
                if (a.receiveAToken) revert ReceiveATokenV2Unsupported();
                if (a.collateralAsset == address(0)) revert InvalidCollateralAsset();
                actionDebt = a.debtAsset;
                actionCollateral = a.collateralAsset;
                actionAmount = a.debtToCover;
            } else if (protocolId == PROTOCOL_MORPHO_BLUE) {
                MorphoLiquidation memory a = abi.decode(data, (MorphoLiquidation));
                if (a.marketParams.loanToken == address(0)) revert MorphoInvalidMarketParams();
                if (a.marketParams.collateralToken == address(0)) revert MorphoInvalidMarketParams();
                // Only seized-assets mode is supported. Share mode and mixed mode are rejected.
                if (a.seizedAssets == 0) revert MorphoShareModeUnsupported();
                if (a.repaidShares != 0) revert MorphoMixedModeUnsupported();
                if (a.maxRepayAssets == 0) revert InvalidPlan();
                actionDebt = a.marketParams.loanToken;
                actionCollateral = a.marketParams.collateralToken;
                actionAmount = a.seizedAssets;
            } else {
                revert InvalidProtocolId(protocolId);
            }

            if (actionAmount == 0) revert ZeroActionAmount();
            if (actionDebt != loanToken) revert DebtAssetMismatch(loanToken, actionDebt);

            if (actionCollateral != address(0)) {
                if (collateralAsset == address(0)) {
                    collateralAsset = actionCollateral;
                } else {
                    if (actionCollateral != collateralAsset) {
                        revert CollateralAssetMismatch(collateralAsset, actionCollateral);
                    }
                }
            }

            // receiveAToken consistency check (Aave V3 only — V2 receiveAToken=true is blocked above)
            if (protocolId == PROTOCOL_AAVE_V3) {
                if (!receiveATokenSet) {
                    receiveAToken = actionReceiveAToken;
                    receiveATokenSet = true;
                    if (receiveAToken) {
                        if (actionATokenAddress == address(0)) revert ATokenAddressRequired();
                        aTokenAddr = actionATokenAddress;
                    }
                } else {
                    if (actionReceiveAToken != receiveAToken) revert MixedReceiveAToken();
                    if (receiveAToken && actionATokenAddress != aTokenAddr) {
                        revert CollateralAssetMismatch(aTokenAddr, actionATokenAddress);
                    }
                }
            }

            liquidationCount++;
        }

        if (liquidationCount == 0) revert NoLiquidationAction();

        // Set trackingToken: aToken when receiveAToken=true, underlying otherwise
        trackingToken = (receiveAToken && aTokenAddr != address(0)) ? aTokenAddr : collateralAsset;
    }

    /// @dev Per-leg fail-fast validation. Called once per leg from execute()
    /// BEFORE the flashloan is requested, so malformed plans never burn a
    /// flash fee. This is authoritative: per-mode executors no longer
    /// re-check shape defensively — the strict call-graph (execute →
    /// activePlanHash pin → flashloan callback → _executeSwapPlan →
    /// _dispatchLeg → leg executor) means any plan reaching a leg executor
    /// has already passed _validateLeg.
    function _validateLeg(SwapLeg memory leg) internal view {
        if (leg.srcToken == address(0)) revert ZeroAddress();
        if (leg.repayToken == address(0)) revert ZeroAddress();

        SwapMode m = leg.mode;

        // NO_SWAP: same-token path (e.g. WETH/WETH). Leg-level checks are
        // skipped; a mismatched src/repay silently early-returns in
        // _executeSwapPlan and the final flash-repay balance check
        // reverts if the plan didn't actually produce enough loanToken.
        if (m == SwapMode.NO_SWAP) return;

        if (leg.srcToken == leg.repayToken) revert InvalidPlan();

        // Paraswap/Bebop: reject useFullBalance (amountIn is inside calldata).
        if ((m == SwapMode.PARASWAP_SINGLE || m == SwapMode.BEBOP_MULTI) && leg.useFullBalance) {
            revert LegUseFullBalanceNotAllowed(uint8(m));
        }

        if (m == SwapMode.PARASWAP_SINGLE) {
            if (leg.paraswapCalldata.length < 4) revert InvalidParaswapCalldata();
            if (leg.amountIn == 0) revert ZeroAmountIn();
        } else if (m == SwapMode.BEBOP_MULTI) {
            if (leg.bebopTarget == address(0)) revert InvalidBebopTarget();
            if (leg.bebopCalldata.length < 4) revert InvalidBebopCalldata();
            if (leg.amountIn == 0) revert ZeroAmountIn();
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.UNI_V2) {
            uint256 pLen = leg.v2Path.length;
            if (pLen < 2) revert InvalidV2Path();
            if (leg.v2Path[0] != leg.srcToken) revert InvalidV2Path();
            if (leg.v2Path[pLen - 1] != leg.repayToken) revert InvalidV2Path();
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.UNI_V3) {
            uint24 f = leg.v3Fee;
            if (f != 100 && f != 500 && f != 3000 && f != 10000) revert InvalidV3Fee(f);
            if (leg.minAmountOut == 0) revert InvalidPlan();
        } else if (m == SwapMode.UNI_V4) {
            _validateV4Leg(leg);
        } else {
            revert InvalidSwapMode();
        }
    }

    // ─── Core Execute ────────────────────────────────────────────────
    function execute(bytes calldata planData) external onlyOperator whenNotPaused nonReentrant {
        Plan memory plan = abi.decode(planData, (Plan));

        // Deadline: check leg1 and leg2 pre-flashloan. block.timestamp is
        // monotonic within a transaction, so no in-pipeline re-check needed.
        if (block.timestamp > plan.swapPlan.leg1.deadline) {
            revert SwapDeadlineExpired(plan.swapPlan.leg1.deadline, block.timestamp);
        }
        if (plan.swapPlan.hasLeg2 && block.timestamp > plan.swapPlan.leg2.deadline) {
            revert SwapDeadlineExpired(plan.swapPlan.leg2.deadline, block.timestamp);
        }

        if (plan.loanToken == address(0)) revert ZeroAddress();
        if (plan.loanAmount == 0) revert InvalidPlan();
        if (plan.swapPlan.profitToken == address(0)) revert ZeroAddress();
        if (plan.actions.length == 0) revert NoActions();
        if (plan.actions.length > MAX_ACTIONS) revert TooManyActions(plan.actions.length);

        // Final-leg repayToken MUST equal outer loanToken. For hasSplit, leg1
        // IS the repay leg (collateral → loanToken), matching the single-leg
        // derivation since hasLeg2 is forbidden in split mode (see block below).
        address finalRepayToken = plan.swapPlan.hasLeg2 ? plan.swapPlan.leg2.repayToken : plan.swapPlan.leg1.repayToken;
        if (finalRepayToken != plan.loanToken) {
            revert RepayTokenMismatch(plan.loanToken, finalRepayToken);
        }

        // Validate all actions use same debt/collateral assets
        (address collateralAsset, address trackingToken) = _validateActions(plan.actions, plan.loanToken);

        // Collateral linkage: leg1.srcToken must be either the underlying
        // collateral (standard path, contract unwraps aToken after
        // liquidation) or the aToken itself (skip-unwrap path, the aToken
        // becomes the swap input). trackingToken differs from
        // collateralAsset only when receiveAToken=true, so the aToken
        // path is only reachable with that setting.
        if (collateralAsset != address(0)) {
            address src = plan.swapPlan.leg1.srcToken;
            if (src != collateralAsset && src != trackingToken) {
                revert SrcTokenNotCollateral(collateralAsset, src);
            }
        }

        // Plan-shape XOR guard: at most ONE of {hasLeg2, hasSplit,
        // hasMixedSplit} may be true. All-false = single-leg plan.
        // NO_SWAP + hasMixedSplit is the one combination NOT already
        // rejected by existing per-shape validation (hasSplit's m1-Uni
        // check + hasLeg2's InvalidLegLink), so it gets a dedicated
        // PlanShapeConflict guard inside the hasMixedSplit block below.
        {
            uint256 shapeCount = 0;
            if (plan.swapPlan.hasLeg2) shapeCount++;
            if (plan.swapPlan.hasSplit) shapeCount++;
            if (plan.swapPlan.hasMixedSplit) shapeCount++;
            if (shapeCount > 1) revert PlanShapeConflict();
        }

        // Validate leg1 (may be any mode). NO_SWAP is only meaningful as
        // a single-leg plan — combined with hasLeg2 / hasMixedSplit it
        // would silently bypass the second leg in _executeSwapPlan. Both
        // combinations are rejected explicitly inside the corresponding
        // shape-validation blocks below. NO_SWAP + hasSplit is rejected
        // by hasSplit's m1-must-be-Uni check.
        _validateLeg(plan.swapPlan.leg1);

        // Validate leg2 (must be Uni V2/V3/V4, must link to leg1 output).
        if (plan.swapPlan.hasLeg2) {
            // NO_SWAP is single-leg-only — _executeSwapPlan early-returns
            // BEFORE the hasLeg2 branch, silently dropping leg2 even
            // though validation accepted it. This is a validator/executor
            // mismatch (worse than a per-mode bug) and would silently
            // break skip-unwrap sequential plans (receiveAToken=true →
            // leg1 NO_SWAP → leg2 peg-pool swap). Reject at validation.
            if (plan.swapPlan.leg1.mode == SwapMode.NO_SWAP) revert PlanShapeConflict();
            SwapMode m2 = plan.swapPlan.leg2.mode;
            if (m2 != SwapMode.UNI_V2 && m2 != SwapMode.UNI_V3 && m2 != SwapMode.UNI_V4) {
                revert Leg2ModeNotAllowed(uint8(m2));
            }
            if (plan.swapPlan.leg1.repayToken != plan.swapPlan.leg2.srcToken) {
                revert InvalidLegLink(plan.swapPlan.leg1.repayToken, plan.swapPlan.leg2.srcToken);
            }
            if (!plan.swapPlan.leg2.useFullBalance) revert InvalidPlan();
            _validateLeg(plan.swapPlan.leg2);
        }

        // Validate SPLIT mode: leg1=repayLeg (collateral→loanToken), leg2=profitLeg
        // (collateral→WETH), each sized by splitBps of collateralDelta at runtime.
        // Both legs restricted to Uni modes (only modes accepting an explicit
        // amountIn parameter).
        if (plan.swapPlan.hasSplit) {
            uint16 bps = plan.swapPlan.splitBps;
            if (bps == 0 || bps >= 10_000) revert InvalidPlan();
            SwapMode m1 = plan.swapPlan.leg1.mode;
            if (m1 != SwapMode.UNI_V2 && m1 != SwapMode.UNI_V3 && m1 != SwapMode.UNI_V4) revert InvalidPlan();
            SwapMode mp = plan.swapPlan.leg2.mode;
            if (mp != SwapMode.UNI_V2 && mp != SwapMode.UNI_V3 && mp != SwapMode.UNI_V4) revert InvalidPlan();
            if (plan.swapPlan.leg2.repayToken != weth) revert InvalidPlan();
            if (collateralAsset != address(0) && plan.swapPlan.leg2.srcToken != collateralAsset) {
                revert SrcTokenNotCollateral(collateralAsset, plan.swapPlan.leg2.srcToken);
            }
            if (plan.swapPlan.leg1.useFullBalance || plan.swapPlan.leg2.useFullBalance) revert InvalidPlan();
            _validateLeg(plan.swapPlan.leg2);
        }

        // Validate MIXED_SPLIT mode: leg1 = any mode (typical Paraswap /
        // Bebop) routes coll → loanToken for repay; leg2 = Uni-only
        // (coll → WETH) runs on whatever collateral is left after leg1.
        //   * leg1.repayToken MUST equal loanToken (its swap directly
        //     produces the token that settles the flashloan).
        //   * leg2 mode ∈ {UNI_V2, UNI_V3, UNI_V4} — those accept a
        //     runtime `amountIn` which we supply from the measured
        //     collateral balance delta.
        //   * leg2.srcToken == collateralAsset (same source token as
        //     leg1) — leg2 is a parallel profit split, not sequential
        //     routing. This is also what distinguishes MIXED_SPLIT from
        //     hasLeg2 (which requires leg2.srcToken == leg1.repayToken).
        //   * leg2.repayToken == weth (contract-pinned profit leg).
        //   * Neither leg may set `useFullBalance` in the on-wire payload
        //     — leg1 uses calldata-embedded amountIn, leg2's amountIn is
        //     filled in at runtime from the measured leg1 consumption.
        //     (If we accepted useFullBalance here the profit leg would
        //     race the repay leg for "all collateral" and produce
        //     non-deterministic output.)
        if (plan.swapPlan.hasMixedSplit) {
            SwapMode m1 = plan.swapPlan.leg1.mode;
            // NO_SWAP is single-leg-only — combined with hasMixedSplit
            // the runtime early-returns in _executeSwapPlan BEFORE
            // reaching the leg2 branch and silently skips the profit
            // leg. Reject at validation time.
            if (m1 == SwapMode.NO_SWAP) revert PlanShapeConflict();
            // leg1 can otherwise be ANY of the four real swap modes.
            // (The contract's per-mode executor enforces the relevant
            // calldata / approval invariants.)
            if (plan.swapPlan.leg1.repayToken != plan.loanToken) {
                revert RepayTokenMismatch(plan.loanToken, plan.swapPlan.leg1.repayToken);
            }

            SwapMode mp = plan.swapPlan.leg2.mode;
            if (mp != SwapMode.UNI_V2 && mp != SwapMode.UNI_V3 && mp != SwapMode.UNI_V4) {
                revert Leg2ModeNotAllowed(uint8(mp));
            }
            if (plan.swapPlan.leg2.repayToken != weth) revert InvalidPlan();
            if (collateralAsset != address(0) && plan.swapPlan.leg2.srcToken != collateralAsset) {
                revert SrcTokenNotCollateral(collateralAsset, plan.swapPlan.leg2.srcToken);
            }
            if (plan.swapPlan.leg1.useFullBalance || plan.swapPlan.leg2.useFullBalance) {
                revert InvalidPlan();
            }
            // PARASWAP_SINGLE / BEBOP_MULTI embed `amountIn` in calldata
            // — that's fine here (leg1 runs first, we measure what it
            // consumed). For Uni leg1 modes we still require an explicit
            // amountIn inside the leg struct because Uni executors read
            // it at dispatch time.
            if (
                (m1 == SwapMode.UNI_V2 || m1 == SwapMode.UNI_V3 || m1 == SwapMode.UNI_V4)
                    && plan.swapPlan.leg1.amountIn == 0
            ) {
                revert ZeroAmountIn();
            }
            _validateLeg(plan.swapPlan.leg2);
        }

        address provider = allowedFlashProviders[plan.flashProviderId];
        if (provider == address(0)) revert FlashProviderNotAllowed();

        _activePlanHash = keccak256(planData);
        _executionPhase = ExecutionPhase.FlashLoanActive;

        if (plan.flashProviderId == FLASH_PROVIDER_BALANCER) {
            IERC20[] memory tokens = new IERC20[](1);
            tokens[0] = IERC20(plan.loanToken);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = plan.loanAmount;
            IBalancerVault(provider).flashLoan(address(this), tokens, amounts, planData);
        } else if (plan.flashProviderId == FLASH_PROVIDER_MORPHO) {
            // Morpho Blue flashloan: zero fee, repayment pulled via safeTransferFrom after callback.
            IMorphoBlue(provider).flashLoan(plan.loanToken, plan.loanAmount, planData);
        } else {
            revert FlashProviderNotAllowed();
        }

        _activePlanHash = bytes32(0);
        _executionPhase = ExecutionPhase.Idle;
        emit FlashExecuted(plan.flashProviderId, plan.loanToken, plan.loanAmount);
    }

    // ─── Balancer Flashloan Callback ─────────────────────────────────
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        if (_executionPhase != ExecutionPhase.FlashLoanActive) {
            revert InvalidExecutionPhase();
        }
        if (_activePlanHash == bytes32(0)) revert NoActivePlan();
        if (msg.sender != allowedFlashProviders[FLASH_PROVIDER_BALANCER]) {
            revert InvalidCallbackCaller();
        }
        if (keccak256(userData) != _activePlanHash) revert InvalidPlan();
        if (tokens.length != 1) revert BalancerSingleTokenOnly();

        Plan memory plan = abi.decode(userData, (Plan));

        // P0 safety: strict token/amount match
        if (address(tokens[0]) != plan.loanToken) revert CallbackAssetMismatch();
        if (amounts[0] != plan.loanAmount) revert CallbackAmountMismatch();
        if (feeAmounts[0] > plan.maxFlashFee) revert FlashFeeExceeded(feeAmounts[0], plan.maxFlashFee);

        uint256 flashRepayAmount = amounts[0] + feeAmounts[0];
        (uint256 realizedProfit, uint256 totalCoinbasePayment) = _runFlashloanPipeline(plan, flashRepayAmount);

        // Balancer expects funds returned by end of callback via transfer (vault=msg.sender).
        _finalizeFlashloan(
            address(tokens[0]),
            flashRepayAmount,
            msg.sender,
            realizedProfit,
            totalCoinbasePayment,
            plan.swapPlan.minProfitAmount
        );
    }

    // ─── Morpho Blue Flashloan Callback ──────────────────────────────
    /// @notice Morpho Blue flashloan callback. Same internal pipeline as Aave V3 / Balancer:
    /// validate caller + plan hash, run liquidation actions, swap collateral, settle profit.
    /// Morpho is fee-free and pulls repayment via safeTransferFrom after this returns, so we
    /// must approve `amount` to msg.sender (the Morpho contract). Reverts on insufficient
    /// repayment balance or any caller other than the registered Morpho flash provider.
    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external override {
        if (_executionPhase != ExecutionPhase.FlashLoanActive) revert InvalidExecutionPhase();
        if (_activePlanHash == bytes32(0)) revert NoActivePlan();
        if (msg.sender != allowedFlashProviders[FLASH_PROVIDER_MORPHO]) revert InvalidCallbackCaller();
        if (keccak256(data) != _activePlanHash) revert InvalidPlan();

        Plan memory plan = abi.decode(data, (Plan));

        // P0 safety: strict amount match. Morpho passes no asset, so we trust loanToken from
        // the plan-hash-bound payload (already pinned by the activePlanHash check above).
        if (amount != plan.loanAmount) revert CallbackAmountMismatch();
        // Morpho flashloan is fee-free, no maxFlashFee comparison needed (0 ≤ any uint256).

        // Morpho fee = 0, so flash repay equals principal
        uint256 flashRepayAmount = amount;
        (uint256 realizedProfit, uint256 totalCoinbasePayment) = _runFlashloanPipeline(plan, flashRepayAmount);

        // Morpho also pulls via safeTransferFrom after callback returns (vault=0).
        _finalizeFlashloan(
            plan.loanToken,
            flashRepayAmount,
            address(0),
            realizedProfit,
            totalCoinbasePayment,
            plan.swapPlan.minProfitAmount
        );
    }

    // ─── Internal: Shared post-loan pipeline ─────────────────────────
    /// @dev Identical body across Aave V3 / Balancer / Morpho callbacks — extracted to
    /// shrink runtime size below EIP-170. Pre-execution validation, snapshot of profit
    /// + collateral, target-action fan-out, post-action delta checks, optional aToken
    /// unwrap, swap, and finally the internal-action loop (e.g. coinbase payment).
    /// Each callback wraps this with provider-specific argument validation and a
    /// finalize call (`_finalizeFlashloan` for repayment).
    function _runFlashloanPipeline(Plan memory plan, uint256 flashRepayAmount)
        internal
        returns (uint256 realizedProfit, uint256 totalCoinbasePayment)
    {
        // Pre-execution: verify flash loan funds received
        if (IERC20(plan.loanToken).balanceOf(address(this)) < plan.loanAmount) revert InvalidFlashLoan();

        // Derive collateralAsset and trackingToken for delta check and swap plan
        (address collateralAsset, address trackingToken) = _validateActions(plan.actions, plan.loanToken);

        // Verify aToken address against canonical source when receiveAToken=true
        if (trackingToken != address(0) && trackingToken != collateralAsset) {
            _verifyATokenAddress(plan.actions, collateralAsset, trackingToken);
        }

        // Snapshot BEFORE protocol actions
        uint256 profitBefore = IERC20(plan.swapPlan.profitToken).balanceOf(address(this));
        uint256 collateralBefore;
        if (trackingToken != address(0)) {
            collateralBefore = IERC20(trackingToken).balanceOf(address(this));
        }
        // Separate snapshot on the collateral asset itself (may differ from
        // trackingToken when receiveAToken=true). Drives UNI_V2/V3 full-balance
        // mode: amountIn is the delta produced by this execute() call, never a
        // pre-existing balance.
        uint256 collateralAssetBefore;
        if (collateralAsset != address(0)) {
            collateralAssetBefore = IERC20(collateralAsset).balanceOf(address(this));
        }

        // Execute protocol actions (liquidations), skip INTERNAL
        for (uint256 i = 0; i < plan.actions.length; ++i) {
            if (plan.actions[i].protocolId != PROTOCOL_INTERNAL) {
                _executeTargetAction(plan.actions[i].protocolId, plan.actions[i].data);
            }
        }

        // Post-action: verify liquidation produced collateral AND
        // optionally unwrap aTokens to underlying in the same block.
        // Unwrap is skipped when leg1.srcToken is the aToken itself
        // (the plan consumes the aToken directly, typically via an
        // aToken/underlying peg pool).
        if (trackingToken != address(0)) {
            uint256 trackingAfter = IERC20(trackingToken).balanceOf(address(this));
            if (trackingAfter <= collateralBefore) revert NoCollateralReceived();

            if (trackingToken != collateralAsset && plan.swapPlan.leg1.srcToken != trackingToken) {
                uint256 aTokenDelta = trackingAfter - collateralBefore;
                uint256 underlyingBefore = IERC20(collateralAsset).balanceOf(address(this));
                _unwrapATokens(collateralAsset, aTokenDelta);
                if (IERC20(collateralAsset).balanceOf(address(this)) <= underlyingBefore) revert UnwrapFailed();
            }
        }

        // Post-pipeline collateral delta (underlying only). In skip-unwrap
        // mode the underlying balance is unchanged, so collateralDelta=0
        // — useFullBalance modes would read zero and fail fast, forcing
        // the caller to use a fixed `amountIn` for the aToken path.
        uint256 collateralDelta;
        if (collateralAsset != address(0)) {
            uint256 collateralAssetAfter = IERC20(collateralAsset).balanceOf(address(this));
            collateralDelta =
                collateralAssetAfter > collateralAssetBefore ? collateralAssetAfter - collateralAssetBefore : 0;
        }

        _executeSwapPlan(plan.swapPlan, flashRepayAmount, collateralAsset, collateralDelta);

        // Compute realized on-chain profit AFTER swap, BEFORE coinbase payments,
        // BEFORE flash repay. This is the authoritative base that ACTION_PAY_COINBASE
        // basis-points arithmetic multiplies against.
        realizedProfit = _computeRealizedProfit(
            plan.loanToken, plan.swapPlan.profitToken, profitBefore, plan.loanAmount, flashRepayAmount
        );

        // Execute internal actions (coinbase bps payments) now that realized profit
        // is known. Per-action bps is validated and multiplied against realizedProfit.
        for (uint256 i = 0; i < plan.actions.length; ++i) {
            if (plan.actions[i].protocolId == PROTOCOL_INTERNAL) {
                totalCoinbasePayment += _executeInternalAction(
                    plan.actions[i].data, plan.swapPlan.profitToken, realizedProfit
                );
            }
        }
    }

    /// @dev Compute realized on-chain profit net of the flashloan obligation, but
    /// BEFORE any coinbase bid is paid. Used as the base for bps-sized coinbase
    /// payments and for the final `minProfitAmount` check.
    function _computeRealizedProfit(
        address asset,
        address profitTkn,
        uint256 profitBefore,
        uint256 principalAmount,
        uint256 repayAmount
    ) internal view returns (uint256) {
        uint256 profitNow = IERC20(profitTkn).balanceOf(address(this));
        if (profitTkn == asset) {
            // profitBefore was snapshotted AFTER flashloan arrival (includes principal).
            // profitNow is post-swap, pre-repay, pre-coinbase (still includes principal).
            // Realized profit once repay is settled:
            //   (profitNow - repayAmount) - (profitBefore - principalAmount)
            // Saturating subtraction — underflow means the swap under-delivered.
            uint256 lhs = profitNow + principalAmount;
            uint256 rhs = profitBefore + repayAmount;
            return lhs > rhs ? lhs - rhs : 0;
        }
        return profitNow > profitBefore ? profitNow - profitBefore : 0;
    }

    // ─── Internal: Finalize Flashloan (unified) ──────────────────────
    /// @dev Single repayment + profit-check path. Aave-style callbacks pull via
    /// `transferFrom` after we return, so `vault == address(0)` signals approve-
    /// only; Balancer expects a push to the vault inside the callback. Profit
    /// accounting is fully decided before this call — `realizedProfit` already
    /// accounts for the flashloan obligation, and `totalCoinbasePayment` is
    /// the sum of on-chain-computed bps payments already made.
    function _finalizeFlashloan(
        address asset,
        uint256 repayAmount,
        address vault,
        uint256 realizedProfit,
        uint256 totalCoinbasePayment,
        uint256 minProfitAmount
    ) internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayBalance(repayAmount, balance);

        if (vault == address(0)) {
            IERC20(asset).forceApprove(msg.sender, repayAmount);
        } else {
            IERC20(asset).safeTransfer(vault, repayAmount);
        }

        _checkProfit(realizedProfit, totalCoinbasePayment, minProfitAmount);
    }

    // ─── Internal: Check Profit ──────────────────────────────────────
    /// @dev Pure: `realizedProfit` already accounts for the flashloan obligation,
    /// and `totalCoinbasePayment` is the on-chain bps-derived sum already paid.
    /// The `> realizedProfit` branch is defensive against multiple coinbase
    /// actions whose bps sum exceeds 100% (each per-action bps is <= 10000,
    /// but nothing blocks operators from stacking them).
    function _checkProfit(uint256 realizedProfit, uint256 totalCoinbasePayment, uint256 minProfitAmount) internal pure {
        if (totalCoinbasePayment > realizedProfit) {
            revert CoinbaseExceedsProfit(totalCoinbasePayment, realizedProfit);
        }
        uint256 effectiveProfit;
        unchecked {
            effectiveProfit = realizedProfit - totalCoinbasePayment;
        }
        if (effectiveProfit < minProfitAmount) revert InsufficientProfit(effectiveProfit, minProfitAmount);
    }

    // ─── Internal: Execute Swap Plan ─────────────────────────────────
    /// @dev Dispatches swap by mode, validates delta-based repay balance covers flash loan obligation.
    /// `collateralDelta` is the net underlying-asset increase produced by the
    /// current execute() invocation (post-liquidation, post-aToken-unwrap),
    /// consumed only by UNI_V2/V3 when useFullBalance=true.
    function _executeSwapPlan(
        SwapPlan memory plan,
        uint256 flashRepayAmount,
        address collateralAsset,
        uint256 collateralDelta
    ) internal {
        SwapLeg memory leg1 = plan.leg1;

        // NO_SWAP: same-token liquidation (e.g. WETH/WETH). The liquidation
        // already deposited loanToken on the contract; _finalizeFlashloan's
        // absolute balance check settles the flashloan.
        if (leg1.mode == SwapMode.NO_SWAP) return;

        address finalRepayToken = (plan.hasLeg2 ? plan.leg2.repayToken : leg1.repayToken);
        uint256 finalRepayBefore = IERC20(finalRepayToken).balanceOf(address(this));

        // Pre-leg1 snapshot of leg1.repayToken balance. Dual-purpose:
        //   * Passed to _dispatchLeg as the Bebop repayDelta baseline (other modes ignore it).
        //   * When hasLeg2==true, leg1.repayToken == leg2.srcToken (InvalidLegLink check),
        //     so this same snapshot is the pre-leg1 intermediate balance used to compute
        //     trackedLeftover after leg1 runs.
        uint256 leg1RepayBefore = IERC20(leg1.repayToken).balanceOf(address(this));

        // SPLIT mode: partition collateralDelta between repay (leg1) and profit
        // (leg2 → WETH); each leg runs with its explicitly-allocated amountIn.
        // Validated in execute(): hasSplit XOR hasLeg2 XOR hasMixedSplit, both
        // legs Uni-only, leg2.repayToken==weth, neither useFullBalance.
        if (plan.hasSplit) {
            uint256 profitAmount = (collateralDelta * plan.splitBps) / 10_000;
            uint256 repayAmount = collateralDelta - profitAmount;
            if (profitAmount == 0 || repayAmount == 0) revert InvalidPlan();

            _dispatchLeg(leg1, repayAmount, leg1RepayBefore);
            _dispatchLeg(plan.leg2, profitAmount, 0);

            uint256 splitRepayAfter = IERC20(finalRepayToken).balanceOf(address(this));
            uint256 splitRepayDelta = splitRepayAfter > finalRepayBefore ? splitRepayAfter - finalRepayBefore : 0;
            if (splitRepayDelta < flashRepayAmount) revert InsufficientRepayOutput(splitRepayDelta, flashRepayAmount);
            return;
        }

        // MIXED_SPLIT mode: leg1 = any swap mode (coll → loanToken,
        // typical Paraswap/Bebop for deep routing), leg2 = Uni-only
        // (coll → WETH) on the residual collateral. Measured execution:
        //
        //   1. Snapshot collateral balance BEFORE leg1.
        //   2. Run leg1 with its own embedded amountIn (calldata for
        //      Paraswap/Bebop, amount_in field for Uni).
        //   3. Measure leg1_consumed = collBefore - collAfter. Must be
        //      strictly < collateralDelta (leaves room for leg2) and
        //      strictly > 0 (leg1 actually did something).
        //   4. Run leg2 on the residual: leg2_amountIn =
        //      collateralDelta - leg1_consumed.
        //   5. Assert final repayDelta on loanToken ≥ flashRepayAmount
        //      (leg1 alone must cover repay; leg2 output is WETH profit).
        //
        // Invariants pinned upstream in execute():
        //   * Exactly one of {hasLeg2, hasSplit, hasMixedSplit} is true.
        //   * leg1.srcToken == collateralAsset (general leg1 check).
        //   * leg1.repayToken == loanToken (MIXED_SPLIT-specific).
        //   * leg2 mode ∈ {UNI_V2, UNI_V3, UNI_V4}.
        //   * leg2.srcToken == collateralAsset (same collateral, parallel
        //     split — NOT the leg1.repayToken link that hasLeg2 uses).
        //   * leg2.repayToken == weth (pinned profit token).
        //   * Neither leg sets useFullBalance (deterministic sizing).
        if (plan.hasMixedSplit) {
            // Safety: if the caller didn't pass collateralAsset we can't
            // measure leg1 consumption — reject here rather than let the
            // mode silently degrade into a no-op profit leg.
            if (collateralAsset == address(0)) revert InvalidPlan();

            uint256 collBeforeLeg1 = IERC20(collateralAsset).balanceOf(address(this));

            // leg1 executes with its own amountIn. The leg1RepayBefore
            // snapshot is still the Bebop delta baseline when leg1 is
            // BEBOP_MULTI — other modes ignore the third arg.
            _dispatchLeg(leg1, leg1.amountIn, leg1RepayBefore);

            uint256 collAfterLeg1 = IERC20(collateralAsset).balanceOf(address(this));
            // Strict: leg1 must consume SOME collateral (non-zero) AND
            // leave strictly positive residual for the profit leg. This
            // prevents both "no-op leg1" (saturate to zero) and "leg1
            // over-approved and consumed more than the opportunity
            // produced" (which would leave zero for leg2 → revert
            // InsufficientRepayOutput or ZeroSwapInput downstream, but
            // a precise error is operationally preferable).
            if (collAfterLeg1 >= collBeforeLeg1) revert MixedSplitLeg1NoConsumption();
            uint256 leg1Consumed;
            unchecked {
                // Safe: checked above that collAfterLeg1 < collBeforeLeg1.
                leg1Consumed = collBeforeLeg1 - collAfterLeg1;
            }
            if (leg1Consumed >= collateralDelta) {
                revert MixedSplitLeg1Overspent(leg1Consumed, collateralDelta);
            }
            uint256 leg2AmountIn;
            unchecked {
                // Safe: checked above that leg1Consumed < collateralDelta.
                leg2AmountIn = collateralDelta - leg1Consumed;
            }

            _dispatchLeg(plan.leg2, leg2AmountIn, 0);

            // Final repay check: leg1's output (loanToken) alone must
            // cover flashRepayAmount. leg2's output is WETH (profit leg)
            // so it does NOT contribute to the repay balance — the
            // finalRepayToken snapshot is taken against loanToken.
            uint256 splitRepayAfter = IERC20(finalRepayToken).balanceOf(address(this));
            uint256 splitRepayDelta = splitRepayAfter > finalRepayBefore ? splitRepayAfter - finalRepayBefore : 0;
            if (splitRepayDelta < flashRepayAmount) {
                revert InsufficientRepayOutput(splitRepayDelta, flashRepayAmount);
            }
            return;
        }

        uint256 leg1AmountIn = leg1.useFullBalance ? collateralDelta : leg1.amountIn;

        _dispatchLeg(leg1, leg1AmountIn, leg1RepayBefore);

        uint256 trackedLeftover;
        if (plan.hasLeg2) {
            // leg2.srcToken == leg1.repayToken (enforced in execute() via InvalidLegLink),
            // so leg1RepayBefore is the pre-leg1 intermediate balance. leg2.useFullBalance
            // is enforced true in execute(), so trackedLeftover is always the leg2 amountIn.
            uint256 intermediateAfter = IERC20(plan.leg2.srcToken).balanceOf(address(this));
            trackedLeftover = intermediateAfter > leg1RepayBefore ? intermediateAfter - leg1RepayBefore : 0;
            if (trackedLeftover == 0) revert Leg2ZeroLeftover();

            _dispatchLeg(plan.leg2, trackedLeftover, 0);
        }

        uint256 finalRepayAfter = IERC20(finalRepayToken).balanceOf(address(this));
        uint256 repayDelta = finalRepayAfter > finalRepayBefore ? finalRepayAfter - finalRepayBefore : 0;
        if (repayDelta < flashRepayAmount) revert InsufficientRepayOutput(repayDelta, flashRepayAmount);

        if (plan.hasLeg2) {
            emit TwoLegSwapExecuted(plan.leg2.srcToken, leg1AmountIn, trackedLeftover, trackedLeftover, repayDelta);
        }
    }

    function _dispatchLeg(SwapLeg memory leg, uint256 amountIn, uint256 outBefore) internal {
        SwapMode m = leg.mode;
        if (m == SwapMode.PARASWAP_SINGLE) {
            SwapLegExecutorLib.executeParaswapLeg(_asLibLeg(leg), paraswapAugustusV6);
        } else if (m == SwapMode.BEBOP_MULTI) {
            _executeBebopLeg(leg, outBefore);
        } else if (m == SwapMode.UNI_V2) {
            SwapLegExecutorLib.executeUniV2Leg(_asLibLeg(leg), amountIn, uniV2Router);
        } else if (m == SwapMode.UNI_V3) {
            SwapLegExecutorLib.executeUniV3Leg(_asLibLeg(leg), amountIn, uniV3Router);
        } else if (m == SwapMode.UNI_V4) {
            _executeUniV4Leg(leg, amountIn);
        } else {
            revert InvalidSwapMode();
        }
    }

    /// @dev Reinterprets a main-contract `SwapLeg memory` pointer as a
    /// `SwapLegExecutorLib.SwapLeg memory` pointer. The two struct
    /// declarations are byte-for-byte identical (field order + types);
    /// memory layout is identical by ABI rules. Pure pointer retype, no
    /// memory copy. Keeping both declarations in sync is enforced by the
    /// STRUCT DISCIPLINE comment in the library file.
    function _asLibLeg(SwapLeg memory leg) internal pure returns (SwapLegExecutorLib.SwapLeg memory libLeg) {
        assembly {
            libLeg := leg
        }
    }

    // Paraswap single leg moved to SwapLegExecutorLib (external library,
    // DELEGATECALL). See `_dispatchLeg` for the call site.

    // ─── Internal: Bebop Multi ───────────────────────────────────────
    /// @dev Executes opaque Bebop settlement call. Security: allowlist + exact approval + output delta checks.
    function _executeBebopLeg(SwapLeg memory leg, uint256 repayBefore) internal {
        address target = leg.bebopTarget;
        if (target.code.length == 0) revert BebopTargetNotContract();
        if (!allowedTargets[target]) revert TargetNotAllowed(target);

        uint256 srcBal = IERC20(leg.srcToken).balanceOf(address(this));
        if (srcBal < leg.amountIn) revert InsufficientSrcBalance(leg.amountIn, srcBal);

        IERC20(leg.srcToken).forceApprove(target, leg.amountIn);
        (bool ok,) = target.call(leg.bebopCalldata);
        IERC20(leg.srcToken).forceApprove(target, 0);

        if (!ok) revert BebopSwapFailed();

        uint256 repayAfter = IERC20(leg.repayToken).balanceOf(address(this));
        uint256 repayDelta = repayAfter > repayBefore ? repayAfter - repayBefore : 0;
        if (repayDelta < leg.minAmountOut) revert InsufficientRepayOutput(repayDelta, leg.minAmountOut);

        emit BebopSwapExecuted(target, leg.srcToken, leg.amountIn, repayDelta, 0);
    }

    // Uniswap V2 + V3 legs moved to SwapLegExecutorLib (external library,
    // DELEGATECALL). See `_dispatchLeg` for the call sites.

    // ─── Internal: V4 leg validation (centralized fail-closed checks) ─
    /// @dev Single source of truth for V4 preconditions. Called from
    /// `_validateLeg` pre-flashloan for UNI_V4 legs. The per-leg executor
    /// (`_executeUniV4Leg`) no longer re-runs these checks — `_validateLeg`
    /// is authoritative. Returns the decoded PoolKey fields so the caller
    /// can reuse them without re-decoding.
    ///
    /// PRODUCTION SCOPE — the V4 path is intentionally narrow:
    ///   * single-hop only (one `swap()` call per leg)
    ///   * exact-input only (amountSpecified negative, see unlockCallback)
    ///   * ERC20 → ERC20 only (native ETH / Currency(0) is rejected)
    ///   * tokenOut MUST equal `leg.repayToken` — which is the outer loan
    ///     token for a one-leg plan (or leg2 of a two-leg plan), and the
    ///     intermediate token (== leg2.srcToken) for leg1 of a two-leg plan
    ///   * hook MUST be address(0) or in `allowedV4Hooks`
    /// Any widening of this scope requires new tests and a fresh review.
    function _validateV4Leg(SwapLeg memory leg)
        internal
        view
        returns (address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hook)
    {
        if (leg.minAmountOut == 0) revert InvalidPlan();

        address pm = leg.v4PoolManager;
        if (pm == address(0)) revert ZeroAddress();
        if (!allowedTargets[pm]) revert TargetNotAllowed(pm);
        if (leg.v4SwapData.length != V4_SWAP_DATA_LENGTH) revert InvalidV4Data();

        (tokenIn, tokenOut, fee, tickSpacing, hook) =
            abi.decode(leg.v4SwapData, (address, address, uint24, int24, address));

        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidV4NativeToken();
        if (tokenIn != leg.srcToken) revert InvalidV4Data();
        if (tokenOut != leg.repayToken) revert InvalidV4TokenOut(leg.repayToken, tokenOut);
        if (tokenIn == tokenOut) revert InvalidV4Data();

        if (fee == 0 || tickSpacing <= 0) revert InvalidV4FeeOrSpacing();
        if (fee & 0x800000 != 0) revert InvalidV4Fee();

        if (hook != address(0) && !allowedV4Hooks[hook]) revert V4HookNotAllowed(hook);
    }

    // ─── Internal: Uniswap V4 single-hop exact-input swap ────────────
    /// @notice PRODUCTION SCOPE — the V4 path is intentionally narrow.
    /// Supported: single-hop, exact-input, ERC20→ERC20, tokenOut == repayToken,
    /// hook ∈ {address(0)} ∪ allowedV4Hooks. Everything else fails closed.
    /// Widening this scope (multi-hop, ETH, exact-output, generic routing)
    /// requires new tests and security review.
    /// @dev Executes a single-hop exact-input swap via PoolManager's
    /// unlock-callback pattern. Full validation already ran in `execute()`
    /// via `_validateV4Leg`; this function re-decodes inline to keep the
    /// runtime size down.
    function _executeUniV4Leg(SwapLeg memory leg, uint256 amountIn) internal {
        (address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hook) =
            abi.decode(leg.v4SwapData, (address, address, uint24, int24, address));

        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(tokenIn).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        address pm = leg.v4PoolManager;
        _activeV4PoolManager = pm;
        _activeV4TokenIn = tokenIn;
        // tokenIn is NOT included in the unlock payload — the callback
        // reads it from storage so the PM cannot substitute it. Encode
        // the remaining five fields only.
        IPoolManager(pm).unlock(abi.encode(tokenOut, fee, tickSpacing, hook, amountIn));
        // _activeV4TokenIn cleared by callback on entry. _activeV4PoolManager
        // cleared so the existing pm-pin guard re-arms for the next leg.
        _activeV4PoolManager = address(0);

        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (received < leg.minAmountOut) revert InsufficientRepayOutput(received, leg.minAmountOut);

        emit UniV4SwapExecuted(tokenIn, tokenOut, fee, amountIn, received);
    }

    /// @inheritdoc IUnlockCallback
    /// @notice PRODUCTION SCOPE — this callback implements exactly ONE shape:
    ///   exact-input single-hop ERC20→ERC20 swap inside the flashloan pipeline.
    /// @dev Three layers of protection against stray or adversarial calls:
    ///   1. `ExecutionPhase.FlashLoanActive` — only valid inside execute()
    ///   2. `_activeV4PoolManager != 0`     — only while `_executeUniV4Leg` is mid-unlock
    ///   3. `msg.sender == _activeV4PoolManager` — only the pinned PoolManager
    /// BalanceDelta invariant: tokenInDelta < 0 (we owe) AND tokenOutDelta > 0
    /// (we receive). Any other shape — including zero-output swaps, partial
    /// settlement, or positive input — fails closed. Widening the callback
    /// (multi-hop, native ETH, exact-output, hook-specific deltas) requires
    /// new tests and security review.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (_executionPhase != ExecutionPhase.FlashLoanActive) revert InvalidExecutionPhase();
        // tokenIn is read from storage (pinned by _executeUniV4Leg) rather
        // than from `data` — PM controls the data, not storage, so
        // substitution is impossible by construction. Clearing on entry
        // doubles as the re-entry guard: a nested unlockCallback from
        // inside swap() finds tokenIn == 0 and the combined check below
        // fails closed. The msg.sender check covers the not-in-flow case
        // (_activeV4PoolManager == 0 → msg.sender != 0 = always true).
        address tokenIn = _activeV4TokenIn;
        if (tokenIn == address(0) || msg.sender != _activeV4PoolManager) revert InvalidCallbackCaller();
        _activeV4TokenIn = address(0); // CLAIM

        (address tokenOut, uint24 fee, int24 tickSpacing, address hook, uint256 amountIn) =
            abi.decode(data, (address, uint24, int24, address, uint256));

        // Hook whitelist re-check defends against a malicious/
        // misconfigured PoolManager substituting the hook field.
        // tokenOut substitution remains caught by the post-unlock
        // `received` delta (computed against `leg.repayToken`) and
        // the pipeline-level `repayDelta >= flashRepayAmount` gate.
        if (hook != address(0) && !allowedV4Hooks[hook]) revert InvalidV4CallbackHook();

        bool zeroForOne = tokenIn < tokenOut;
        PoolKey memory key = PoolKey({
            currency0: zeroForOne ? tokenIn : tokenOut,
            currency1: zeroForOne ? tokenOut : tokenIn,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hook
        });

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? V4_MIN_SQRT_PRICE_LIMIT : V4_MAX_SQRT_PRICE_LIMIT
        });

        int256 swapDelta = IPoolManager(msg.sender).swap(key, params, "");
        int128 amount0 = int128(swapDelta >> 128);
        int128 amount1 = int128(swapDelta);

        int128 tokenInDelta = zeroForOne ? amount0 : amount1;
        int128 tokenOutDelta = zeroForOne ? amount1 : amount0;

        // Exact-input single-hop invariant: owe strictly positive tokenIn
        // (tokenInDelta < 0), gain strictly positive tokenOut (tokenOutDelta > 0).
        // Any other shape — including zero-output, positive-input, or partial
        // settlement — fails closed. Strict `< 0` / `> 0` makes owedIn > 0
        // and gainedOut > 0 by construction (no extra zero-guards needed).
        if (tokenInDelta >= 0 || tokenOutDelta <= 0) revert V4UnexpectedDelta();

        uint256 owedIn = uint256(int256(-tokenInDelta));
        uint256 gainedOut = uint256(int256(tokenOutDelta));

        IPoolManager(msg.sender).sync(tokenIn);
        IERC20(tokenIn).safeTransfer(msg.sender, owedIn);
        IPoolManager(msg.sender).settle();
        IPoolManager(msg.sender).take(tokenOut, address(this), gainedOut);
        return "";
    }

    // Paraswap orchestration (decode + validate + approve + call + delta
    // check) moved to SwapLegExecutorLib.executeParaswapLeg. The decoder
    // itself (ParaswapDecoderLib) remains a separate external library
    // that the SwapLegExecutor library calls into.

    // ─── Internal: Execute Target Action ─────────────────────────────
    function _executeTargetAction(uint8 protocolId, bytes memory actionData) internal {
        if (protocolId == PROTOCOL_AAVE_V3) {
            _executeAaveV3Liquidation(actionData);
        } else if (protocolId == PROTOCOL_AAVE_V2) {
            _executeAaveV2Liquidation(actionData);
        } else if (protocolId == PROTOCOL_MORPHO_BLUE) {
            _executeMorphoLiquidation(actionData);
        } else {
            revert InvalidProtocolId(protocolId);
        }
    }

    function _executeAaveV3Liquidation(bytes memory actionData) internal {
        AaveV3Action memory action = abi.decode(actionData, (AaveV3Action));

        address pool = aavePool;
        if (pool == address(0)) revert ZeroAddress();
        if (!allowedTargets[pool]) revert TargetNotAllowed(pool);
        if (action.actionType != 4) revert UnsupportedActionType(action.actionType);
        if (action.user == address(0)) revert ZeroAddress();
        if (action.debtToCover == 0) revert InvalidPlan();

        IERC20(action.debtAsset).forceApprove(pool, action.debtToCover);
        IAaveV3Pool(pool)
            .liquidationCall(
                action.collateralAsset, action.debtAsset, action.user, action.debtToCover, action.receiveAToken
            );
        IERC20(action.debtAsset).forceApprove(pool, 0);

        emit LiquidationExecuted(PROTOCOL_AAVE_V3, action.collateralAsset, action.debtAsset, action.debtToCover);
    }

    function _executeAaveV2Liquidation(bytes memory actionData) internal {
        AaveV2Liquidation memory liq = abi.decode(actionData, (AaveV2Liquidation));

        address pool = aaveV2LendingPool;
        if (pool == address(0)) revert ZeroAddress();
        if (!allowedTargets[pool]) revert TargetNotAllowed(pool);

        IERC20(liq.debtAsset).forceApprove(pool, liq.debtToCover);
        IAaveV2LendingPool(pool)
            .liquidationCall(liq.collateralAsset, liq.debtAsset, liq.user, liq.debtToCover, liq.receiveAToken);
        IERC20(liq.debtAsset).forceApprove(pool, 0);

        emit LiquidationExecuted(PROTOCOL_AAVE_V2, liq.collateralAsset, liq.debtAsset, liq.debtToCover);
    }

    function _executeMorphoLiquidation(bytes memory actionData) internal {
        MorphoLiquidation memory liq = abi.decode(actionData, (MorphoLiquidation));

        address morpho = morphoBlue;
        if (morpho == address(0)) revert ZeroAddress();
        if (!allowedTargets[morpho]) revert TargetNotAllowed(morpho);
        if (liq.borrower == address(0)) revert ZeroAddress();
        if (liq.seizedAssets == 0) revert MorphoShareModeUnsupported();
        if (liq.repaidShares != 0) revert MorphoMixedModeUnsupported();
        if (liq.maxRepayAssets == 0) revert InvalidPlan();
        if (liq.marketParams.loanToken == address(0)) revert MorphoInvalidMarketParams();
        if (liq.marketParams.collateralToken == address(0)) revert MorphoInvalidMarketParams();

        // Approve maxRepayAssets — loan-token denominated bound (NOT collateral-side seizedAssets).
        // seizedAssets is collateral units; assetsRepaid (what Morpho actually pulls) is loan-token units.
        // These are different dimensions — approval must match the repay side.
        IERC20(liq.marketParams.loanToken).forceApprove(morpho, liq.maxRepayAssets);
        (, uint256 assetsRepaid) =
            IMorphoBlue(morpho).liquidate(liq.marketParams, liq.borrower, liq.seizedAssets, liq.repaidShares, "");
        IERC20(liq.marketParams.loanToken).forceApprove(morpho, 0);

        // Verify Morpho didn't pull more than the operator authorized
        if (assetsRepaid > liq.maxRepayAssets) revert InsufficientRepayBalance(assetsRepaid, liq.maxRepayAssets);

        emit LiquidationExecuted(
            PROTOCOL_MORPHO_BLUE, liq.marketParams.collateralToken, liq.marketParams.loanToken, assetsRepaid
        );
    }

    /// @dev Verifies operator-supplied aTokenAddress matches the canonical aToken from the Aave pool.
    /// Uses low-level call + assembly to avoid stack-too-deep with getReserveData's 15 return values.
    function _verifyATokenAddress(Action[] memory actions, address collateralAsset, address suppliedAToken)
        internal
        view
    {
        for (uint256 i = 0; i < actions.length; ++i) {
            if (actions[i].protocolId == PROTOCOL_AAVE_V3) {
                address pool = aavePool;
                // getReserveData(address) selector = 0x35ea6a75
                // aTokenAddress is the 9th return value (offset 8*32 = 256 in returndata)
                address canonical;
                assembly {
                    let ptr := mload(0x40)
                    mstore(ptr, 0x35ea6a7500000000000000000000000000000000000000000000000000000000)
                    mstore(add(ptr, 4), collateralAsset)
                    let ok := staticcall(gas(), pool, ptr, 36, ptr, 480)
                    if iszero(ok) { revert(0, 0) }
                    canonical := mload(add(ptr, 256)) // 9th slot
                }
                if (suppliedAToken != canonical) revert InvalidATokenAddress(suppliedAToken, canonical);
                return;
            }
            // V2 receiveAToken=true is blocked in _validateActions — unreachable here
        }
    }

    /// @dev Unwraps aTokens to underlying via the appropriate Aave pool.
    /// @dev Unwraps aTokens to underlying via Aave V3 pool withdraw.
    /// Only V3 supports receiveAToken=true (V2 is blocked in validation).
    function _unwrapATokens(address collateralAsset, uint256 amount) internal {
        IAaveV3Pool(aavePool).withdraw(collateralAsset, amount, address(this));
    }

    // ─── Internal: Execute Internal Action ──────────────────────────
    /// @dev Centralized dispatch for PROTOCOL_INTERNAL actions. Only
    /// ACTION_PAY_COINBASE is defined.
    ///
    /// ACTION_PAY_COINBASE amount is interpreted as basis points (0..10000)
    /// over realized on-chain profit, not as an absolute payment amount.
    /// The operator specifies a percentage; the contract sizes the actual
    /// bid from the on-chain-computed `realizedProfit` snapshot taken
    /// between swap completion and any coinbase payment.
    ///
    /// No-ops (returns 0, no transfer) when `realizedProfit == 0` or
    /// `coinbaseBps == 0` — consistent behaviour in both degenerate cases.
    function _executeInternalAction(bytes memory actionData, address profitToken, uint256 realizedProfit)
        internal
        returns (uint256 coinbasePaid)
    {
        uint8 actionType = abi.decode(actionData, (uint8));

        if (actionType == ACTION_PAY_COINBASE) {
            // Coinbase payment is ETH-denominated — only valid when profit is in WETH
            if (profitToken != weth) revert CoinbasePaymentRequiresWethProfit();

            (, uint256 coinbaseBps) = abi.decode(actionData, (uint8, uint256));
            if (coinbaseBps > 10_000) revert InvalidCoinbaseBps();

            if (realizedProfit == 0 || coinbaseBps == 0) return 0;

            coinbasePaid = realizedProfit * coinbaseBps / 10_000;
            if (coinbasePaid > 0) {
                _payCoinbase(coinbasePaid);
            }
        } else {
            revert InvalidAction(actionType);
        }
    }

    /// @dev Send ETH to block.coinbase. Only reachable when profitToken == weth
    /// (enforced by caller). Auto-unwraps WETH if insufficient ETH.
    function _payCoinbase(uint256 amount) internal {
        if (amount == 0) return;
        if (block.coinbase == address(0)) revert InvalidCoinbase();

        // Auto-unwrap WETH if insufficient ETH
        if (address(this).balance < amount) {
            address wethAddr = weth;
            if (wethAddr != address(0)) {
                uint256 deficit = amount - address(this).balance;
                uint256 wethBal = IERC20(wethAddr).balanceOf(address(this));
                uint256 toUnwrap = deficit < wethBal ? deficit : wethBal;
                if (toUnwrap > 0) {
                    IWETH(wethAddr).withdraw(toUnwrap);
                }
            }
        }

        if (address(this).balance < amount) revert InsufficientEth(amount, address(this).balance);

        // Gas-capped transfer: bounds work a hostile block.coinbase can perform
        // in the receive fallback. ETH transfer to any well-behaved EOA or
        // builder contract completes in <2300 gas; 10_000 is ample slack.
        (bool success,) = block.coinbase.call{value: amount, gas: COINBASE_CALL_GAS}("");
        if (!success) revert CoinbasePaymentFailed();

        emit CoinbasePaid(block.coinbase, amount);
    }

    // ─── Rescue Functions ────────────────────────────────────────────
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescue(token, to, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert RescueFailed();
        emit Rescue(address(0), to, amount);
    }

    function rescueAllERC20(address token, address to) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();
        IERC20(token).safeTransfer(to, balance);
        emit Rescue(token, to, balance);
    }

    function rescueERC20Batch(address[] calldata tokens, address to) external onlyOwner {
        if (tokens.length == 0) revert EmptyArray();
        if (to == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).safeTransfer(to, balance);
                emit Rescue(tokens[i], to, balance);
            }
        }
    }

    receive() external payable {}
}
