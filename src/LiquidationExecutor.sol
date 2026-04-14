// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool, IFlashLoanSimpleReceiver} from "./interfaces/IAaveV3Pool.sol";
import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancerVault.sol";
import {IAaveV2LendingPool} from "./interfaces/IAaveV2LendingPool.sol";
import {IMorphoBlue, IMorphoFlashLoanCallback, MarketParams} from "./interfaces/IMorphoBlue.sol";

interface IWETH {
    function withdraw(uint256 amount) external;
}

/// @title LiquidationExecutor
/// @notice Flashloan + multi-swap + liquidation executor.
/// @dev Fail-closed. No upgradeability. External calls restricted to allowedTargets allowlist.
/// Supports Paraswap single/double swaps and Bebop multi-output swaps.
contract LiquidationExecutor is
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    IFlashLoanSimpleReceiver,
    IFlashLoanRecipient,
    IMorphoFlashLoanCallback
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
    error ChainedInputExceedsOutput(uint256 amountIn2, uint256 amountOut1);
    error InvalidCoinbase();
    error MorphoMixedModeUnsupported();

    // Swap errors
    error InvalidSwapMode();
    error InvalidDoubleSwapPattern();
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

    // Double swap errors
    error SplitSrcTokenMismatch(address src1, address src2);
    error SplitDstTokensMustDiffer(address dst);
    error SplitNoRepayLeg();
    error SplitRepayLegInsufficient(uint256 actual, uint256 required);
    error SplitDstTokenUnexpected(address dst1, address dst2);
    error ChainLinkMismatch(address dst1, address src2);
    error ChainDstNotRepay(address dst2, address repayToken);
    error ChainedProfitMustMatchRepay();
    error Leg1SrcNotCollateral(address src1, address collateral);

    // Profit / payment errors
    error InsufficientProfit(uint256 actual, uint256 required);
    error CoinbasePaymentRequiresWethProfit();
    error InsufficientRepayBalance(uint256 required, uint256 available);
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error TargetNotAllowed(address target);

    // ─── Constants ───────────────────────────────────────────────────
    uint8 public constant FLASH_PROVIDER_AAVE_V3 = 1;
    uint8 public constant FLASH_PROVIDER_BALANCER = 2;
    uint8 public constant FLASH_PROVIDER_MORPHO = 3;

    uint8 public constant PROTOCOL_AAVE_V3 = 1;
    uint8 public constant PROTOCOL_MORPHO_BLUE = 2;
    uint8 public constant PROTOCOL_AAVE_V2 = 3;
    uint8 public constant PROTOCOL_INTERNAL = 100;

    uint8 public constant ACTION_PAY_COINBASE = 1;

    /// @dev Paraswap Augustus V6 supported selectors.
    ///
    /// Generic family (GenericData layout — first arg is `address executor`, second arg
    /// is the GenericData struct holding src/dst/amounts/beneficiary).
    bytes4 private constant _SWAP_EXACT_AMOUNT_IN = bytes4(
        keccak256(
            "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    );
    bytes4 private constant _SWAP_EXACT_AMOUNT_OUT = bytes4(
        keccak256(
            "swapExactAmountOut(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    );

    /// Optimized family (UniswapV3-style struct as the first arg — no executor address,
    /// recipient/beneficiary lives at slot 6 of the struct). Layout:
    ///   selector(4) + srcToken(32) + destToken(32) + fromAmount(32) + toAmount(32)
    ///   + quotedAmount(32) + metadata(32) + recipient(32) + pool(32) + partnerAndFee(32)
    ///   + offset_to_permit(32) + permit_len(32) + permit_data
    /// Both ExactIn and ExactOut use the same fixed-head shape.
    bytes4 private constant _SWAP_EXACT_IN_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,uint256),uint256,bytes)"
        )
    );
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,uint256),uint256,bytes)"
        )
    );

    /// @dev Categorises a 4-byte Paraswap selector. Used everywhere we need to know
    /// which decoder + amount-direction semantics apply. Unknown selectors map to
    /// `Unsupported` and the caller MUST revert — never silently fall through.
    enum ParaswapSelectorKind {
        ExactInGeneric,
        ExactOutGeneric,
        ExactInOptimized,
        ExactOutOptimized,
        Unsupported
    }

    // ─── State ───────────────────────────────────────────────────────
    address public immutable operator;
    address public immutable weth;
    address public aavePool;
    address public morphoBlue;
    address public balancerVault;
    address public paraswapAugustusV6;
    address public aaveV2LendingPool;

    mapping(uint8 => address) public allowedFlashProviders;
    mapping(address => bool) public allowedTargets;

    bytes32 private _activePlanHash;

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
    event DoubleSwapExecuted(
        DoubleSwapPattern indexed pattern,
        address srcToken1,
        address dstToken1,
        uint256 amountIn1,
        uint256 amountOut1,
        address srcToken2,
        address dstToken2,
        uint256 amountIn2,
        uint256 amountOut2
    );
    event ChainedRemainder(address indexed token, uint256 amount);

    // ─── Enums ────────────────────────────────────────────────────────
    enum SwapMode {
        PARASWAP_SINGLE,
        BEBOP_MULTI,
        PARASWAP_DOUBLE
    }

    enum DoubleSwapPattern {
        SPLIT,
        CHAINED
    }

    // ─── Plan Structs ─────────────────────────────────────────────────
    struct SwapPlan {
        SwapMode mode;
        // PARASWAP_SINGLE and BEBOP_MULTI only (ignored by PARASWAP_DOUBLE):
        address srcToken;
        uint256 amountIn;
        // All modes:
        uint256 deadline;
        // PARASWAP_SINGLE: single swap calldata. PARASWAP_DOUBLE: swap 1 calldata.
        bytes paraswapCalldata;
        // BEBOP_MULTI only:
        address bebopTarget;
        bytes bebopCalldata;
        // PARASWAP_DOUBLE only:
        DoubleSwapPattern doubleSwapPattern;
        bytes paraswapCalldata2;
        // Output validation:
        address repayToken;
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
        address[] memory allowedTargets_
    ) Ownable(owner_) {
        if (operator_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (paraswapAugustus_ == address(0)) revert ZeroAddress();

        operator = operator_;
        weth = weth_;
        aavePool = aavePool_;
        balancerVault = balancerVault_;
        paraswapAugustusV6 = paraswapAugustus_;

        allowedFlashProviders[FLASH_PROVIDER_AAVE_V3] = aavePool_;
        allowedFlashProviders[FLASH_PROVIDER_BALANCER] = balancerVault_;

        allowedTargets[aavePool_] = true;
        allowedTargets[balancerVault_] = true;
        allowedTargets[paraswapAugustus_] = true;

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

        // Collateral linkage for SINGLE/BEBOP (DOUBLE validated after calldata extraction)
        if (plan.swapPlan.mode != SwapMode.PARASWAP_DOUBLE) {
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
        } else if (plan.swapPlan.mode == SwapMode.PARASWAP_DOUBLE) {
            if (plan.swapPlan.paraswapCalldata.length < 4) revert InvalidParaswapCalldata();
            if (plan.swapPlan.paraswapCalldata2.length < 4) revert InvalidParaswapCalldata();
        } else {
            revert InvalidSwapMode();
        }

        address provider = allowedFlashProviders[plan.flashProviderId];
        if (provider == address(0)) revert FlashProviderNotAllowed();

        _activePlanHash = keccak256(planData);
        _executionPhase = ExecutionPhase.FlashLoanActive;

        if (plan.flashProviderId == FLASH_PROVIDER_AAVE_V3) {
            IAaveV3Pool(provider).flashLoanSimple(address(this), plan.loanToken, plan.loanAmount, planData, 0);
        } else if (plan.flashProviderId == FLASH_PROVIDER_BALANCER) {
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

    // ─── Aave V3 Flashloan Callback ─────────────────────────────────
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        override
        returns (bool)
    {
        if (_executionPhase != ExecutionPhase.FlashLoanActive) revert InvalidExecutionPhase();
        if (msg.sender != allowedFlashProviders[FLASH_PROVIDER_AAVE_V3]) revert InvalidCallbackCaller();
        if (initiator != address(this)) revert InvalidInitiator();
        if (keccak256(params) != _activePlanHash) revert InvalidPlan();

        Plan memory plan = abi.decode(params, (Plan));

        // P0 safety: strict asset/amount match
        if (asset != plan.loanToken) revert CallbackAssetMismatch();
        if (amount != plan.loanAmount) revert CallbackAmountMismatch();
        if (premium > plan.maxFlashFee) revert FlashFeeExceeded(premium, plan.maxFlashFee);

        uint256 flashRepayAmount = amount + premium;
        (uint256 profitBefore, uint256 totalCoinbasePayment, uint256 totalWethUnwrapped) =
            _runFlashloanPipeline(plan, flashRepayAmount);

        // Aave pulls repayment after we return true — approve exact amount (vault=0).
        _finalizeFlashloan(
            asset,
            amount,
            flashRepayAmount,
            address(0),
            plan.swapPlan.profitToken,
            profitBefore,
            plan.swapPlan.minProfitAmount,
            totalCoinbasePayment,
            totalWethUnwrapped
        );
        return true;
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
        (uint256 profitBefore, uint256 totalCoinbasePayment, uint256 totalWethUnwrapped) =
            _runFlashloanPipeline(plan, flashRepayAmount);

        // Balancer expects funds returned by end of callback via transfer (vault=msg.sender).
        _finalizeFlashloan(
            address(tokens[0]),
            amounts[0],
            flashRepayAmount,
            msg.sender,
            plan.swapPlan.profitToken,
            profitBefore,
            plan.swapPlan.minProfitAmount,
            totalCoinbasePayment,
            totalWethUnwrapped
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
        (uint256 profitBefore, uint256 totalCoinbasePayment, uint256 totalWethUnwrapped) =
            _runFlashloanPipeline(plan, flashRepayAmount);

        // Morpho also pulls via safeTransferFrom after callback returns (vault=0).
        _finalizeFlashloan(
            plan.loanToken,
            amount,
            flashRepayAmount,
            address(0),
            plan.swapPlan.profitToken,
            profitBefore,
            plan.swapPlan.minProfitAmount,
            totalCoinbasePayment,
            totalWethUnwrapped
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
        returns (uint256 profitBefore, uint256 totalCoinbasePayment, uint256 totalWethUnwrapped)
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
        profitBefore = IERC20(plan.swapPlan.profitToken).balanceOf(address(this));
        uint256 collateralBefore;
        if (trackingToken != address(0)) {
            collateralBefore = IERC20(trackingToken).balanceOf(address(this));
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

        _executeSwapPlan(plan.swapPlan, flashRepayAmount, collateralAsset);

        // Execute internal actions (coinbase payment) after swap
        for (uint256 i = 0; i < plan.actions.length; ++i) {
            if (plan.actions[i].protocolId == PROTOCOL_INTERNAL) {
                (uint256 cbPaid, uint256 wethUsed) =
                    _executeInternalAction(plan.actions[i].data, plan.swapPlan.profitToken);
                totalCoinbasePayment += cbPaid;
                totalWethUnwrapped += wethUsed;
            }
        }
    }

    // ─── Internal: Finalize Flashloan (unified) ──────────────────────
    /// @dev Single repayment + profit-check path for all three providers. Aave V3 and
    /// Morpho pull repayment via safeTransferFrom after the callback returns, so we
    /// approve the principal back to msg.sender (`vault == address(0)`). Balancer
    /// expects funds returned via safeTransfer to the vault inside the callback
    /// (`vault != address(0)`). The `repayPending` flag forwarded to `_checkProfit`
    /// reflects whether the principal still sits on this contract at check-time.
    function _finalizeFlashloan(
        address asset,
        uint256 principalAmount,
        uint256 repayAmount,
        address vault,
        address profitTkn,
        uint256 profitBefore,
        uint256 minProfitAmount,
        uint256 totalCoinbasePayment,
        uint256 totalWethUnwrapped
    ) internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayBalance(repayAmount, balance);

        bool repayPending;
        if (vault == address(0)) {
            // Aave V3 / Morpho: pool pulls after we return — approve exact amount.
            IERC20(asset).forceApprove(msg.sender, repayAmount);
            repayPending = true;
        } else {
            // Balancer: push funds back to vault inside the callback.
            IERC20(asset).safeTransfer(vault, repayAmount);
        }

        _checkProfit(
            asset,
            principalAmount,
            repayAmount,
            profitTkn,
            profitBefore,
            minProfitAmount,
            repayPending,
            totalCoinbasePayment,
            totalWethUnwrapped
        );
    }

    // ─── Internal: Check Profit ──────────────────────────────────────
    function _checkProfit(
        address asset,
        uint256 principalAmount,
        uint256 repayAmount,
        address profitTkn,
        uint256 profitBefore,
        uint256 minProfitAmount,
        bool repayPending, // true for Aave (pool pulls later), false for Balancer (already transferred)
        uint256 totalCoinbasePayment,
        uint256 totalWethUnwrapped
    ) internal view {
        uint256 profitAfter = IERC20(profitTkn).balanceOf(address(this));
        uint256 effectiveProfit;

        if (profitTkn == asset) {
            if (repayPending) {
                // Aave: profitBefore includes principal; profitAfter still includes repayAmount (pool pulls later)
                effectiveProfit = profitAfter + principalAmount > profitBefore + repayAmount
                    ? profitAfter + principalAmount - profitBefore - repayAmount
                    : 0;
            } else {
                // Balancer: repayAmount already transferred out; profitBefore included principal
                effectiveProfit =
                    profitAfter + principalAmount > profitBefore ? profitAfter + principalAmount - profitBefore : 0;
            }
        } else {
            effectiveProfit = profitAfter > profitBefore ? profitAfter - profitBefore : 0;
        }

        // Coinbase payment accounting: always deduct the cost NOT already in the ERC20 delta.
        // - WETH unwrapped: already reduced profitAfter (in delta), no additional deduction needed.
        // - Pre-existing ETH: NOT in the ERC20 delta, MUST be deducted explicitly.
        // Formula: deduct = totalCoinbasePayment - totalWethUnwrapped (the native ETH portion).
        if (totalCoinbasePayment > 0) {
            uint256 costNotInDelta =
                totalCoinbasePayment > totalWethUnwrapped ? totalCoinbasePayment - totalWethUnwrapped : 0;
            effectiveProfit = effectiveProfit > costNotInDelta ? effectiveProfit - costNotInDelta : 0;
        }

        if (effectiveProfit < minProfitAmount) revert InsufficientProfit(effectiveProfit, minProfitAmount);
    }

    // ─── Internal: Execute Swap Plan ─────────────────────────────────
    /// @dev Dispatches swap by mode, validates absolute repay balance covers flash loan obligation.
    /// Uses absolute balance (not delta) because partial liquidations may leave residual loanToken
    /// that legitimately contributes to repayment.
    function _executeSwapPlan(SwapPlan memory plan, uint256 flashRepayAmount, address collateralAsset) internal {
        if (block.timestamp > plan.deadline) revert SwapDeadlineExpired(plan.deadline, block.timestamp);

        uint256 repayBefore = IERC20(plan.repayToken).balanceOf(address(this));

        if (plan.mode == SwapMode.PARASWAP_SINGLE) {
            _executeParaswapSingle(plan);
        } else if (plan.mode == SwapMode.BEBOP_MULTI) {
            _executeBebopMulti(plan, repayBefore);
        } else if (plan.mode == SwapMode.PARASWAP_DOUBLE) {
            _executeParaswapDouble(plan, flashRepayAmount, collateralAsset);
        } else {
            revert InvalidSwapMode();
        }

        // Absolute balance check: total repayToken must cover flash loan obligation
        uint256 repayBalance = IERC20(plan.repayToken).balanceOf(address(this));
        if (repayBalance < flashRepayAmount) revert InsufficientRepayOutput(repayBalance, flashRepayAmount);
    }

    // ─── Internal: Paraswap Single ───────────────────────────────────
    function _executeParaswapSingle(SwapPlan memory plan) internal {
        if (plan.srcToken == address(0)) revert ZeroAddress();
        if (plan.amountIn == 0) revert InvalidPlan();

        (address srcToken, address dstToken, uint256 amountIn, uint256 amountOut) =
            _executeParaswapCall(plan.paraswapCalldata);

        if (srcToken != plan.srcToken) revert ParaswapSrcTokenMismatch(plan.srcToken, srcToken);

        // For ExactIn (generic OR optimized): actual consumed must equal declared.
        // For ExactOut (generic OR optimized): actual consumed must be <= declared max.
        bytes4 selector;
        bytes memory cd = plan.paraswapCalldata;
        assembly {
            selector := mload(add(cd, 32))
        }
        ParaswapSelectorKind kind = _classifyParaswapSelector(selector);
        if (kind == ParaswapSelectorKind.ExactInGeneric || kind == ParaswapSelectorKind.ExactInOptimized) {
            if (amountIn != plan.amountIn) revert ParaswapAmountInMismatch(plan.amountIn, amountIn);
        } else {
            // ExactOut: plan.amountIn is the declared maximum.
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
        if (plan.amountIn == 0) revert InvalidPlan();
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
        uint256 profitDelta;
        if (plan.repayToken == plan.profitToken) {
            profitDelta = repayDelta;
        } else {
            uint256 profitAfter = IERC20(plan.profitToken).balanceOf(address(this));
            profitDelta = profitAfter > profitSnapBefore ? profitAfter - profitSnapBefore : 0;
        }

        emit BebopSwapExecuted(target, plan.srcToken, plan.amountIn, repayDelta, profitDelta);
    }

    // ─── Internal: Paraswap Double ───────────────────────────────────
    /// @dev PARASWAP_DOUBLE supports two routing patterns:
    ///
    /// Split pattern (same srcToken, different dstTokens):
    ///   collateral ──┬── swap1 ──→ repayToken
    ///                └── swap2 ──→ profitToken
    ///
    /// Chained pattern (swap1 output feeds swap2 input):
    ///   collateral ── swap1 ──→ intermediate ── swap2 ──→ repayToken
    ///
    /// Each leg is self-contained: srcToken and amountIn extracted from calldata.
    function _executeParaswapDouble(
        SwapPlan memory plan,
        uint256,
        /* flashRepayAmount */
        address collateralAsset
    )
        internal
    {
        // Execute leg 1
        (address src1, address dst1, uint256 amountIn1, uint256 amountOut1) =
            _executeParaswapCall(plan.paraswapCalldata);

        // For CHAINED: validate leg 2 input <= leg 1 output BEFORE executing leg 2
        if (plan.doubleSwapPattern == DoubleSwapPattern.CHAINED) {
            bytes memory cd2 = plan.paraswapCalldata2;
            // Ensure calldata is long enough for assembly read at offset 132 (36+96)
            if (cd2.length < 132) revert InvalidParaswapCalldata();
            uint256 leg2FromAmount;
            assembly {
                leg2FromAmount := mload(add(add(cd2, 36), 96)) // same offset as _executeParaswapCall
            }
            if (leg2FromAmount > amountOut1) revert ChainedInputExceedsOutput(leg2FromAmount, amountOut1);
        }

        // Execute leg 2
        (address src2, address dst2, uint256 amountIn2, uint256 amountOut2) =
            _executeParaswapCall(plan.paraswapCalldata2);

        // Collateral linkage: leg 1 must consume liquidation collateral
        if (collateralAsset != address(0)) {
            if (src1 != collateralAsset) revert Leg1SrcNotCollateral(src1, collateralAsset);
        }

        if (plan.doubleSwapPattern == DoubleSwapPattern.SPLIT) {
            if (src1 != src2) revert SplitSrcTokenMismatch(src1, src2);
            if (dst1 == dst2) revert SplitDstTokensMustDiffer(dst1);

            // Validate repay/profit leg routing — repay sufficiency checked by _executeSwapPlan
            // via absolute balance (not per-leg delta) to support pre-existing repayToken balance.
            if (dst1 == plan.repayToken) {
                if (dst2 != plan.profitToken) revert SplitDstTokenUnexpected(dst1, dst2);
            } else if (dst2 == plan.repayToken) {
                if (dst1 != plan.profitToken) revert SplitDstTokenUnexpected(dst1, dst2);
            } else {
                revert SplitNoRepayLeg();
            }
        } else if (plan.doubleSwapPattern == DoubleSwapPattern.CHAINED) {
            if (dst1 != src2) revert ChainLinkMismatch(dst1, src2);
            if (dst2 != plan.repayToken) revert ChainDstNotRepay(dst2, plan.repayToken);
            if (plan.profitToken != plan.repayToken) revert ChainedProfitMustMatchRepay();

            // Signal any leftover intermediate tokens for off-chain observability
            uint256 intermediateBalance = IERC20(dst1).balanceOf(address(this));
            if (intermediateBalance > 0) {
                emit ChainedRemainder(dst1, intermediateBalance);
            }
        } else {
            revert InvalidDoubleSwapPattern();
        }

        emit DoubleSwapExecuted(
            plan.doubleSwapPattern, src1, dst1, amountIn1, amountOut1, src2, dst2, amountIn2, amountOut2
        );
    }

    // ─── Internal: Paraswap selector classification + decoders ───────

    /// @dev Maps a 4-byte selector to its ParaswapSelectorKind. Pure / no storage.
    /// Explicit whitelist — every supported variant has a dedicated branch; every
    /// other selector returns `Unsupported` so the caller must revert. Keeping this
    /// `pure` and tight lets it be safely inlined into the hot path.
    function _classifyParaswapSelector(bytes4 selector) internal pure returns (ParaswapSelectorKind) {
        if (selector == _SWAP_EXACT_AMOUNT_IN) return ParaswapSelectorKind.ExactInGeneric;
        if (selector == _SWAP_EXACT_AMOUNT_OUT) return ParaswapSelectorKind.ExactOutGeneric;
        if (selector == _SWAP_EXACT_IN_UNI_V3) return ParaswapSelectorKind.ExactInOptimized;
        if (selector == _SWAP_EXACT_OUT_UNI_V3) return ParaswapSelectorKind.ExactOutOptimized;
        return ParaswapSelectorKind.Unsupported;
    }

    /// @dev Decode the GenericData layout used by the generic Paraswap V6 selectors
    /// (`swapExactAmountIn` / `swapExactAmountOut`). Argument layout after selector:
    ///   args[0..32]   = address executor
    ///   args[32..64]  = GenericData.srcToken
    ///   args[64..96]  = GenericData.destToken
    ///   args[96..128] = GenericData.fromAmount
    ///   args[128..160]= GenericData.toAmount     ← minAmountOut for ExactIn
    ///   args[160..192]= GenericData.quotedAmount
    ///   args[192..224]= GenericData.metadata
    ///   args[224..256]= GenericData.beneficiary
    /// `cd` includes the 32-byte length prefix in memory, so absolute offsets add 36
    /// (32 length + 4 selector) before the args block.
    function _decodeParaswapGeneric(bytes memory cd)
        internal
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        if (cd.length < 260) {
            revert InvalidParaswapCalldata();
        }
        assembly {
            let p := add(cd, 36) // skip length prefix (32) + selector (4)
            srcToken := and(mload(add(p, 32)), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(p, 64)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(p, 96))
            minAmountOut := mload(add(p, 128))
            beneficiary := and(mload(add(p, 224)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev Decode the optimized layout used by `swapExactAmountInOnUniswapV3` /
    /// `swapExactAmountOutOnUniswapV3`. Argument layout after selector:
    ///   args[0..32]   = data.srcToken
    ///   args[32..64]  = data.destToken
    ///   args[64..96]  = data.fromAmount
    ///   args[96..128] = data.toAmount     ← minAmountOut for ExactIn / max for ExactOut
    ///   args[128..160]= data.quotedAmount
    ///   args[160..192]= data.metadata
    ///   args[192..224]= data.recipient   ← beneficiary
    ///   args[224..256]= data.pool
    /// Min head length: 4 (selector) + 8*32 (struct) + 32 (partnerAndFee)
    ///                + 32 (permit offset) + 32 (permit length) = 356.
    /// Reverts on shorter calldata so a malformed payload cannot under-read.
    function _decodeParaswapOptimized(bytes memory cd)
        internal
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        if (cd.length < 356) {
            revert InvalidParaswapCalldata();
        }
        assembly {
            let p := add(cd, 36)
            srcToken := and(mload(p), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(p, 32)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(p, 64))
            minAmountOut := mload(add(p, 96))
            beneficiary := and(mload(add(p, 192)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    // ─── Internal: Decode + validate Paraswap calldata ───────────────
    /// @dev Single entry that classifies the selector, routes to the correct decoder,
    /// and applies the universal validation rules. Returning the decoded tuple lets
    /// the orchestrator stay below Solidity's 16-slot stack limit. Reverts on:
    ///   - calldata too short to even read the selector
    ///   - selector not in the explicit whitelist (`InvalidParaswapSelector`)
    ///   - beneficiary not in {address(this), address(0)}
    ///   - srcToken / dstToken == address(0)
    function _decodeAndValidateParaswap(bytes memory cd)
        internal
        view
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut)
    {
        if (cd.length < 4) revert InvalidParaswapCalldata();
        bytes4 selector;
        assembly {
            selector := mload(add(cd, 32))
        }
        ParaswapSelectorKind kind = _classifyParaswapSelector(selector);
        if (kind == ParaswapSelectorKind.Unsupported) {
            revert InvalidParaswapSelector(selector);
        }

        address beneficiary;
        if (kind == ParaswapSelectorKind.ExactInGeneric || kind == ParaswapSelectorKind.ExactOutGeneric) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeParaswapGeneric(cd);
        } else {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeParaswapOptimized(cd);
        }

        // Paraswap V6 sometimes omits the beneficiary write when it equals the
        // caller, so the slot reads back as address(0). Treat as equivalent to
        // address(this); reject anything else.
        if (beneficiary != address(this) && beneficiary != address(0)) {
            revert SwapRecipientInvalid(beneficiary);
        }
        if (srcToken == address(0)) revert ZeroAddress();
        if (dstToken == address(0)) revert ZeroAddress();
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
        returns (address srcToken, address dstToken, uint256 amountIn, uint256 amountOut)
    {
        uint256 minAmountOut;
        (srcToken, dstToken, amountIn, minAmountOut) = _decodeAndValidateParaswap(cd);

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
    /// @dev Centralized dispatch for PROTOCOL_INTERNAL actions.
    /// Only supports ACTION_PAY_COINBASE. Returns coinbase payment accounting.
    function _executeInternalAction(bytes memory actionData, address profitToken)
        internal
        returns (uint256 coinbasePaid, uint256 wethUnwrapped)
    {
        uint8 actionType = abi.decode(actionData, (uint8));

        if (actionType == ACTION_PAY_COINBASE) {
            // Coinbase payment is ETH-denominated — only valid when profit is in WETH
            if (profitToken != weth) revert CoinbasePaymentRequiresWethProfit();

            (, uint256 amount) = abi.decode(actionData, (uint8, uint256));
            wethUnwrapped = _payCoinbase(amount);
            coinbasePaid = amount;
        } else {
            revert InvalidAction(actionType);
        }
    }

    /// @dev Send ETH to block.coinbase. Only reachable when profitToken == weth (enforced by caller).
    /// Auto-unwraps WETH if insufficient ETH. Returns the amount unwrapped (for profit accounting).
    function _payCoinbase(uint256 amount) internal returns (uint256 wethUnwrapped) {
        if (amount == 0) return 0;
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
                    wethUnwrapped = toUnwrap;
                }
            }
        }

        if (address(this).balance < amount) revert InsufficientEth(amount, address(this).balance);

        (bool success,) = block.coinbase.call{value: amount}("");
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
