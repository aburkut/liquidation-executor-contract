// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {SwapMode, SwapLeg} from "../src/types/SwapTypes.sol";
import {SwapValidationLib} from "../src/libraries/SwapValidationLib.sol";
import {CoinbasePaymentLib} from "../src/libraries/CoinbasePaymentLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniV2Router} from "./mocks/MockUniV2Router.sol";
import {MockUniV3Router} from "./mocks/MockUniV3Router.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: ETH transfer failed");
    }

    receive() external payable {}
}

/// @title ArbExecutorTest
/// @notice Focused suite for `ArbExecutor`. The execution pipeline shares
/// its swap-leg libraries with `LiquidationExecutor` (already covered in
/// the 10k-line legacy suite), so we don't re-test every per-mode swap
/// shape here. Coverage instead pins:
///   * Chain wiring (first/last/link constraints) on top of the lib's
///     per-leg validation.
///   * Flash callback gates (phase + planHash + provider pin).
///   * Coinbase gating (`loanToken == weth` precondition).
///   * Profit floor + withdraw + admin surface.
contract ArbExecutorTest is Test {
    ArbExecutor public exec;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockWETH public weth;

    MockMorphoBlue public morpho;
    MockBalancerVault public balancerFlash;
    MockUniV2Router public uniV2;
    MockUniV3Router public uniV3;
    MockParaswapAugustus public augustus; // unused in tests but required by constructor

    address public ownerAddr = address(0xA11CE);
    address public operatorAddr = address(0xB0B);
    address public attacker = address(0xDEAD);
    address public recipient = address(0xC0DE);

    uint256 constant LOAN_AMOUNT = 1_000e18;
    uint256 constant SWAP_RATE = 1.1e18; // 10% gain per hop in the mocks

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenC = new MockERC20("C", "C", 18);
        weth = new MockWETH();

        morpho = new MockMorphoBlue();
        balancerFlash = new MockBalancerVault(0); // flashloan fee = 0 for simpler assertions
        uniV2 = new MockUniV2Router(SWAP_RATE);
        uniV3 = new MockUniV3Router(SWAP_RATE);
        augustus = new MockParaswapAugustus(SWAP_RATE);

        address[] memory allowed = new address[](1);
        allowed[0] = address(morpho); // morpho needs to be allowlisted? actually not — flashProvider check is separate. Keep for symmetry.

        vm.prank(ownerAddr);
        exec = new ArbExecutor(
            ownerAddr,
            operatorAddr,
            address(weth),
            address(balancerFlash),
            address(morpho),
            address(augustus),
            address(uniV2),
            address(uniV3),
            allowed
        );

        // Wire Morpho as flash provider (mirrors LiquidationExecutor).
        vm.prank(ownerAddr);

        // Seed swap venues + flash sources with liquidity so they can
        // honour callbacks / swaps.
        tokenA.mint(address(morpho), 10 * LOAN_AMOUNT);
        tokenA.mint(address(uniV2), 10 * LOAN_AMOUNT);
        tokenA.mint(address(uniV3), 10 * LOAN_AMOUNT);
        tokenB.mint(address(uniV2), 10 * LOAN_AMOUNT);
        tokenB.mint(address(uniV3), 10 * LOAN_AMOUNT);
        tokenC.mint(address(uniV2), 10 * LOAN_AMOUNT);
        tokenC.mint(address(uniV3), 10 * LOAN_AMOUNT);
        weth.mint(address(morpho), 10 * LOAN_AMOUNT);
        weth.mint(address(uniV2), 10 * LOAN_AMOUNT);
        weth.mint(address(uniV3), 10 * LOAN_AMOUNT);

        // ETH funding so the coinbase auto-unwrap path has somewhere
        // to draw from when the executor holds WETH. Sized > the
        // maximum unwrap amount any single test would request.
        vm.deal(address(weth), 1_000 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _v2Leg(address src, address dst, bool useFullBalance, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (SwapLeg memory leg)
    {
        address[] memory path = new address[](2);
        path[0] = src;
        path[1] = dst;
        leg = SwapLeg({
            mode: SwapMode.UNI_V2,
            srcToken: src,
            amountIn: amountIn,
            useFullBalance: useFullBalance,
            deadline: block.timestamp + 1 hours,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: path,
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dst,
            minAmountOut: minOut
        });
    }

    function _v3Leg(address src, address dst, bool useFullBalance, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (SwapLeg memory leg)
    {
        address[] memory empty = new address[](0);
        leg = SwapLeg({
            mode: SwapMode.UNI_V3,
            srcToken: src,
            amountIn: amountIn,
            useFullBalance: useFullBalance,
            deadline: block.timestamp + 1 hours,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: empty,
            v3Fee: 500,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dst,
            minAmountOut: minOut
        });
    }

    function _planMorpho(
        address loanToken,
        uint256 amount,
        SwapLeg[] memory legs,
        uint256 minProfit,
        uint256 coinbaseBps
    ) internal pure returns (bytes memory) {
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: 3, // FLASH_PROVIDER_MORPHO
            loanToken: loanToken,
            loanAmount: amount,
            maxFlashFee: 0,
            legs: legs,
            coinbaseBps: coinbaseBps,
            minProfitAmount: minProfit
        });
        return abi.encode(plan);
    }

    function _planBalancer(
        address loanToken,
        uint256 amount,
        uint256 maxFlashFee,
        SwapLeg[] memory legs,
        uint256 minProfit
    ) internal pure returns (bytes memory) {
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: 2, // FLASH_PROVIDER_BALANCER
            loanToken: loanToken,
            loanAmount: amount,
            maxFlashFee: maxFlashFee,
            legs: legs,
            coinbaseBps: 0,
            minProfitAmount: minProfit
        });
        return abi.encode(plan);
    }

    // ─── Happy paths ─────────────────────────────────────────────────

    /// 2-hop A→B→A chain via Morpho flash, V2 router both legs.
    /// rate=1.1 ⇒ 1000 A → 1100 B → 1210 A → repay 1000 → profit 210.
    function test_happy_2hop_morpho_v2() public {
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT); // useFullBalance, minOut = principal

        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 100e18, 0);

        uint256 balBefore = tokenA.balanceOf(address(exec));
        vm.prank(operatorAddr);
        exec.execute(plan);
        uint256 balAfter = tokenA.balanceOf(address(exec));

        // 210 A profit retained on the contract.
        assertEq(balAfter - balBefore, 210e18, "profit retained");
    }

    /// Same chain via Balancer flash (zero fee in this test setup).
    function test_happy_2hop_balancer_v2() public {
        // Fund Balancer flash source with tokenA.
        tokenA.mint(address(balancerFlash), 10 * LOAN_AMOUNT);

        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);

        bytes memory plan = _planBalancer(address(tokenA), LOAN_AMOUNT, 0, legs, 100e18);

        vm.prank(operatorAddr);
        exec.execute(plan);

        assertEq(tokenA.balanceOf(address(exec)), 210e18, "profit retained");
    }

    /// 3-hop A→B→C→A across V2 and V3 routers.
    /// rate=1.1 each ⇒ 1000 → 1100 → 1210 → 1331; repay 1000 → 331 A profit.
    function test_happy_3hop_v2_v3_v2() public {
        SwapLeg[] memory legs = new SwapLeg[](3);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v3Leg(address(tokenB), address(tokenC), true, 0, 1);
        legs[2] = _v2Leg(address(tokenC), address(tokenA), true, 0, LOAN_AMOUNT);

        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 100e18, 0);

        vm.prank(operatorAddr);
        exec.execute(plan);

        assertEq(tokenA.balanceOf(address(exec)), 331e18, "3-hop profit retained");
    }

    /// Coinbase bribe: loanToken = weth, coinbaseBps = 5000 (50%) of the
    /// 210 weth realized profit ⇒ 105 weth = 105 ether goes to coinbase.
    function test_happy_coinbase_50pct_when_loan_is_weth() public {
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(weth), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(weth), true, 0, LOAN_AMOUNT);

        bytes memory plan = _planMorpho(address(weth), LOAN_AMOUNT, legs, 0, 5_000);

        address coinbaseAddr = address(0xC0FFEE);
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseBefore = coinbaseAddr.balance;

        vm.prank(operatorAddr);
        exec.execute(plan);

        assertEq(coinbaseAddr.balance - coinbaseBefore, 105e18, "50% of 210 weth profit bribed");
        // Residual 105 weth stays on the executor.
        assertEq(weth.balanceOf(address(exec)), 105e18, "residual weth retained");
    }

    /// Owner sweep — withdraw the retained profit to a recipient.
    function test_happy_owner_withdraws_profit() public {
        // First run a chain to accumulate profit.
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0));

        uint256 profit = tokenA.balanceOf(address(exec));
        assertEq(profit, 210e18);

        vm.prank(ownerAddr);
        exec.withdraw(address(tokenA), recipient, profit);

        assertEq(tokenA.balanceOf(recipient), profit, "recipient credited");
        assertEq(tokenA.balanceOf(address(exec)), 0, "executor swept clean");
    }

    // ─── Chain wiring reverts ────────────────────────────────────────

    function test_revert_legs_empty() public {
        SwapLeg[] memory legs = new SwapLeg[](0);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_legs_first_src_mismatch_loanToken() public {
        // leg[0].srcToken = tokenB but loanToken = tokenA — chain doesn't open.
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenB), address(tokenC), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenC), address(tokenA), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_legs_last_repay_mismatch_loanToken() public {
        // Last leg leaves chain in tokenB, not loanToken — can't repay.
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenC), true, 0, 1);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_legs_link_mismatch() public {
        // leg[1].srcToken = tokenC but leg[0].repayToken = tokenB.
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenC), address(tokenA), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_coinbase_bps_over_cap() public {
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(weth), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(weth), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(weth), LOAN_AMOUNT, legs, 0, 10_001);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.execute(plan);
    }

    function test_revert_coinbase_requires_weth_loan() public {
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 5_000);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.CoinbaseRequiresWethLoan.selector);
        exec.execute(plan);
    }

    function test_revert_minProfitAmount_floor_unmet() public {
        // 210 A realized profit; require 500 → InsufficientProfit.
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 500e18, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(CoinbasePaymentLib.InsufficientProfit.selector, 210e18, 500e18));
        exec.execute(plan);
    }

    function test_revert_invalid_flash_provider() public {
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);
        ArbTypes.ArbPlan memory plan = ArbTypes.ArbPlan({
            flashProviderId: 99, // not configured
            loanToken: address(tokenA),
            loanAmount: LOAN_AMOUNT,
            maxFlashFee: 0,
            legs: legs,
            coinbaseBps: 0,
            minProfitAmount: 0
        });
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.InvalidFlashProvider.selector, uint8(99)));
        exec.execute(abi.encode(plan));
    }

    // ─── Flash callback gates ────────────────────────────────────────

    function test_revert_morphoCallbackFromNonMorpho() public {
        // Direct call to onMorphoFlashLoan from attacker without a pinned
        // plan / phase → InvalidExecutionPhase (idle).
        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.InvalidExecutionPhase.selector);
        exec.onMorphoFlashLoan(LOAN_AMOUNT, hex"");
    }

    function test_revert_morphoCallbackWrongCaller_evenInsidePhase() public {
        // Plant `_executionPhase = FlashLoanActive` and `_activePlanHash`
        // matching `data` — only the caller check should reject.
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0);
        bytes32 planHash = keccak256(plan);

        // Storage slots (forge inspect ArbExecutor storage):
        //   morphoBlue              slot 2
        //   allowedFlashProviders   slot 3 (mapping)
        //   allowedTargets          slot 4 (mapping)
        //   _activePlanHash         slot 5
        //   _executionPhase         slot 6 (uint8 enum offset 0)
        vm.store(address(exec), bytes32(uint256(5)), planHash);
        vm.store(address(exec), bytes32(uint256(6)), bytes32(uint256(1))); // FlashLoanActive

        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.InvalidCallbackCaller.selector);
        exec.onMorphoFlashLoan(LOAN_AMOUNT, plan);
    }

    function test_revert_balancerCallbackFromNonBalancer() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(tokenA));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN_AMOUNT;
        uint256[] memory feeAmounts = new uint256[](1);
        feeAmounts[0] = 0;

        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.InvalidExecutionPhase.selector);
        exec.receiveFlashLoan(tokens, amounts, feeAmounts, hex"");
    }

    // ─── Admin gates ─────────────────────────────────────────────────

    function test_revert_executeFromNonOperator() public {
        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0);
        vm.prank(attacker);
        vm.expectRevert(ArbExecutor.UnauthorizedOperator.selector);
        exec.execute(plan);
    }

    function test_revert_pausedBlocksExecute() public {
        vm.prank(ownerAddr);
        exec.pause();

        SwapLeg[] memory legs = new SwapLeg[](2);
        legs[0] = _v2Leg(address(tokenA), address(tokenB), false, LOAN_AMOUNT, 1);
        legs[1] = _v2Leg(address(tokenB), address(tokenA), true, 0, LOAN_AMOUNT);
        bytes memory plan = _planMorpho(address(tokenA), LOAN_AMOUNT, legs, 0, 0);

        vm.prank(operatorAddr);
        vm.expectRevert();
        exec.execute(plan);

        // Unpause restores.
        vm.prank(ownerAddr);
        exec.unpause();
        vm.prank(operatorAddr);
        exec.execute(plan);
        assertEq(tokenA.balanceOf(address(exec)), 210e18);
    }

    function test_revert_withdrawFromNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        exec.withdraw(address(tokenA), recipient, 1);
    }

    function test_revert_setAllowedTargetFromNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        exec.setAllowedTarget(address(0xBEEF), true);
    }

    // V10+: `configureMorpho` removed (Morpho is constructor-pinned).
}
