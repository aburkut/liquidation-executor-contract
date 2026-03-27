// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
import {MockBebopSettlement} from "./mocks/MockBebopSettlement.sol";

contract ExecutorTest is Test {
    LiquidationExecutor public executor;

    MockERC20 public loanToken;
    MockERC20 public collateralToken;
    MockERC20 public profitToken;

    MockAavePool public aavePool;
    MockMorphoBlue public morphoBlue;
    MockBalancerVault public balancerVault;
    MockParaswapAugustus public augustus;
    MockAaveV2LendingPool public aaveV2Pool;
    MockWETH public mockWeth;
    MockBebopSettlement public bebop;

    address public owner = address(0xA11CE);
    address public operatorAddr = address(0xB0B);
    address public attacker = address(0xDEAD);

    uint256 constant LOAN_AMOUNT = 1000e18;
    uint256 constant FLASH_FEE = 1e18;
    uint256 constant SWAP_RATE = 1.1e18; // 10% gain
    uint256 constant MIN_PROFIT = 5e18;
    uint256 constant COLLATERAL_REWARD = 600e18;
    uint256 constant DEFAULT_SWAP_AMOUNT = 1000e18; // Pre-funded collateral balance used in default swaps

    bytes4 constant SWAP_EXACT_IN_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    );

    function setUp() public {
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18);
        profitToken = new MockERC20("Profit Token", "PROF", 18);

        aavePool = new MockAavePool(FLASH_FEE);
        morphoBlue = new MockMorphoBlue();
        balancerVault = new MockBalancerVault(FLASH_FEE);
        augustus = new MockParaswapAugustus(SWAP_RATE);
        aaveV2Pool = new MockAaveV2LendingPool(COLLATERAL_REWARD);
        mockWeth = new MockWETH();
        bebop = new MockBebopSettlement();

        address[] memory targets = new address[](5);
        targets[0] = address(aavePool);
        targets[1] = address(morphoBlue);
        targets[2] = address(augustus);
        targets[3] = address(aaveV2Pool);
        targets[4] = address(bebop);

        executor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        vm.startPrank(owner);
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

        // Fund pools with mockWeth for WETH-denominated coinbase tests
        mockWeth.mint(address(aavePool), 100_000e18);
        mockWeth.mint(address(balancerVault), 100_000e18);
        mockWeth.mint(address(augustus), 100_000e18);
        mockWeth.mint(address(executor), LOAN_AMOUNT + FLASH_FEE + 100e18);
        vm.deal(address(mockWeth), 100_000 ether);

        // Fund bebop with output tokens
        loanToken.mint(address(bebop), 100_000e18);
        collateralToken.mint(address(bebop), 100_000e18);
        profitToken.mint(address(bebop), 100_000e18);
        profitToken.mint(address(augustus), 100_000e18);
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

    function _buildParaswapSingleSwapPlan(address srcToken, address dstToken, uint256 amountIn, uint256 minProfitAmt)
        internal
        view
        returns (LiquidationExecutor.SwapPlan memory)
    {
        return LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: srcToken,
            amountIn: amountIn,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(srcToken, dstToken, amountIn, address(executor)),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: dstToken,
            profitToken: dstToken,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildBebopMultiSwapPlan(
        address srcToken,
        uint256 amountIn,
        address bebopTarget,
        bytes memory bebopCd,
        address repayTkn,
        address profitTkn,
        uint256 minProfitAmt
    ) internal view returns (LiquidationExecutor.SwapPlan memory) {
        return LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.BEBOP_MULTI,
            srcToken: srcToken,
            amountIn: amountIn,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: bebopTarget,
            bebopCalldata: bebopCd,
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: repayTkn,
            profitToken: profitTkn,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildParaswapDoubleSwapPlan(
        LiquidationExecutor.DoubleSwapPattern pattern,
        bytes memory cd1,
        bytes memory cd2,
        address repayTkn,
        address profitTkn,
        uint256 minProfitAmt
    ) internal view returns (LiquidationExecutor.SwapPlan memory) {
        return LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_DOUBLE,
            srcToken: address(0), // ignored by PARASWAP_DOUBLE
            amountIn: 0, // ignored by PARASWAP_DOUBLE
            deadline: block.timestamp + 3600,
            paraswapCalldata: cd1,
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: pattern,
            paraswapCalldata2: cd2,
            repayToken: repayTkn,
            profitToken: profitTkn,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildPlan(
        uint8 flashProviderId,
        address lToken,
        uint256 loanAmount,
        uint256 maxFlashFee,
        LiquidationExecutor.Action[] memory actions,
        LiquidationExecutor.SwapPlan memory swapPlan
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.Plan({
                flashProviderId: flashProviderId,
                loanToken: lToken,
                loanAmount: loanAmount,
                maxFlashFee: maxFlashFee,
                actions: actions,
                swapPlan: swapPlan
            })
        );
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

    /// @dev Default liquidation action for tests that don't test the action itself.
    /// Uses collateralToken as collateral, loanToken as debt (correct roles).
    function _defaultLiqAction(uint256 debtToCover) internal view returns (LiquidationExecutor.Action[] memory) {
        return _singleAction(
            1,
            _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
            )
        );
    }

    /// @dev Default swap plan: PARASWAP_SINGLE swapping collateralToken -> loanToken
    /// Uses DEFAULT_SWAP_AMOUNT (1000e18) so that at 1.1x rate, output (1100e18) covers
    /// the flash loan repay (LOAN_AMOUNT + FLASH_FEE = 1001e18).
    function _defaultSwapPlan() internal view returns (LiquidationExecutor.SwapPlan memory) {
        return _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
    }

    // ─── WETH-denominated helpers (for coinbase payment tests) ───────

    function _wethSwapPlan() internal view returns (LiquidationExecutor.SwapPlan memory) {
        return _buildParaswapSingleSwapPlan(address(collateralToken), address(mockWeth), DEFAULT_SWAP_AMOUNT, 0);
    }

    function _wethSwapPlanWithMinProfit(uint256 minProfitAmt)
        internal
        view
        returns (LiquidationExecutor.SwapPlan memory)
    {
        return _buildParaswapSingleSwapPlan(
            address(collateralToken), address(mockWeth), DEFAULT_SWAP_AMOUNT, minProfitAmt
        );
    }

    function _wethLiqActionWithCoinbase(uint256 debtToCover, uint256 coinbaseAmount)
        internal
        view
        returns (LiquidationExecutor.Action[] memory)
    {
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), debtToCover, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(coinbaseAmount);
        return actions;
    }

    function _buildWethPlan(uint8 flashProviderId, LiquidationExecutor.Action[] memory actions, uint256 minProfitAmt)
        internal
        view
        returns (bytes memory)
    {
        LiquidationExecutor.SwapPlan memory swapPlan = _wethSwapPlanWithMinProfit(minProfitAmt);
        return _buildPlan(flashProviderId, address(mockWeth), LOAN_AMOUNT, FLASH_FEE, actions, swapPlan);
    }

    function _buildCoinbasePaymentAction(uint256 amount) internal pure returns (LiquidationExecutor.Action memory) {
        return LiquidationExecutor.Action({
            protocolId: 100, // PROTOCOL_INTERNAL
            data: abi.encode(uint8(1), amount) // ACTION_PAY_COINBASE
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

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
        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.Unauthorized.selector);
        executor.execute(plan);
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
        new LiquidationExecutor(address(0), address(1), address(2), address(3), address(4), address(5), targets);
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

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_pauseBlocksExecuteBalancer() public {
        vm.prank(owner);
        executor.pause();

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // AAVE V3 FLASH + PARASWAP + AAVE V3 REPAY (happy path)
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV3Flash_paraswap_aaveV3Repay() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, MIN_PROFIT);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

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
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
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
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, MIN_PROFIT);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

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
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), _defaultSwapPlan());
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
    // AAVE V3 CALLBACK VALIDATION
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
    // PARASWAP SINGLE SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_paraswapSingle_happyPath() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, MIN_PROFIT);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGe(loanAfter - loanBefore, MIN_PROFIT);

        // Approval hygiene
        assertEq(collateralToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_paraswapSingle_revertsOnSwapFailure() public {
        augustus.setSwapReverts(true);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(); // ParaswapSwapFailed
        executor.execute(plan);

        // Approvals zero after revert
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_paraswapSingle_revertsOnDeadlineExpired() public {
        uint256 expiredDeadline = block.timestamp - 1;
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: DEFAULT_SWAP_AMOUNT,
            deadline: expiredDeadline,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(executor)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.SwapDeadlineExpired.selector, expiredDeadline, block.timestamp)
        );
        executor.execute(plan);
    }

    function test_paraswapApprovalResetAfterSwap() public {
        uint256 repayAmt = 500e18;
        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), _defaultSwapPlan());
        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BEBOP MULTI SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_bebopMulti_happyPath() public {
        // Single output: repayToken == profitToken == loanToken
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD; // 600e18

        // Configure bebop: pull collateralToken, send loanToken
        uint256 bebopOutputAmount = 1100e18; // enough to repay flash loan + profit
        bebop.configure(address(collateralToken), collateralIn, address(loanToken), bebopOutputAmount, address(0), 0);

        // Build bebop calldata (any 4+ byte calldata triggers the fallback)
        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGt(loanAfter, loanBefore);
    }

    function test_bebopMulti_multiOutput() public {
        // Two different output tokens: repayToken=loanToken, profitToken=profitToken
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        // Configure bebop: pull collateralToken, send loanToken + profitToken
        uint256 repayOutput = 1100e18;
        uint256 profitOutput = 50e18;
        bebop.configure(
            address(collateralToken), collateralIn, address(loanToken), repayOutput, address(profitToken), profitOutput
        );

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(profitToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        uint256 profitBefore = profitToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 profitAfter = profitToken.balanceOf(address(executor));
        assertEq(profitAfter - profitBefore, profitOutput);
    }

    function test_bebopMulti_revertsOnUntrustedTarget() public {
        address untrustedTarget = address(0xBAD);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken),
            COLLATERAL_REWARD,
            untrustedTarget,
            bebopCd,
            address(loanToken),
            address(loanToken),
            0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // BebopTargetNotContract (no code at 0xBAD)
        executor.execute(plan);
    }

    function test_bebopMulti_revertsOnInsufficientRepay() public {
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        // Configure bebop to return too little loanToken
        uint256 tooLittleRepay = 10e18; // way less than flash loan repay
        bebop.configure(address(collateralToken), collateralIn, address(loanToken), tooLittleRepay, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // InsufficientRepayOutput
        executor.execute(plan);
    }

    function test_bebopMulti_revertsOnSwapFailure() public {
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        bebop.configure(address(collateralToken), collateralIn, address(loanToken), 1100e18, address(0), 0);
        bebop.setReverts(true);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // BebopSwapFailed
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARASWAP DOUBLE SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_paraswapDouble_split_happyPath() public {
        // Split pattern: collateral -> repayToken (leg 1), collateral -> profitToken (leg 2)
        uint256 debtToCover = 400e18;

        // Fund augustus with profitToken for the second leg
        profitToken.mint(address(augustus), 100_000e18);

        // Leg 1: 920 collateral -> loanToken (at 1.1x = 1012 loanToken, >= 1001 flash repay)
        uint256 leg1AmountIn = 920e18;
        bytes memory cd1 =
            _buildParaswapCalldata(address(collateralToken), address(loanToken), leg1AmountIn, address(executor));

        // Leg 2: 80 collateral -> profitToken (at 1.1x = 88 profitToken)
        uint256 leg2AmountIn = 80e18;
        bytes memory cd2 =
            _buildParaswapCalldata(address(collateralToken), address(profitToken), leg2AmountIn, address(executor));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildParaswapDoubleSwapPlan(
            LiquidationExecutor.DoubleSwapPattern.SPLIT, cd1, cd2, address(loanToken), address(profitToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        uint256 profitBefore = profitToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 profitAfter = profitToken.balanceOf(address(executor));
        assertGt(profitAfter, profitBefore);
    }

    function test_paraswapDouble_chained_happyPath() public {
        // Chained pattern: collateral -> intermediate -> repayToken
        uint256 debtToCover = 400e18;

        // Leg 1: collateral -> profitToken (intermediate) at 1.1x
        uint256 leg1AmountIn = DEFAULT_SWAP_AMOUNT; // 1000e18
        uint256 leg1AmountOut = leg1AmountIn * SWAP_RATE / 1e18; // 1100e18
        bytes memory cd1 =
            _buildParaswapCalldata(address(collateralToken), address(profitToken), leg1AmountIn, address(executor));

        // Leg 2: profitToken -> loanToken at 1.1x
        uint256 leg2AmountIn = leg1AmountOut; // 1100e18
        bytes memory cd2 =
            _buildParaswapCalldata(address(profitToken), address(loanToken), leg2AmountIn, address(executor));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildParaswapDoubleSwapPlan(
            LiquidationExecutor.DoubleSwapPattern.CHAINED, cd1, cd2, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan); // should succeed
    }

    function test_paraswapDouble_split_revertsRepayLegInsufficient() public {
        // Split pattern where the repay leg output is insufficient for flash loan repay
        uint256 debtToCover = 400e18;

        // Set a low rate so repay leg does not produce enough
        augustus.setRate(0.5e18);

        // Leg 1: 300 collateral -> loanToken (at 0.5x = 150 loanToken, insufficient for 1001 repay)
        uint256 leg1AmountIn = 300e18;
        bytes memory cd1 =
            _buildParaswapCalldata(address(collateralToken), address(loanToken), leg1AmountIn, address(executor));

        // Leg 2: 300 collateral -> profitToken
        uint256 leg2AmountIn = 300e18;
        bytes memory cd2 =
            _buildParaswapCalldata(address(collateralToken), address(profitToken), leg2AmountIn, address(executor));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildParaswapDoubleSwapPlan(
            LiquidationExecutor.DoubleSwapPattern.SPLIT, cd1, cd2, address(loanToken), address(profitToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // SplitRepayLegInsufficient
        executor.execute(plan);

        // Reset rate
        augustus.setRate(SWAP_RATE);
    }

    function test_paraswapDouble_chained_revertsOnLinkMismatch() public {
        // Chained pattern where dst1 != src2 -> ChainLinkMismatch
        uint256 debtToCover = 400e18;

        // Leg 1: collateral -> profitToken
        bytes memory cd1 =
            _buildParaswapCalldata(address(collateralToken), address(profitToken), 300e18, address(executor));

        // Leg 2: collateral -> loanToken (src2 = collateral, but dst1 = profitToken != collateral)
        bytes memory cd2 =
            _buildParaswapCalldata(address(collateralToken), address(loanToken), 300e18, address(executor));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildParaswapDoubleSwapPlan(
            LiquidationExecutor.DoubleSwapPattern.CHAINED, cd1, cd2, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.ChainLinkMismatch.selector, address(profitToken), address(collateralToken)
            )
        );
        executor.execute(plan);
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
            address(loanToken), // debt paid
            address(0x1234),
            debtToCover,
            false
        );

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(3, targetAction), swapPlan);

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
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

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
            swapPlan
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
            _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PROFIT GATE
    // ═══════════════════════════════════════════════════════════════════

    function test_profitGateRevertsIfBelowMinimum() public {
        // With swap amount 1000 at 1.1x = 1100 output. Flash repay = 1001.
        // Effective profit with debtToCover=400: = swap_output(1100) - flash_fee(1) - (debtToCover already paid from flash balance)
        // effectiveProfit = 699. Set minProfit impossibly high.
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 700e18);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_profitGateSucceedsIfMeetsMinimum() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 99e18);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);
        vm.prank(operatorAddr);
        executor.execute(plan); // should not revert
    }

    function test_profitGateWithBalancerProvider() public {
        // effectiveProfit with Balancer and debtToCover=100: ~999.
        // Set minProfit = 1000 -> reverts.
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1000e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(100e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEE CAP
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV3FeeCap() public {
        aavePool.setFlashFee(100e18);
        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, 1e18, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.FlashFeeExceeded.selector, 100e18, 1e18));
        executor.execute(plan);
    }

    function test_balancerFeeCap() public {
        balancerVault.setFlashFee(100e18);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, 1e18, _defaultLiqAction(500e18), _defaultSwapPlan());
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
        LiquidationExecutor exec2 = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        vm.prank(owner);
        exec2.setFlashProvider(1, address(liarPool));

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(exec2), 1000e18);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

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
        LiquidationExecutor exec2 = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        vm.startPrank(owner);
        exec2.setFlashProvider(1, address(liarPool));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

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
        LiquidationExecutor exec2 = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        vm.startPrank(owner);
        exec2.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(exec2), 1000e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

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
        LiquidationExecutor exec2 = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        vm.startPrank(owner);
        exec2.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

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
        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

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
            _defaultSwapPlan()
        );
        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_PROTOCOL");
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FLASH PROVIDER VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfFlashProviderNotConfigured() public {
        bytes memory plan =
            _buildPlan(99, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.FlashProviderNotAllowed.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVALID PLAN FIELDS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfLoanAmountZero() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 0, 0);

        bytes memory plan = _buildPlan(1, address(loanToken), 0, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_revertIfLoanTokenZeroAddress() public {
        bytes memory plan =
            _buildPlan(1, address(0), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
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
            _defaultSwapPlan()
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
    // RESCUE ALL ERC20
    // ═══════════════════════════════════════════════════════════════════

    function test_rescueAllERC20TransfersFullBalance() public {
        loanToken.mint(address(executor), 200e18);
        uint256 fullBalance = loanToken.balanceOf(address(executor));
        uint256 ownerBefore = loanToken.balanceOf(owner);
        vm.prank(owner);
        executor.rescueAllERC20(address(loanToken), owner);
        assertEq(loanToken.balanceOf(address(executor)), 0);
        assertEq(loanToken.balanceOf(owner) - ownerBefore, fullBalance);
    }

    function test_rescueAllERC20RevertsOnZeroBalance() public {
        MockERC20 emptyToken = new MockERC20("Empty", "EMP", 18);
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroBalance.selector);
        executor.rescueAllERC20(address(emptyToken), owner);
    }

    function test_rescueAllERC20RevertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueAllERC20(address(loanToken), attacker);
    }

    function test_rescueAllERC20RevertsOnZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueAllERC20(address(0), owner);
    }

    function test_rescueAllERC20RevertsOnZeroTo() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueAllERC20(address(loanToken), address(0));
    }

    function test_rescueAllERC20EmitsEvent() public {
        loanToken.mint(address(executor), 50e18);
        uint256 fullBalance = loanToken.balanceOf(address(executor));
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit LiquidationExecutor.Rescue(address(loanToken), owner, fullBalance);
        executor.rescueAllERC20(address(loanToken), owner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // RESCUE ERC20 BATCH
    // ═══════════════════════════════════════════════════════════════════

    function test_rescueERC20BatchTransfersMultipleTokens() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(executor), 100e18);
        tokenB.mint(address(executor), 200e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        vm.prank(owner);
        executor.rescueERC20Batch(tokens, owner);

        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
        assertEq(tokenA.balanceOf(owner), 100e18);
        assertEq(tokenB.balanceOf(owner), 200e18);
    }

    function test_rescueERC20BatchSkipsZeroBalanceTokens() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(executor), 100e18);
        // tokenB has zero balance

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        vm.prank(owner);
        executor.rescueERC20Batch(tokens, owner);

        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenA.balanceOf(owner), 100e18);
        assertEq(tokenB.balanceOf(owner), 0);
    }

    function test_rescueERC20BatchMixedBalances() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        MockERC20 tokenC = new MockERC20("C", "C", 18);
        tokenA.mint(address(executor), 50e18);
        // tokenB has zero balance
        tokenC.mint(address(executor), 300e18);

        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);

        vm.prank(owner);
        executor.rescueERC20Batch(tokens, owner);

        assertEq(tokenA.balanceOf(owner), 50e18);
        assertEq(tokenB.balanceOf(owner), 0);
        assertEq(tokenC.balanceOf(owner), 300e18);
    }

    function test_rescueERC20BatchRevertsOnEmptyArray() public {
        address[] memory tokens = new address[](0);
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.EmptyArray.selector);
        executor.rescueERC20Batch(tokens, owner);
    }

    function test_rescueERC20BatchRevertsIfNotOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(loanToken);
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueERC20Batch(tokens, attacker);
    }

    function test_rescueERC20BatchRevertsOnZeroTo() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(loanToken);
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueERC20Batch(tokens, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // EVENT EMISSION
    // ═══════════════════════════════════════════════════════════════════

    function test_emitsFlashExecutedBalancer() public {
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectEmit(true, true, false, true);
        emit LiquidationExecutor.FlashExecuted(2, address(loanToken), LOAN_AMOUNT);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 REGRESSION: Aave V3 profit gate when profitToken == loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_aave_profit_token_equals_loan_token_profit_gate_works() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 5e18);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

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

        uint256 repayAmt = 500e18;
        uint256 netGain = 94e18; // swap gain (100) - flash fee (5) - rounding = ~94
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, netGain);

        bytes memory plan = _buildPlan(
            2, // Balancer
            address(loanToken),
            LOAN_AMOUNT,
            flashFee,
            _defaultLiqAction(repayAmt),
            swapPlan
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

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

        bytes memory plan = _buildPlan(
            1, // Aave V3 flash
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(1, targetAction),
            swapPlan
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

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

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
            swapPlan
        );
        vm.prank(operatorAddr);
        vm.expectEmit(true, true, true, true);
        emit LiquidationExecutor.LiquidationExecuted(3, address(collateralToken), address(loanToken), 500e18);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARASWAP CALLDATA VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfSwapRecipientInvalid() public {
        address badRecipient = address(0xBAAD);
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: DEFAULT_SWAP_AMOUNT,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, badRecipient
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.SwapRecipientInvalid.selector, badRecipient));
        executor.execute(plan);
    }

    function test_revertIfSwapAmountInMismatch() public {
        // Build calldata with fromAmount = DEFAULT_SWAP_AMOUNT but spec.amountIn = LOAN_AMOUNT / 2
        uint256 specAmountIn = LOAN_AMOUNT / 2;
        bytes memory cd = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(executor)
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: specAmountIn,
            deadline: block.timestamp + 3600,
            paraswapCalldata: cd,
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.ParaswapAmountInMismatch.selector, specAmountIn, DEFAULT_SWAP_AMOUNT
            )
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

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: DEFAULT_SWAP_AMOUNT,
            deadline: block.timestamp + 3600,
            paraswapCalldata: badCalldata,
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidSwapSelector.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP INVARIANTS: repayToken must match loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfRepayTokenNotLoanToken() public {
        // repayToken != loanToken -> RepayTokenMismatch
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(loanToken), address(collateralToken), LOAN_AMOUNT, 0);

        bytes memory plan =
            _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.RepayTokenMismatch.selector, address(loanToken), address(collateralToken)
            )
        );
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // REAL LIQUIDATION FLOW: flash debtAsset -> liquidate -> swap collateral -> repay
    // ═══════════════════════════════════════════════════════════════════

    function test_aave_v3_liquidation_real_flow() public {
        // Fresh executor with ZERO balances
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        // Verify executor starts with zero balances
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "Executor must start with zero loanToken");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "Executor must start with zero collateralToken");

        // Configure liquidation parameters
        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18; // 20% liquidation bonus
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        // Fund ONLY the pools (not the executor)
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Build liquidation action
        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        // Build swap plan
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: collateralReward,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(1, address(loanToken), debtToCover, flashFee, _singleAction(1, targetAction), swapPlan);

        vm.prank(operatorAddr);
        freshExecutor.execute(plan);

        // Assertions
        uint256 profit = loanToken.balanceOf(address(freshExecutor));
        assertGt(profit, 0, "Executor must have positive loanToken profit");
        assertEq(
            collateralToken.balanceOf(address(freshExecutor)), 0, "Executor must have zero collateralToken after swap"
        );

        // No dangling approvals
        assertEq(loanToken.allowance(address(freshExecutor), address(aavePool)), 0);
        assertEq(collateralToken.allowance(address(freshExecutor), address(augustus)), 0);
        assertEq(loanToken.allowance(address(freshExecutor), address(augustus)), 0);

        // Verify profit math
        uint256 expectedProfit = (collateralReward * SWAP_RATE / 1e18) - debtToCover - flashFee;
        assertEq(profit, expectedProfit, "Profit must match expected calculation");
    }

    // ═══════════════════════════════════════════════════════════════════
    // NEGATIVE: swap slippage causes revert
    // ═══════════════════════════════════════════════════════════════════

    function test_liquidation_reverts_on_insufficient_swap_output() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Set swap rate so output is LESS than repay amount
        augustus.setRate(0.6e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: collateralReward,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(1, address(loanToken), debtToCover, flashFee, _singleAction(1, targetAction), swapPlan);

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

    function test_liquidation_reverts_on_non_profitable_execution() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Set swap rate so profit is minimal
        augustus.setRate(0.836e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        uint256 swapOutput = collateralReward * 0.836e18 / 1e18; // 501.6e18

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: collateralReward,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 10e18
        });

        bytes memory plan =
            _buildPlan(1, address(loanToken), debtToCover, flashFee, _singleAction(1, targetAction), swapPlan);

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

    function test_multi_liquidation_flow() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        assertEq(loanToken.balanceOf(address(freshExecutor)), 0);
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0);

        uint256 debtToCover1 = 300e18;
        uint256 debtToCover2 = 200e18;
        uint256 totalDebt = debtToCover1 + debtToCover2; // 500e18
        uint256 collateralReward = 600e18;
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

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: totalCollateral,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), totalCollateral, address(freshExecutor)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan = _buildPlan(1, address(loanToken), totalDebt, flashFee, actions, swapPlan);

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

    function test_multi_action_partial_failure_reverts() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        uint256 debtToCover = 300e18;
        uint256 collateralReward = 400e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // First action: valid liquidation
        // Second action: uses invalid protocol ID -> guaranteed revert
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), debtToCover, false
            )
        });
        // Second action uses invalid protocol ID -> guaranteed revert
        actions[1] = LiquidationExecutor.Action({
            protocolId: 99,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x2222), debtToCover, false
            )
        });

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: collateralReward * 2,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), collateralReward * 2, address(freshExecutor)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan = _buildPlan(1, address(loanToken), debtToCover * 2, flashFee, actions, swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        freshExecutor.execute(plan);

        // Atomic rollback -- no stuck tokens
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "No loanToken stuck");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateralToken stuck");
    }

    // ═══════════════════════════════════════════════════════════════════
    // INPUT VALIDATION: empty actions, too many actions
    // ═══════════════════════════════════════════════════════════════════

    function test_execute_reverts_on_empty_actions() public {
        LiquidationExecutor.Action[] memory empty = new LiquidationExecutor.Action[](0);

        bytes memory plan = _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, empty, _defaultSwapPlan());

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

        bytes memory plan = _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, tooMany, _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert("TOO_MANY_ACTIONS");
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // VALIDATION: debt/collateral/swap consistency
    // ═══════════════════════════════════════════════════════════════════

    function test_reverts_on_invalid_debt_asset() public {
        // Two liquidations with DIFFERENT debt assets -> INVALID_DEBT_ASSET
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

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 200e18, 0);

        bytes memory plan = _buildPlan(1, address(loanToken), 200e18, FLASH_FEE, actions, swapPlan);

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

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 200e18, 0);

        bytes memory plan = _buildPlan(1, address(loanToken), 200e18, FLASH_FEE, actions, swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_COLLATERAL_ASSET");
        executor.execute(plan);
    }

    function test_reverts_on_src_not_collateral() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);

        // Swap srcToken != collateralAsset -> SRC_NOT_COLLATERAL
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(otherToken), address(loanToken), 200e18, 0);

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
            swapPlan
        );

        vm.prank(operatorAddr);
        vm.expectRevert("SRC_NOT_COLLATERAL");
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
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 200e18, 0)
        );

        vm.prank(operatorAddr);
        vm.expectRevert("ZERO_ACTION_AMOUNT");
        executor.execute(plan);
    }

    function test_reverts_on_unsupported_action() public {
        // Aave V3 actionType != 4 (e.g. repay=1) -> UNSUPPORTED_ACTION
        bytes memory plan = _buildPlan(
            1,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(1, _buildAaveV3RepayAction(address(collateralToken), 500e18, address(0x1234))),
            _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert("UNSUPPORTED_ACTION");
        executor.execute(plan);
    }

    function test_reverts_on_invalid_protocol() public {
        // Protocol ID 99 -> INVALID_PROTOCOL
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
            _defaultSwapPlan()
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
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            targets
        );

        // Liquidation returns 0 collateral -> NO_COLLATERAL
        aavePool.setLiquidationCollateralReward(0);
        loanToken.mint(address(aavePool), 100_000e18);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: 1,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), 1, address(freshExec)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

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
            swapPlan
        );

        vm.prank(operatorAddr);
        vm.expectRevert("NO_COLLATERAL");
        freshExec.execute(plan);
    }

    function test_reverts_on_invalid_flash_loan_balance() public {
        // Deploy a stingy flash provider that transfers LESS than requested
        MockAavePoolStingy stingyPool = new MockAavePoolStingy(FLASH_FEE);
        loanToken.mint(address(stingyPool), 100_000e18);

        // Fresh executor wired to stingy pool
        address[] memory targets = new address[](2);
        targets[0] = address(stingyPool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(stingyPool),
            address(balancerVault),
            address(augustus),
            targets
        );

        aavePool.setLiquidationCollateralReward(COLLATERAL_REWARD);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: DEFAULT_SWAP_AMOUNT,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(
                address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(freshExec)
            ),
            bebopTarget: address(0),
            bebopCalldata: "",
            doubleSwapPattern: LiquidationExecutor.DoubleSwapPattern.SPLIT,
            paraswapCalldata2: "",
            repayToken: address(loanToken),
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

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
            swapPlan
        );

        vm.prank(operatorAddr);
        vm.expectRevert("INVALID_FLASH_LOAN");
        freshExec.execute(plan);

        // No stuck tokens
        assertEq(loanToken.balanceOf(address(freshExec)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT (requires profitToken == weth)
    // ═══════════════════════════════════════════════════════════════════

    function test_coinbasePayment_sendsETH() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 1 ether);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 0.5 ether), 0));

        assertEq(coinbase.balance, 0.5 ether);
        assertEq(address(executor).balance, 0.5 ether);
    }

    function test_coinbasePayment_revertsInsufficientETH() public {
        vm.coinbase(address(0xC01B));
        // No pre-funded ETH. Auto-unwrap gets ~2361e18 wei from WETH.
        // Payment of 100_000 ether exceeds that -> INSUFFICIENT_ETH.
        vm.prank(operatorAddr);
        vm.expectRevert("INSUFFICIENT_ETH");
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 100_000 ether), 0));
    }

    function test_coinbasePayment_revertsOnFailedCall() public {
        ETHRejecter rejecter = new ETHRejecter();
        vm.coinbase(address(rejecter));
        vm.deal(address(executor), 1 ether);

        vm.prank(operatorAddr);
        vm.expectRevert("COINBASE_PAYMENT_FAILED");
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 0.5 ether), 0));
    }

    function test_coinbasePayment_zeroAmountNoOp() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 0), 0));

        assertEq(coinbase.balance, 0);
    }

    function test_coinbasePayment_profitStillChecked() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1 ether);

        // Raw profit = 699e18. Coinbase = 0.1e18 (from pre-funded ETH).
        // coinbaseCostNotInDelta = 0.1e18 (pre-funded, not in delta).
        // effectiveProfit = 699 - 0.1 = 698.9 > 99 -> passes.
        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 0.1 ether), 99e18));
    }

    function test_coinbasePayment_minProfitFailsIfUnprofitable() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1 ether);

        // effectiveProfit with 0.1 ether coinbase from pre-funded ETH:
        // raw = 699, coinbaseCostNotInDelta = 0.1e18, effective = 698.9.
        // minProfit = 700 -> reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 0.1 ether), 700e18));
    }

    function test_coinbasePayment_invalidActionTypeReverts() public {
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), 400e18, false
            )
        });
        actions[1] = LiquidationExecutor.Action({protocolId: 100, data: abi.encode(uint8(99), uint256(0.5 ether))});

        bytes memory plan = _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidAction.selector, 99));
        executor.execute(plan);
    }

    function test_coinbasePayment_emitsEvent() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 1 ether);

        vm.prank(operatorAddr);
        vm.expectEmit(true, false, false, true);
        emit LiquidationExecutor.CoinbasePaid(coinbase, 0.5 ether);
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 0.5 ether), 0));
    }

    function test_coinbasePayment_balancerProvider() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 1 ether);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 0.5 ether), 0));

        assertEq(coinbase.balance, 0.5 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT -- UNIT RESTRICTION
    // ═══════════════════════════════════════════════════════════════════

    function test_coinbasePayment_revertsWhenProfitTokenNotWeth() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1 ether);

        // Build plan using loanToken as profitToken (not weth)
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(0.5 ether);

        bytes memory plan = _buildPlan(1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CoinbasePaymentRequiresWethProfit.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT -- PROFIT ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════

    function test_coinbasePayment_subtractsFromProfit() public {
        vm.coinbase(address(0xC01B));

        // Raw profit = 699e18. Coinbase = 1e18 (from WETH unwrap, in delta).
        // effectiveProfit = 698e18. minProfit = 699 -> 698 < 699 -> reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 1e18), 699e18));
    }

    function test_coinbasePayment_exactProfitBoundaryPasses() public {
        vm.coinbase(address(0xC01B));

        // effectiveProfit = 698e18. minProfit = 698 -> passes.
        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 1e18), 698e18));
    }

    function test_coinbasePayment_prefundedETH_subtracted() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1000 ether);

        // Raw profit = 699e18. Coinbase = 100e18 (from pre-funded ETH).
        // coinbaseCostNotInDelta = 100 - 0 = 100 (no WETH unwrap since ETH available).
        // effectiveProfit = 699 - 100 = 599. minProfit = 600 -> reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 100e18), 600e18));
    }

    function test_coinbasePayment_multiplePaymentsAccumulated() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 10 ether);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](3);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(1e18);
        actions[2] = _buildCoinbasePaymentAction(2e18);

        // Total coinbase = 3e18 (from pre-funded ETH). effectiveProfit = 699 - 3 = 696.
        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(1, actions, 696e18));

        assertEq(coinbase.balance, 3 ether);
    }

    function test_coinbasePayment_multiplePaymentsExceedProfit() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 10 ether);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](3);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(1e18);
        actions[2] = _buildCoinbasePaymentAction(2e18);

        // effectiveProfit = 696. minProfit = 697 -> reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(1, actions, 697e18));
    }

    function test_coinbasePayment_wethUnwrap() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        // No vm.deal -> executor has 0 ETH, must unwrap WETH

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 1 ether), 0));

        // Coinbase received ETH that could only have come from WETH unwrap
        assertEq(coinbase.balance, 1 ether);
        // Executor has no remaining ETH (all unwrapped ETH went to coinbase)
        assertEq(address(executor).balance, 0);
    }

    function test_coinbasePayment_wethProfitNoDoubleCount() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        // No pre-funded ETH -> payment entirely from WETH unwrap -> captured in delta.
        // 699 - 1 = 698. minProfit = 698 -> passes.

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(1, _wethLiqActionWithCoinbase(400e18, 1e18), 698e18));

        assertEq(coinbase.balance, 1 ether);
    }
}

/// @dev Contract that rejects ETH -- used to test coinbase payment failure
contract ETHRejecter {
    // No receive() or fallback() -- rejects all ETH transfers

    }

/// @dev Mock WETH for testing auto-unwrap in coinbase payment
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "WETH: ETH transfer failed");
    }

    receive() external payable {}
}

/// @dev Flash provider mock that transfers LESS than requested (triggers INVALID_FLASH_LOAN)
contract MockAavePoolStingy {
    using SafeERC20 for IERC20;

    uint256 public flashFee;

    constructor(uint256 _fee) {
        flashFee = _fee;
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        // Transfer only HALF the requested amount -- triggers INVALID_FLASH_LOAN
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
