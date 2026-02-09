// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MarketParams} from "../src/interfaces/IMorphoBlue.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract ExecutorTest is Test {
    LiquidationExecutor public executor;

    MockERC20 public loanToken;
    MockERC20 public collateralToken;
    MockERC20 public profitToken;

    MockAavePool public aavePool;
    MockMorphoBlue public morphoBlue;
    MockSwapRouter public swapRouter;

    address public owner = address(0xA11CE);
    address public operatorAddr = address(0xB0B);
    address public attacker = address(0xDEAD);

    uint256 constant LOAN_AMOUNT = 1000e18;
    uint256 constant FLASH_FEE = 1e18; // 1 token fee
    uint256 constant SWAP_RATE = 1.1e18; // 10% gain on swap
    uint256 constant MIN_PROFIT = 5e18;

    function setUp() public {
        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18);
        profitToken = collateralToken; // profit measured in collateral for most tests

        // Deploy mocks
        aavePool = new MockAavePool(FLASH_FEE);
        morphoBlue = new MockMorphoBlue();
        swapRouter = new MockSwapRouter(SWAP_RATE, address(collateralToken));

        // Deploy executor
        executor = new LiquidationExecutor(owner);

        // Configure executor
        vm.startPrank(owner);
        executor.setOperator(operatorAddr);
        executor.setAavePool(address(aavePool));
        executor.setMorphoBlue(address(morphoBlue));
        executor.setUniswapV3Router(address(swapRouter));

        // Flash providers
        executor.setFlashProvider(1, address(aavePool));

        // Allowlists
        executor.setAssetAllowed(address(loanToken), true);
        executor.setAssetAllowed(address(collateralToken), true);
        executor.setTargetAllowed(address(aavePool), true);
        executor.setTargetAllowed(address(morphoBlue), true);
        vm.stopPrank();

        // Fund the mock Aave pool with loan tokens for flashloan
        loanToken.mint(address(aavePool), 100_000e18);

        // Fund the mock swap router with collateral tokens for swap output
        collateralToken.mint(address(swapRouter), 100_000e18);

        // Fund the executor with loan tokens to cover flash fee + repay
        // After swap: executor has collateralTokens.
        // For Aave repay test: executor needs loanTokens to repay flashloan.
        // We'll fund the executor with enough to cover the flashloan repay.
        loanToken.mint(address(executor), LOAN_AMOUNT + FLASH_FEE + 100e18);

        // Fund morpho with collateral tokens for withdrawCollateral
        collateralToken.mint(address(morphoBlue), 100_000e18);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _buildSwapDataExactInputSingle(
        address tokenIn,
        address tokenOutAddr,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOutAddr,
            fee: 3000,
            recipient: recipient,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });
        return abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, params);
    }

    function _buildAaveRepayAction(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) internal pure returns (bytes memory) {
        LiquidationExecutor.AaveV3Action memory action = LiquidationExecutor.AaveV3Action({
            actionType: 1, // repay
            asset: asset,
            amount: amount,
            interestRateMode: 2, // variable
            onBehalfOf: onBehalfOf
        });
        return abi.encode(action);
    }

    function _buildMorphoRepayAction(
        address lToken,
        address collToken,
        uint256 assets,
        address onBehalfOf
    ) internal pure returns (bytes memory) {
        LiquidationExecutor.MorphoBlueAction memory action = LiquidationExecutor.MorphoBlueAction({
            actionType: 1, // repay
            marketParams: MarketParams({
                loanToken: lToken,
                collateralToken: collToken,
                oracle: address(0x1),
                irm: address(0x2),
                lltv: 0.8e18
            }),
            assets: assets,
            shares: 0,
            onBehalfOf: onBehalfOf
        });
        return abi.encode(action);
    }

    function _buildPlan(
        uint8 flashProviderId,
        address lToken,
        uint256 loanAmount,
        uint256 maxFlashFee,
        uint8 targetProtocolId,
        bytes memory targetActionData,
        bytes memory swapData,
        address profitTkn,
        uint256 minProfitAmt
    ) internal pure returns (bytes memory) {
        LiquidationExecutor.Plan memory plan = LiquidationExecutor.Plan({
            flashProviderId: flashProviderId,
            loanToken: lToken,
            loanAmount: loanAmount,
            maxFlashFee: maxFlashFee,
            targetProtocolId: targetProtocolId,
            targetActionData: targetActionData,
            swapData: swapData,
            profitToken: profitTkn,
            minProfit: minProfitAmt
        });
        return abi.encode(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_onlyOwnerCanSetOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setOperator(attacker);
    }

    function test_onlyOwnerCanSetAavePool() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setAavePool(address(0x123));
    }

    function test_onlyOwnerCanSetMorphoBlue() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setMorphoBlue(address(0x123));
    }

    function test_onlyOwnerCanSetUniswapV3Router() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setUniswapV3Router(address(0x123));
    }

    function test_onlyOwnerCanSetAssetAllowed() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setAssetAllowed(address(loanToken), false);
    }

    function test_onlyOwnerCanSetFlashProvider() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setFlashProvider(1, address(0x123));
    }

    function test_onlyOwnerCanSetTargetAllowed() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setTargetAllowed(address(0x123), true);
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
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.Unauthorized.selector);
        executor.execute(plan);
    }

    function test_pauseBlocksExecute() public {
        vm.prank(owner);
        executor.pause();

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_ownerCanSetOperator() public {
        address newOp = address(0xCAFE);
        vm.prank(owner);
        executor.setOperator(newOp);
        assertEq(executor.operator(), newOp);
    }

    function test_setOperatorZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setOperator(address(0));
    }

    function test_onlyOwnerCanRescueERC20() public {
        loanToken.mint(address(executor), 100e18);
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueERC20(address(loanToken), attacker, 100e18);
    }

    function test_onlyOwnerCanRescueETH() public {
        vm.deal(address(executor), 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueETH(payable(attacker), 1 ether);
    }

    function test_rescueERC20() public {
        uint256 rescueAmount = 50e18;
        loanToken.mint(address(executor), rescueAmount);
        uint256 before = loanToken.balanceOf(owner);
        vm.prank(owner);
        executor.rescueERC20(address(loanToken), owner, rescueAmount);
        assertEq(loanToken.balanceOf(owner) - before, rescueAmount);
    }

    function test_rescueETH() public {
        vm.deal(address(executor), 1 ether);
        uint256 before = owner.balance;
        vm.prank(owner);
        executor.rescueETH(payable(owner), 1 ether);
        assertEq(owner.balance - before, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // CALLBACK VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_callbackFromWrongCallerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.InvalidCallbackCaller.selector);
        executor.executeOperation(
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            address(executor),
            ""
        );
    }

    function test_callbackFromAavePoolButWrongInitiatorReverts() public {
        // First we need to set up the active plan hash by starting an execution
        // But we can test directly by calling from aavePool address
        vm.prank(address(aavePool));
        vm.expectRevert(LiquidationExecutor.InvalidInitiator.selector);
        executor.executeOperation(
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            attacker, // wrong initiator
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // SUCCESSFUL EXECUTION: AAVE V3 REPAY
    // ═══════════════════════════════════════════════════════════════════

    function test_successfulAaveV3RepayExecution() public {
        // Scenario: flashloan LOAN tokens -> swap LOAN to COLL -> repay COLL to Aave
        // After repay, profit is measured in COLL tokens.

        uint256 swapOutput = LOAN_AMOUNT * SWAP_RATE / 1e18; // 1100e18
        uint256 repayAmount = 500e18;
        uint256 expectedProfit = swapOutput - repayAmount; // 600e18

        bytes memory swapData = _buildSwapDataExactInputSingle(
            address(loanToken),
            address(collateralToken),
            LOAN_AMOUNT,
            0,
            address(executor),
            block.timestamp + 1000
        );

        bytes memory targetAction = _buildAaveRepayAction(
            address(collateralToken),
            repayAmount,
            address(0x1234) // some user position
        );

        bytes memory plan = _buildPlan(
            1,                         // Aave V3 flash provider
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,                // max flash fee
            1,                         // Aave V3 target
            targetAction,
            swapData,
            address(collateralToken),  // profit token
            MIN_PROFIT                 // min profit
        );

        uint256 collBefore = collateralToken.balanceOf(address(executor));

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Verify profit was retained
        uint256 collAfter = collateralToken.balanceOf(address(executor));
        assertGe(collAfter - collBefore, MIN_PROFIT, "Profit below minimum");

        // Verify no leftover approvals
        assertEq(loanToken.allowance(address(executor), address(swapRouter)), 0, "Swap router approval not reset");
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0, "Aave pool approval not reset");
    }

    // ═══════════════════════════════════════════════════════════════════
    // SUCCESSFUL EXECUTION: MORPHO BLUE REPAY
    // ═══════════════════════════════════════════════════════════════════

    function test_successfulMorphoBlueRepayExecution() public {
        // Scenario: flashloan LOAN tokens -> swap LOAN to COLL ->
        // repay COLL to Morpho (treating collateralToken as the morpho loanToken for this test)
        // In this mock scenario: we swap loanToken -> collateralToken,
        // then repay collateralToken to Morpho.

        uint256 swapOutput = LOAN_AMOUNT * SWAP_RATE / 1e18; // 1100e18
        uint256 repayAmount = 500e18;

        bytes memory swapData = _buildSwapDataExactInputSingle(
            address(loanToken),
            address(collateralToken),
            LOAN_AMOUNT,
            0,
            address(executor),
            block.timestamp + 1000
        );

        // For Morpho repay: loanToken in the market is collateralToken (the token we got from swap)
        bytes memory targetAction;
        {
            LiquidationExecutor.MorphoBlueAction memory action = LiquidationExecutor.MorphoBlueAction({
                actionType: 1,
                marketParams: MarketParams({
                    loanToken: address(collateralToken),     // Morpho market's loan token
                    collateralToken: address(loanToken),     // Morpho market's collateral
                    oracle: address(0x1),
                    irm: address(0x2),
                    lltv: 0.8e18
                }),
                assets: repayAmount,
                shares: 0,
                onBehalfOf: address(0x1234)
            });
            targetAction = abi.encode(action);
        }

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            2,                         // Morpho Blue target
            targetAction,
            swapData,
            address(collateralToken),
            MIN_PROFIT
        );

        uint256 collBefore = collateralToken.balanceOf(address(executor));

        vm.prank(operatorAddr);
        executor.execute(plan);

        uint256 collAfter = collateralToken.balanceOf(address(executor));
        assertGe(collAfter - collBefore, MIN_PROFIT, "Profit below minimum");

        // Verify no leftover approvals
        assertEq(loanToken.allowance(address(executor), address(swapRouter)), 0);
        assertEq(collateralToken.allowance(address(executor), address(morphoBlue)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // APPROVAL HYGIENE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_approvalHygieneAfterExecution() public {
        uint256 repayAmount = 500e18;

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), repayAmount, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // All approvals must be zero
        assertEq(loanToken.allowance(address(executor), address(swapRouter)), 0, "Router LOAN approval");
        assertEq(loanToken.allowance(address(executor), address(aavePool)), 0, "AavePool LOAN approval");
        assertEq(collateralToken.allowance(address(executor), address(swapRouter)), 0, "Router COLL approval");
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0, "AavePool COLL approval");
        assertEq(collateralToken.allowance(address(executor), address(morphoBlue)), 0, "Morpho COLL approval");
    }

    // ═══════════════════════════════════════════════════════════════════
    // PROFIT GATE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfProfitBelowMinimum() public {
        // Set swap rate very low so profit is insufficient
        swapRouter.setRate(0.5e18); // 50% of input
        uint256 repayAmount = 400e18;

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), repayAmount, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            500e18 // unreachable min profit
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_succeedIfProfitMeetsMinimum() public {
        uint256 repayAmount = 500e18;
        uint256 swapOutput = LOAN_AMOUNT * SWAP_RATE / 1e18; // 1100e18
        uint256 expectedProfit = swapOutput - repayAmount;   // 600e18

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), repayAmount, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            expectedProfit // exactly meets
        );

        vm.prank(operatorAddr);
        executor.execute(plan); // should not revert
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEE CAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfFlashFeeExceedsMax() public {
        aavePool.setFlashFee(100e18); // very high fee

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            1e18, // max fee = 1 token, but actual = 100
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.FlashFeeExceeded.selector, 100e18, 1e18)
        );
        executor.execute(plan);
    }

    function test_succeedIfFlashFeeWithinMax() public {
        aavePool.setFlashFee(0); // zero fee

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            1e18,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        executor.execute(plan); // should not revert
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP DECODING ENFORCEMENT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfSwapRecipientNotThis() public {
        // Malicious swap data with recipient = operator
        bytes memory maliciousSwapData = _buildSwapDataExactInputSingle(
            address(loanToken),
            address(collateralToken),
            LOAN_AMOUNT,
            0,
            operatorAddr, // WRONG: should be address(executor)
            block.timestamp + 1000
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            maliciousSwapData,
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.SwapRecipientInvalid.selector, operatorAddr)
        );
        executor.execute(plan);
    }

    function test_revertIfSwapDeadlineExpired() public {
        // Warp time forward
        vm.warp(block.timestamp + 10000);

        bytes memory swapData = _buildSwapDataExactInputSingle(
            address(loanToken),
            address(collateralToken),
            LOAN_AMOUNT,
            0,
            address(executor),
            1 // expired deadline
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            swapData,
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.SwapDeadlineInvalid.selector, 1)
        );
        executor.execute(plan);
    }

    function test_revertIfSwapAmountInMismatch() public {
        // Swap data has different amountIn than plan's loanAmount
        bytes memory swapData = _buildSwapDataExactInputSingle(
            address(loanToken),
            address(collateralToken),
            LOAN_AMOUNT + 1, // mismatched
            0,
            address(executor),
            block.timestamp + 1000
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            swapData,
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.SwapAmountInMismatch.selector, LOAN_AMOUNT, LOAN_AMOUNT + 1)
        );
        executor.execute(plan);
    }

    function test_revertIfSwapSelectorInvalid() public {
        // Random 4 bytes + garbage
        bytes memory badSwapData = abi.encodePacked(bytes4(0xdeadbeef), bytes32(0));

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            badSwapData,
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidSwapSelector.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARTIAL FAILURE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_swapFailsWholeTxReverts() public {
        swapRouter.setSwapReverts(true);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        // Record balances before
        uint256 loanBefore = loanToken.balanceOf(address(executor));
        uint256 collBefore = collateralToken.balanceOf(address(executor));

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);

        // Verify no state changes (tx reverted, so balances unchanged)
        assertEq(loanToken.balanceOf(address(executor)), loanBefore, "Loan token balance changed after revert");
        assertEq(collateralToken.balanceOf(address(executor)), collBefore, "Coll token balance changed after revert");

        // Approvals should be 0 (tx reverted so no approvals were set)
        assertEq(loanToken.allowance(address(executor), address(swapRouter)), 0);
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0);
    }

    function test_aaveRepayFailsWholeTxReverts() public {
        aavePool.setRepayReverts(true);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        uint256 loanBefore = loanToken.balanceOf(address(executor));

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);

        assertEq(loanToken.balanceOf(address(executor)), loanBefore);
        assertEq(loanToken.allowance(address(executor), address(swapRouter)), 0);
    }

    function test_morphoRepayFailsWholeTxReverts() public {
        morphoBlue.setRepayReverts(true);

        LiquidationExecutor.MorphoBlueAction memory action = LiquidationExecutor.MorphoBlueAction({
            actionType: 1,
            marketParams: MarketParams({
                loanToken: address(collateralToken),
                collateralToken: address(loanToken),
                oracle: address(0x1),
                irm: address(0x2),
                lltv: 0.8e18
            }),
            assets: 500e18,
            shares: 0,
            onBehalfOf: address(0x1234)
        });

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            2,
            abi.encode(action),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
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
            99, // non-existent provider
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.FlashProviderNotAllowed.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ASSET ALLOWLIST TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfLoanTokenNotAllowed() public {
        vm.prank(owner);
        executor.setAssetAllowed(address(loanToken), false);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.AssetNotAllowed.selector, address(loanToken)));
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVALID PLAN FIELDS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfLoanAmountZero() public {
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            0, // zero loan amount
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                0,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_revertIfLoanTokenZeroAddress() public {
        bytes memory plan = _buildPlan(
            1,
            address(0), // zero address
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
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
            99, // invalid protocol
            _buildAaveRepayAction(address(collateralToken), 500e18, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PROFIT TOKEN == LOAN TOKEN (edge case)
    // ═══════════════════════════════════════════════════════════════════

    function test_profitTokenIsLoanToken() public {
        // When profitToken == loanToken, profit accounts for flashloan repayment
        // Ensure executor has enough loanToken to repay flash + keep profit
        loanToken.mint(address(executor), 10_000e18);

        // Swap collateral back to loanToken scenario:
        // Use a separate mock approach: swap loanToken -> collateralToken -> then Morpho gives back loanToken
        // Simplify: just test that the profit calculation correctly subtracts repayAmount

        // For this test, make swapRouter output loanTokens
        MockSwapRouter swapRouter2 = new MockSwapRouter(SWAP_RATE, address(loanToken));
        loanToken.mint(address(swapRouter2), 100_000e18);

        vm.startPrank(owner);
        executor.setUniswapV3Router(address(swapRouter2));
        vm.stopPrank();

        uint256 repayAmount = 500e18;

        // Target action: Aave repay with loanToken
        bytes memory targetAction = _buildAaveRepayAction(
            address(loanToken),
            repayAmount,
            address(0x1234)
        );

        bytes memory swapData = _buildSwapDataExactInputSingle(
            address(loanToken),
            address(loanToken),
            LOAN_AMOUNT,
            0,
            address(executor),
            block.timestamp + 1000
        );

        // swapOutput = 1100e18 loanTokens
        // After Aave repay: -500e18 loanTokens
        // Net change in loanToken from operations: +1100 - 500 = +600
        // But we also need to repay flash: -(1000 + 1) = -1001
        // effectiveProfit = (balanceAfter - balanceBefore - repayAmount_flash)
        // Since profitToken == asset: effectiveProfit = change - repayAmount
        // We have enough initial balance to cover everything.

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            targetAction,
            swapData,
            address(loanToken), // profit measured in loan token
            0                   // min profit = 0 for this edge case test
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Verify approvals reset
        assertEq(loanToken.allowance(address(executor), address(swapRouter2)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // OWNABLE 2-STEP
    // ═══════════════════════════════════════════════════════════════════

    function test_ownable2Step() public {
        address newOwner = address(0xBEEF);

        vm.prank(owner);
        executor.transferOwnership(newOwner);

        // Not yet accepted
        assertEq(executor.owner(), owner);

        vm.prank(newOwner);
        executor.acceptOwnership();

        assertEq(executor.owner(), newOwner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // EVENT EMISSION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_emitsOperatorUpdated() public {
        address newOp = address(0xCAFE);
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit LiquidationExecutor.OperatorUpdated(operatorAddr, newOp);
        executor.setOperator(newOp);
    }

    function test_emitsAssetAllowed() public {
        address token = address(0x999);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LiquidationExecutor.AssetAllowed(token, true);
        executor.setAssetAllowed(token, true);
    }

    function test_emitsFlashExecuted() public {
        uint256 repayAmount = 500e18;

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            1,
            _buildAaveRepayAction(address(collateralToken), repayAmount, address(0x1234)),
            _buildSwapDataExactInputSingle(
                address(loanToken),
                address(collateralToken),
                LOAN_AMOUNT,
                0,
                address(executor),
                block.timestamp + 1000
            ),
            address(collateralToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectEmit(true, true, false, true);
        emit LiquidationExecutor.FlashExecuted(1, address(loanToken), LOAN_AMOUNT);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_constructorRevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LiquidationExecutor(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONFIG ZERO ADDRESS CHECKS
    // ═══════════════════════════════════════════════════════════════════

    function test_setAavePoolZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setAavePool(address(0));
    }

    function test_setMorphoBlueZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setMorphoBlue(address(0));
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

    function test_setAssetAllowedZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setAssetAllowed(address(0), true);
    }

    function test_setTargetAllowedZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setTargetAllowed(address(0), true);
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
}
