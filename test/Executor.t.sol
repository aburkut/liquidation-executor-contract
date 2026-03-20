// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {MarketParams} from "../src/interfaces/IMorphoBlue.sol";
import {IFlashLoanRecipient} from "../src/interfaces/IBalancerVault.sol";
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

    bytes4 constant SWAP_EXACT_IN_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    );

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

    function _buildParaswapCalldata(address srcToken, address dstToken, uint256 amountIn, address beneficiary)
        internal
        pure
        returns (bytes memory)
    {
        // Encode as Paraswap Augustus V6 swapExactAmountIn with GenericData layout
        return abi.encodeWithSelector(
            SWAP_EXACT_IN_SELECTOR,
            address(0), // executor
            srcToken, // GenericData.srcToken
            dstToken, // GenericData.destToken
            amountIn, // GenericData.fromAmount
            uint256(0), // GenericData.toAmount
            uint256(0), // GenericData.quotedAmount
            bytes32(0), // GenericData.metadata
            beneficiary, // GenericData.beneficiary
            uint256(0), // partnerAndFee
            bytes(""), // permit
            bytes("") // executorData
        );
    }

    /// @dev Default overload: beneficiary = executor, deadline = block.timestamp + 1 hour
    function _buildSwapSpec(address srcToken, address dstToken, uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (LiquidationExecutor.SwapSpec memory)
    {
        return _buildSwapSpec(srcToken, dstToken, amountIn, minAmountOut, block.timestamp + 3600, address(executor));
    }

    function _buildSwapSpec(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address beneficiary
    ) internal pure returns (LiquidationExecutor.SwapSpec memory) {
        return LiquidationExecutor.SwapSpec({
            srcToken: srcToken,
            dstToken: dstToken,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            deadline: deadline,
            paraswapCalldata: _buildParaswapCalldata(srcToken, dstToken, amountIn, beneficiary)
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
        LiquidationExecutor.Action[] memory actions,
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
                actions: actions,
                swapSpec: swapSpec,
                profitToken: profitTkn,
                minProfit: minProfitAmt
            })
        );
    }

    /// @dev Convenience: wrap a single action into Action[]
    function _singleAction(uint8 protocolId, bytes memory data)
        internal
        pure
        returns (LiquidationExecutor.Action[] memory)
    {
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](1);
        actions[0] = LiquidationExecutor.Action({protocolId: protocolId, data: data});
        return actions;
    }

    /// @dev Default liquidation action + swap for tests that don't test the action itself.
    /// Uses collateralToken as collateral, loanToken as debt (correct roles).
    function _defaultLiqAction(uint256 debtToCover) internal view returns (LiquidationExecutor.Action[] memory) {
        return _singleAction(
            1,
            _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
            )
        );
    }

    function _defaultLiqSwap() internal view returns (LiquidationExecutor.SwapSpec memory) {
        return _buildSwapSpec(address(collateralToken), address(loanToken), COLLATERAL_REWARD, 0);
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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
            _defaultLiqAction(repayAmt),
            _defaultLiqSwap(),
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

    function test_morphoProtocolReverts() public {
        uint256 repayAmt = 500e18;
        bytes memory targetAction =
            _buildMorphoRepayAction(address(collateralToken), address(loanToken), repayAmt, address(0x1234));
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(2, targetAction),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_PROTOCOL");
        executor.execute(plan);
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
            _defaultLiqAction(repayAmt),
            _defaultLiqSwap(),
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
            _defaultLiqAction(repayAmt),
            _defaultLiqSwap(),
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
            _defaultLiqAction(200e18),
            _buildSwapSpec(address(collateralToken), address(loanToken), COLLATERAL_REWARD, 900e18),
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
            _defaultLiqAction(repayAmt),
            _defaultLiqSwap(),
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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
        collateralToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 debtToCover = 500e18;
        bytes memory targetAction = _buildAaveV2LiquidationAction(
            address(collateralToken), // collateral received
            address(loanToken), // debt paid — must match plan.loanToken
            address(0x1234),
            debtToCover,
            false
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(3, targetAction),
            _buildSwapSpec(address(collateralToken), address(loanToken), COLLATERAL_REWARD, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(aaveV2Pool)), 0);
        assertEq(collateralToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_aaveV2Liquidation_approvalReset() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        collateralToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 debtToCover = 500e18;
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                3,
                _buildAaveV2LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
                )
            ),
            _buildSwapSpec(address(collateralToken), address(loanToken), COLLATERAL_REWARD, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(loanToken.allowance(address(executor), address(aaveV2Pool)), 0);
    }

    function test_aaveV2Liquidation_reverts() public {
        aaveV2Pool.setLiquidationReverts(true);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                3,
                _buildAaveV2LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            _defaultLiqSwap(),
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
            _defaultLiqAction(400e18),
            _defaultLiqSwap(),
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
            _defaultLiqAction(repayAmt),
            _defaultLiqSwap(),
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
            _defaultLiqAction(100e18),
            _defaultLiqSwap(),
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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

        // Deploy a fresh executor with liarPool in allowedTargets
        address[] memory targets = new address[](5);
        targets[0] = address(aavePool);
        targets[1] = address(morphoBlue);
        targets[2] = address(augustus);
        targets[3] = address(aaveV2Pool);
        targets[4] = address(liarPool);
        LiquidationExecutor exec2 =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);

        vm.startPrank(owner);
        exec2.setOperator(operatorAddr);
        exec2.setFlashProvider(1, address(liarPool));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(exec2), 1000e18);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAssetMismatch.selector);
        exec2.execute(plan);
    }

    function test_aaveV3CallbackRejectsAmountMismatch() public {
        MockAavePoolAmountLiar liarPool = new MockAavePoolAmountLiar(FLASH_FEE);
        loanToken.mint(address(liarPool), 100_000e18);

        address[] memory targets = new address[](5);
        targets[0] = address(aavePool);
        targets[1] = address(morphoBlue);
        targets[2] = address(augustus);
        targets[3] = address(aaveV2Pool);
        targets[4] = address(liarPool);
        LiquidationExecutor exec2 =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);

        vm.startPrank(owner);
        exec2.setOperator(operatorAddr);
        exec2.setFlashProvider(1, address(liarPool));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAmountMismatch.selector);
        exec2.execute(plan);
    }

    function test_balancerCallbackRejectsTokenMismatch() public {
        MockBalancerVaultLiar liarVault =
            new MockBalancerVaultLiar(FLASH_FEE, address(loanToken), address(collateralToken));
        loanToken.mint(address(liarVault), 100_000e18);
        collateralToken.mint(address(liarVault), 100_000e18);

        address[] memory targets = new address[](5);
        targets[0] = address(aavePool);
        targets[1] = address(morphoBlue);
        targets[2] = address(augustus);
        targets[3] = address(aaveV2Pool);
        targets[4] = address(liarVault);
        LiquidationExecutor exec2 =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);

        vm.startPrank(owner);
        exec2.setOperator(operatorAddr);
        exec2.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(exec2), 1000e18);

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAssetMismatch.selector);
        exec2.execute(plan);
    }

    function test_balancerCallbackRejectsAmountMismatch() public {
        MockBalancerVaultAmountLiar liarVault = new MockBalancerVaultAmountLiar(FLASH_FEE);
        loanToken.mint(address(liarVault), 100_000e18);

        address[] memory targets = new address[](5);
        targets[0] = address(aavePool);
        targets[1] = address(morphoBlue);
        targets[2] = address(augustus);
        targets[3] = address(aaveV2Pool);
        targets[4] = address(liarVault);
        LiquidationExecutor exec2 =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);

        vm.startPrank(owner);
        exec2.setOperator(operatorAddr);
        exec2.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAmountMismatch.selector);
        exec2.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARTIAL FAILURE (swap/repay fails => whole tx reverts)
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveLiquidationFailsWholeTxReverts() public {
        aavePool.setLiquidationReverts(true);
        collateralToken.mint(address(aavePool), 100_000e18);
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_morphoRepayFailsWholeTxReverts() public {
        // Morpho protocol (id=2) is no longer supported — must revert at validation
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                2, _buildMorphoRepayAction(address(collateralToken), address(loanToken), 500e18, address(0x1234))
            ),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_PROTOCOL");
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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
            _defaultLiqAction(500e18),
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
            1, address(0), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultLiqSwap(), address(loanToken), 0
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
            _singleAction(
                99,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            _defaultLiqSwap(),
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

    function test_setFlashProviderRejectsNonWhitelisted() public {
        address notWhitelisted = address(0xDEAD3);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, notWhitelisted));
        executor.setFlashProvider(1, notWhitelisted);
    }

    function test_setFlashProviderAcceptsWhitelisted() public {
        // aavePool is in allowedTargets (set in constructor)
        vm.prank(owner);
        executor.setFlashProvider(1, address(aavePool));
        assertEq(executor.allowedFlashProviders(1), address(aavePool));
    }

    function test_setMorphoBlueRejectsNonWhitelisted() public {
        address notWhitelisted = address(0xDEAD1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, notWhitelisted));
        executor.setMorphoBlue(notWhitelisted);
    }

    function test_setAaveV2LendingPoolRejectsNonWhitelisted() public {
        address notWhitelisted = address(0xDEAD2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, notWhitelisted));
        executor.setAaveV2LendingPool(notWhitelisted);
    }

    function test_settersAcceptWhitelistedAddresses() public {
        // morphoBlue and aaveV2Pool are in allowedTargets (set in setUp)
        vm.startPrank(owner);
        executor.setMorphoBlue(address(morphoBlue));
        assertEq(executor.morphoBlue(), address(morphoBlue));
        executor.setAaveV2LendingPool(address(aaveV2Pool));
        assertEq(executor.aaveV2LendingPool(), address(aaveV2Pool));
        vm.stopPrank();
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
            _defaultLiqAction(500e18),
            _defaultLiqSwap(),
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
        // Profit gate test: profitToken == loanToken, using repay action (non-liquidation)
        uint256 repayAmt = 500e18;
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(repayAmt),
            _defaultLiqSwap(),
            address(loanToken), // profitToken == loanToken
            5e18 // minProfit
        );

        vm.prank(operatorAddr);
        executor.execute(plan); // must not revert

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 REGRESSION: Balancer profit gate when profitToken == loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_balancer_profit_token_equals_loan_token_profit_gate_works() public {
        uint256 flashFee = 5e18;
        balancerVault.setFlashFee(flashFee);

        // Profit gate test: Balancer flash with profitToken == loanToken, using repay action
        uint256 repayAmt = 500e18;
        uint256 netGain = 94e18; // swap gain (100) - flash fee (5) - rounding = ~94
        bytes memory plan = _buildPlan(
            2, // Balancer
            address(loanToken),
            LOAN_AMOUNT,
            flashFee,
            _defaultLiqAction(repayAmt),
            _defaultLiqSwap(),
            address(loanToken), // profitToken == loanToken
            netGain // minProfit
        );

        vm.prank(operatorAddr);
        executor.execute(plan); // must not revert — profit gate passes

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
        collateralToken.mint(address(aavePool), 100_000e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), // collateralAsset (received)
            address(loanToken), // debtAsset (paid) — must match plan.loanToken
            address(0x1234), // user being liquidated
            debtToCover,
            false
        );

        bytes memory plan = _buildPlan(
            1, // Aave V3 flash
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(1, targetAction),
            _buildSwapSpec(address(collateralToken), address(loanToken), collateralReward, 0),
            address(loanToken), // profit in loanToken
            0 // minProfit
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Assert allowance reset for debtAsset -> aavePool
        assertEq(loanToken.allowance(address(executor), address(aavePool)), 0);
        // Assert allowance reset for swap
        assertEq(collateralToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // EVENT EMISSION (preserved)
    // ═══════════════════════════════════════════════════════════════════

    function test_emitsLiquidationExecuted() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        collateralToken.mint(address(aaveV2Pool), 100_000e18);

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                3,
                _buildAaveV2LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            _buildSwapSpec(address(collateralToken), address(loanToken), COLLATERAL_REWARD, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectEmit(true, true, true, true);
        emit LiquidationExecutor.LiquidationExecuted(3, address(collateralToken), address(loanToken), 500e18);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP INVARIANTS: srcToken and dstToken must equal loanToken
    // ═══════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════
    // PARASWAP CALLDATA VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfSwapRecipientInvalid() public {
        address badRecipient = address(0xBAAD);
        LiquidationExecutor.SwapSpec memory spec = _buildSwapSpec(
            address(collateralToken), address(loanToken), COLLATERAL_REWARD, 0, block.timestamp + 3600, badRecipient
        );

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), spec, address(loanToken), 0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.SwapRecipientInvalid.selector, badRecipient));
        executor.execute(plan);
    }

    function test_revertIfSwapDeadlineExpired() public {
        uint256 expiredDeadline = block.timestamp - 1;
        LiquidationExecutor.SwapSpec memory spec = _buildSwapSpec(
            address(collateralToken), address(loanToken), COLLATERAL_REWARD, 0, expiredDeadline, address(executor)
        );

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), spec, address(loanToken), 0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.SwapDeadlineInvalid.selector, expiredDeadline));
        executor.execute(plan);
    }

    function test_revertIfSwapAmountInMismatch() public {
        // Build calldata with fromAmount = LOAN_AMOUNT but spec.amountIn = LOAN_AMOUNT / 2
        uint256 specAmountIn = LOAN_AMOUNT / 2;
        bytes memory cd =
            _buildParaswapCalldata(address(collateralToken), address(loanToken), COLLATERAL_REWARD, address(executor));
        LiquidationExecutor.SwapSpec memory spec = LiquidationExecutor.SwapSpec({
            srcToken: address(collateralToken),
            dstToken: address(loanToken),
            amountIn: specAmountIn,
            minAmountOut: 0,
            deadline: block.timestamp + 3600,
            paraswapCalldata: cd
        });

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), spec, address(loanToken), 0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.SwapAmountInMismatch.selector, specAmountIn, COLLATERAL_REWARD)
        );
        executor.execute(plan);
    }

    function test_revertIfUnsupportedSwapSelector() public {
        // Build calldata with an unknown selector but valid length
        bytes memory badCalldata = abi.encodeWithSelector(
            bytes4(0xdeadbeef),
            address(0),
            address(collateralToken),
            address(loanToken),
            COLLATERAL_REWARD,
            uint256(0),
            uint256(0),
            bytes32(0),
            address(executor),
            uint256(0),
            bytes(""),
            bytes("")
        );
        LiquidationExecutor.SwapSpec memory spec = LiquidationExecutor.SwapSpec({
            srcToken: address(collateralToken),
            dstToken: address(loanToken),
            amountIn: COLLATERAL_REWARD,
            minAmountOut: 0,
            deadline: block.timestamp + 3600,
            paraswapCalldata: badCalldata
        });

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), spec, address(loanToken), 0
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidSwapSelector.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP INVARIANTS: srcToken must equal loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfSwapDstTokenNotLoanToken() public {
        // loanToken = loanToken, swapSpec.dstToken = collateralToken → SWAP_DST_MUST_BE_LOAN_TOKEN
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _buildSwapSpec(address(loanToken), address(collateralToken), LOAN_AMOUNT, 0),
            address(loanToken),
            0
        );
        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_SWAP_SPEC");
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // REAL LIQUIDATION FLOW: flash debtAsset → liquidate → swap collateral → repay
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Validates the production liquidation flow with zero pre-funded balances.
    ///
    /// Flow:
    ///   1. Flash loan loanToken (= debt asset, e.g. USDC)
    ///   2. liquidationCall: pay loanToken debt → receive collateralToken (with bonus)
    ///   3. Swap collateralToken → loanToken via ParaSwap
    ///   4. Repay flash loan (loanToken + fee)
    ///   5. Profit = remaining loanToken
    function test_aave_v3_liquidation_real_flow() public {
        // ── Setup: fresh executor with ZERO balances ──
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);
        vm.prank(owner);
        freshExecutor.setOperator(operatorAddr);

        // Verify executor starts with zero balances
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "Executor must start with zero loanToken");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "Executor must start with zero collateralToken");

        // ── Configure liquidation parameters ──
        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18; // 20% liquidation bonus
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        // Fund ONLY the pools (not the executor):
        // - Aave flash pool needs loanToken to lend
        // - Aave liquidation pool needs collateralToken to reward
        // - Augustus needs loanToken to return after swap
        loanToken.mint(address(aavePool), 100_000e18); // flash loan source
        collateralToken.mint(address(aavePool), 100_000e18); // liquidation collateral reward
        loanToken.mint(address(augustus), 100_000e18); // swap output (collateral → loanToken)

        // ── Build liquidation action ──
        // Roles: loanToken = debtAsset (what we repay), collateralToken = collateralAsset (what we receive)
        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), // collateralAsset — what liquidator receives
            address(loanToken), // debtAsset — what liquidator pays
            address(0x1234), // user being liquidated
            debtToCover,
            false // receiveAToken = false (receive underlying)
        );

        // ── Build swap spec ──
        // After liquidation: executor holds collateralToken (600e18)
        // Swap: collateralToken → loanToken (to repay flash loan)
        // At 1.1x rate: 600e18 collateralToken → 660e18 loanToken
        // Need: debtToCover(500) + flashFee(1) = 501e18 loanToken for repay
        LiquidationExecutor.SwapSpec memory swapSpec = _buildSwapSpec(
            address(collateralToken), // srcToken — received from liquidation
            address(loanToken), // dstToken — needed for flash loan repay
            collateralReward, // amountIn — full collateral reward
            debtToCover + flashFee, // minAmountOut — at least enough to repay
            block.timestamp + 3600, // deadline
            address(freshExecutor) // beneficiary — must be the fresh executor
        );

        // ── Build plan ──
        bytes memory plan = _buildPlan(
            1, // Aave V3 flash provider
            address(loanToken), // loanToken = flash loan the debt asset
            debtToCover, // borrow exactly what we need to cover debt
            flashFee, // maxFlashFee
            _singleAction(1, targetAction),
            swapSpec,
            address(loanToken), // profitToken — measure profit in loanToken
            0 // minProfit — accept any profit for test
        );

        // ── Execute ──
        vm.prank(operatorAddr);
        freshExecutor.execute(plan);

        // ── Assertions ──
        // 1. Executor should have profit in loanToken
        uint256 profit = loanToken.balanceOf(address(freshExecutor));
        assertGt(profit, 0, "Executor must have positive loanToken profit");

        // 2. Executor should have zero collateralToken (all swapped)
        assertEq(
            collateralToken.balanceOf(address(freshExecutor)), 0, "Executor must have zero collateralToken after swap"
        );

        // 3. No dangling approvals
        assertEq(
            loanToken.allowance(address(freshExecutor), address(aavePool)),
            0,
            "loanToken approval to pool must be reset"
        );
        assertEq(
            collateralToken.allowance(address(freshExecutor), address(augustus)),
            0,
            "collateralToken approval to augustus must be reset"
        );
        assertEq(
            loanToken.allowance(address(freshExecutor), address(augustus)),
            0,
            "loanToken approval to augustus must be reset"
        );

        // 4. Verify profit math: swap output (660e18) - flash repay (501e18) = 159e18
        // swap: 600e18 * 1.1 = 660e18 loanToken
        // repay: 500e18 + 1e18 = 501e18
        // profit: 660 - 501 = 159e18
        uint256 expectedProfit = (collateralReward * SWAP_RATE / 1e18) - debtToCover - flashFee;
        assertEq(profit, expectedProfit, "Profit must match expected calculation");
    }

    // ═══════════════════════════════════════════════════════════════════
    // NEGATIVE: swap slippage causes revert
    // ═══════════════════════════════════════════════════════════════════

    /// @notice If the swap returns less than required to repay the flash loan,
    /// the entire transaction must revert. No tokens should remain stuck.
    function test_liquidation_reverts_on_insufficient_swap_output() public {
        // ── Fresh executor with ZERO balances ──
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);
        vm.prank(owner);
        freshExecutor.setOperator(operatorAddr);

        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;
        uint256 flashFee = 1e18;
        uint256 repayRequired = debtToCover + flashFee; // 501e18

        aavePool.setLiquidationCollateralReward(collateralReward);

        // Fund pools only
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Set swap rate so output is LESS than repay amount.
        // At rate 0.6: 600e18 * 0.6 = 360e18 loanToken < 501e18 required
        augustus.setRate(0.6e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        // minAmountOut set to repayRequired — swap will not meet this
        LiquidationExecutor.SwapSpec memory swapSpec = _buildSwapSpec(
            address(collateralToken),
            address(loanToken),
            collateralReward,
            repayRequired, // minAmountOut = 501e18, but swap returns 360e18
            block.timestamp + 3600,
            address(freshExecutor)
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            debtToCover,
            flashFee,
            _singleAction(1, targetAction),
            swapSpec,
            address(loanToken),
            0
        );

        // Must revert — InsufficientSwapOutput (360e18 < 501e18)
        vm.prank(operatorAddr);
        vm.expectRevert();
        freshExecutor.execute(plan);

        // Reset rate for other tests
        augustus.setRate(SWAP_RATE);

        // Executor must have no leftover tokens (tx reverted = state rolled back)
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "No loanToken stuck after revert");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateralToken stuck after revert");
    }

    // ═══════════════════════════════════════════════════════════════════
    // NEGATIVE: non-profitable liquidation with minProfit > 0
    // ═══════════════════════════════════════════════════════════════════

    /// @notice If liquidation + swap produces less profit than minProfit,
    /// execution must revert with InsufficientProfit.
    function test_liquidation_reverts_on_non_profitable_execution() public {
        // ── Fresh executor with ZERO balances ──
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);
        vm.prank(owner);
        freshExecutor.setOperator(operatorAddr);

        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        // Fund pools only
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Set swap rate so output is barely enough to repay but not enough for profit.
        // At rate 0.836: 600e18 * 0.836 = 501.6e18 → repay 501e18 → profit 0.6e18
        // Set minProfit to 10e18 → insufficient profit → revert
        augustus.setRate(0.836e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        uint256 swapOutput = collateralReward * 0.836e18 / 1e18; // 501.6e18
        LiquidationExecutor.SwapSpec memory swapSpec = _buildSwapSpec(
            address(collateralToken),
            address(loanToken),
            collateralReward,
            debtToCover + flashFee, // minAmountOut = 501e18 (swap passes this check)
            block.timestamp + 3600,
            address(freshExecutor)
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            debtToCover,
            flashFee,
            _singleAction(1, targetAction),
            swapSpec,
            address(loanToken),
            10e18 // minProfit = 10e18, but actual profit ≈ 0.6e18
        );

        // Must revert — InsufficientProfit(0.6e18, 10e18)
        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InsufficientProfit.selector,
                swapOutput - debtToCover - flashFee, // actual profit
                10e18 // required profit
            )
        );
        freshExecutor.execute(plan);

        // Reset rate for other tests
        augustus.setRate(SWAP_RATE);

        // Executor must have no leftover tokens
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "No loanToken stuck after revert");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateralToken stuck after revert");
    }

    // ═══════════════════════════════════════════════════════════════════
    // MULTI-ACTION: two liquidations in one flash loan
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Execute two liquidations atomically in one flash loan,
    /// then swap total collateral back to loanToken.
    function test_multi_liquidation_flow() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);
        vm.prank(owner);
        freshExecutor.setOperator(operatorAddr);

        assertEq(loanToken.balanceOf(address(freshExecutor)), 0);
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0);

        uint256 debtToCover1 = 300e18;
        uint256 debtToCover2 = 200e18;
        uint256 totalDebt = debtToCover1 + debtToCover2; // 500e18
        uint256 collateralReward = 600e18; // reward per liquidation (mock returns same for both)
        uint256 totalCollateral = collateralReward * 2; // 1200e18
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Two liquidation actions
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), debtToCover1, false
            )
        });
        actions[1] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x2222), debtToCover2, false
            )
        });

        // Swap: total collateral (1200e18) → loanToken
        // At 1.1x: 1200 * 1.1 = 1320e18 loanToken
        // Repay: 500 + 1 = 501e18
        // Profit: 1320 - 501 = 819e18
        LiquidationExecutor.SwapSpec memory swapSpec = _buildSwapSpec(
            address(collateralToken),
            address(loanToken),
            totalCollateral,
            totalDebt + flashFee,
            block.timestamp + 3600,
            address(freshExecutor)
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), totalDebt, flashFee, actions, swapSpec, address(loanToken), 0);

        vm.prank(operatorAddr);
        freshExecutor.execute(plan);

        // Profit
        uint256 profit = loanToken.balanceOf(address(freshExecutor));
        uint256 expectedProfit = (totalCollateral * SWAP_RATE / 1e18) - totalDebt - flashFee;
        assertEq(profit, expectedProfit, "Multi-liq profit must match");

        // No leftover collateral
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateral left");

        // No approvals
        assertEq(loanToken.allowance(address(freshExecutor), address(aavePool)), 0);
        assertEq(collateralToken.allowance(address(freshExecutor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MULTI-ACTION: partial failure causes atomic revert
    // ═══════════════════════════════════════════════════════════════════

    /// @notice If any action in a multi-action plan fails,
    /// the entire transaction reverts atomically.
    function test_multi_action_partial_failure_reverts() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);
        vm.prank(owner);
        freshExecutor.setOperator(operatorAddr);

        uint256 debtToCover = 300e18;
        uint256 collateralReward = 400e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // First action: valid liquidation
        // Second action: liquidation that will fail (setLiquidationReverts after first)
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), debtToCover, false
            )
        });
        // Second action uses invalid protocol ID → guaranteed revert
        actions[1] = LiquidationExecutor.Action({
            protocolId: 99,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x2222), debtToCover, false
            )
        });

        LiquidationExecutor.SwapSpec memory swapSpec = _buildSwapSpec(
            address(collateralToken),
            address(loanToken),
            collateralReward * 2,
            debtToCover * 2 + flashFee,
            block.timestamp + 3600,
            address(freshExecutor)
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), debtToCover * 2, flashFee, actions, swapSpec, address(loanToken), 0);

        vm.prank(operatorAddr);
        vm.expectRevert();
        freshExecutor.execute(plan);

        // Atomic rollback — no stuck tokens
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "No loanToken stuck");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateralToken stuck");
    }

    // ═══════════════════════════════════════════════════════════════════
    // INPUT VALIDATION: empty actions, too many actions
    // ═══════════════════════════════════════════════════════════════════

    function test_execute_reverts_on_empty_actions() public {
        LiquidationExecutor.Action[] memory empty = new LiquidationExecutor.Action[](0);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, empty, _defaultLiqSwap(), address(loanToken), 0);

        vm.prank(operatorAddr);
        vm.expectRevert("NO_ACTIONS");
        executor.execute(plan);
    }

    function test_execute_reverts_on_too_many_actions() public {
        LiquidationExecutor.Action[] memory tooMany = new LiquidationExecutor.Action[](11);
        for (uint256 i = 0; i < 11; i++) {
            tooMany[i] = LiquidationExecutor.Action({
                protocolId: 1,
                data: _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 100e18, false
                )
            });
        }

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, tooMany, _defaultLiqSwap(), address(loanToken), 0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("TOO_MANY_ACTIONS");
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // VALIDATION: debt/collateral/swap consistency
    // ═══════════════════════════════════════════════════════════════════

    function test_reverts_on_invalid_debt_asset() public {
        // Two liquidations with DIFFERENT debt assets → INVALID_DEBT_ASSET
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), 100e18, false
            )
        });
        actions[1] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken),
                address(collateralToken),
                address(0x2222),
                100e18,
                false // wrong debt
            )
        });

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            200e18,
            FLASH_FEE,
            actions,
            _buildSwapSpec(address(collateralToken), address(loanToken), 200e18, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_DEBT_ASSET");
        executor.execute(plan);
    }

    function test_reverts_on_invalid_collateral_asset() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), 100e18, false
            )
        });
        actions[1] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(otherToken),
                address(loanToken),
                address(0x2222),
                100e18,
                false // different collateral
            )
        });

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            200e18,
            FLASH_FEE,
            actions,
            _buildSwapSpec(address(collateralToken), address(loanToken), 200e18, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_COLLATERAL_ASSET");
        executor.execute(plan);
    }

    function test_reverts_on_invalid_swap_spec() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);

        // Swap srcToken != collateralAsset → INVALID_SWAP_SPEC
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            200e18,
            FLASH_FEE,
            _singleAction(
                1,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 200e18, false
                )
            ),
            _buildSwapSpec(address(otherToken), address(loanToken), 200e18, 0), // wrong srcToken
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_SWAP_SPEC");
        executor.execute(plan);
    }

    function test_reverts_on_zero_action_amount() public {
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            200e18,
            FLASH_FEE,
            _singleAction(
                1,
                _buildAaveV3LiquidationAction(
                    address(collateralToken),
                    address(loanToken),
                    address(0x1234),
                    0,
                    false // zero amount
                )
            ),
            _buildSwapSpec(address(collateralToken), address(loanToken), 200e18, 0),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("ZERO_ACTION_AMOUNT");
        executor.execute(plan);
    }

    function test_reverts_on_unsupported_action() public {
        // Aave V3 actionType != 4 (e.g. repay=1) → UNSUPPORTED_ACTION
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(1, _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234))),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("UNSUPPORTED_ACTION");
        executor.execute(plan);
    }

    function test_reverts_on_invalid_protocol() public {
        // Protocol ID 99 → INVALID_PROTOCOL
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                99,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            _defaultLiqSwap(),
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_PROTOCOL");
        executor.execute(plan);
    }

    function test_reverts_on_no_collateral_received() public {
        // Fresh executor with zero balance
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExec =
            new LiquidationExecutor(owner, address(aavePool), address(balancerVault), address(augustus), targets);
        vm.prank(owner);
        freshExec.setOperator(operatorAddr);

        // Liquidation returns 0 collateral → NO_COLLATERAL
        aavePool.setLiquidationCollateralReward(0);
        loanToken.mint(address(aavePool), 100_000e18);

        LiquidationExecutor.SwapSpec memory swapSpec = _buildSwapSpec(
            address(collateralToken),
            address(loanToken),
            1,
            0, // any swap amount
            block.timestamp + 3600,
            address(freshExec)
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            500e18,
            FLASH_FEE,
            _singleAction(
                1,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            swapSpec,
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("NO_COLLATERAL");
        freshExec.execute(plan);
    }

    /// @notice Validates the INVALID_FLASH_LOAN branch: callback receives
    /// less loanToken than plan.loanAmount → revert before any action executes.
    function test_reverts_on_invalid_flash_loan_balance() public {
        // Deploy a stingy flash provider that transfers LESS than requested
        MockAavePoolStingy stingyPool = new MockAavePoolStingy(FLASH_FEE);
        loanToken.mint(address(stingyPool), 100_000e18);

        // Fresh executor wired to stingy pool
        address[] memory targets = new address[](2);
        targets[0] = address(stingyPool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExec =
            new LiquidationExecutor(owner, address(stingyPool), address(balancerVault), address(augustus), targets);
        vm.prank(owner);
        freshExec.setOperator(operatorAddr);

        aavePool.setLiquidationCollateralReward(COLLATERAL_REWARD);

        LiquidationExecutor.SwapSpec memory swapSpec = _buildSwapSpec(
            address(collateralToken),
            address(loanToken),
            COLLATERAL_REWARD,
            0,
            block.timestamp + 3600,
            address(freshExec)
        );

        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                1,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            swapSpec,
            address(loanToken),
            0
        );

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_FLASH_LOAN");
        freshExec.execute(plan);

        // No stuck tokens
        assertEq(loanToken.balanceOf(address(freshExec)), 0);
    }
}

/// @dev Flash provider mock that transfers LESS than requested (triggers INVALID_FLASH_LOAN)
contract MockAavePoolStingy {
    using SafeERC20 for IERC20;

    uint256 public flashFee;

    constructor(uint256 _fee) {
        flashFee = _fee;
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        // Transfer only HALF the requested amount — triggers INVALID_FLASH_LOAN
        uint256 shortAmount = amount / 2;
        IERC20(asset).safeTransfer(receiver, shortAmount);

        IFlashLoanSimpleReceiver(receiver).executeOperation(asset, amount, flashFee, receiver, params);

        // Pull back (will fail anyway due to revert, but needed for compilation)
        IERC20(asset).safeTransferFrom(receiver, address(this), shortAmount + flashFee);
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
