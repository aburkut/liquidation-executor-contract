// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {MarketParams} from "../src/interfaces/IMorphoBlue.sol";
import {IFlashLoanRecipient} from "../src/interfaces/IBalancerVault.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";
import {MockAaveV2LendingPool} from "./mocks/MockAaveV2LendingPool.sol";

contract ExecutorTest is Test {
    LiquidationExecutor public executor;

    MockERC20 public loanToken;
    MockERC20 public collateralToken;

    MockAavePool public aavePool;
    MockMorphoBlue public morphoBlue;
    MockBalancerVault public balancerVault;
    MockParaswapAugustus public augustus;
    MockAaveV2LendingPool public aaveV2Pool;

    address public owner = address(0xA11CE);
    address public operatorAddr = address(0xB0B);
    address public attacker = address(0xDEAD);

    uint256 constant LOAN_AMOUNT = 1000e18;
    uint256 constant FLASH_FEE = 1e18;
    uint256 constant SWAP_RATE = 1.1e18; // 10% gain
    uint256 constant MIN_PROFIT = 5e18;
    uint256 constant COLLATERAL_REWARD = 600e18;

    // Valid Paraswap selector (must pass selector validation)
    bytes4 constant VALID_SWAP_SELECTOR = ISwapRouter.exactInputSingle.selector;

    function setUp() public {
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18);

        aavePool = new MockAavePool(FLASH_FEE);
        morphoBlue = new MockMorphoBlue();
        balancerVault = new MockBalancerVault(FLASH_FEE);
        augustus = new MockParaswapAugustus(SWAP_RATE);
        aaveV2Pool = new MockAaveV2LendingPool(COLLATERAL_REWARD);

        address[] memory targets = new address[](4);
        targets[0] = address(aavePool);
        targets[1] = address(morphoBlue);
        targets[2] = address(augustus);
        targets[3] = address(aaveV2Pool);

        executor = new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);

        vm.startPrank(owner);
        executor.setOperator(operatorAddr);
        executor.setMorphoBlue(address(morphoBlue));
        executor.setUniswapV3Router(address(0x1)); // placeholder, not used by new swap
        executor.setAaveV2LendingPool(address(aaveV2Pool));

        executor.setFlashProvider(1, address(aavePool));
        executor.setFlashProvider(2, address(balancerVault));
        vm.stopPrank();

        // Fund pools
        loanToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(balancerVault), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18); // Augustus needs loanToken for same-token swaps
        collateralToken.mint(address(augustus), 100_000e18);
        loanToken.mint(address(executor), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(executor), 1000e18); // Pre-fund for repay actions
        collateralToken.mint(address(morphoBlue), 100_000e18);
        collateralToken.mint(address(aaveV2Pool), 100_000e18);
        loanToken.mint(address(aaveV2Pool), 100_000e18);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _buildParaswapCalldata(address srcToken, address dstToken, uint256 amountIn)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(VALID_SWAP_SELECTOR, srcToken, dstToken, amountIn);
    }

    function _buildSwapSpec(address srcToken, address dstToken, uint256 amountIn, uint256 minAmountOut)
        internal
        pure
        returns (LiquidationExecutor.SwapSpec memory)
    {
        return LiquidationExecutor.SwapSpec({
            srcToken: srcToken,
            dstToken: dstToken,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            paraswapCalldata: _buildParaswapCalldata(srcToken, dstToken, amountIn)
        });
    }

    function _buildAaveV3RepayAction(address asset, uint256 amount, address onBehalfOf)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 1,
                asset: asset,
                amount: amount,
                interestRateMode: 2,
                onBehalfOf: onBehalfOf,
                collateralAsset: address(0),
                debtAsset: address(0),
                user: address(0),
                debtToCover: 0,
                receiveAToken: false
            })
        );
    }

    function _buildAaveV3LiquidationAction(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 4,
                asset: address(0),
                amount: 0,
                interestRateMode: 0,
                onBehalfOf: address(0),
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                user: user,
                debtToCover: debtToCover,
                receiveAToken: receiveAToken
            })
        );
    }

    function _buildMorphoRepayAction(address lToken, address collToken, uint256 assets, address onBehalfOf)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            LiquidationExecutor.MorphoBlueAction({
                actionType: 1,
                marketParams: MarketParams({
                    loanToken: lToken, collateralToken: collToken, oracle: address(0x1), irm: address(0x2), lltv: 0.8e18
                }),
                assets: assets,
                shares: 0,
                onBehalfOf: onBehalfOf
            })
        );
    }

    function _buildAaveV2LiquidationAction(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.AaveV2Liquidation({
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                user: user,
                debtToCover: debtToCover,
                receiveAToken: receiveAToken
            })
        );
    }

    function _buildPlan(
        uint8 flashProviderId,
        address lToken,
        uint256 loanAmount,
        uint256 maxFlashFee,
        uint8 targetProtocolId,
        bytes memory targetActionData,
        LiquidationExecutor.SwapSpec memory swapSpec,
        address profitTkn,
        uint256 minProfitAmt
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.Plan({
                flashProviderId: flashProviderId,
                loanToken: lToken,
                loanAmount: loanAmount,
                maxFlashFee: maxFlashFee,
                targetProtocolId: targetProtocolId,
                targetActionData: targetActionData,
                swapSpec: swapSpec,
                profitToken: profitTkn,
                minProfit: minProfitAmt
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // ACCESS CONTROL (preserved from original)
    // ═══════════════════════════════════════════════════════════════════

    function test_onlyOwnerCanSetOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setOperator(attacker);
    }

    function test_onlyOwnerCanSetMorphoBlue() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setMorphoBlue(address(0x123));
    }

    function test_onlyOwnerCanSetAaveV2LendingPool() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setAaveV2LendingPool(address(0x123));
    }

    function test_onlyOwnerCanPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.pause();
    }

    function test_onlyOwnerCanUnpause() public {
        vm.prank(owner);
        executor.pause();
        vm.prank(attacker);
        vm.expectRevert();
        executor.unpause();
    }

    function test_onlyOperatorCanExecute() public {
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.Unauthorized.selector);
        executor.execute(plan);
    }

    function test_setOperatorZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setOperator(address(0));
    }

    function test_ownerCanSetOperator() public {
        address newOp = address(0xCAFE);
        vm.prank(owner);
        executor.setOperator(newOp);
        assertEq(executor.operator(), newOp);
    }

    function test_ownable2Step() public {
        address newOwner = address(0xBEEF);
        vm.prank(owner);
        executor.transferOwnership(newOwner);
        assertEq(executor.owner(), owner);
        vm.prank(newOwner);
        executor.acceptOwnership();
        assertEq(executor.owner(), newOwner);
    }

    function test_constructorRevertsOnZeroOwner() public {
        address[] memory targets = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LiquidationExecutor(address(0), address(1), address(2), address(3), targets);
    }

    function test_rescueERC20() public {
        uint256 amt = 50e18;
        loanToken.mint(address(executor), amt);
        uint256 before = loanToken.balanceOf(owner);
        vm.prank(owner);
        executor.rescueERC20(address(loanToken), owner, amt);
        assertEq(loanToken.balanceOf(owner) - before, amt);
    }

    function test_rescueETH() public {
        vm.deal(address(executor), 1 ether);
        uint256 before = owner.balance;
        vm.prank(owner);
        executor.rescueETH(payable(owner), 1 ether);
        assertEq(owner.balance - before, 1 ether);
    }

    function test_onlyOwnerCanRescueERC20() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueERC20(address(loanToken), attacker, 1);
    }

    function test_onlyOwnerCanRescueETH() public {
        vm.deal(address(executor), 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueETH(payable(attacker), 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSE BLOCKS EXECUTE FOR ALL PROVIDERS
    // ═══════════════════════════════════════════════════════════════════

    function test_pauseBlocksExecuteAaveV3() public {
        vm.prank(owner);
        executor.pause();

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_pauseBlocksExecuteBalancer() public {
        vm.prank(owner);
        executor.pause();

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // AAVE V3 FLASH + PARASWAP + AAVE V3 REPAY (happy path)
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV3Flash_paraswap_aaveV3Repay() public {
        uint256 repayAmt = 500e18;
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), repayAmt, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            MIN_PROFIT
        );

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGe(loanAfter - loanBefore, MIN_PROFIT);

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // AAVE V3 FLASH + PARASWAP + MORPHO REPAY (cross-protocol)
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV3Flash_paraswap_morphoRepay() public {
        uint256 repayAmt = 500e18;
        bytes memory targetAction =
            _buildMorphoRepayAction(address(collateralToken), address(loanToken), repayAmt, address(0x1234));
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            2,
            targetAction,
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            MIN_PROFIT
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
        assertEq(collateralToken.allowance(address(executor), address(morphoBlue)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BALANCER FLASH HAPPY PATH
    // ═══════════════════════════════════════════════════════════════════

    function test_balancerFlash_paraswap_aaveV3Repay() public {
        uint256 repayAmt = 500e18;
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), repayAmt, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            MIN_PROFIT
        );

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGe(loanAfter - loanBefore, MIN_PROFIT);

        // Balancer doesn't use approval (safeTransfer), but check Augustus approval reset
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0);
    }

    function test_balancerFlash_approvalHygiene() public {
        uint256 repayAmt = 500e18;
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), repayAmt, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
        assertEq(loanToken.allowance(address(executor), address(balancerVault)), 0);
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0);
        assertEq(collateralToken.allowance(address(executor), address(balancerVault)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BALANCER CALLBACK VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_balancerCallbackRejectsWrongCaller() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(loanToken));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN_AMOUNT;
        uint256[] memory fees = new uint256[](1);
        fees[0] = FLASH_FEE;

        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.InvalidCallbackCaller.selector);
        executor.receiveFlashLoan(tokens, amounts, fees, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    // AAVE V3 CALLBACK VALIDATION (preserved + extended)
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV3CallbackRejectsWrongCaller() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.InvalidCallbackCaller.selector);
        executor.executeOperation(address(loanToken), LOAN_AMOUNT, FLASH_FEE, address(executor), "");
    }

    function test_aaveV3CallbackRejectsWrongInitiator() public {
        vm.prank(address(aavePool));
        vm.expectRevert(LiquidationExecutor.InvalidInitiator.selector);
        executor.executeOperation(address(loanToken), LOAN_AMOUNT, FLASH_FEE, attacker, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARASWAP SWAP GATING
    // ═══════════════════════════════════════════════════════════════════

    function test_paraswapMinAmountOutRevert() public {
        // Set rate low: with same-token swap, net output will underflow
        augustus.setRate(0.5e18);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 200e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 900e18),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(); // arithmetic underflow or InsufficientSwapOutput
        executor.execute(plan);
    }

    function test_paraswapApprovalResetAfterSwap() public {
        uint256 repayAmt = 500e18;
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), repayAmt, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_paraswapSwapFailReverts() public {
        augustus.setSwapReverts(true);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(); // SwapFailed
        executor.execute(plan);

        // Approvals zero after revert
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // AAVE V2 LIQUIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV2Liquidation_happyPath() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        loanToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 debtToCover = 500e18;
        bytes memory targetAction = _buildAaveV2LiquidationAction(
            address(loanToken), // collateral received
            address(collateralToken), // debt paid
            address(0x1234), // user
            debtToCover,
            false
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            3,
            targetAction,
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Approval hygiene
        assertEq(collateralToken.allowance(address(executor), address(aaveV2Pool)), 0);
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_aaveV2Liquidation_approvalReset() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        loanToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 debtToCover = 500e18;
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            3,
            _buildAaveV2LiquidationAction(
                address(loanToken), address(collateralToken), address(0x1234), debtToCover, false
            ),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(collateralToken.allowance(address(executor), address(aaveV2Pool)), 0);
    }

    function test_aaveV2Liquidation_reverts() public {
        aaveV2Pool.setLiquidationReverts(true);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            3,
            _buildAaveV2LiquidationAction(address(loanToken), address(collateralToken), address(0x1234), 500e18, false),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PROFIT GATE
    // ═══════════════════════════════════════════════════════════════════

    function test_profitGateRevertsIfBelowMinimum() public {
        // With rate 1.1, swap net = 100 LOAN. After fee, effectiveProfit ≈ 99 LOAN.
        // Set minProfit impossibly high.
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 400e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            500e18
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_profitGateSucceedsIfMeetsMinimum() public {
        uint256 repayAmt = 500e18;
        // Swap net = 100 LOAN. effectiveProfit = 99 LOAN (100 - 1 fee).
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), repayAmt, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            99e18
        );
        vm.prank(operatorAddr);
        executor.execute(plan); // should not revert
    }

    function test_profitGateWithBalancerProvider() public {
        // effectiveProfit ≈ 99 LOAN. Set minProfit impossibly high.
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 100e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            999e18 // impossibly high
        );
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEE CAP
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV3FeeCap() public {
        aavePool.setFlashFee(100e18);
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            1e18,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.FlashFeeExceeded.selector, 100e18, 1e18));
        executor.execute(plan);
    }

    function test_balancerFeeCap() public {
        balancerVault.setFlashFee(100e18);
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            1e18,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.FlashFeeExceeded.selector, 100e18, 1e18));
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 SAFETY: CALLBACK ASSET/AMOUNT MISMATCH
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV3CallbackRejectsAssetMismatch() public {
        MockAavePoolLiar liarPool = new MockAavePoolLiar(FLASH_FEE, address(collateralToken));
        collateralToken.mint(address(liarPool), 100_000e18);
        loanToken.mint(address(liarPool), 100_000e18);

        vm.startPrank(owner);
        executor.setFlashProvider(1, address(liarPool));
        vm.stopPrank();

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAssetMismatch.selector);
        executor.execute(plan);

        // Restore
        vm.prank(owner);
        executor.setFlashProvider(1, address(aavePool));
    }

    function test_aaveV3CallbackRejectsAmountMismatch() public {
        MockAavePoolAmountLiar liarPool = new MockAavePoolAmountLiar(FLASH_FEE);
        loanToken.mint(address(liarPool), 100_000e18);

        vm.startPrank(owner);
        executor.setFlashProvider(1, address(liarPool));
        vm.stopPrank();

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAmountMismatch.selector);
        executor.execute(plan);

        vm.prank(owner);
        executor.setFlashProvider(1, address(aavePool));
    }

    function test_balancerCallbackRejectsTokenMismatch() public {
        MockBalancerVaultLiar liarVault =
            new MockBalancerVaultLiar(FLASH_FEE, address(loanToken), address(collateralToken));
        loanToken.mint(address(liarVault), 100_000e18);
        collateralToken.mint(address(liarVault), 100_000e18);

        vm.startPrank(owner);
        executor.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAssetMismatch.selector);
        executor.execute(plan);

        vm.prank(owner);
        executor.setFlashProvider(2, address(balancerVault));
    }

    function test_balancerCallbackRejectsAmountMismatch() public {
        MockBalancerVaultAmountLiar liarVault = new MockBalancerVaultAmountLiar(FLASH_FEE);
        loanToken.mint(address(liarVault), 100_000e18);

        vm.startPrank(owner);
        executor.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAmountMismatch.selector);
        executor.execute(plan);

        vm.prank(owner);
        executor.setFlashProvider(2, address(balancerVault));
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARTIAL FAILURE (swap/repay fails => whole tx reverts)
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveRepayFailsWholeTxReverts() public {
        aavePool.setRepayReverts(true);
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );

        uint256 before = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
        assertEq(loanToken.balanceOf(address(executor)), before);
    }

    function test_morphoRepayFailsWholeTxReverts() public {
        morphoBlue.setRepayReverts(true);
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            2,
            _buildMorphoRepayAction(address(collateralToken), address(loanToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FLASH PROVIDER VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfFlashProviderNotConfigured() public {
        bytes memory plan = _buildPlan(
            99,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.FlashProviderNotAllowed.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVALID PLAN FIELDS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfLoanAmountZero() public {
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            0,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), 0, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_revertIfLoanTokenZeroAddress() public {
        bytes memory plan = _buildPlan(
            1,
            address(0),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.execute(plan);
    }

    function test_revertIfInvalidProtocolId() public {
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            99,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONFIG ZERO ADDRESS CHECKS
    // ═══════════════════════════════════════════════════════════════════

    function test_setMorphoBlueZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setMorphoBlue(address(0));
    }

    function test_setAaveV2LendingPoolZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setAaveV2LendingPool(address(0));
    }

    function test_setUniswapV3RouterZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setUniswapV3Router(address(0));
    }

    function test_setFlashProviderZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setFlashProvider(1, address(0));
    }

    function test_rescueERC20ZeroToReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueERC20(address(loanToken), address(0), 1);
    }

    function test_rescueETHZeroToReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueETH(payable(address(0)), 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // EVENT EMISSION
    // ═══════════════════════════════════════════════════════════════════

    function test_emitsFlashExecutedBalancer() public {
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectEmit(true, true, false, true);
        emit LiquidationExecutor.FlashExecuted(2, address(loanToken), LOAN_AMOUNT);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 REGRESSION: Aave V3 profit gate when profitToken == loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_aave_profit_token_equals_loan_token_profit_gate_works() public {
        // Clear executor balance and set precisely to 50 LOAN + 600 COLL
        uint256 currentBal = loanToken.balanceOf(address(executor));
        if (currentBal > 0) {
            vm.prank(address(executor));
            loanToken.transfer(address(1), currentBal);
        }
        uint256 currentColl = collateralToken.balanceOf(address(executor));
        if (currentColl > 0) {
            vm.prank(address(executor));
            collateralToken.transfer(address(1), currentColl);
        }
        uint256 executorInitialLoan = 50e18;
        loanToken.mint(address(executor), executorInitialLoan);
        collateralToken.mint(address(executor), 600e18); // for V2 liq debt payment

        aaveV2Pool.setCollateralReward(600e18);
        loanToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 swapAmountIn = 500e18;
        bytes memory targetAction = _buildAaveV2LiquidationAction(
            address(loanToken), // collateralAsset (received)
            address(collateralToken), // debtAsset (paid)
            address(0x1234),
            550e18, // debtToCover
            false
        );

        // Flow: flash 1000 LOAN, swap 500 LOAN -> 550 LOAN (net +50), V2 liq pays 550 COLL gets 600 LOAN
        // profitBefore = 50 + 1000 = 1050
        // After swap: 1050 - 500 + 550 = 1100
        // After V2 liq: 1100 + 600 = 1700
        // profitAfter = 1700
        // effectiveProfit = 1700 + 1000 - 1050 - 1001 = 649
        uint256 expectedProfit = 649e18;
        bytes memory plan = _buildPlan(
            1, // Aave V3
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            3, // Aave V2 protocol
            targetAction,
            _buildSwapSpec(address(loanToken), address(loanToken), swapAmountIn, 0),
            address(loanToken), // profitToken == loanToken
            expectedProfit // minProfit
        );

        vm.prank(operatorAddr);
        executor.execute(plan); // must not revert

        // Verify net gain
        uint256 finalBal = loanToken.balanceOf(address(executor));
        assertGe(finalBal - executorInitialLoan, expectedProfit);

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 REGRESSION: Balancer profit gate when profitToken == loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_balancer_profit_token_equals_loan_token_profit_gate_works() public {
        uint256 flashFee = 5e18;
        balancerVault.setFlashFee(flashFee);

        // Clear executor balance and set precisely
        uint256 currentBal = loanToken.balanceOf(address(executor));
        if (currentBal > 0) {
            vm.prank(address(executor));
            loanToken.transfer(address(1), currentBal);
        }
        uint256 currentColl = collateralToken.balanceOf(address(executor));
        if (currentColl > 0) {
            vm.prank(address(executor));
            collateralToken.transfer(address(1), currentColl);
        }
        uint256 executorInitialLoan = 50e18;
        loanToken.mint(address(executor), executorInitialLoan);
        collateralToken.mint(address(executor), 600e18); // for V2 liq debt payment

        aaveV2Pool.setCollateralReward(600e18);
        loanToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 swapAmountIn = 500e18;
        bytes memory targetAction = _buildAaveV2LiquidationAction(
            address(loanToken), // collateral received
            address(collateralToken), // debt paid
            address(0x1234),
            550e18, // debtToCover
            false
        );

        // Flow: flash 1000 LOAN (fee=5), swap 500 LOAN -> 550 LOAN (net +50),
        // V2 liq: pay 550 COLL, get 600 LOAN
        // profitBefore = 50 + 1000 = 1050
        // After swap: 1050 - 500 + 550 = 1100
        // After V2 liq: 1100 + 600 = 1700
        // Transfer 1005 to Balancer: 695
        // profitAfter = 695
        // effectiveProfit = 695 + 1000 - 1050 = 645
        uint256 netGain = 645e18;
        bytes memory plan = _buildPlan(
            2, // Balancer
            address(loanToken),
            LOAN_AMOUNT,
            flashFee,
            3, // Aave V2
            targetAction,
            _buildSwapSpec(address(loanToken), address(loanToken), swapAmountIn, 0),
            address(loanToken), // profitToken == loanToken
            netGain // minProfit
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Verify profit
        uint256 finalBal = loanToken.balanceOf(address(executor));
        assertGe(finalBal - executorInitialLoan, netGain - 1); // allow 1 wei rounding

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEATURE: Aave V3 liquidation
    // ═══════════════════════════════════════════════════════════════════

    function test_aave_v3_liquidation_executes_and_resets_allowance() public {
        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        loanToken.mint(address(aavePool), 100_000e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(loanToken), // collateralAsset (received)
            address(collateralToken), // debtAsset (paid)
            address(0x1234), // user being liquidated
            debtToCover,
            false
        );

        bytes memory plan = _buildPlan(
            1, // Aave V3 flash
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1, // protocolId = Aave V3
            targetAction,
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken), // profit in loanToken
            0 // minProfit
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Assert allowance reset for debtAsset -> aavePool
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0);
        // Assert allowance reset for swap
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // EVENT EMISSION (preserved)
    // ═══════════════════════════════════════════════════════════════════

    function test_emitsLiquidationExecuted() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        loanToken.mint(address(aaveV2Pool), 100_000e18);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            3,
            _buildAaveV2LiquidationAction(address(loanToken), address(collateralToken), address(0x1234), 500e18, false),
            _buildSwapSpec(address(loanToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectEmit(true, true, true, true);
        emit LiquidationExecutor.LiquidationExecuted(3, address(loanToken), address(collateralToken), 500e18);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP INVARIANTS: srcToken and dstToken must equal loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfSwapSrcTokenNotLoanToken() public {
        // loanToken = loanToken, swapSpec.srcToken = collateralToken → INVALID_SWAP_SRC
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(collateralToken), address(loanToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_SWAP_SRC");
        executor.execute(plan);
    }

    function test_revertIfSwapDstTokenNotLoanToken() public {
        // loanToken = loanToken, swapSpec.dstToken = collateralToken → INVALID_SWAP_DST
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapSpec(address(loanToken), address(collateralToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_SWAP_DST");
        executor.execute(plan);
    }

    function test_revertIfInvalidParaswapSelector() public {
        // Build calldata with invalid selector
        bytes4 rugSelector = bytes4(keccak256("rug(address)"));
        bytes memory badCalldata =
            abi.encodeWithSelector(rugSelector, address(loanToken), address(loanToken), LOAN_AMOUNT);

        LiquidationExecutor.SwapSpec memory swapSpec = LiquidationExecutor.SwapSpec({
            srcToken: address(loanToken),
            dstToken: address(loanToken),
            amountIn: LOAN_AMOUNT,
            minAmountOut: 0,
            paraswapCalldata: badCalldata
        });

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234)),
            swapSpec,
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_SWAP_SELECTOR");
        executor.execute(plan);
    }
}

// ═══════════════════════════════════════════════════════════════════
// HELPER MOCK: Aave Pool that lies about asset in callback
// ═══════════════════════════════════════════════════════════════════

import {IFlashLoanSimpleReceiver} from "../src/interfaces/IAaveV3Pool.sol";

contract MockAavePoolLiar {
    using SafeERC20 for IERC20;
    uint256 public flashFee;
    address public fakeAsset; // lies about this asset in callback

    constructor(uint256 _fee, address _fakeAsset) {
        flashFee = _fee;
        fakeAsset = _fakeAsset;
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        IERC20(asset).safeTransfer(receiver, amount);
        // Call back with WRONG asset
        IFlashLoanSimpleReceiver(receiver).executeOperation(fakeAsset, amount, flashFee, receiver, params);
        IERC20(asset).safeTransferFrom(receiver, address(this), amount + flashFee);
    }
}

// ═══════════════════════════════════════════════════════════════════
// HELPER MOCK: Aave Pool that lies about amount in callback
// ═══════════════════════════════════════════════════════════════════

contract MockAavePoolAmountLiar {
    using SafeERC20 for IERC20;
    uint256 public flashFee;

    constructor(uint256 _fee) {
        flashFee = _fee;
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        IERC20(asset).safeTransfer(receiver, amount);
        // Call back with WRONG amount
        IFlashLoanSimpleReceiver(receiver).executeOperation(asset, amount + 1, flashFee, receiver, params);
        IERC20(asset).safeTransferFrom(receiver, address(this), amount + flashFee);
    }
}

// ═══════════════════════════════════════════════════════════════════
// HELPER MOCK: Balancer Vault that lies about token in callback
// ═══════════════════════════════════════════════════════════════════

contract MockBalancerVaultLiar {
    using SafeERC20 for IERC20;
    uint256 public flashFee;
    address public realToken;
    address public fakeToken;

    constructor(uint256 _fee, address _real, address _fake) {
        flashFee = _fee;
        realToken = _real;
        fakeToken = _fake;
    }

    function flashLoan(address recipient, IERC20[] memory, uint256[] memory amounts, bytes memory userData) external {
        IERC20(realToken).safeTransfer(recipient, amounts[0]);
        // Callback with wrong token
        IERC20[] memory fakeTokens = new IERC20[](1);
        fakeTokens[0] = IERC20(fakeToken);
        uint256[] memory feeAmounts = new uint256[](1);
        feeAmounts[0] = flashFee;
        IFlashLoanRecipient(recipient).receiveFlashLoan(fakeTokens, amounts, feeAmounts, userData);
    }
}

// ═══════════════════════════════════════════════════════════════════
// HELPER MOCK: Balancer Vault that lies about amount in callback
// ═══════════════════════════════════════════════════════════════════

contract MockBalancerVaultAmountLiar {
    using SafeERC20 for IERC20;
    uint256 public flashFee;

    constructor(uint256 _fee) {
        flashFee = _fee;
    }

    function flashLoan(address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external
    {
        tokens[0].safeTransfer(recipient, amounts[0]);
        // Callback with wrong amount
        uint256[] memory fakeAmounts = new uint256[](1);
        fakeAmounts[0] = amounts[0] + 1;
        uint256[] memory feeAmounts = new uint256[](1);
        feeAmounts[0] = flashFee;
        IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, fakeAmounts, feeAmounts, userData);
    }
}
