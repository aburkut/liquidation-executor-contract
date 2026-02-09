// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool, IFlashLoanSimpleReceiver} from "./interfaces/IAaveV3Pool.sol";
import {IMorphoBlue, MarketParams} from "./interfaces/IMorphoBlue.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @title LiquidationExecutor
/// @notice Flashloan + Swap + Repay executor for liquidation/repay workflows.
/// @dev Fail-closed design. No upgradeability. No arbitrary external calls.
contract LiquidationExecutor is
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    IFlashLoanSimpleReceiver
{
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
    error AssetNotAllowed(address token);
    error SwapRecipientInvalid(address recipient);
    error SwapDeadlineInvalid(uint256 deadline);
    error SwapAmountInMismatch(uint256 expected, uint256 actual);
    error InvalidProtocolId(uint8 id);
    error InsufficientRepayBalance(uint256 required, uint256 available);
    error InvalidSwapSelector();
    error RescueFailed();

    // ─── Constants ───────────────────────────────────────────────────
    uint8 public constant FLASH_PROVIDER_AAVE_V3 = 1;
    uint8 public constant PROTOCOL_AAVE_V3 = 1;
    uint8 public constant PROTOCOL_MORPHO_BLUE = 2;

    bytes4 private constant EXACT_INPUT_SINGLE_SELECTOR = ISwapRouter.exactInputSingle.selector;
    bytes4 private constant EXACT_INPUT_SELECTOR = ISwapRouter.exactInput.selector;

    // ─── State ───────────────────────────────────────────────────────
    address public operator;
    address public aavePool;
    address public morphoBlue;
    address public uniswapV3Router;

    mapping(address => bool) public allowedAssets;
    mapping(uint8 => address) public allowedFlashProviders;
    mapping(address => bool) public allowedTargets;

    bytes32 private _activePlanHash;

    // ─── Events ──────────────────────────────────────────────────────
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event ConfigUpdated(bytes32 indexed key, address indexed oldValue, address indexed newValue);
    event AssetAllowed(address indexed token, bool allowed);
    event FlashProviderUpdated(uint8 indexed providerId, address indexed oldProvider, address indexed newProvider);
    event TargetAllowed(address indexed target, bool allowed);
    event FlashExecuted(uint8 indexed providerId, address indexed loanToken, uint256 loanAmount);
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event RepayExecuted(uint8 indexed protocolId, bytes32 indexed positionKeyHash, address indexed asset, uint256 amount);
    event Rescue(address indexed token, address indexed to, uint256 amount);

    // ─── Plan Struct ─────────────────────────────────────────────────
    struct Plan {
        uint8 flashProviderId;
        address loanToken;
        uint256 loanAmount;
        uint256 maxFlashFee;
        uint8 targetProtocolId;
        bytes targetActionData;
        bytes swapData;
        address profitToken;
        uint256 minProfit;
    }

    // ─── Aave V3 target action ───────────────────────────────────────
    struct AaveV3Action {
        uint8 actionType; // 1 = repay, 2 = withdraw, 3 = supply
        address asset;
        uint256 amount;
        uint256 interestRateMode; // for repay
        address onBehalfOf;
    }

    // ─── Morpho Blue target action ───────────────────────────────────
    struct MorphoBlueAction {
        uint8 actionType; // 1 = repay, 2 = withdrawCollateral, 3 = supplyCollateral
        MarketParams marketParams;
        uint256 assets;
        uint256 shares; // for repay
        address onBehalfOf;
    }

    // ─── Constructor ─────────────────────────────────────────────────
    constructor(address initialOwner) Ownable(initialOwner) {}


    // ─── Modifiers ───────────────────────────────────────────────────
    modifier onlyOperator() {
        if (msg.sender != operator) revert Unauthorized();
        _;
    }

    // ─── Owner Config Functions ──────────────────────────────────────
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address old = operator;
        operator = newOperator;
        emit OperatorUpdated(old, newOperator);
    }

    function setAavePool(address pool) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        address old = aavePool;
        aavePool = pool;
        emit ConfigUpdated("aavePool", old, pool);
    }

    function setMorphoBlue(address morpho) external onlyOwner {
        if (morpho == address(0)) revert ZeroAddress();
        address old = morphoBlue;
        morphoBlue = morpho;
        emit ConfigUpdated("morphoBlue", old, morpho);
    }

    function setUniswapV3Router(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        address old = uniswapV3Router;
        uniswapV3Router = router;
        emit ConfigUpdated("uniswapV3Router", old, router);
    }

    function setAssetAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedAssets[token] = allowed;
        emit AssetAllowed(token, allowed);
    }

    function setFlashProvider(uint8 providerId, address provider) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        address old = allowedFlashProviders[providerId];
        allowedFlashProviders[providerId] = provider;
        emit FlashProviderUpdated(providerId, old, provider);
    }

    function setTargetAllowed(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Core Execute ────────────────────────────────────────────────
    function execute(bytes calldata planData) external onlyOperator whenNotPaused nonReentrant {
        Plan memory plan = abi.decode(planData, (Plan));

        if (plan.loanToken == address(0)) revert ZeroAddress();
        if (plan.loanAmount == 0) revert InvalidPlan();
        if (plan.profitToken == address(0)) revert ZeroAddress();
        if (!allowedAssets[plan.loanToken]) revert AssetNotAllowed(plan.loanToken);
        if (!allowedAssets[plan.profitToken]) revert AssetNotAllowed(plan.profitToken);

        address provider = allowedFlashProviders[plan.flashProviderId];
        if (provider == address(0)) revert FlashProviderNotAllowed();

        _activePlanHash = keccak256(planData);

        if (plan.flashProviderId == FLASH_PROVIDER_AAVE_V3) {
            IAaveV3Pool(provider).flashLoanSimple(
                address(this),
                plan.loanToken,
                plan.loanAmount,
                planData,
                0
            );
        } else {
            revert FlashProviderNotAllowed();
        }

        _activePlanHash = bytes32(0);

        emit FlashExecuted(plan.flashProviderId, plan.loanToken, plan.loanAmount);
    }

    // ─── Aave V3 Flashloan Callback ─────────────────────────────────
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        // Strict callback validation
        if (msg.sender != allowedFlashProviders[FLASH_PROVIDER_AAVE_V3]) revert InvalidCallbackCaller();
        if (initiator != address(this)) revert InvalidInitiator();
        if (keccak256(params) != _activePlanHash) revert InvalidPlan();

        Plan memory plan = abi.decode(params, (Plan));

        if (premium > plan.maxFlashFee) revert FlashFeeExceeded(premium, plan.maxFlashFee);

        uint256 profitBefore = IERC20(plan.profitToken).balanceOf(address(this));

        // Step 1: Swap
        _executeSwap(plan.loanToken, plan.loanAmount, plan.swapData);

        // Step 2: Target Action
        _executeTargetAction(plan.targetProtocolId, plan.targetActionData);

        // Step 3: Approve flashloan repay & check profit
        _finalizeFlashloan(asset, amount + premium, plan.profitToken, profitBefore, plan.minProfit);

        return true;
    }

    // ─── Internal: Finalize Flashloan ────────────────────────────────
    function _finalizeFlashloan(
        address asset,
        uint256 repayAmount,
        address profitTkn,
        uint256 profitBefore,
        uint256 minProfit
    ) internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayBalance(repayAmount, balance);

        // Approve exact repay to caller (Aave pool) — pool pulls after we return true
        IERC20(asset).forceApprove(msg.sender, repayAmount);

        // Profit check: balance includes repayAmount that pool will pull
        uint256 profitAfter = IERC20(profitTkn).balanceOf(address(this));
        uint256 effectiveProfit;

        if (profitTkn == asset) {
            // Adjust for the repayAmount that will be pulled after we return
            effectiveProfit = profitAfter > profitBefore + repayAmount
                ? profitAfter - profitBefore - repayAmount
                : 0;
        } else {
            effectiveProfit = profitAfter > profitBefore
                ? profitAfter - profitBefore
                : 0;
        }

        if (effectiveProfit < minProfit) revert InsufficientProfit(effectiveProfit, minProfit);
    }

    // ─── Internal: Execute Swap ──────────────────────────────────────
    function _executeSwap(
        address loanToken,
        uint256 expectedAmountIn,
        bytes memory swapData
    ) internal {
        if (swapData.length < 4) revert InvalidSwapSelector();

        bytes4 sel;
        assembly {
            sel := mload(add(swapData, 32))
        }

        address router = uniswapV3Router;
        if (router == address(0)) revert ZeroAddress();

        if (sel == EXACT_INPUT_SINGLE_SELECTOR) {
            _executeExactInputSingle(loanToken, expectedAmountIn, swapData, router);
        } else if (sel == EXACT_INPUT_SELECTOR) {
            _executeExactInput(loanToken, expectedAmountIn, swapData, router);
        } else {
            revert InvalidSwapSelector();
        }
    }

    function _executeExactInputSingle(
        address loanToken,
        uint256 expectedAmountIn,
        bytes memory swapData,
        address router
    ) internal {
        ISwapRouter.ExactInputSingleParams memory p = abi.decode(
            _sliceBytes(swapData, 4),
            (ISwapRouter.ExactInputSingleParams)
        );

        if (p.recipient != address(this)) revert SwapRecipientInvalid(p.recipient);
        if (p.deadline < block.timestamp) revert SwapDeadlineInvalid(p.deadline);
        if (p.amountIn != expectedAmountIn) revert SwapAmountInMismatch(expectedAmountIn, p.amountIn);
        if (!allowedAssets[p.tokenIn]) revert AssetNotAllowed(p.tokenIn);
        if (!allowedAssets[p.tokenOut]) revert AssetNotAllowed(p.tokenOut);

        IERC20(loanToken).forceApprove(router, expectedAmountIn);
        uint256 amountOut = ISwapRouter(router).exactInputSingle(p);
        IERC20(loanToken).forceApprove(router, 0);

        emit SwapExecuted(loanToken, p.tokenOut, expectedAmountIn, amountOut);
    }

    function _executeExactInput(
        address loanToken,
        uint256 expectedAmountIn,
        bytes memory swapData,
        address router
    ) internal {
        ISwapRouter.ExactInputParams memory p = abi.decode(
            _sliceBytes(swapData, 4),
            (ISwapRouter.ExactInputParams)
        );

        if (p.recipient != address(this)) revert SwapRecipientInvalid(p.recipient);
        if (p.deadline < block.timestamp) revert SwapDeadlineInvalid(p.deadline);
        if (p.amountIn != expectedAmountIn) revert SwapAmountInMismatch(expectedAmountIn, p.amountIn);
        if (p.path.length < 43) revert InvalidPlan();

        address tokenIn;
        address tokenOut;
        bytes memory path = p.path;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            tokenOut := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
        if (!allowedAssets[tokenIn]) revert AssetNotAllowed(tokenIn);
        if (!allowedAssets[tokenOut]) revert AssetNotAllowed(tokenOut);

        IERC20(loanToken).forceApprove(router, expectedAmountIn);
        uint256 amountOut = ISwapRouter(router).exactInput(p);
        IERC20(loanToken).forceApprove(router, 0);

        emit SwapExecuted(loanToken, tokenOut, expectedAmountIn, amountOut);
    }

    // ─── Internal: Execute Target Action ─────────────────────────────
    function _executeTargetAction(uint8 protocolId, bytes memory actionData) internal {
        if (protocolId == PROTOCOL_AAVE_V3) {
            _executeAaveV3Action(actionData);
        } else if (protocolId == PROTOCOL_MORPHO_BLUE) {
            _executeMorphoBlueAction(actionData);
        } else {
            revert InvalidProtocolId(protocolId);
        }
    }

    function _executeAaveV3Action(bytes memory actionData) internal {
        AaveV3Action memory action = abi.decode(actionData, (AaveV3Action));

        address pool = aavePool;
        if (pool == address(0)) revert ZeroAddress();
        if (!allowedTargets[pool]) revert AssetNotAllowed(pool);
        if (!allowedAssets[action.asset]) revert AssetNotAllowed(action.asset);

        if (action.actionType == 1) {
            IERC20(action.asset).forceApprove(pool, action.amount);
            uint256 repaid = IAaveV3Pool(pool).repay(
                action.asset, action.amount, action.interestRateMode, action.onBehalfOf
            );
            IERC20(action.asset).forceApprove(pool, 0);
            emit RepayExecuted(
                PROTOCOL_AAVE_V3,
                keccak256(abi.encodePacked(action.asset, action.onBehalfOf)),
                action.asset,
                repaid
            );
        } else if (action.actionType == 2) {
            uint256 withdrawn = IAaveV3Pool(pool).withdraw(action.asset, action.amount, address(this));
            emit RepayExecuted(
                PROTOCOL_AAVE_V3,
                keccak256(abi.encodePacked(action.asset, action.onBehalfOf)),
                action.asset,
                withdrawn
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

    function _executeMorphoBlueAction(bytes memory actionData) internal {
        MorphoBlueAction memory action = abi.decode(actionData, (MorphoBlueAction));

        address morpho = morphoBlue;
        if (morpho == address(0)) revert ZeroAddress();
        if (!allowedTargets[morpho]) revert AssetNotAllowed(morpho);
        if (!allowedAssets[action.marketParams.loanToken]) revert AssetNotAllowed(action.marketParams.loanToken);
        if (!allowedAssets[action.marketParams.collateralToken]) {
            revert AssetNotAllowed(action.marketParams.collateralToken);
        }

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
        (uint256 assetsRepaid,) = IMorphoBlue(morpho).repay(
            action.marketParams, action.assets, action.shares, action.onBehalfOf, ""
        );
        IERC20(action.marketParams.loanToken).forceApprove(morpho, 0);
        emit RepayExecuted(
            PROTOCOL_MORPHO_BLUE,
            keccak256(abi.encode(action.marketParams)),
            action.marketParams.loanToken,
            assetsRepaid
        );
    }

    function _morphoWithdrawCollateral(address morpho, MorphoBlueAction memory action) internal {
        IMorphoBlue(morpho).withdrawCollateral(
            action.marketParams, action.assets, action.onBehalfOf, address(this)
        );
        emit RepayExecuted(
            PROTOCOL_MORPHO_BLUE,
            keccak256(abi.encode(action.marketParams)),
            action.marketParams.collateralToken,
            action.assets
        );
    }

    function _morphoSupplyCollateral(address morpho, MorphoBlueAction memory action) internal {
        IERC20(action.marketParams.collateralToken).forceApprove(morpho, action.assets);
        IMorphoBlue(morpho).supplyCollateral(
            action.marketParams, action.assets, action.onBehalfOf, ""
        );
        IERC20(action.marketParams.collateralToken).forceApprove(morpho, 0);
        emit RepayExecuted(
            PROTOCOL_MORPHO_BLUE,
            keccak256(abi.encode(action.marketParams)),
            action.marketParams.collateralToken,
            action.assets
        );
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

    // ─── Internal Helpers ────────────────────────────────────────────
    function _sliceBytes(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        uint256 len = data.length - start;
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = data[start + i];
        }
        return result;
    }

    receive() external payable {}
}
