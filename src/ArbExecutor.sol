// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancerVault.sol";
import {IMorphoBlue, IMorphoFlashLoanCallback} from "./interfaces/IMorphoBlue.sol";
import {UniswapLib} from "./libraries/UniswapLib.sol";
import {CurveV1Lib} from "./libraries/CurveV1Lib.sol";
import {BalancerV2Lib} from "./libraries/BalancerV2Lib.sol";
import {SwapLegExecutorLib} from "./libraries/SwapLegExecutorLib.sol";
import {SwapValidationLib} from "./libraries/SwapValidationLib.sol";
import {CoinbasePaymentLib} from "./libraries/CoinbasePaymentLib.sol";
import {SwapMode, SwapLeg} from "./types/SwapTypes.sol";

/// @title ArbExecutor
/// @notice Flashloan-driven N-hop atomic arbitrage executor. Sister
/// contract to `LiquidationExecutor`; reuses every per-mode swap
/// library and the SwapTypes / SwapValidationLib / CoinbasePaymentLib
/// extracted in the V10 refactor.
///
/// SCOPE — pure DEX arbitrage:
///   * Flashloan principal from Morpho (fee=0) or Balancer.
///   * Run a sequential chain of swap legs (`legs[]`): leg1 consumes
///     the loaned principal; each subsequent leg consumes the previous
///     leg's output via `useFullBalance` (the typical chain shape).
///   * Final leg's `repayToken` MUST equal `loanToken` so the contract
///     can settle the flashloan.
///   * Optional `coinbaseBps` slice of realized profit → `block.coinbase`
///     as a builder bribe (only valid when `loanToken == weth`).
///   * Remaining loan-token balance stays on the contract until the
///     owner calls `withdraw(...)`.
///
/// Out of scope (vs. `LiquidationExecutor`):
///   * No Aave V3 / V2 / Morpho liquidation actions — `legs[]` is the
///     entire payload, no `actions[]` array.
///   * No V4 swap leg (Uni V4's `unlockCallback` needs storage-coupled
///     `_activeV4PoolManager` / `_activeV4TokenIn` pins; not worth the
///     complexity until shadow data shows V4 wins on arb routes).
///   * No SPLIT / MIXED_SPLIT — those shapes only make sense when
///     splitting collateral between repay + WETH-bribe legs, which is
///     liquidation-specific.
library ArbTypes {
    /// @dev Operator-supplied plan for one arb execution.
    ///
    /// `flashProviderId` selects between Morpho (3, fee=0, preferred)
    /// and Balancer (2, has a `maxFlashFee` cap on the protocol fee).
    ///
    /// Chain invariants enforced in `execute(...)`:
    ///   * `legs.length >= 1`
    ///   * `legs[0].srcToken == loanToken`
    ///   * `legs[N-1].repayToken == loanToken`  (chain closes; can repay)
    ///   * `legs[i+1].srcToken == legs[i].repayToken`  (links match)
    ///   * Each leg validated via `SwapValidationLib.validateNonV4Leg`.
    ///   * V4 swap modes rejected by the lib's `InvalidSwapMode` revert.
    ///
    /// Coinbase bribe (optional): `coinbaseBps` × realizedProfit /
    /// 10_000 is paid to `block.coinbase`. Caller MUST set
    /// `coinbaseBps == 0` when `loanToken != weth` (chain doesn't land
    /// in WETH so coinbase auto-unwrap has nothing to convert).
    struct ArbPlan {
        uint8 flashProviderId;
        address loanToken;
        uint256 loanAmount;
        uint256 maxFlashFee;
        SwapLeg[] legs;
        uint256 coinbaseBps;
        uint256 minProfitAmount;
    }
}

contract ArbExecutor is Ownable2Step, Pausable, ReentrancyGuard, IFlashLoanRecipient, IMorphoFlashLoanCallback {
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
    error InvalidSwapMode();
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

    // ─── Events ──────────────────────────────────────────────────────
    event ArbExecuted(
        bytes32 indexed planHash, address indexed loanToken, uint256 realizedProfit, uint256 coinbasePaid
    );
    event AllowedTargetUpdated(address indexed target, bool allowed);
    event FlashProviderUpdated(uint8 indexed providerId, address indexed oldProvider, address indexed newProvider);
    event Withdraw(address indexed token, address indexed to, uint256 amount);
    // Mirrors CoinbasePaymentLib.CoinbasePaid for tests that pin the topic.
    event CoinbasePaid(address indexed coinbase, uint256 amount);

    // ─── Constants ───────────────────────────────────────────────────
    uint8 public constant FLASH_PROVIDER_BALANCER = 2;
    uint8 public constant FLASH_PROVIDER_MORPHO = 3;
    uint8 private constant MAX_LEGS = 8;

    // ─── Immutables (constructor-pinned) ─────────────────────────────
    address public immutable operator;
    address public immutable weth;
    address public immutable paraswapAugustusV6;
    address public immutable uniV2Router;
    address public immutable uniV3Router;

    // ─── Storage ─────────────────────────────────────────────────────
    address public morphoBlue;
    mapping(uint8 => address) public allowedFlashProviders;
    /// @dev Generic allowlist for Bebop settlement / future protocol
    /// targets that need owner-curated trust. Uni V2/V3 routers are
    /// constructor-immutable; Curve / Balancer pool addresses are
    /// trusted from the bot (sanity-gated inside their libraries).
    mapping(address => bool) public allowedTargets;

    bytes32 private _activePlanHash;
    enum ExecutionPhase {
        Idle,
        FlashLoanActive
    }
    ExecutionPhase private _executionPhase;

    // ─── Constructor ─────────────────────────────────────────────────
    constructor(
        address owner_,
        address operator_,
        address weth_,
        address balancerVault_,
        address paraswapAugustus_,
        address uniV2Router_,
        address uniV3Router_,
        address[] memory allowedTargets_
    ) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        if (balancerVault_ == address(0)) revert ZeroAddress();
        if (paraswapAugustus_ == address(0)) revert ZeroAddress();
        if (uniV2Router_ == address(0)) revert ZeroAddress();
        if (uniV3Router_ == address(0)) revert ZeroAddress();

        operator = operator_;
        weth = weth_;
        paraswapAugustusV6 = paraswapAugustus_;
        uniV2Router = uniV2Router_;
        uniV3Router = uniV3Router_;

        allowedFlashProviders[FLASH_PROVIDER_BALANCER] = balancerVault_;
        // Seed allowedTargets with the routers + Paraswap so Bebop
        // dispatch can re-check `allowedTargets[bebopTarget]` if used.
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
        if (msg.sender != operator) revert UnauthorizedOperator();
        _;
    }

    // ─── Owner: admin ────────────────────────────────────────────────
    function configureMorpho(address morpho) external onlyOwner {
        if (morpho == address(0)) revert ZeroAddress();
        morphoBlue = morpho;
        address oldProvider = allowedFlashProviders[FLASH_PROVIDER_MORPHO];
        allowedFlashProviders[FLASH_PROVIDER_MORPHO] = morpho;
        emit FlashProviderUpdated(FLASH_PROVIDER_MORPHO, oldProvider, morpho);
    }

    function setFlashProvider(uint8 providerId, address provider) external onlyOwner {
        // Mirrors LiquidationExecutor: Balancer-only reconfig path.
        // Morpho re-configuration MUST go through `configureMorpho`.
        if (providerId != FLASH_PROVIDER_BALANCER) revert InvalidPlan();
        if (provider == address(0)) revert ZeroAddress();
        address old = allowedFlashProviders[providerId];
        allowedFlashProviders[providerId] = provider;
        allowedTargets[provider] = true;
        emit FlashProviderUpdated(providerId, old, provider);
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = allowed;
        emit AllowedTargetUpdated(target, allowed);
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
    function execute(bytes calldata planData) external onlyOperator whenNotPaused nonReentrant {
        ArbTypes.ArbPlan memory plan = abi.decode(planData, (ArbTypes.ArbPlan));

        // Plan invariants — fail fast pre-flashloan.
        if (plan.loanToken == address(0)) revert ZeroAddress();
        if (plan.loanAmount == 0) revert InvalidPlan();
        if (plan.legs.length == 0 || plan.legs.length > MAX_LEGS) revert InvalidPlan();
        if (plan.coinbaseBps > 10_000) revert InvalidPlan();
        if (plan.coinbaseBps > 0 && plan.loanToken != weth) revert CoinbaseRequiresWethLoan();

        // Chain wiring: first leg starts at loanToken, each subsequent
        // leg picks up the previous leg's repayToken, last leg closes
        // back to loanToken.
        if (plan.legs[0].srcToken != plan.loanToken) revert InvalidPlan();
        if (plan.legs[plan.legs.length - 1].repayToken != plan.loanToken) revert InvalidPlan();
        for (uint256 i = 1; i < plan.legs.length; ++i) {
            if (plan.legs[i].srcToken != plan.legs[i - 1].repayToken) revert InvalidPlan();
        }

        // Per-leg field-shape validation (V4 modes rejected here).
        for (uint256 i = 0; i < plan.legs.length; ++i) {
            SwapValidationLib.validateNonV4Leg(plan.legs[i]);
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
        if (tokens.length != 1) revert BalancerSingleTokenOnly();

        ArbTypes.ArbPlan memory plan = abi.decode(userData, (ArbTypes.ArbPlan));

        if (address(tokens[0]) != plan.loanToken) revert CallbackAssetMismatch();
        if (amounts[0] != plan.loanAmount) revert CallbackAmountMismatch();
        if (feeAmounts[0] > plan.maxFlashFee) revert FlashFeeExceeded(feeAmounts[0], plan.maxFlashFee);

        uint256 flashRepay = amounts[0] + feeAmounts[0];
        _runArbPipeline(plan, flashRepay, msg.sender);
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

        ArbTypes.ArbPlan memory plan = abi.decode(data, (ArbTypes.ArbPlan));
        if (amount != plan.loanAmount) revert CallbackAmountMismatch();

        // Morpho fee = 0
        _runArbPipeline(plan, amount, address(0));
    }

    // ─── Pipeline (inside flash) ─────────────────────────────────────
    /// @dev `vault == address(0)` ⇒ approve-only (Morpho pulls).
    /// `vault != 0` ⇒ push transfer to the vault.
    function _runArbPipeline(ArbTypes.ArbPlan memory plan, uint256 flashRepay, address vault) internal {
        address loanToken = plan.loanToken;

        // Verify the flash actually arrived.
        if (IERC20(loanToken).balanceOf(address(this)) < plan.loanAmount) revert InvalidFlashLoan();

        // Snapshot loanToken balance AFTER flash arrival (includes
        // principal). Used by `computeRealizedProfit` to back out the
        // pre-flash baseline.
        uint256 profitBefore = IERC20(loanToken).balanceOf(address(this));

        // Run the chain. leg[0] consumes `loanAmount`; subsequent legs
        // either useFullBalance (typical) or carry an explicit
        // `amountIn` (e.g. when the bot wants to retain some
        // intermediate token on the contract).
        for (uint256 i = 0; i < plan.legs.length; ++i) {
            SwapLeg memory leg = plan.legs[i];
            uint256 amountIn;
            if (i == 0) {
                amountIn = plan.loanAmount;
            } else if (leg.useFullBalance) {
                amountIn = IERC20(leg.srcToken).balanceOf(address(this));
            } else {
                amountIn = leg.amountIn;
            }
            uint256 outBefore = IERC20(leg.repayToken).balanceOf(address(this));
            _dispatchLeg(leg, amountIn, outBefore);
        }

        // Realized profit (loanToken-denominated, net of flash repay).
        uint256 realizedProfit =
            CoinbasePaymentLib.computeRealizedProfit(loanToken, loanToken, profitBefore, plan.loanAmount, flashRepay);

        // Optional coinbase bribe.
        uint256 coinbasePaid;
        if (plan.coinbaseBps > 0) {
            coinbasePaid = realizedProfit * plan.coinbaseBps / 10_000;
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

        emit ArbExecuted(_activePlanHash, loanToken, realizedProfit, coinbasePaid);
    }

    /// @dev Mode → library router. V4 is rejected here (no
    /// `unlockCallback` infrastructure in this contract — V4 legs
    /// would never validate past `SwapValidationLib.validateNonV4Leg`
    /// either, but the inline reject is defense-in-depth).
    function _dispatchLeg(SwapLeg memory leg, uint256 amountIn, uint256 outBefore) internal {
        SwapMode m = leg.mode;
        if (m == SwapMode.PARASWAP_SINGLE) {
            SwapLegExecutorLib.executeParaswapLeg(leg, paraswapAugustusV6);
        } else if (m == SwapMode.BEBOP_MULTI) {
            SwapLegExecutorLib.executeBebopLeg(leg, outBefore, allowedTargets[leg.bebopTarget]);
        } else if (m == SwapMode.UNI_V2 || m == SwapMode.UNI_V2_BUY) {
            UniswapLib.executeUniV2Leg(leg, amountIn, uniV2Router);
        } else if (m == SwapMode.UNI_V3 || m == SwapMode.UNI_V3_BUY) {
            UniswapLib.executeUniV3Leg(leg, amountIn, uniV3Router);
        } else if (m == SwapMode.CURVE_V1 || m == SwapMode.CURVE_V1_BUY) {
            CurveV1Lib.executeLeg(leg, amountIn);
        } else if (m == SwapMode.BAL_V2 || m == SwapMode.BAL_V2_BUY) {
            BalancerV2Lib.executeLeg(leg, amountIn);
        } else {
            // NO_SWAP doesn't make sense in arb (no liquidation step to
            // settle the same-token path); V4 not supported. Reject.
            revert InvalidSwapMode();
        }
    }
}
