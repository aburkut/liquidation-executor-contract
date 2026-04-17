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
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";

interface IWETH {
    function withdraw(uint256 amount) external;
}

/// @title LiquidationExecutor
/// @notice Flashloan + multi-swap + liquidation executor.
/// @dev Fail-closed. No upgradeability. External calls restricted to allowedTargets allowlist.
/// Supports Paraswap single/double swaps and Bebop multi-output swaps.
contract LiquidationExecutor is Ownable2Step, Pausable, ReentrancyGuard, IFlashLoanRecipient, IMorphoFlashLoanCallback {
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

    // Universal Router errors
    error UniversalRouterNotSet();
    error ZeroSwapInput();
    error UniversalRouterSwapFailed();

    // Profit / payment errors
    error InsufficientProfit(uint256 actual, uint256 required);
    error CoinbasePaymentRequiresWethProfit();
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

    /// Direct router families — selectors and struct layouts derived from the
    /// deployed Augustus V6.2 source (Sourcify metadata for
    /// 0x6A000F20005980200259B80c5102003040001068, see AugustusV6Types.sol).
    /// Each `swapExactAmountInOn{Family}` / `swapExactAmountOutOn{Family}`
    /// entrypoint takes the family-specific data struct as its first arg
    /// (no executor head word). Two distinct calldata shapes:
    ///
    ///   Inline (struct has only static fields → inlines into the head):
    ///     selector(4) + struct fields packed at fixed positions
    ///     + partnerAndFee(32) + offset_to_permit(32) + permit_len(32)
    ///     + permit_data + (optional) data tail.
    ///     CurveV1 (9 fields), CurveV2 (11 fields), Generic (7 fields), and
    ///     BalancerV2 (5 fields) all use this shape.
    ///
    ///   Tail (struct has at least one dynamic field — `bytes pools` — so the
    ///   head holds an offset and the struct lives in the tail):
    ///     selector(4) + offset_to_struct(32) + partnerAndFee(32)
    ///     + offset_to_permit(32) + (struct at offset, 8 head words: 7 fixed
    ///     + offset_to_pools) + pools data + permit data.
    ///     UniswapV2 and UniswapV3 use this shape (both share `(srcToken,
    ///     destToken, fromAmount, toAmount, quotedAmount, metadata, beneficiary,
    ///     bytes pools)`).
    ///
    /// V6.2 has no MakerPSM entrypoint and no CurveV1/V2 ExactOut — those are
    /// not in the contract ABI.
    bytes4 private constant _SWAP_EXACT_IN_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0x876a02f6
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V3 = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0x5e94e28d
    bytes4 private constant _SWAP_EXACT_IN_UNI_V2 = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0xe8bb3b6c
    bytes4 private constant _SWAP_EXACT_OUT_UNI_V2 = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0xa76f4eb6
    /// BalancerV2 direct: explicitly rejected. The on-chain BalancerV2Data
    /// struct carries no srcToken/destToken — they're encoded into the opaque
    /// `bytes data` Balancer-batch blob — so we cannot cross-check calldata
    /// tokens against `plan.srcToken` / `plan.repayToken` without a full
    /// Balancer-batch parser. Paraswap API falls back to the Generic family
    /// for Balancer routes when direct isn't available, so rejection only
    /// narrows our route set slightly while keeping the validator provable.
    bytes4 private constant _SWAP_EXACT_IN_BALANCER_V2 = bytes4(
        keccak256("swapExactAmountInOnBalancerV2((uint256,uint256,uint256,bytes32,uint256),uint256,bytes,bytes)")
    ); // 0xd85ca173
    bytes4 private constant _SWAP_EXACT_OUT_BALANCER_V2 = bytes4(
        keccak256("swapExactAmountOutOnBalancerV2((uint256,uint256,uint256,bytes32,uint256),uint256,bytes,bytes)")
    ); // 0xd6ed22e6
    bytes4 private constant _SWAP_EXACT_IN_CURVE_V1 = bytes4(
        keccak256(
            "swapExactAmountInOnCurveV1((uint256,uint256,address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes)"
        )
    ); // 0x1a01c532
    bytes4 private constant _SWAP_EXACT_IN_CURVE_V2 = bytes4(
        keccak256(
            "swapExactAmountInOnCurveV2((uint256,uint256,uint256,address,address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes)"
        )
    ); // 0xe37ed256
    /// AugustusRFQ batch fill — explicitly rejected. RFQ flows route through the
    /// off-chain order matcher; we never want to execute one accidentally.
    bytes4 private constant _SWAP_RFQ_BATCH_FILL = bytes4(
        keccak256(
            "swapOnAugustusRFQTryBatchFill((uint256,uint256,uint8,bytes32,address),((uint256,uint128,address,address,address,address,uint256,uint256),bytes,uint256,bytes,bytes)[],bytes)"
        )
    ); // 0xda35bb0d

    /// @dev Categorises a 4-byte Paraswap selector. Maps every Augustus V6.2 swap
    /// entrypoint (10 non-RFQ + 1 RFQ) to a deterministic outcome — either a
    /// supported family (decoder + amount-direction semantics) or an explicit
    /// rejection reason. Unknown selectors fall through to `Unsupported`.
    /// Every variant in this enum either drives a decoder branch in
    /// `_decodeAndValidateParaswap` or maps to a `revert InvalidParaswapSelector`
    /// branch — there is no silent path.
    enum ParaswapSelectorKind {
        // Accepted families (12 entrypoints across 7 decoder shapes).
        ExactInGeneric, // 0xe3ead59e
        ExactOutGeneric, // 0x7f457675
        UniswapV2ExactIn, // 0xe8bb3b6c
        UniswapV2ExactOut, // 0xa76f4eb6
        UniswapV3ExactIn, // 0x876a02f6
        UniswapV3ExactOut, // 0x5e94e28d
        CurveV1ExactIn, // 0x1a01c532
        CurveV2ExactIn, // 0xe37ed256
        BalancerV2ExactIn, // 0xd85ca173
        BalancerV2ExactOut, // 0xd6ed22e6
        // Explicit-reject (documented V6.2 selectors we choose not to support).
        RFQ, // 0xda35bb0d — off-chain order matching
        // Unknown selector (always reverts).
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
    /// @dev Immutable — the executor assumes a fixed calldata layout for inputs[0].
    /// Changing router requires redeploying the contract.
    address public immutable universalRouter;

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
    event UniversalRouterSwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    // ─── Enums ────────────────────────────────────────────────────────
    enum SwapMode {
        PARASWAP_SINGLE,
        BEBOP_MULTI,
        UNIVERSAL_ROUTER
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
        // Universal Router fields (leg1 when mode == UNIVERSAL_ROUTER)
        bytes universalCommands;
        bytes[] universalInputs;
        uint256 minSwapOutput;
        // Optional second leg (always UR, tracked leftover from leg1)
        bool hasLeg2;
        address leg2TokenIn;
        address leg2TokenOut;
        uint256 leg2MinAmountOut;
        bytes leg2Commands;
        bytes[] leg2Inputs;
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
        address universalRouter_,
        address[] memory allowedTargets_
    ) Ownable(owner_) {
        if (operator_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (paraswapAugustus_ == address(0)) revert ZeroAddress();
        if (universalRouter_ == address(0)) revert ZeroAddress();

        operator = operator_;
        weth = weth_;
        universalRouter = universalRouter_;
        aavePool = aavePool_;
        balancerVault = balancerVault_;
        paraswapAugustusV6 = paraswapAugustus_;

        allowedFlashProviders[FLASH_PROVIDER_BALANCER] = balancerVault_;

        allowedTargets[aavePool_] = true;
        allowedTargets[balancerVault_] = true;
        allowedTargets[paraswapAugustus_] = true;
        allowedTargets[universalRouter_] = true;

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
        } else if (plan.swapPlan.mode == SwapMode.UNIVERSAL_ROUTER) {
            if (plan.swapPlan.universalCommands.length == 0) revert InvalidPlan();
            if (plan.swapPlan.universalInputs.length == 0) revert InvalidPlan();
        } else {
            revert InvalidSwapMode();
        }

        if (plan.swapPlan.hasLeg2) {
            if (plan.swapPlan.leg2Commands.length == 0) revert InvalidPlan();
            if (plan.swapPlan.leg2Inputs.length == 0) revert InvalidPlan();
            if (plan.swapPlan.leg2TokenIn == address(0)) revert ZeroAddress();
            if (plan.swapPlan.leg2TokenOut == address(0)) revert ZeroAddress();
            if (plan.swapPlan.leg2Inputs[0].length < 64) revert InvalidPlan();
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
    function _executeSwapPlan(
        SwapPlan memory plan,
        uint256 flashRepayAmount,
        address /* collateralAsset */
    )
        internal
    {
        if (block.timestamp > plan.deadline) revert SwapDeadlineExpired(plan.deadline, block.timestamp);

        uint256 repayBefore = IERC20(plan.repayToken).balanceOf(address(this));

        // Snapshot leg2 intermediate token BEFORE leg1 (for tracked leftover)
        uint256 leg2InBefore;
        if (plan.hasLeg2) {
            leg2InBefore = IERC20(plan.leg2TokenIn).balanceOf(address(this));
        }

        if (plan.mode == SwapMode.PARASWAP_SINGLE) {
            _executeParaswapSingle(plan);
        } else if (plan.mode == SwapMode.BEBOP_MULTI) {
            _executeBebopMulti(plan, repayBefore);
        } else if (plan.mode == SwapMode.UNIVERSAL_ROUTER) {
            address tokenOut = plan.hasLeg2 ? plan.leg2TokenIn : plan.repayToken;
            _executeUniversalRouterSwap(
                plan.srcToken,
                tokenOut,
                plan.amountIn,
                plan.minSwapOutput,
                plan.universalCommands,
                plan.universalInputs,
                plan.deadline
            );
        } else {
            revert InvalidSwapMode();
        }

        if (plan.hasLeg2) {
            // Tracked leftover: only the delta from leg1, not pre-existing dust
            uint256 trackedLeftover = IERC20(plan.leg2TokenIn).balanceOf(address(this)) - leg2InBefore;
            if (trackedLeftover == 0) revert ZeroSwapInput();

            // REQUIRED INPUT SHAPE: leg2Inputs[0] must have amountIn at ABI word 1
            // (byte offset 32). This matches Uniswap UR V2/V3 SWAP_EXACT_IN:
            //   abi.encode(address recipient, uint256 amountIn, uint256 minOut, bytes path, bool payer)
            // The executor overwrites word 1 with the tracked leftover so the router
            // receives the REAL on-chain amount, not the stale off-chain estimate.
            // Validation: execute() requires leg2Inputs[0].length >= 64.
            bytes memory input0 = plan.leg2Inputs[0];
            assembly {
                mstore(add(input0, 0x40), trackedLeftover)
            }

            _executeUniversalRouterSwap(
                plan.leg2TokenIn,
                plan.leg2TokenOut,
                trackedLeftover,
                plan.leg2MinAmountOut,
                plan.leg2Commands,
                plan.leg2Inputs,
                plan.deadline
            );
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
        if (_isExactIn(kind)) {
            // ExactIn (any family): consumed must equal declared.
            if (amountIn != plan.amountIn) revert ParaswapAmountInMismatch(plan.amountIn, amountIn);
        } else {
            // ExactOut (any family): plan.amountIn is the declared maximum.
            if (amountIn > plan.amountIn) revert ParaswapAmountInMismatch(plan.amountIn, amountIn);
        }

        if (plan.hasLeg2) {
            if (dstToken != plan.leg2TokenIn) revert ParaswapDstTokenUnexpected(dstToken);
        } else {
            if (dstToken != plan.repayToken) revert ParaswapDstTokenUnexpected(dstToken);
        }

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

    // ─── Internal: Universal Router Swap ─────────────────────────────
    /// @dev Executes a swap via the trusted Universal Router.
    /// Caller must provide the exact amountIn (for leg2, this is the tracked leftover
    /// with inputs[0] already patched at word 1).
    function _executeUniversalRouterSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 deadline
    ) internal {
        address router = universalRouter;
        if (router == address(0)) revert UniversalRouterNotSet();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert InvalidPlan();

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(router, amountIn);
        {
            (bool ok,) =
                router.call(abi.encodeWithSelector(IUniversalRouter.execute.selector, commands, inputs, deadline));
            if (!ok) revert UniversalRouterSwapFailed();
        }
        IERC20(tokenIn).forceApprove(router, 0);

        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (received == 0) revert ZeroSwapOutput();
        if (received < minAmountOut) revert InsufficientRepayOutput(received, minAmountOut);

        emit UniversalRouterSwapExecuted(tokenIn, tokenOut, amountIn, received);
    }

    // ─── Internal: Paraswap selector classification + decoders ───────

    /// @dev Maps a 4-byte selector to its ParaswapSelectorKind. Pure / no storage.
    /// Every Augustus V6.2 swap entrypoint has an explicit branch — accepted
    /// selectors return their decoder-bound kind; documented-reject selectors
    /// (BalancerV2 direct, RFQ) return their dedicated reject kind so the caller
    /// can revert with `InvalidParaswapSelector(selector)`. Unknown selectors
    /// return `Unsupported`, which also reverts.
    function _classifyParaswapSelector(bytes4 selector) internal pure returns (ParaswapSelectorKind) {
        // Generic family (Paraswap router does the routing internally).
        if (selector == _SWAP_EXACT_AMOUNT_IN) return ParaswapSelectorKind.ExactInGeneric;
        if (selector == _SWAP_EXACT_AMOUNT_OUT) return ParaswapSelectorKind.ExactOutGeneric;
        // UniswapV2 / V3 direct (tail-encoded UniV2Data / UniV3Data).
        if (selector == _SWAP_EXACT_IN_UNI_V3) return ParaswapSelectorKind.UniswapV3ExactIn;
        if (selector == _SWAP_EXACT_OUT_UNI_V3) return ParaswapSelectorKind.UniswapV3ExactOut;
        if (selector == _SWAP_EXACT_IN_UNI_V2) return ParaswapSelectorKind.UniswapV2ExactIn;
        if (selector == _SWAP_EXACT_OUT_UNI_V2) return ParaswapSelectorKind.UniswapV2ExactOut;
        // Curve V1 / V2 direct (inline CurveV1Data / CurveV2Data — no ExactOut in V6.2).
        if (selector == _SWAP_EXACT_IN_CURVE_V1) return ParaswapSelectorKind.CurveV1ExactIn;
        if (selector == _SWAP_EXACT_IN_CURVE_V2) return ParaswapSelectorKind.CurveV2ExactIn;
        // BalancerV2 direct: srcToken/dstToken extracted from bytes data blob.
        if (selector == _SWAP_EXACT_IN_BALANCER_V2) return ParaswapSelectorKind.BalancerV2ExactIn;
        if (selector == _SWAP_EXACT_OUT_BALANCER_V2) return ParaswapSelectorKind.BalancerV2ExactOut;
        // Documented-reject: RFQ.
        if (selector == _SWAP_RFQ_BATCH_FILL) return ParaswapSelectorKind.RFQ;
        return ParaswapSelectorKind.Unsupported;
    }

    /// @dev True for any ExactIn-direction kind. Used by the orchestrator
    /// to decide between strict "consumed == declared" (ExactIn) vs lenient
    /// "consumed <= declared" (ExactOut) amount validation. Reject kinds
    /// (BalancerV2Rejected, RFQ, Unsupported) never reach this function — the
    /// orchestrator reverts before the ExactIn check — so they are not listed.
    function _isExactIn(ParaswapSelectorKind kind) internal pure returns (bool) {
        return kind == ParaswapSelectorKind.ExactInGeneric || kind == ParaswapSelectorKind.UniswapV2ExactIn
            || kind == ParaswapSelectorKind.UniswapV3ExactIn || kind == ParaswapSelectorKind.CurveV1ExactIn
            || kind == ParaswapSelectorKind.CurveV2ExactIn || kind == ParaswapSelectorKind.BalancerV2ExactIn;
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

    /// @dev Decode the tail-encoded UniV2 / UniV3 layout. Both share `(srcToken,
    /// destToken, fromAmount, toAmount, quotedAmount, metadata, beneficiary,
    /// bytes pools)` — the trailing `bytes pools` makes the struct dynamic, so
    /// the head holds an offset and the struct lives in the tail.
    ///
    /// Calldata after selector:
    ///   args[0..32]    = offset_to_struct  (head[0])
    ///   args[32..64]   = partnerAndFee     (head[1])
    ///   args[64..96]   = offset_to_permit  (head[2])
    /// Struct at args[offset_to_struct]:
    ///   struct[0..32]    = srcToken
    ///   struct[32..64]   = destToken
    ///   struct[64..96]   = fromAmount
    ///   struct[96..128]  = toAmount        ← minAmountOut for ExactIn / max for ExactOut
    ///   struct[128..160] = quotedAmount
    ///   struct[160..192] = metadata
    ///   struct[192..224] = beneficiary
    ///   struct[224..256] = offset_to_pools (rel. to struct start)
    /// Pools data + permit data follow further in the tail.
    ///
    /// `cd` includes the 32-byte length prefix, so absolute offsets add 36
    /// (32 length + 4 selector). Strict bounds: `structOffset` is word-aligned,
    /// at least 96 (after the 3 head words), and the struct's 8 head words
    /// (256 bytes) must fit inside `cd.length`.
    function _decodeParaswapTailUniV2V3(bytes memory cd)
        internal
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        // Bare structural minimum: selector(4) + 3 head words (96) + 8 struct
        // head words (256) = 356. The dynamic bound below catches larger
        // structOffset values.
        if (cd.length < 356) revert InvalidParaswapCalldata();

        uint256 structOffset;
        assembly {
            structOffset := mload(add(cd, 36)) // first head word after selector
        }
        if (structOffset % 32 != 0) revert InvalidParaswapCalldata();
        if (structOffset < 96) revert InvalidParaswapCalldata();
        // The struct's 8 head words (256 bytes) must lie inside the args
        // portion of cd. cd.length excludes the in-memory length prefix, and
        // structOffset is relative to the args base (post-selector), so we
        // need: 4 (selector) + structOffset + 256 <= cd.length.
        if (4 + structOffset + 256 > cd.length) revert InvalidParaswapCalldata();

        assembly {
            let s := add(add(cd, 36), structOffset)
            srcToken := and(mload(s), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(s, 32)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(s, 64))
            minAmountOut := mload(add(s, 96))
            beneficiary := and(mload(add(s, 192)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev Decode the inline CurveV1Data layout (9 static fields, no dynamic
    /// → struct inlines into the head). Calldata after selector:
    ///   args[0..32]    = curveData     (uint256, packed pool address + flags)
    ///   args[32..64]   = curveAssets   (uint256, packed i/j indices)
    ///   args[64..96]   = srcToken
    ///   args[96..128]  = destToken
    ///   args[128..160] = fromAmount
    ///   args[160..192] = toAmount      ← minAmountOut for ExactIn (no ExactOut on V6.2)
    ///   args[192..224] = quotedAmount
    ///   args[224..256] = metadata
    ///   args[256..288] = beneficiary
    ///   args[288..320] = partnerAndFee
    ///   args[320..352] = offset_to_permit
    ///   ... permit length + data in tail.
    function _decodeParaswapInlineCurveV1(bytes memory cd)
        internal
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        // Last read is `beneficiary` at args[256..288], so min cd.length covers
        // selector(4) + 9 struct words (288). 4 + 288 = 292.
        if (cd.length < 292) revert InvalidParaswapCalldata();
        assembly {
            let p := add(cd, 36)
            srcToken := and(mload(add(p, 64)), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(p, 96)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(p, 128))
            minAmountOut := mload(add(p, 160))
            beneficiary := and(mload(add(p, 256)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev Decode the inline CurveV2Data layout (11 static fields, no dynamic).
    /// Calldata after selector:
    ///   args[0..32]    = curveData
    ///   args[32..64]   = i
    ///   args[64..96]   = j
    ///   args[96..128]  = poolAddress
    ///   args[128..160] = srcToken
    ///   args[160..192] = destToken
    ///   args[192..224] = fromAmount
    ///   args[224..256] = toAmount      ← minAmountOut for ExactIn (no ExactOut on V6.2)
    ///   args[256..288] = quotedAmount
    ///   args[288..320] = metadata
    ///   args[320..352] = beneficiary
    ///   args[352..384] = partnerAndFee
    ///   args[384..416] = offset_to_permit
    ///   ... permit length + data in tail.
    function _decodeParaswapInlineCurveV2(bytes memory cd)
        internal
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        // Last read is `beneficiary` at args[320..352], so min cd.length covers
        // selector(4) + 11 struct words (352). 4 + 352 = 356.
        if (cd.length < 356) revert InvalidParaswapCalldata();
        assembly {
            let p := add(cd, 36)
            srcToken := and(mload(add(p, 128)), 0xffffffffffffffffffffffffffffffffffffffff)
            dstToken := and(mload(add(p, 160)), 0xffffffffffffffffffffffffffffffffffffffff)
            fromAmount := mload(add(p, 192))
            minAmountOut := mload(add(p, 224))
            beneficiary := and(mload(add(p, 320)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev Decode BalancerV2 direct calldata. srcToken/dstToken parsed from the
    /// `bytes data` param (raw Balancer Vault calldata). Matches Augustus V6.2
    /// BalancerV2Utils._decodeBalancerV2Params exactly.
    function _decodeParaswapBalancerV2(bytes memory cd)
        internal
        pure
        returns (address srcToken, address dstToken, uint256 fromAmount, uint256 minAmountOut, address beneficiary)
    {
        if (cd.length < 296) {
            revert InvalidParaswapCalldata();
        }
        assembly {
            let mask := 0xffffffffffffffffffffffffffffffffffffffff
            let p := add(cd, 36)
            fromAmount := mload(p)
            minAmountOut := mload(add(p, 32))
            beneficiary := and(mload(add(p, 128)), mask)
            let dataOff := mload(add(p, 224))
            let dataLen := mload(add(p, dataOff))
            // d = pointer to data content (past length word)
            let d := add(p, add(dataOff, 32))
            let vSel := shr(224, mload(d))
            // 0x52bbbe29 = swap()
            switch vSel
            case 0x52bbbe29 {
                if lt(dataLen, 324) {
                    mstore(0, 0x25d306c600000000000000000000000000000000000000000000000000000000)
                    revert(0, 4)
                }
                srcToken := and(mload(add(d, 292)), mask)
                dstToken := and(mload(add(d, 324)), mask)
            }
            // 0x945bcec9 = batchSwap()
            case 0x945bcec9 {
                let assetsOff := mload(add(d, 68))
                let cnt := mload(add(d, add(4, assetsOff)))
                if iszero(cnt) {
                    mstore(0, 0x25d306c600000000000000000000000000000000000000000000000000000000)
                    revert(0, 4)
                }
                let first := and(mload(add(d, add(4, add(assetsOff, 32)))), mask)
                let last := and(mload(add(d, add(4, add(assetsOff, mul(cnt, 32))))), mask)
                switch eq(mload(add(d, 4)), 1)
                case 1 {
                    srcToken := last
                    dstToken := first
                }
                default {
                    srcToken := first
                    dstToken := last
                }
            }
            default {
                mstore(0, 0x25d306c600000000000000000000000000000000000000000000000000000000)
                revert(0, 4)
            }
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
        // Documented-reject + unknown selectors all revert with the same error.
        // Each is kept as a distinct enum variant so the classifier coverage test
        // can assert the *reason* a selector is rejected.
        if (kind == ParaswapSelectorKind.Unsupported || kind == ParaswapSelectorKind.RFQ) {
            revert InvalidParaswapSelector(selector);
        }

        address beneficiary;
        if (kind == ParaswapSelectorKind.ExactInGeneric || kind == ParaswapSelectorKind.ExactOutGeneric) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeParaswapGeneric(cd);
        } else if (
            kind == ParaswapSelectorKind.UniswapV2ExactIn || kind == ParaswapSelectorKind.UniswapV2ExactOut
                || kind == ParaswapSelectorKind.UniswapV3ExactIn || kind == ParaswapSelectorKind.UniswapV3ExactOut
        ) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeParaswapTailUniV2V3(cd);
        } else if (kind == ParaswapSelectorKind.CurveV1ExactIn) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeParaswapInlineCurveV1(cd);
        } else if (kind == ParaswapSelectorKind.CurveV2ExactIn) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeParaswapInlineCurveV2(cd);
        } else if (kind == ParaswapSelectorKind.BalancerV2ExactIn || kind == ParaswapSelectorKind.BalancerV2ExactOut) {
            (srcToken, dstToken, fromAmount, minAmountOut, beneficiary) = _decodeParaswapBalancerV2(cd);
        } else {
            // Unreachable: every accepted kind is covered above and every reject
            // kind is handled before this branch. Defensive revert in case a future
            // enum variant is added without a decoder.
            revert InvalidParaswapSelector(selector);
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
