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
    /// by the output delta check against `plan.minAmountOut`).
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
    /// deadline; the executor enforces its own via plan.deadline.
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

    /// @dev PoolManager address currently mid-unlock. Set by `_executeUniV4`
    /// before `unlock()` and cleared on return. `unlockCallback` refuses any
    /// caller that is not this address, so stray `unlockCallback` invocations
    /// from an allow-listed PoolManager acting outside our pipeline revert.
    address private _activeV4PoolManager;

    /// @dev Execution phase guard — prevents unexpected callbacks
    enum ExecutionPhase {
        Idle,
        FlashLoanActive
    }
    ExecutionPhase private _executionPhase;

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
    event V4HookAllowedUpdated(address indexed hook, bool allowed);

    // ─── Enums ────────────────────────────────────────────────────────
    enum SwapMode {
        PARASWAP_SINGLE,
        BEBOP_MULTI,
        UNI_V2,
        UNI_V3,
        UNI_V4
    }

    // ─── Plan Structs ─────────────────────────────────────────────────
    struct SwapPlan {
        SwapMode mode;
        address srcToken;
        uint256 amountIn;
        uint256 deadline;
        bytes paraswapCalldata;
        address bebopTarget;
        bytes bebopCalldata;
        address repayToken;
        address profitToken;
        uint256 minProfitAmount;
        // Uniswap V2 / V3 / V4 fields (ignored for other modes)
        /// @dev UNI_V3 only — pool fee tier, must be in {100, 500, 3000, 10000}.
        uint24 v3Fee;
        /// @dev UNI_V2 only — swap path, path[0]==srcToken, path[last]==repayToken, length >= 2.
        address[] v2Path;
        /// @dev UNI_V2/V3/V4 only — output floor (strict > 0).
        uint256 minAmountOut;
        /// @dev UNI_V2/V3/V4 only — if true, swap input = collateral balance delta
        /// produced during this execute() invocation. Prevents swapping
        /// pre-existing collateral balances acquired outside the flash pipeline.
        bool useFullBalance;
        /// @dev UNI_V4 only — PoolManager address (must be in allowedTargets).
        address v4PoolManager;
        /// @dev UNI_V4 only — strict-encoded PoolKey fields:
        ///   abi.encode(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hook)
        /// Length must be exactly 160 bytes; shorter/longer payloads revert with InvalidV4Data.
        bytes v4SwapData;
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

    // ─── Core Execute ────────────────────────────────────────────────
    function execute(bytes calldata planData) external onlyOperator whenNotPaused nonReentrant {
        Plan memory plan = abi.decode(planData, (Plan));

        // Early deadline check — reject stale plans before any state changes
        if (block.timestamp > plan.swapPlan.deadline) {
            revert SwapDeadlineExpired(plan.swapPlan.deadline, block.timestamp);
        }

        if (plan.loanToken == address(0)) revert ZeroAddress();
        if (plan.loanAmount == 0) revert InvalidPlan();
        if (plan.swapPlan.profitToken == address(0)) revert ZeroAddress();
        if (plan.actions.length == 0) revert NoActions();
        if (plan.actions.length > MAX_ACTIONS) revert TooManyActions(plan.actions.length);

        // Repay token must equal loan token
        if (plan.swapPlan.repayToken != plan.loanToken) {
            revert RepayTokenMismatch(plan.loanToken, plan.swapPlan.repayToken);
        }

        // Validate all actions use same debt/collateral assets
        (address collateralAsset,) = _validateActions(plan.actions, plan.loanToken);

        // Collateral linkage: srcToken must match liquidation collateral
        {
            if (collateralAsset != address(0)) {
                if (plan.swapPlan.srcToken != collateralAsset) {
                    revert SrcTokenNotCollateral(collateralAsset, plan.swapPlan.srcToken);
                }
            }
        }

        // Mode-specific validation
        if (plan.swapPlan.mode == SwapMode.PARASWAP_SINGLE) {
            if (plan.swapPlan.paraswapCalldata.length < 4) revert InvalidParaswapCalldata();
        } else if (plan.swapPlan.mode == SwapMode.BEBOP_MULTI) {
            if (plan.swapPlan.bebopTarget == address(0)) revert InvalidBebopTarget();
            if (plan.swapPlan.bebopCalldata.length < 4) revert InvalidBebopCalldata();
        } else if (plan.swapPlan.mode == SwapMode.UNI_V2) {
            uint256 pLen = plan.swapPlan.v2Path.length;
            if (pLen < 2) revert InvalidV2Path();
            if (plan.swapPlan.v2Path[0] != plan.swapPlan.srcToken) revert InvalidV2Path();
            if (plan.swapPlan.v2Path[pLen - 1] != plan.swapPlan.repayToken) revert InvalidV2Path();
            if (plan.swapPlan.minAmountOut == 0) revert InvalidPlan();
        } else if (plan.swapPlan.mode == SwapMode.UNI_V3) {
            uint24 f = plan.swapPlan.v3Fee;
            if (f != 100 && f != 500 && f != 3000 && f != 10000) revert InvalidV3Fee(f);
            if (plan.swapPlan.minAmountOut == 0) revert InvalidPlan();
        } else if (plan.swapPlan.mode == SwapMode.UNI_V4) {
            // Eager full-content validation — fails closed BEFORE the flashloan
            // is requested, so misconfigured V4 plans never burn a flash fee.
            _validateV4Plan(plan.swapPlan);
        } else {
            revert InvalidSwapMode();
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

        // Post-action: verify liquidation produced collateral (delta-based, all modes)
        if (trackingToken != address(0)) {
            if (IERC20(trackingToken).balanceOf(address(this)) <= collateralBefore) revert NoCollateralReceived();
        }

        // Unwrap aTokens to underlying if receiveAToken was used — delta only
        if (trackingToken != address(0) && trackingToken != collateralAsset) {
            uint256 aTokenDelta = IERC20(trackingToken).balanceOf(address(this)) - collateralBefore;
            if (aTokenDelta > 0) {
                uint256 underlyingBefore = IERC20(collateralAsset).balanceOf(address(this));
                _unwrapATokens(collateralAsset, aTokenDelta);
                if (IERC20(collateralAsset).balanceOf(address(this)) <= underlyingBefore) revert UnwrapFailed();
            }
        }

        // Post-pipeline collateral delta (underlying asset only) — consumed by
        // UNI_V2/V3 useFullBalance mode. Computed AFTER aToken unwrap so the
        // full produced amount is available for swapping regardless of
        // receiveAToken setting.
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
        address, /* collateralAsset */
        uint256 collateralDelta
    )
        internal
    {
        if (block.timestamp > plan.deadline) revert SwapDeadlineExpired(plan.deadline, block.timestamp);

        uint256 repayBefore = IERC20(plan.repayToken).balanceOf(address(this));

        if (plan.mode == SwapMode.PARASWAP_SINGLE) {
            _executeParaswapSingle(plan);
        } else if (plan.mode == SwapMode.BEBOP_MULTI) {
            _executeBebopMulti(plan, repayBefore);
        } else if (plan.mode == SwapMode.UNI_V2) {
            _executeUniV2(plan, collateralDelta);
        } else if (plan.mode == SwapMode.UNI_V3) {
            _executeUniV3(plan, collateralDelta);
        } else if (plan.mode == SwapMode.UNI_V4) {
            _executeUniV4(plan, collateralDelta);
        } else {
            revert InvalidSwapMode();
        }

        // Delta-based repay check: swap output alone must cover the flashloan
        // obligation. Using the delta (not absolute balance) prevents a
        // pre-funded or dust repayToken balance from masking an insufficient
        // swap.
        uint256 repayAfter = IERC20(plan.repayToken).balanceOf(address(this));
        uint256 repayDelta = repayAfter > repayBefore ? repayAfter - repayBefore : 0;
        if (repayDelta < flashRepayAmount) revert InsufficientRepayOutput(repayDelta, flashRepayAmount);
    }

    // ─── Internal: Paraswap Single ───────────────────────────────────
    function _executeParaswapSingle(SwapPlan memory plan) internal {
        if (plan.srcToken == address(0)) revert ZeroAddress();
        if (plan.amountIn == 0) revert ZeroAmountIn();

        (address srcToken, address dstToken, uint256 amountIn, uint256 amountOut, bool isExactIn) =
            _executeParaswapCall(plan.paraswapCalldata);

        if (srcToken != plan.srcToken) revert ParaswapSrcTokenMismatch(plan.srcToken, srcToken);

        if (isExactIn) {
            // ExactIn (any family): consumed must equal declared.
            if (amountIn != plan.amountIn) revert ParaswapAmountInMismatch(plan.amountIn, amountIn);
        } else {
            // ExactOut (any family): plan.amountIn is the declared maximum.
            if (amountIn > plan.amountIn) revert ParaswapAmountInMismatch(plan.amountIn, amountIn);
        }

        if (dstToken != plan.repayToken) revert ParaswapDstTokenUnexpected(dstToken);

        emit ParaswapSwapExecuted(srcToken, dstToken, amountIn, amountOut);
    }

    // ─── Internal: Bebop Multi ───────────────────────────────────────
    /// @dev Executes opaque Bebop settlement call. Security: allowlist + exact approval + output delta checks.
    function _executeBebopMulti(SwapPlan memory plan, uint256 repayBefore) internal {
        address target = plan.bebopTarget;
        if (target == address(0)) revert InvalidBebopTarget();
        if (target.code.length == 0) revert BebopTargetNotContract();
        if (!allowedTargets[target]) revert TargetNotAllowed(target);
        if (plan.srcToken == address(0)) revert ZeroAddress();
        if (plan.amountIn == 0) revert ZeroAmountIn();
        if (plan.bebopCalldata.length < 4) revert InvalidBebopCalldata();

        uint256 srcBal = IERC20(plan.srcToken).balanceOf(address(this));
        if (srcBal < plan.amountIn) revert InsufficientSrcBalance(plan.amountIn, srcBal);

        // Snapshot profitToken for event (separate from repayToken if different)
        uint256 profitSnapBefore;
        if (plan.repayToken != plan.profitToken) {
            profitSnapBefore = IERC20(plan.profitToken).balanceOf(address(this));
        }

        // Exact approval, call, reset
        IERC20(plan.srcToken).forceApprove(target, plan.amountIn);
        (bool ok,) = target.call(plan.bebopCalldata);
        IERC20(plan.srcToken).forceApprove(target, 0);

        if (!ok) revert BebopSwapFailed();

        // Compute deltas for event only (safe subtraction — never reverts).
        // Repay sufficiency is checked by _executeSwapPlan via absolute balance.
        uint256 repayAfter = IERC20(plan.repayToken).balanceOf(address(this));
        uint256 repayDelta = repayAfter > repayBefore ? repayAfter - repayBefore : 0;
        // Bebop has no mode-local minAmountOut; fail closed on zero output so a
        // silent 0-delivery Bebop call cannot slip through when minProfitAmount
        // is also 0 (the aggregate repay check catches it only transitively).
        if (repayDelta == 0) revert ZeroRepayOutput();
        uint256 profitDelta;
        if (plan.repayToken == plan.profitToken) {
            profitDelta = repayDelta;
        } else {
            uint256 profitAfter = IERC20(plan.profitToken).balanceOf(address(this));
            profitDelta = profitAfter > profitSnapBefore ? profitAfter - profitSnapBefore : 0;
        }

        emit BebopSwapExecuted(target, plan.srcToken, plan.amountIn, repayDelta, profitDelta);
    }

    // ─── Internal: Uniswap V2 single-call swap ───────────────────────
    /// @dev Executes `swapExactTokensForTokens` on the immutable V2 router.
    /// Path endpoints are pinned to `plan.srcToken` and `plan.repayToken`
    /// (also asserted up-front in `execute()`). When `useFullBalance=true`,
    /// `amountIn` is the collateral delta produced by the current
    /// execute() call — never a pre-existing balance.
    function _executeUniV2(SwapPlan memory plan, uint256 collateralDelta) internal {
        if (plan.srcToken == address(0)) revert ZeroAddress();
        if (plan.repayToken == address(0)) revert ZeroAddress();

        // Re-assert path shape (execute() already validated; this is the
        // in-pipeline fail-closed check so no caller can reach here with a
        // malformed path even if validation is skipped in the future).
        uint256 pLen = plan.v2Path.length;
        if (pLen < 2) revert InvalidV2Path();
        if (plan.v2Path[0] != plan.srcToken) revert InvalidV2Path();
        if (plan.v2Path[pLen - 1] != plan.repayToken) revert InvalidV2Path();
        if (plan.minAmountOut == 0) revert InvalidPlan();

        uint256 amountIn = plan.useFullBalance ? collateralDelta : plan.amountIn;
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(plan.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        address router = uniV2Router;
        uint256 outBefore = IERC20(plan.repayToken).balanceOf(address(this));

        IERC20(plan.srcToken).forceApprove(router, amountIn);
        IUniV2Router(router)
            .swapExactTokensForTokens(amountIn, plan.minAmountOut, plan.v2Path, address(this), plan.deadline);
        IERC20(plan.srcToken).forceApprove(router, 0);

        uint256 received = IERC20(plan.repayToken).balanceOf(address(this)) - outBefore;
        if (received < plan.minAmountOut) revert InsufficientRepayOutput(received, plan.minAmountOut);

        emit UniV2SwapExecuted(plan.srcToken, plan.repayToken, amountIn, received);
    }

    // ─── Internal: Uniswap V3 single-hop swap ────────────────────────
    /// @dev Executes `exactInputSingle` on the immutable V3 SwapRouter02.
    /// Fee tier is restricted to the four canonical pools. A non-existent
    /// pool reverts inside the router — no pre-call factory lookup needed.
    function _executeUniV3(SwapPlan memory plan, uint256 collateralDelta) internal {
        if (plan.srcToken == address(0)) revert ZeroAddress();
        if (plan.repayToken == address(0)) revert ZeroAddress();

        uint24 fee = plan.v3Fee;
        if (fee != 100 && fee != 500 && fee != 3000 && fee != 10000) revert InvalidV3Fee(fee);
        if (plan.minAmountOut == 0) revert InvalidPlan();

        uint256 amountIn = plan.useFullBalance ? collateralDelta : plan.amountIn;
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(plan.srcToken).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        address router = uniV3Router;
        uint256 outBefore = IERC20(plan.repayToken).balanceOf(address(this));

        IERC20(plan.srcToken).forceApprove(router, amountIn);
        IUniV3SwapRouter(router)
            .exactInputSingle(
                IUniV3SwapRouter.ExactInputSingleParams({
                    tokenIn: plan.srcToken,
                    tokenOut: plan.repayToken,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: plan.minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(plan.srcToken).forceApprove(router, 0);

        uint256 received = IERC20(plan.repayToken).balanceOf(address(this)) - outBefore;
        if (received < plan.minAmountOut) revert InsufficientRepayOutput(received, plan.minAmountOut);

        emit UniV3SwapExecuted(plan.srcToken, plan.repayToken, fee, amountIn, received);
    }

    // ─── Internal: V4 plan validation (centralized fail-closed checks) ─
    /// @dev Single source of truth for V4 preconditions. Called from both
    /// `execute()` (fail-fast before flashloan) and `_executeUniV4` (defensive
    /// re-check inside the pipeline). Returns the decoded PoolKey fields so
    /// the caller can reuse them without re-decoding.
    ///
    /// PRODUCTION SCOPE — the V4 path is intentionally narrow:
    ///   * single-hop only (one `swap()` call per execute())
    ///   * exact-input only (amountSpecified negative, see unlockCallback)
    ///   * ERC20 → ERC20 only (native ETH / Currency(0) is rejected)
    ///   * tokenOut MUST equal plan.repayToken (no intermediate swaps)
    ///   * hook MUST be address(0) or in `allowedV4Hooks`
    /// Any widening of this scope requires new tests and a fresh review.
    function _validateV4Plan(SwapPlan memory plan)
        internal
        view
        returns (address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hook)
    {
        if (plan.srcToken == address(0)) revert ZeroAddress();
        if (plan.repayToken == address(0)) revert ZeroAddress();
        if (plan.minAmountOut == 0) revert InvalidPlan();

        address pm = plan.v4PoolManager;
        if (pm == address(0)) revert ZeroAddress();
        if (!allowedTargets[pm]) revert TargetNotAllowed(pm);
        if (plan.v4SwapData.length != V4_SWAP_DATA_LENGTH) revert InvalidV4Data();

        (tokenIn, tokenOut, fee, tickSpacing, hook) =
            abi.decode(plan.v4SwapData, (address, address, uint24, int24, address));

        // ERC20 → ERC20 only. V4 Currency(0) is native ETH; explicitly blocked
        // because the executor's accounting assumes `IERC20.balanceOf` deltas.
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidV4NativeToken();

        if (tokenIn != plan.srcToken) revert InvalidV4Data();
        // Distinct error for the single most common operator misconfiguration
        // (routing to profit token instead of repay token).
        if (tokenOut != plan.repayToken) revert InvalidV4TokenOut(plan.repayToken, tokenOut);
        if (tokenIn == tokenOut) revert InvalidV4Data();

        // Reject clearly-broken PoolKey params. Canonical V4 pools require
        // positive tickSpacing and a non-zero fee.
        if (fee == 0 || tickSpacing <= 0) revert InvalidV4FeeOrSpacing();
        // Explicitly reject dynamic-fee pools (V4 sets the high bit of `fee`
        // for dynamic-fee pools — out of scope for this executor).
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
    /// via `_validateV4Plan`; this function re-decodes inline to keep the
    /// runtime size down.
    function _executeUniV4(SwapPlan memory plan, uint256 collateralDelta) internal {
        (address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hook) =
            abi.decode(plan.v4SwapData, (address, address, uint24, int24, address));

        uint256 amountIn = plan.useFullBalance ? collateralDelta : plan.amountIn;
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 srcBal = IERC20(tokenIn).balanceOf(address(this));
        if (srcBal < amountIn) revert InsufficientSrcBalance(amountIn, srcBal);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        address pm = plan.v4PoolManager;
        _activeV4PoolManager = pm;
        IPoolManager(pm).unlock(abi.encode(tokenIn, tokenOut, fee, tickSpacing, hook, amountIn));
        _activeV4PoolManager = address(0);

        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (received < plan.minAmountOut) revert InsufficientRepayOutput(received, plan.minAmountOut);

        emit UniV4SwapExecuted(tokenIn, tokenOut, fee, amountIn, received);
    }

    /// @inheritdoc IUnlockCallback
    /// @notice PRODUCTION SCOPE — this callback implements exactly ONE shape:
    ///   exact-input single-hop ERC20→ERC20 swap inside the flashloan pipeline.
    /// @dev Three layers of protection against stray or adversarial calls:
    ///   1. `ExecutionPhase.FlashLoanActive` — only valid inside execute()
    ///   2. `_activeV4PoolManager != 0`     — only while `_executeUniV4` is mid-unlock
    ///   3. `msg.sender == _activeV4PoolManager` — only the pinned PoolManager
    /// BalanceDelta invariant: tokenInDelta < 0 (we owe) AND tokenOutDelta > 0
    /// (we receive). Any other shape — including zero-output swaps, partial
    /// settlement, or positive input — fails closed. Widening the callback
    /// (multi-hop, native ETH, exact-output, hook-specific deltas) requires
    /// new tests and security review.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (_executionPhase != ExecutionPhase.FlashLoanActive) revert InvalidExecutionPhase();
        address pm = _activeV4PoolManager;
        // pm == 0 covered by the strict caller check below (msg.sender can never be 0).
        if (msg.sender != pm) revert InvalidCallbackCaller();

        (address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hook, uint256 amountIn) =
            abi.decode(data, (address, address, uint24, int24, address, uint256));

        // Defense-in-depth against a malicious/misconfigured PoolManager
        // echoing modified data back to us: re-assert the hook whitelist
        // against owner-curated state. tokenIn/tokenOut are NOT re-asserted
        // here because `plan` is out of scope and adding storage is out of
        // scope for this patch — tokenOut substitution is caught by the
        // post-unlock `received` delta (computed against plan.repayToken) and
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

        int256 swapDelta = IPoolManager(pm).swap(key, params, "");
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

        IPoolManager(pm).sync(tokenIn);
        IERC20(tokenIn).safeTransfer(pm, owedIn);
        IPoolManager(pm).settle();

        IPoolManager(pm).take(tokenOut, address(this), gainedOut);

        return "";
    }

    // ─── Internal: Paraswap selector classification + decoders ───────

    /// @dev Maps a 4-byte selector to its ParaswapSelectorKind. Pure / no storage.
    /// Every Augustus V6.2 swap entrypoint has an explicit branch — accepted
    /// selectors return their decoder-bound kind; documented-reject selectors
    /// (BalancerV2 direct, RFQ) return their dedicated reject kind so the caller
    /// can revert with `InvalidParaswapSelector(selector)`. Unknown selectors
    /// return `Unsupported`, which also reverts.
    // ─── Internal: Decode + validate Paraswap calldata ───────────────
    /// @dev Thin wrapper around `ParaswapDecoderLib.decodeAndValidate`. All
    /// bulk decoding + classification lives in the library (DELEGATECALL)
    /// to keep this contract under EIP-170. Returns `isExactIn` so the
    /// orchestrator can pick strict vs lenient amount-in validation.
    function _decodeAndValidateParaswap(bytes memory cd)
        internal
        view
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, bool isExactIn)
    {
        (srcToken, dstToken, fromAmount, minAmountOut, isExactIn) =
            ParaswapDecoderLib.decodeAndValidate(cd, address(this));
    }

    // ─── Internal: Execute Single Paraswap Call ──────────────────────
    /// @dev Executes a single Paraswap swap. Validation lives in
    /// `_decodeAndValidateParaswap`; this orchestrator only handles approvals,
    /// the call itself, and post-execution accounting. Belt-and-suspenders:
    /// even though Augustus enforces `minAmountOut` internally, we re-check
    /// `amountOut >= minAmountOut` so a future adapter that skips the check
    /// cannot silently let a bad swap through.
    function _executeParaswapCall(bytes memory cd)
        internal
        returns (address srcToken, address dstToken, uint256 amountIn, uint256 amountOut, bool isExactIn)
    {
        uint256 minAmountOut;
        (srcToken, dstToken, amountIn, minAmountOut, isExactIn) = _decodeAndValidateParaswap(cd);

        address augustus = paraswapAugustusV6;
        if (augustus == address(0)) revert ZeroAddress();
        if (!allowedTargets[augustus]) revert TargetNotAllowed(augustus);

        uint256 srcBefore = IERC20(srcToken).balanceOf(address(this));
        if (srcBefore < amountIn) revert InsufficientSrcBalance(amountIn, srcBefore);
        uint256 dstBefore = IERC20(dstToken).balanceOf(address(this));

        IERC20(srcToken).forceApprove(augustus, amountIn);
        (bool ok,) = augustus.call(cd);
        IERC20(srcToken).forceApprove(augustus, 0);

        if (!ok) revert ParaswapSwapFailed();

        // Compute actual consumed input (handles ExactOut where actual < declared max).
        {
            uint256 srcAfter = IERC20(srcToken).balanceOf(address(this));
            amountIn = srcBefore > srcAfter ? srcBefore - srcAfter : 0;
        }
        {
            uint256 dstAfter = IERC20(dstToken).balanceOf(address(this));
            amountOut = dstAfter - dstBefore;
        }
        if (amountOut == 0) revert ZeroSwapOutput();
        if (amountOut < minAmountOut) revert InsufficientRepayOutput(amountOut, minAmountOut);
    }

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
