// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";

/// @title ExecutorForkV4Test
/// @notice FORK-ONLY tests for the Uniswap V4 swap path against the real
/// mainnet PoolManager (0x000000000004444c5dc75cB358380D2e3dE08A90).
///
/// Runs only when `MAINNET_RPC_URL` is exported; absent RPC → silent skip.
/// Invocation:
///
///     MAINNET_RPC_URL=https://... forge test --match-path "test/fork/*"
///
/// Scope:
/// - Validation fork tests exercise the fail-closed gates (native ETH,
///   wrong tokenOut, zero fee, zero tickSpacing, unwhitelisted hook,
///   malformed v4SwapData). These fire in `execute()`'s eager
///   `_validateV4Leg` call BEFORE any flashloan request, so they work
///   against the real PoolManager without needing a liquidatable position.
/// - Happy-path fork tests (real swap through mainnet V4) are gated
///   behind `test_fork_UniV4_happyPath_skipped_needsLiquidatablePosition`
///   — see the TODO notes there. Executing a real V4 swap end-to-end
///   requires either (a) pinning a historical block with a known
///   liquidatable Aave/Morpho position, or (b) a custom harness that
///   bypasses the flashloan gate. Both are out of scope for this pass.
///
/// Mainnet addresses: see README.md.
contract ExecutorForkV4Test is Test {
    // ─── Mainnet addresses ─────────────────────────────────────────────
    address constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    address owner = address(0xA11CE);
    address operatorAddr = address(0xB0B);

    LiquidationExecutor executor;

    modifier forkOnly() {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // skip marker lives on each test
        vm.createSelectFork(rpc);

        address[] memory targets = new address[](1);
        targets[0] = V4_POOL_MANAGER;

        executor = new LiquidationExecutor(
            owner,
            operatorAddr,
            WETH,
            AAVE_V3_POOL,
            BALANCER_VAULT,
            PARASWAP_AUGUSTUS,
            UNI_V2_ROUTER,
            UNI_V3_ROUTER,
            targets
        );
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _zeroLeg() internal pure returns (LiquidationExecutor.SwapLeg memory) {
        return LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(0),
            amountIn: 0,
            useFullBalance: false,
            deadline: 0,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: address(0),
            minAmountOut: 0
        });
    }

    function _basePlan(bytes memory v4Data) internal view returns (LiquidationExecutor.SwapPlan memory) {
        LiquidationExecutor.SwapLeg memory leg1 = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V4,
            srcToken: USDC,
            amountIn: 1000e6,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: V4_POOL_MANAGER,
            v4SwapData: v4Data,
            repayToken: WETH,
            minAmountOut: 1
        });
        return LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: WETH,
            minProfitAmount: 0
        });
    }

    function _wrapInPlan(LiquidationExecutor.SwapPlan memory sp) internal view returns (bytes memory) {
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](1);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: abi.encode(
                LiquidationExecutor.AaveV3Action({
                    actionType: 4,
                    asset: address(0),
                    amount: 0,
                    interestRateMode: 0,
                    onBehalfOf: address(0),
                    collateralAsset: USDC,
                    debtAsset: WETH,
                    user: address(0x1234),
                    debtToCover: 1e6,
                    receiveAToken: false,
                    aTokenAddress: address(0)
                })
            )
        });
        return abi.encode(
            LiquidationExecutor.Plan({
                flashProviderId: 2, loanToken: WETH, loanAmount: 1e18, maxFlashFee: 1e15, actions: actions, swapPlan: sp
            })
        );
    }

    // ─── Validation fork tests ────────────────────────────────────────
    // These run the eager `_validateV4Leg` against the real PoolManager
    // allowlist slot and revert before any flashloan request.

    function test_fork_UniV4_nativeETH_tokenIn_reverts() public forkOnly {
        bytes memory v4Data = abi.encode(address(0), WETH, uint24(3000), int24(60), address(0));
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        sp.leg1.srcToken = address(0);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_fork_UniV4_wrongTokenOut_reverts() public forkOnly {
        // repayToken = WETH, decoded tokenOut = USDC → InvalidV4TokenOut
        bytes memory v4Data = abi.encode(USDC, USDC, uint24(3000), int24(60), address(0));
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidV4TokenOut.selector, WETH, USDC));
        executor.execute(plan);
    }

    function test_fork_UniV4_zeroFee_reverts() public forkOnly {
        bytes memory v4Data = abi.encode(USDC, WETH, uint24(0), int24(60), address(0));
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.InvalidV4FeeOrSpacing.selector, uint24(0), int24(60))
        );
        executor.execute(plan);
    }

    function test_fork_UniV4_zeroTickSpacing_reverts() public forkOnly {
        bytes memory v4Data = abi.encode(USDC, WETH, uint24(3000), int24(0), address(0));
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.InvalidV4FeeOrSpacing.selector, uint24(3000), int24(0))
        );
        executor.execute(plan);
    }

    function test_fork_UniV4_rogueHook_reverts() public forkOnly {
        address rogueHook = address(0xdeadbeef);
        bytes memory v4Data = abi.encode(USDC, WETH, uint24(3000), int24(60), rogueHook);
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.V4HookNotAllowed.selector, rogueHook));
        executor.execute(plan);
    }

    function test_fork_UniV4_malformedData_reverts() public forkOnly {
        LiquidationExecutor.SwapPlan memory sp = _basePlan(hex"aabbcc");
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV4Data.selector);
        executor.execute(plan);
    }

    function test_fork_UniV4_unwhitelistedPoolManager_reverts() public forkOnly {
        // A PoolManager address that was not added to allowedTargets at
        // construction — even if the payload is otherwise well-formed,
        // _validateV4Leg must reject.
        address stranger = address(0x1234);
        bytes memory v4Data = abi.encode(USDC, WETH, uint24(3000), int24(60), address(0));
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        sp.leg1.v4PoolManager = stranger;
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, stranger));
        executor.execute(plan);
    }

    // ─── Happy-path scaffolding ────────────────────────────────────────

    /// @dev FORK-ONLY — requires additional setup out of scope for this pass.
    ///
    /// To exercise an end-to-end V4 swap against the real mainnet PoolManager,
    /// one of the following is needed:
    ///   (a) Pin the fork to a historical block with a known liquidatable
    ///       Aave V3 / Morpho Blue position whose debt asset is available
    ///       in a V4 pool with sufficient liquidity, OR
    ///   (b) A dedicated test-only harness contract that bypasses the
    ///       flashloan + liquidation gate and invokes `_executeUniV4`
    ///       directly (requires exposing internals — rejected as
    ///       production-code contamination).
    ///
    /// Until either is wired up, this test documents the expected shape and
    /// short-circuits via `vm.skip`. The validation fork tests above are the
    /// current coverage of real PoolManager behaviour.
    function test_fork_UniV4_happyPath_skipped_needsLiquidatablePosition() public forkOnly {
        vm.skip(true);
        // Outline (when setup is wired up):
        //   1. vm.rollFork(<block with liquidatable position>);
        //   2. Fund executor with debt asset via vm.deal / token whale prank.
        //   3. Build plan pointing at a real V4 pool (USDC/WETH fee=500,
        //      tickSpacing=10, hook=address(0)).
        //   4. vm.prank(operatorAddr); executor.execute(plan);
        //   5. Assert loanToken balance delta >= repayAmount, profit > 0,
        //      and `UniV4SwapExecuted` event emitted with the expected tokens.
    }
}
