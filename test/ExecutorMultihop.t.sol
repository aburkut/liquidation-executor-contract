// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ExecutorTest} from "./Executor.t.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {SwapMode, SwapLeg} from "../src/types/SwapTypes.sol";
import {CurveV1Lib} from "../src/libraries/CurveV1Lib.sol";
import {BalancerV2Lib, IBalancerV2Vault} from "../src/libraries/BalancerV2Lib.sol";
import {SwapValidationLib} from "../src/libraries/SwapValidationLib.sol";

import {MockCurveRouterNG} from "./mocks/MockCurveRouterNG.sol";
import {MockBalancerV2VaultBatch} from "./mocks/MockBalancerV2VaultBatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ExecutorMultihopTest
/// @notice Coverage for the V10+ Curve V1 / Balancer V2 native-multihop
/// dispatchers added on `LIQ-161-bal-v2-curve-v1-multihop`.
///
/// Layered as:
///   1. Integration via `executor.execute(plan)` for each new SwapMode
///      (CURVE_V1_MH, CURVE_V1_MH_BUY, BAL_V2_MH, BAL_V2_MH_BUY).
///      Asserts the full flash + liquidate + multihop + repay path
///      using the existing ExecutorTest fixtures (MockMorphoBlue,
///      MockAavePool, MockAaveV2LendingPool) extended with the two new
///      RouterNG / BatchSwap mocks.
///   2. Direct library invocation via DELEGATECALL harnesses for
///      granular branch coverage on the new entrypoints — endpoint
///      mismatches, zero amounts, malformed payloads, etc. The harness
///      mirrors how `LiquidationExecutor._dispatchLeg` calls the
///      library so the storage context (forceApprove, balance reads)
///      matches production.
///   3. SwapValidationLib coverage for the four new modes.
contract ExecutorMultihopTest is ExecutorTest {
    MockCurveRouterNG public curveRouter;
    MockBalancerV2VaultBatch public balancerBatchVault;

    // Mid-path token used by multihop tests. Cannot reuse the existing
    // `profitToken` because some MIXED_SPLIT tests configure it as the
    // profit-leg destination; using a dedicated token keeps multihop
    // assertions isolated from the broader fixture.
    MockERC20 public midToken;

    function setUp() public virtual override {
        super.setUp();
        curveRouter = new MockCurveRouterNG(SWAP_RATE);
        balancerBatchVault = new MockBalancerV2VaultBatch(SWAP_RATE);

        midToken = new MockERC20("Mid Token", "MID", 18);

        // Fund the new mocks with every token they might need to deliver.
        loanToken.mint(address(curveRouter), 1_000_000e18);
        collateralToken.mint(address(curveRouter), 1_000_000e18);
        profitToken.mint(address(curveRouter), 1_000_000e18);
        mockWeth.mint(address(curveRouter), 1_000_000e18);
        midToken.mint(address(curveRouter), 1_000_000e18);

        loanToken.mint(address(balancerBatchVault), 1_000_000e18);
        collateralToken.mint(address(balancerBatchVault), 1_000_000e18);
        profitToken.mint(address(balancerBatchVault), 1_000_000e18);
        mockWeth.mint(address(balancerBatchVault), 1_000_000e18);
        midToken.mint(address(balancerBatchVault), 1_000_000e18);
    }

    // ───────────────────────────────────────────────────────────────
    // Helpers — Curve V1 multihop leg construction
    // ───────────────────────────────────────────────────────────────

    function _curveMHExtData(address[11] memory path) internal pure returns (bytes memory) {
        uint256[5][5] memory swapParams; // every entry stays zero — mock ignores
        address[5] memory pools; // factory metapool stubs — mock ignores
        return abi.encode(path, swapParams, pools);
    }

    function _curveMHLeg(
        SwapMode m,
        address srcToken,
        address dstToken,
        address router,
        address[11] memory path,
        uint256 amountIn,
        uint256 minAmountOut,
        bool useFullBalance
    ) internal view returns (SwapLeg memory) {
        return SwapLeg({
            mode: m,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: useFullBalance,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: router,
            bebopCalldata: _curveMHExtData(path),
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: minAmountOut
        });
    }

    function _curveMHSinglePlan(SwapMode m, address[11] memory path, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (LiquidationExecutor.SwapPlan memory)
    {
        return LiquidationExecutor.SwapPlan({
            leg1: _curveMHLeg(
                m, address(collateralToken), address(loanToken), address(curveRouter), path, amountIn, minOut, false
            ),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
    }

    function _path3(address t0, address pool0, address t1, address pool1, address t2)
        internal
        pure
        returns (address[11] memory p)
    {
        p[0] = t0;
        p[1] = pool0;
        p[2] = t1;
        p[3] = pool1;
        p[4] = t2;
    }

    function _path5(
        address t0,
        address p0,
        address t1,
        address p1,
        address t2,
        address p2,
        address t3,
        address p3,
        address t4,
        address p4,
        address t5
    ) internal pure returns (address[11] memory p) {
        p[0] = t0;
        p[1] = p0;
        p[2] = t1;
        p[3] = p1;
        p[4] = t2;
        p[5] = p2;
        p[6] = t3;
        p[7] = p3;
        p[8] = t4;
        p[9] = p4;
        p[10] = t5;
    }

    function _path1(address t0, address pool, address t1) internal pure returns (address[11] memory p) {
        p[0] = t0;
        p[1] = pool;
        p[2] = t1;
    }

    // ───────────────────────────────────────────────────────────────
    // Helpers — Balancer V2 multihop leg construction
    // ───────────────────────────────────────────────────────────────

    function _balMHExtData(
        IBalancerV2Vault.BatchSwapStep[] memory swaps,
        address[] memory assets,
        int256[] memory limits
    ) internal pure returns (bytes memory) {
        return abi.encode(swaps, assets, limits);
    }

    function _balMHLeg(
        SwapMode m,
        address srcToken,
        address dstToken,
        address vault,
        IBalancerV2Vault.BatchSwapStep[] memory swaps,
        address[] memory assets,
        int256[] memory limits,
        uint256 amountIn,
        uint256 minAmountOut,
        bool useFullBalance
    ) internal view returns (SwapLeg memory) {
        return SwapLeg({
            mode: m,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: useFullBalance,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: vault,
            bebopCalldata: _balMHExtData(swaps, assets, limits),
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: minAmountOut
        });
    }

    /// @dev Build SELL-side BatchSwapStep[] for an N-hop straight chain.
    /// `amountIn` lives in `swaps[0].amount`; trailing steps have amount=0
    /// so the Vault chains output→input.
    function _balSellSteps(uint256 amountIn, uint256 hopCount, bytes32 firstPoolId)
        internal
        pure
        returns (IBalancerV2Vault.BatchSwapStep[] memory steps)
    {
        steps = new IBalancerV2Vault.BatchSwapStep[](hopCount);
        for (uint256 s = 0; s < hopCount; ++s) {
            steps[s] = IBalancerV2Vault.BatchSwapStep({
                poolId: bytes32(uint256(firstPoolId) ^ s),
                assetInIndex: s,
                assetOutIndex: s + 1,
                amount: s == 0 ? amountIn : 0,
                userData: ""
            });
        }
    }

    /// @dev Build BUY-side BatchSwapStep[] for an N-hop straight chain.
    /// `exactOut` lives in `swaps[last].amount`; earlier steps have amount=0
    /// so the Vault back-solves the required input.
    function _balBuySteps(uint256 exactOut, uint256 hopCount, bytes32 firstPoolId)
        internal
        pure
        returns (IBalancerV2Vault.BatchSwapStep[] memory steps)
    {
        steps = new IBalancerV2Vault.BatchSwapStep[](hopCount);
        for (uint256 s = 0; s < hopCount; ++s) {
            steps[s] = IBalancerV2Vault.BatchSwapStep({
                poolId: bytes32(uint256(firstPoolId) ^ s),
                assetInIndex: s,
                assetOutIndex: s + 1,
                amount: (s == hopCount - 1) ? exactOut : 0,
                userData: ""
            });
        }
    }

    function _intArray(int256 a, int256 b) internal pure returns (int256[] memory r) {
        r = new int256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _intArray3(int256 a, int256 b, int256 c) internal pure returns (int256[] memory r) {
        r = new int256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _addrArray(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _addrArray3(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    // ═══════════════════════════════════════════════════════════════
    // CURVE V1 MULTIHOP — INTEGRATION (via executor.execute(plan))
    // ═══════════════════════════════════════════════════════════════

    function test_CurveMH_sell_1hop_singletonPath_success() public {
        // Degenerate 1-hop path (still uses the Router primitive, but the
        // mock observes hopCount=1). Verifies Router endpoint plumbing
        // even before native multihop adds any value.
        address[11] memory path = _path1(address(collateralToken), address(0xC0FFEE), address(loanToken));

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.expectEmit(true, true, true, false);
        emit LiquidationExecutor.CurveV1SwapExecuted(
            address(curveRouter), address(collateralToken), address(loanToken), 0, 0
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(curveRouter.exchangeCalls(), 1, "router not called");
        assertEq(curveRouter.lastFirstToken(), address(collateralToken), "src mismatch");
        assertEq(curveRouter.lastFinalToken(), address(loanToken), "dst mismatch");
        assertEq(curveRouter.lastHopCount(), 1, "hop count != 1");
        // Approval must be cleared post-call.
        assertEq(IERC20(address(collateralToken)).allowance(address(executor), address(curveRouter)), 0);
    }

    function test_CurveMH_sell_3hop_success() public {
        // coll → mid → profit → loan — 3 hops, two intermediate tokens.
        // Each hop compounds the 1.1x rate → final factor = 1.1^3 ≈ 1.331x.
        address[11] memory path = _path5(
            address(collateralToken),
            address(0x1),
            address(midToken),
            address(0x2),
            address(profitToken),
            address(0x3),
            address(loanToken),
            address(0),
            address(0),
            address(0),
            address(0)
        );

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(curveRouter.lastHopCount(), 3, "expected 3 hops");
        assertEq(curveRouter.lastAmountIn(), DEFAULT_SWAP_AMOUNT);
        // 1.1^3 = 1.331, applied to DEFAULT_SWAP_AMOUNT.
        uint256 expectedOut = (DEFAULT_SWAP_AMOUNT * SWAP_RATE / 1e18) * SWAP_RATE / 1e18 * SWAP_RATE / 1e18;
        assertEq(curveRouter.lastAmountOut(), expectedOut, "compound rate mismatch");
    }

    function test_CurveMH_sell_5hop_maxPath_success() public {
        // Full 5-hop path — exercise the highest path index slot.
        address[11] memory path = _path5(
            address(collateralToken),
            address(0x1),
            address(midToken),
            address(0x2),
            address(profitToken),
            address(0x3),
            address(mockWeth),
            address(0x4),
            address(loanToken), // hop 4 endpoint
            address(0x5),
            address(loanToken) // final hop endpoint (re-used token by mock — mock doesn't enforce path uniqueness)
        );

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(curveRouter.lastHopCount(), 5, "expected 5 hops");
    }

    function test_CurveMH_buy_3hop_success() public {
        // BUY mode — bot precomputes `dx` so `dy` matches the target
        // exact-out. We just verify the executor dispatches CURVE_V1_MH_BUY
        // through the same RouterNG path (no mode-specific branch on
        // the router side).
        address[11] memory path = _path5(
            address(collateralToken),
            address(0x1),
            address(midToken),
            address(0x2),
            address(profitToken),
            address(0x3),
            address(loanToken),
            address(0),
            address(0),
            address(0),
            address(0)
        );
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH_BUY, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(curveRouter.lastHopCount(), 3);
        assertEq(curveRouter.lastFirstToken(), address(collateralToken));
        assertEq(curveRouter.lastFinalToken(), address(loanToken));
    }

    // ───────────────────────────────────────────────────────────────
    // CURVE V1 MULTIHOP — REVERTS
    // ───────────────────────────────────────────────────────────────

    function test_CurveMH_revertEndpointMismatchSrc() public {
        // path[0] != srcToken. The library decodes the path, checks
        // `path[0] == leg.srcToken`, reverts InvalidPlan otherwise.
        address[11] memory path =
            _path3(address(0xBAD), address(0x1), address(midToken), address(0x2), address(loanToken));
        // Use the helper but inject a deliberately wrong path[0].
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        vm.expectRevert(); // bubbles `CurveV1Lib.InvalidPlan` through flashloan callback
        executor.execute(plan);
    }

    function test_CurveMH_revertEndpointMismatchDst() public {
        // Last non-zero path entry != repayToken.
        address[11] memory path =
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(0xCAFE));
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_CurveMH_revertRouterZero() public {
        // bebopTarget = 0 — caught by validateNonV4Leg (pre-flashloan).
        // Asserts the validation gate fires BEFORE we hit the
        // library's own `InvalidPoolTarget` check.
        SwapLeg memory leg = _curveMHLeg(
            SwapMode.CURVE_V1_MH,
            address(collateralToken),
            address(loanToken),
            address(0),
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken)),
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_CurveMH_revertCalldataTooShort() public {
        // bebopCalldata length < 1312 (the canonical
        // abi.encode(address[11], uint256[5][5], address[5]) size).
        // validateNonV4Leg short-circuits with InvalidPlan.
        SwapLeg memory leg = _curveMHLeg(
            SwapMode.CURVE_V1_MH,
            address(collateralToken),
            address(loanToken),
            address(curveRouter),
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken)),
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        leg.bebopCalldata = hex"de";
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_CurveMH_revertZeroMinAmountOut() public {
        SwapLeg memory leg = _curveMHLeg(
            SwapMode.CURVE_V1_MH,
            address(collateralToken),
            address(loanToken),
            address(curveRouter),
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken)),
            DEFAULT_SWAP_AMOUNT,
            0, // zero — validateNonV4Leg must reject
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_CurveMH_revertRouterSwapFails() public {
        // Router itself reverts mid-swap (simulates pool failure /
        // unexpected slippage). Library catches and bubbles
        // CurveSwapFailed.
        curveRouter.setRevertNext(true);
        address[11] memory path =
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken));
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        vm.expectRevert(); // wraps CurveSwapFailed inside the flashloan unwind
        executor.execute(plan);
    }

    function test_CurveMH_revertInsufficientOutput() public {
        // Operator-supplied minAmountOut larger than what the rate yields.
        // Router enforces its own _expected first ("amountOut < expected"),
        // bubbles through CurveSwapFailed.
        address[11] memory path =
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken));
        // Expected ≈ 1.21 * DEFAULT for 2 hops; demand 100x — guaranteed to underflow.
        LiquidationExecutor.SwapPlan memory sp =
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, DEFAULT_SWAP_AMOUNT * 100);
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_CurveMH_voidReturnTolerated() public {
        // Some Router builds declared the exchange function as `void`
        // (no return value). The library uses balance-delta accounting
        // so it MUST NOT depend on the declared return type.
        curveRouter.setVoidReturn(true);
        address[11] memory path =
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken));
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        executor.execute(plan); // must NOT revert
    }

    function test_CurveMH_approvalClearedAfterCall() public {
        address[11] memory path =
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken));
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _defaultLiqAction(500e18),
            _curveMHSinglePlan(SwapMode.CURVE_V1_MH, path, DEFAULT_SWAP_AMOUNT, 1)
        );
        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(IERC20(address(collateralToken)).allowance(address(executor), address(curveRouter)), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // BALANCER V2 MULTIHOP — INTEGRATION
    // ═══════════════════════════════════════════════════════════════

    function test_BalMH_sell_2hop_success() public {
        // coll → mid → loan, GIVEN_IN
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF)));
        address[] memory assets = _addrArray3(address(collateralToken), address(midToken), address(loanToken));
        // Min-out limit on the destination side: 1 wei (operator-allowed).
        int256[] memory limits = _intArray3(int256(DEFAULT_SWAP_AMOUNT), int256(0), int256(1));

        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            swaps,
            assets,
            limits,
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );

        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);

        vm.expectEmit(true, true, true, false);
        emit LiquidationExecutor.BalancerV2SwapExecuted(
            swaps[0].poolId, address(collateralToken), address(loanToken), 0, 0, 0
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(balancerBatchVault.batchSwapCalls(), 1, "vault not called");
        assertEq(balancerBatchVault.lastStepCount(), 2, "step count != 2");
        assertEq(balancerBatchVault.lastSrcAsset(), address(collateralToken));
        assertEq(balancerBatchVault.lastDstAsset(), address(loanToken));
        assertEq(IERC20(address(collateralToken)).allowance(address(executor), address(balancerBatchVault)), 0);
    }

    function test_BalMH_sell_3hop_success() public {
        // coll → mid → profit → loan
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(DEFAULT_SWAP_AMOUNT, 3, bytes32(uint256(0xABCD)));
        address[] memory assets = new address[](4);
        assets[0] = address(collateralToken);
        assets[1] = address(midToken);
        assets[2] = address(profitToken);
        assets[3] = address(loanToken);
        int256[] memory limits = new int256[](4);
        limits[0] = int256(DEFAULT_SWAP_AMOUNT);
        limits[1] = 0;
        limits[2] = 0;
        limits[3] = int256(uint256(1));

        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            swaps,
            assets,
            limits,
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(balancerBatchVault.lastStepCount(), 3);
    }

    function test_BalMH_buy_2hop_success() public {
        // BUY: target exact-out lives in swaps[last].amount.
        // The flashloan callback enforces post-swap output ≥ loan + fee,
        // so the exact-out target must clear `LOAN_AMOUNT + FLASH_FEE`.
        // 1.1^2 input multiplier means we need at most exactOut / 1.21
        // of source — comfortably under DEFAULT_SWAP_AMOUNT (= 1000e18).
        uint256 exactOut = LOAN_AMOUNT + FLASH_FEE;
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balBuySteps(exactOut, 2, bytes32(uint256(0xFFEE)));
        address[] memory assets = _addrArray3(address(collateralToken), address(midToken), address(loanToken));
        int256[] memory limits = _intArray3(
            -int256(DEFAULT_SWAP_AMOUNT), // max in
            int256(0),
            int256(exactOut) // exact-out
        );

        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH_BUY,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            swaps,
            assets,
            limits,
            DEFAULT_SWAP_AMOUNT, // amountIn = upper bound
            exactOut,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(balancerBatchVault.lastDelivered(), exactOut, "delivered must equal exact-out");
        assertGt(balancerBatchVault.lastConsumed(), 0);
        assertLe(balancerBatchVault.lastConsumed(), DEFAULT_SWAP_AMOUNT, "consumed > approved");
        assertEq(uint8(balancerBatchVault.lastKind()), 1, "kind=GIVEN_OUT");
    }

    // ───────────────────────────────────────────────────────────────
    // BALANCER V2 MULTIHOP — REVERTS
    // ───────────────────────────────────────────────────────────────

    function test_BalMH_revertEndpointMismatchSrc() public {
        // assets[0] != srcToken
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF)));
        address[] memory assets = _addrArray3(address(0xBAD), address(midToken), address(loanToken));
        int256[] memory limits = _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, 1);

        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            swaps,
            assets,
            limits,
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_BalMH_revertEndpointMismatchDst() public {
        // assets[last] != repayToken
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF)));
        address[] memory assets = _addrArray3(address(collateralToken), address(midToken), address(0xCAFE));
        int256[] memory limits = _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, 1);

        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            swaps,
            assets,
            limits,
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_BalMH_revertVaultZero() public {
        // bebopTarget = 0 — caught by validateNonV4Leg (pre-flashloan).
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF)));
        address[] memory assets = _addrArray3(address(collateralToken), address(midToken), address(loanToken));
        int256[] memory limits = _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, 1);

        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(0),
            swaps,
            assets,
            limits,
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_BalMH_revertCalldataTooShort() public {
        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF))),
            _addrArray3(address(collateralToken), address(midToken), address(loanToken)),
            _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, 1),
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        leg.bebopCalldata = hex"de"; // below 192-byte sanity floor
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_BalMH_revertZeroMinAmountOut() public {
        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF))),
            _addrArray3(address(collateralToken), address(midToken), address(loanToken)),
            _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, 1),
            DEFAULT_SWAP_AMOUNT,
            0,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_BalMH_revertVaultReverts() public {
        balancerBatchVault.setRevertNext(true);
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF)));
        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            swaps,
            _addrArray3(address(collateralToken), address(midToken), address(loanToken)),
            _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, 1),
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_BalMH_revertReceivedBelowMinOut() public {
        // Operator demands more than the rate yields — mock's
        // `delivered >= minOut` check fires inside batchSwap.
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF)));
        // 1.1^2 = 1.21 * DEFAULT; demand 100x → underflow.
        uint256 unreachableMin = DEFAULT_SWAP_AMOUNT * 100;
        SwapLeg memory leg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            swaps,
            _addrArray3(address(collateralToken), address(midToken), address(loanToken)),
            _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, int256(unreachableMin)),
            DEFAULT_SWAP_AMOUNT,
            unreachableMin,
            false
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════
    // SwapValidationLib — branch coverage on the four new modes
    // ═══════════════════════════════════════════════════════════════

    function _validateLeg(SwapLeg memory leg) internal view {
        SwapValidationLib.validateNonV4Leg(leg);
    }

    function _validCurveMHLeg() internal view returns (SwapLeg memory) {
        return _curveMHLeg(
            SwapMode.CURVE_V1_MH,
            address(collateralToken),
            address(loanToken),
            address(curveRouter),
            _path3(address(collateralToken), address(0x1), address(midToken), address(0x2), address(loanToken)),
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
    }

    function _validBalMHLeg() internal view returns (SwapLeg memory) {
        return _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(loanToken),
            address(balancerBatchVault),
            _balSellSteps(DEFAULT_SWAP_AMOUNT, 2, bytes32(uint256(0xBEEF))),
            _addrArray3(address(collateralToken), address(midToken), address(loanToken)),
            _intArray3(int256(DEFAULT_SWAP_AMOUNT), 0, 1),
            DEFAULT_SWAP_AMOUNT,
            1,
            false
        );
    }

    function test_validate_CurveMH_accepts_validLeg() public view {
        _validateLeg(_validCurveMHLeg());
    }

    function test_validate_CurveMHBuy_normalisesToSell() public view {
        SwapLeg memory leg = _validCurveMHLeg();
        leg.mode = SwapMode.CURVE_V1_MH_BUY;
        _validateLeg(leg);
    }

    function test_validate_CurveMH_rejectsTargetZero() public {
        SwapLeg memory leg = _validCurveMHLeg();
        leg.bebopTarget = address(0);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        _validateLeg(leg);
    }

    function test_validate_CurveMH_rejectsCalldataTooShort() public {
        SwapLeg memory leg = _validCurveMHLeg();
        leg.bebopCalldata = hex"de";
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        _validateLeg(leg);
    }

    function test_validate_CurveMH_rejectsZeroMinOut() public {
        SwapLeg memory leg = _validCurveMHLeg();
        leg.minAmountOut = 0;
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        _validateLeg(leg);
    }

    function test_validate_BalMH_accepts_validLeg() public view {
        _validateLeg(_validBalMHLeg());
    }

    function test_validate_BalMHBuy_normalisesToSell() public view {
        SwapLeg memory leg = _validBalMHLeg();
        leg.mode = SwapMode.BAL_V2_MH_BUY;
        _validateLeg(leg);
    }

    function test_validate_BalMH_rejectsTargetZero() public {
        SwapLeg memory leg = _validBalMHLeg();
        leg.bebopTarget = address(0);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        _validateLeg(leg);
    }

    function test_validate_BalMH_rejectsCalldataTooShort() public {
        SwapLeg memory leg = _validBalMHLeg();
        leg.bebopCalldata = hex"de";
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        _validateLeg(leg);
    }

    function test_validate_BalMH_rejectsZeroMinOut() public {
        SwapLeg memory leg = _validBalMHLeg();
        leg.minAmountOut = 0;
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        _validateLeg(leg);
    }

    // ═══════════════════════════════════════════════════════════════
    // Plan-shape allowlist (leg2 sequential + SPLIT + MIXED_SPLIT)
    // ═══════════════════════════════════════════════════════════════

    function test_CurveMH_acceptedAsLeg2InTwoLegPlan() public {
        // leg1 = Uni V3 (coll → mid), leg2 = Curve V1 MH (mid → loan)
        // useFullBalance=true so leg2's amountIn comes from leg1's
        // measured output delta. This exercises the leg2 allowlist
        // extension in LiquidationExecutor.sol.
        SwapLeg memory leg1 =
            _buildUniV3SellLeg(address(collateralToken), address(midToken), DEFAULT_SWAP_AMOUNT, 1, 3000);
        SwapLeg memory leg2 = _curveMHLeg(
            SwapMode.CURVE_V1_MH,
            address(midToken),
            address(loanToken),
            address(curveRouter),
            _path1(address(midToken), address(0xC0FFEE), address(loanToken)),
            0, // useFullBalance — runtime
            1,
            true
        );
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: true,
            leg2: leg2,
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);

        // Fund the V3 mock with the mid token so leg1 can settle.
        midToken.mint(address(uniV3Mock), 100_000e18);

        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(curveRouter.exchangeCalls(), 1, "curve MH not dispatched in leg2");
    }

    function test_BalMH_acceptedInSplitPlan() public {
        // leg1 = Uni V3 SELL (coll → loan)         — repay leg
        // leg2 = Bal V2 MH SELL (coll → WETH)      — profit leg
        // both sized by splitBps of the collateral delta.
        SwapLeg memory repayLeg = _buildUniV3SellLeg(
            address(collateralToken), address(loanToken), uint256(COLLATERAL_REWARD) * 95 / 100, 1, 3000
        );
        // Setting splitBps=500 (5%) — leg2 inputs 5% of COLLATERAL_REWARD.
        // 5% = 50e18, but the contract overrides amountIn at runtime so
        // the helper-passed amountIn for leg2 only needs to be >0 for
        // validation. We use 50e18 to mirror the runtime size.
        IBalancerV2Vault.BatchSwapStep[] memory swaps = _balSellSteps(50e18, 2, bytes32(uint256(0xFEED)));
        address[] memory assets = _addrArray3(address(collateralToken), address(midToken), address(mockWeth));
        int256[] memory limits = _intArray3(int256(50e18), 0, 1);
        SwapLeg memory profitLeg = _balMHLeg(
            SwapMode.BAL_V2_MH,
            address(collateralToken),
            address(mockWeth),
            address(balancerBatchVault),
            swaps,
            assets,
            limits,
            50e18,
            1,
            false
        );

        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            leg1: repayLeg,
            hasLeg2: false,
            leg2: profitLeg,
            hasSplit: true,
            splitBps: 500,
            hasMixedSplit: false,
            profitToken: address(mockWeth),
            minProfitAmount: 0
        });
        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);

        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(balancerBatchVault.batchSwapCalls(), 1, "Bal MH not dispatched in profit leg");
    }

    // ─── Small helper to build a Uni V3 SELL leg (used by leg1 in TwoLeg test) ──
    function _buildUniV3SellLeg(address src, address dst, uint256 amountIn, uint256 minOut, uint24 fee)
        internal
        view
        returns (SwapLeg memory)
    {
        return SwapLeg({
            mode: SwapMode.UNI_V3,
            srcToken: src,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: fee,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dst,
            minAmountOut: minOut
        });
    }
}
