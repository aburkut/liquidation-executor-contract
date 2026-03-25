// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool, IFlashLoanSimpleReceiver} from "./interfaces/IAaveV3Pool.sol";
import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancerVault.sol";
import {IMorphoBlue, MarketParams} from "./interfaces/IMorphoBlue.sol";
import {IAaveV2LendingPool} from "./interfaces/IAaveV2LendingPool.sol";

interface IWETH {
    function withdraw(uint256 amount) external;
}

/// @title LiquidationExecutor
/// @notice Flashloan + Swap + Repay/Liquidation executor.
/// @dev Fail-closed. No upgradeability. External calls restricted to allowedTargets allowlist.
/// Swaps are executed via Paraswap Augustus (a trusted generic router) using operator-supplied calldata.
contract LiquidationExecutor is Ownable2Step, Pausable, ReentrancyGuard, IFlashLoanSimpleReceiver, IFlashLoanRecipient {
    using SafeERC20 for IERC20;

    // ─── Custom Errors ───────────────────────────────────────────────
    error Unauthorized();
    error ZeroAddress();
    error InvalidPlan();
    error FlashProviderNotAllowed();
    error FlashFeeExceeded(uint256 actual, uint256 max);
    error InsufficientProfit(uint256 actual, uint256 required);
    error InvalidCallbackCaller();
    error InvalidInitiator();
    error SwapRecipientInvalid(address recipient);
    error SwapDeadlineInvalid(uint256 deadline);
    error SwapAmountInMismatch(uint256 expected, uint256 actual);
    error InvalidProtocolId(uint8 id);
    error InvalidAction(uint8 actionType);
    error InsufficientRepayBalance(uint256 required, uint256 available);
    error RescueFailed();
    error CallbackAssetMismatch();
    error CallbackAmountMismatch();
    error BalancerSingleTokenOnly();
    error SwapFailed();
    error InsufficientSwapOutput(uint256 actual, uint256 minimum);
    error InsufficientSrcBalance(uint256 required, uint256 available);
    error TargetNotAllowed(address target);
    error InvalidSwapSpec();
    error InvalidSwapSelector();
    error ZeroBalance();
    error EmptyArray();
    error CoinbasePaymentRequiresWethProfit();

    // ─── Constants ───────────────────────────────────────────────────
    uint8 public constant FLASH_PROVIDER_AAVE_V3 = 1;
    uint8 public constant FLASH_PROVIDER_BALANCER = 2;

    uint8 public constant PROTOCOL_AAVE_V3 = 1;
    uint8 public constant PROTOCOL_MORPHO_BLUE = 2;
    uint8 public constant PROTOCOL_AAVE_V2 = 3;
    uint8 public constant PROTOCOL_INTERNAL = 100;

    uint8 public constant ACTION_PAY_COINBASE = 1;
    uint8 public constant ACTION_PAY_BUILDER_ERC20 = 2;

    /// @dev Paraswap Augustus V6 supported selectors (GenericData layout)
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

    // ─── State ───────────────────────────────────────────────────────
    address public immutable operator;
    address public immutable weth;
    address public aavePool;
    address public morphoBlue;
    // NOTE: Legacy configuration field.
    // The executor currently performs swaps via Paraswap Augustus.
    // This variable is kept for backward compatibility but is not used
    // in the current execution flow.
    address public uniswapV3Router;
    address public balancerVault;
    address public paraswapAugustusV6;
    address public aaveV2LendingPool;

    mapping(uint8 => address) public allowedFlashProviders;
    mapping(address => bool) public allowedTargets;

    bytes32 private _activePlanHash;

    // ─── Events ──────────────────────────────────────────────────────
    event ConfigUpdated(bytes32 indexed key, address indexed oldValue, address indexed newValue);
    event FlashProviderUpdated(uint8 indexed providerId, address indexed oldProvider, address indexed newProvider);
    event FlashExecuted(uint8 indexed providerId, address indexed loanToken, uint256 loanAmount);
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event RepayExecuted(
        uint8 indexed protocolId, bytes32 indexed positionKeyHash, address indexed asset, uint256 amount
    );
    event LiquidationExecuted(
        uint8 indexed protocolId, address indexed collateralAsset, address indexed debtAsset, uint256 debtToCover
    );
    event CoinbasePaid(address indexed coinbase, uint256 amount);
    event BuilderPaid(address indexed builder, address indexed token, uint256 amount);
    event Rescue(address indexed token, address indexed to, uint256 amount);

    // ─── Plan Struct ─────────────────────────────────────────────────
    struct SwapSpec {
        address srcToken;
        address dstToken;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        bytes paraswapCalldata;
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
        SwapSpec swapSpec;
        address profitToken;
        uint256 minProfit;
    }

    uint8 private constant MAX_ACTIONS = 10;

    // ─── Aave V3 target action ───────────────────────────────────────
    struct AaveV3Action {
        uint8 actionType; // 1 = repay, 2 = withdraw, 3 = supply, 4 = liquidation
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
    }

    // ─── Morpho Blue target action ───────────────────────────────────
    struct MorphoBlueAction {
        uint8 actionType; // 1 = repay, 2 = withdrawCollateral, 3 = supplyCollateral
        MarketParams marketParams;
        uint256 assets;
        uint256 shares;
        address onBehalfOf;
    }

    // ─── Aave V2 liquidation action ──────────────────────────────────
    struct AaveV2Liquidation {
        address collateralAsset;
        address debtAsset;
        address user;
        uint256 debtToCover;
        bool receiveAToken;
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

    // NOTE: Legacy setter. The executor currently performs swaps via Paraswap Augustus.
    // This setter is kept for backward compatibility but the stored value is not used
    // in the current execution flow.
    function setUniswapV3Router(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        address old = uniswapV3Router;
        uniswapV3Router = router;
        emit ConfigUpdated("uniswapV3Router", old, router);
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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal: Validate Actions ─────────────────────────────────
    /// @dev Validates all actions share the same debt/collateral assets and have non-zero amounts.
    /// Returns the common collateralAsset for swap validation.
    /// Gas-efficient: reads only the required fields from ABI-encoded action data.
    function _validateActions(Action[] memory actions, address loanToken)
        internal
        pure
        returns (address collateralAsset)
    {
        for (uint256 i = 0; i < actions.length; ++i) {
            uint8 protocolId = actions[i].protocolId;

            // Internal actions (e.g. coinbase payment) are not liquidation actions
            if (protocolId == PROTOCOL_INTERNAL) continue;

            bytes memory data = actions[i].data;

            address actionDebt;
            address actionCollateral;
            uint256 actionAmount;

            if (protocolId == PROTOCOL_AAVE_V3) {
                AaveV3Action memory a = abi.decode(data, (AaveV3Action));
                require(a.actionType == 4, "UNSUPPORTED_ACTION");
                actionDebt = a.debtAsset;
                actionCollateral = a.collateralAsset;
                actionAmount = a.debtToCover;
            } else if (protocolId == PROTOCOL_AAVE_V2) {
                AaveV2Liquidation memory a = abi.decode(data, (AaveV2Liquidation));
                actionDebt = a.debtAsset;
                actionCollateral = a.collateralAsset;
                actionAmount = a.debtToCover;
            } else {
                revert("INVALID_PROTOCOL");
            }

            require(actionAmount > 0, "ZERO_ACTION_AMOUNT");
            require(actionDebt == loanToken, "INVALID_DEBT_ASSET");

            if (actionCollateral != address(0)) {
                if (collateralAsset == address(0)) {
                    collateralAsset = actionCollateral;
                } else {
                    require(actionCollateral == collateralAsset, "INVALID_COLLATERAL_ASSET");
                }
            }
        }
    }

    // ─── Core Execute ────────────────────────────────────────────────
    function execute(bytes calldata planData) external onlyOperator whenNotPaused nonReentrant {
        Plan memory plan = abi.decode(planData, (Plan));

        if (plan.loanToken == address(0)) revert ZeroAddress();
        if (plan.loanAmount == 0) revert InvalidPlan();
        if (plan.profitToken == address(0)) revert ZeroAddress();
        require(plan.actions.length > 0, "NO_ACTIONS");
        require(plan.actions.length <= MAX_ACTIONS, "TOO_MANY_ACTIONS");

        // Validate all actions use same debt/collateral assets
        address collateralAsset = _validateActions(plan.actions, plan.loanToken);

        // Swap dstToken must equal loanToken (to repay flash loan).
        require(plan.swapSpec.dstToken == plan.loanToken, "INVALID_SWAP_SPEC");

        // Swap srcToken must equal collateral (if liquidation actions produce collateral)
        if (collateralAsset != address(0)) {
            require(plan.swapSpec.srcToken == collateralAsset, "INVALID_SWAP_SPEC");
        }

        address provider = allowedFlashProviders[plan.flashProviderId];
        if (provider == address(0)) revert FlashProviderNotAllowed();

        _activePlanHash = keccak256(planData);

        if (plan.flashProviderId == FLASH_PROVIDER_AAVE_V3) {
            IAaveV3Pool(provider).flashLoanSimple(address(this), plan.loanToken, plan.loanAmount, planData, 0);
        } else if (plan.flashProviderId == FLASH_PROVIDER_BALANCER) {
            IERC20[] memory tokens = new IERC20[](1);
            tokens[0] = IERC20(plan.loanToken);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = plan.loanAmount;
            IBalancerVault(provider).flashLoan(address(this), tokens, amounts, planData);
        } else {
            revert FlashProviderNotAllowed();
        }

        _activePlanHash = bytes32(0);
        emit FlashExecuted(plan.flashProviderId, plan.loanToken, plan.loanAmount);
    }

    // ─── Aave V3 Flashloan Callback ─────────────────────────────────
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        override
        returns (bool)
    {
        if (msg.sender != allowedFlashProviders[FLASH_PROVIDER_AAVE_V3]) revert InvalidCallbackCaller();
        if (initiator != address(this)) revert InvalidInitiator();
        if (keccak256(params) != _activePlanHash) revert InvalidPlan();

        Plan memory plan = abi.decode(params, (Plan));

        // P0 safety: strict asset/amount match
        if (asset != plan.loanToken) revert CallbackAssetMismatch();
        if (amount != plan.loanAmount) revert CallbackAmountMismatch();
        if (premium > plan.maxFlashFee) revert FlashFeeExceeded(premium, plan.maxFlashFee);

        // Pre-execution: verify flash loan funds received
        require(IERC20(plan.loanToken).balanceOf(address(this)) >= plan.loanAmount, "INVALID_FLASH_LOAN");

        uint256 profitBefore = IERC20(plan.profitToken).balanceOf(address(this));

        // Execute protocol actions (liquidations), then swap result back to loanToken for repay.
        for (uint256 i = 0; i < plan.actions.length; ++i) {
            if (plan.actions[i].protocolId != PROTOCOL_INTERNAL) {
                _executeTargetAction(plan.actions[i].protocolId, plan.actions[i].data);
            }
        }

        // Post-action: verify collateral was received (if swap expects it)
        if (plan.swapSpec.srcToken != plan.loanToken) {
            require(IERC20(plan.swapSpec.srcToken).balanceOf(address(this)) > 0, "NO_COLLATERAL");
        }

        _executeSwap(plan.swapSpec);

        // Execute internal actions (payments) after swap, with accounting
        uint256 totalCoinbasePayment;
        uint256 totalWethUnwrapped;
        for (uint256 i = 0; i < plan.actions.length; ++i) {
            if (plan.actions[i].protocolId == PROTOCOL_INTERNAL) {
                (uint256 cbPaid, uint256 wethUsed) = _executeInternalAction(plan.actions[i].data, plan.profitToken);
                totalCoinbasePayment += cbPaid;
                totalWethUnwrapped += wethUsed;
            }
        }

        // Aave pulls repayment after we return true — approve exact amount
        _finalizeAaveFlashloan(
            asset,
            amount,
            amount + premium,
            plan.profitToken,
            profitBefore,
            plan.minProfit,
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

        // Pre-execution: verify flash loan funds received
        require(IERC20(plan.loanToken).balanceOf(address(this)) >= plan.loanAmount, "INVALID_FLASH_LOAN");

        uint256 profitBefore = IERC20(plan.profitToken).balanceOf(address(this));

        // Execute protocol actions (liquidations)
        for (uint256 i = 0; i < plan.actions.length; ++i) {
            if (plan.actions[i].protocolId != PROTOCOL_INTERNAL) {
                _executeTargetAction(plan.actions[i].protocolId, plan.actions[i].data);
            }
        }

        // Post-action: verify collateral was received
        if (plan.swapSpec.srcToken != plan.loanToken) {
            require(IERC20(plan.swapSpec.srcToken).balanceOf(address(this)) > 0, "NO_COLLATERAL");
        }

        _executeSwap(plan.swapSpec);

        // Execute internal actions (payments) after swap, with accounting
        uint256 totalCoinbasePayment;
        uint256 totalWethUnwrapped;
        for (uint256 i = 0; i < plan.actions.length; ++i) {
            if (plan.actions[i].protocolId == PROTOCOL_INTERNAL) {
                (uint256 cbPaid, uint256 wethUsed) = _executeInternalAction(plan.actions[i].data, plan.profitToken);
                totalCoinbasePayment += cbPaid;
                totalWethUnwrapped += wethUsed;
            }
        }

        // Balancer expects funds returned by end of callback via transfer
        uint256 repayAmount = amounts[0] + feeAmounts[0];
        _finalizeBalancerFlashloan(
            address(tokens[0]),
            amounts[0],
            repayAmount,
            msg.sender,
            plan.profitToken,
            profitBefore,
            plan.minProfit,
            totalCoinbasePayment,
            totalWethUnwrapped
        );
    }

    // ─── Internal: Finalize Aave Flashloan ───────────────────────────
    function _finalizeAaveFlashloan(
        address asset,
        uint256 principalAmount,
        uint256 repayAmount,
        address profitTkn,
        uint256 profitBefore,
        uint256 minProfit,
        uint256 totalCoinbasePayment,
        uint256 totalWethUnwrapped
    ) internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayBalance(repayAmount, balance);

        // Approve exact repay to Aave pool — pool pulls after we return true
        IERC20(asset).forceApprove(msg.sender, repayAmount);

        _checkProfit(
            asset,
            principalAmount,
            repayAmount,
            profitTkn,
            profitBefore,
            minProfit,
            true,
            totalCoinbasePayment,
            totalWethUnwrapped
        );
    }

    // ─── Internal: Finalize Balancer Flashloan ───────────────────────
    function _finalizeBalancerFlashloan(
        address asset,
        uint256 principalAmount,
        uint256 repayAmount,
        address vault,
        address profitTkn,
        uint256 profitBefore,
        uint256 minProfit,
        uint256 totalCoinbasePayment,
        uint256 totalWethUnwrapped
    ) internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayBalance(repayAmount, balance);

        // Balancer: transfer back to vault
        IERC20(asset).safeTransfer(vault, repayAmount);

        _checkProfit(
            asset,
            principalAmount,
            repayAmount,
            profitTkn,
            profitBefore,
            minProfit,
            false,
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
        uint256 minProfit,
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

        // Subtract coinbase payment cost not already captured in ERC20 delta.
        // When profitToken is WETH and WETH was unwrapped to fund payment,
        // that portion already reduced profitAfter — only subtract the remainder
        // (ETH paid from pre-funded balance, invisible to ERC20 delta).
        if (totalCoinbasePayment > 0) {
            uint256 coinbaseCostNotInDelta;
            address wethAddr = weth;
            if (wethAddr != address(0) && profitTkn == wethAddr) {
                coinbaseCostNotInDelta =
                    totalCoinbasePayment > totalWethUnwrapped ? totalCoinbasePayment - totalWethUnwrapped : 0;
            } else {
                coinbaseCostNotInDelta = totalCoinbasePayment;
            }
            effectiveProfit = effectiveProfit > coinbaseCostNotInDelta ? effectiveProfit - coinbaseCostNotInDelta : 0;
        }

        if (effectiveProfit < minProfit) revert InsufficientProfit(effectiveProfit, minProfit);
    }

    // ─── Internal: Execute Swap (ParaSwap) ───────────────────────────
    function _executeSwap(SwapSpec memory spec) internal {
        if (spec.srcToken == address(0) || spec.dstToken == address(0)) revert InvalidSwapSpec();
        if (spec.amountIn == 0) revert InvalidSwapSpec();
        if (spec.paraswapCalldata.length < 4) revert InvalidSwapSpec();

        // ── Deadline validation ──
        if (spec.deadline < block.timestamp) revert SwapDeadlineInvalid(spec.deadline);

        // ── Selector & calldata validation ──
        bytes memory cd = spec.paraswapCalldata;
        bytes4 selector;
        assembly {
            selector := mload(add(cd, 32))
        }

        if (selector != _SWAP_EXACT_AMOUNT_IN && selector != _SWAP_EXACT_AMOUNT_OUT) {
            revert InvalidSwapSelector();
        }

        // Both selectors share the same GenericData layout (7 static fields after executor).
        // Minimum: selector(4) + executor(32) + 7 GenericData fields(224) = 260 bytes.
        if (cd.length < 260) revert InvalidSwapSpec();

        address beneficiary;
        uint256 fromAmount;
        assembly {
            let p := add(cd, 36) // skip length prefix (32) + selector (4)
            fromAmount := mload(add(p, 96)) // GenericData.fromAmount
            beneficiary := and(mload(add(p, 224)), 0xffffffffffffffffffffffffffffffffffffffff) // GenericData.beneficiary
        }

        if (beneficiary != address(this)) revert SwapRecipientInvalid(beneficiary);
        if (fromAmount != spec.amountIn) revert SwapAmountInMismatch(spec.amountIn, fromAmount);

        address augustus = paraswapAugustusV6;
        if (augustus == address(0)) revert ZeroAddress();
        if (!allowedTargets[augustus]) revert TargetNotAllowed(augustus);

        uint256 srcBal = IERC20(spec.srcToken).balanceOf(address(this));
        if (srcBal < spec.amountIn) revert InsufficientSrcBalance(spec.amountIn, srcBal);

        uint256 dstBefore = IERC20(spec.dstToken).balanceOf(address(this));

        // Approve exact amountIn, call, reset
        IERC20(spec.srcToken).forceApprove(augustus, spec.amountIn);
        (bool ok,) = augustus.call(spec.paraswapCalldata);
        IERC20(spec.srcToken).forceApprove(augustus, 0);

        if (!ok) revert SwapFailed();

        uint256 dstAfter = IERC20(spec.dstToken).balanceOf(address(this));
        uint256 amountOut = dstAfter - dstBefore;
        if (amountOut < spec.minAmountOut) revert InsufficientSwapOutput(amountOut, spec.minAmountOut);

        emit SwapExecuted(spec.srcToken, spec.dstToken, spec.amountIn, amountOut);
    }

    // ─── Internal: Execute Target Action ─────────────────────────────
    function _executeTargetAction(uint8 protocolId, bytes memory actionData) internal {
        if (protocolId == PROTOCOL_AAVE_V3) {
            _executeAaveV3Action(actionData);
        } else if (protocolId == PROTOCOL_MORPHO_BLUE) {
            _executeMorphoBlueAction(actionData);
        } else if (protocolId == PROTOCOL_AAVE_V2) {
            _executeAaveV2Liquidation(actionData);
        } else {
            revert InvalidProtocolId(protocolId);
        }
    }

    function _executeAaveV3Action(bytes memory actionData) internal {
        AaveV3Action memory action = abi.decode(actionData, (AaveV3Action));

        address pool = aavePool;
        if (pool == address(0)) revert ZeroAddress();
        if (!allowedTargets[pool]) revert TargetNotAllowed(pool);

        if (action.actionType == 4) {
            _executeAaveV3Liquidation(pool, action);
            return;
        }

        if (action.actionType == 1) {
            IERC20(action.asset).forceApprove(pool, action.amount);
            uint256 repaid =
                IAaveV3Pool(pool).repay(action.asset, action.amount, action.interestRateMode, action.onBehalfOf);
            IERC20(action.asset).forceApprove(pool, 0);
            emit RepayExecuted(
                PROTOCOL_AAVE_V3, keccak256(abi.encodePacked(action.asset, action.onBehalfOf)), action.asset, repaid
            );
        } else if (action.actionType == 2) {
            uint256 withdrawn = IAaveV3Pool(pool).withdraw(action.asset, action.amount, address(this));
            emit RepayExecuted(
                PROTOCOL_AAVE_V3, keccak256(abi.encodePacked(action.asset, action.onBehalfOf)), action.asset, withdrawn
            );
        } else if (action.actionType == 3) {
            IERC20(action.asset).forceApprove(pool, action.amount);
            IAaveV3Pool(pool).supply(action.asset, action.amount, action.onBehalfOf, 0);
            IERC20(action.asset).forceApprove(pool, 0);
            emit RepayExecuted(
                PROTOCOL_AAVE_V3,
                keccak256(abi.encodePacked(action.asset, action.onBehalfOf)),
                action.asset,
                action.amount
            );
        } else {
            revert InvalidPlan();
        }
    }

    function _executeAaveV3Liquidation(address pool, AaveV3Action memory action) internal {
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

    function _executeMorphoBlueAction(bytes memory actionData) internal {
        MorphoBlueAction memory action = abi.decode(actionData, (MorphoBlueAction));

        address morpho = morphoBlue;
        if (morpho == address(0)) revert ZeroAddress();
        if (!allowedTargets[morpho]) revert TargetNotAllowed(morpho);

        if (action.actionType == 1) {
            _morphoRepay(morpho, action);
        } else if (action.actionType == 2) {
            _morphoWithdrawCollateral(morpho, action);
        } else if (action.actionType == 3) {
            _morphoSupplyCollateral(morpho, action);
        } else {
            revert InvalidPlan();
        }
    }

    function _morphoRepay(address morpho, MorphoBlueAction memory action) internal {
        IERC20(action.marketParams.loanToken).forceApprove(morpho, action.assets);
        (uint256 assetsRepaid,) =
            IMorphoBlue(morpho).repay(action.marketParams, action.assets, action.shares, action.onBehalfOf, "");
        IERC20(action.marketParams.loanToken).forceApprove(morpho, 0);
        emit RepayExecuted(
            PROTOCOL_MORPHO_BLUE,
            keccak256(abi.encode(action.marketParams)),
            action.marketParams.loanToken,
            assetsRepaid
        );
    }

    function _morphoWithdrawCollateral(address morpho, MorphoBlueAction memory action) internal {
        IMorphoBlue(morpho).withdrawCollateral(action.marketParams, action.assets, action.onBehalfOf, address(this));
        emit RepayExecuted(
            PROTOCOL_MORPHO_BLUE,
            keccak256(abi.encode(action.marketParams)),
            action.marketParams.collateralToken,
            action.assets
        );
    }

    function _morphoSupplyCollateral(address morpho, MorphoBlueAction memory action) internal {
        IERC20(action.marketParams.collateralToken).forceApprove(morpho, action.assets);
        IMorphoBlue(morpho).supplyCollateral(action.marketParams, action.assets, action.onBehalfOf, "");
        IERC20(action.marketParams.collateralToken).forceApprove(morpho, 0);
        emit RepayExecuted(
            PROTOCOL_MORPHO_BLUE,
            keccak256(abi.encode(action.marketParams)),
            action.marketParams.collateralToken,
            action.assets
        );
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

    // ─── Internal: Execute Internal Action ──────────────────────────
    /// @dev Centralized dispatch for PROTOCOL_INTERNAL actions.
    /// Returns coinbase payment accounting for profit validation.
    function _executeInternalAction(bytes memory actionData, address profitToken)
        internal
        returns (uint256 coinbasePaid, uint256 wethUnwrapped)
    {
        uint8 actionType = abi.decode(actionData, (uint8));

        if (actionType == ACTION_PAY_COINBASE) {
            // Coinbase payment is ETH-denominated — only valid when profit is in WETH
            // so that the subtraction in _checkProfit uses consistent units.
            if (profitToken != weth) revert CoinbasePaymentRequiresWethProfit();

            (, uint256 amount) = abi.decode(actionData, (uint8, uint256));
            wethUnwrapped = _payCoinbase(amount);
            coinbasePaid = amount;
        } else if (actionType == ACTION_PAY_BUILDER_ERC20) {
            (, address token, address builder, uint256 amount) =
                abi.decode(actionData, (uint8, address, address, uint256));
            _payBuilderERC20(token, builder, amount, profitToken);
        } else {
            revert InvalidAction(actionType);
        }
    }

    /// @dev Transfer ERC20 to builder. Token must match profitToken so the cost
    /// is automatically captured in the ERC20 balance delta used by _checkProfit.
    function _payBuilderERC20(address token, address builder, uint256 amount, address profitToken) internal {
        if (amount == 0) return;

        require(builder != address(0), "INVALID_BUILDER");
        require(token != address(0), "INVALID_TOKEN");
        require(token == profitToken, "BUILDER_PAYMENT_TOKEN_MISMATCH");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "INSUFFICIENT_TOKEN");

        IERC20(token).safeTransfer(builder, amount);

        emit BuilderPaid(builder, token, amount);
    }

    /// @dev Send ETH to block.coinbase. Only reachable when profitToken == weth (enforced by caller).
    /// Auto-unwraps WETH if insufficient ETH. Returns the amount unwrapped (for profit accounting).
    function _payCoinbase(uint256 amount) internal returns (uint256 wethUnwrapped) {
        if (amount == 0) return 0;

        // Auto-unwrap WETH if insufficient ETH and WETH is configured
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

        require(address(this).balance >= amount, "INSUFFICIENT_ETH");

        (bool success,) = block.coinbase.call{value: amount}("");
        require(success, "COINBASE_PAYMENT_FAILED");

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
