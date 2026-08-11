// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Action, AaveV3Action, AaveV2Liquidation, MorphoLiquidation} from "../../src/types/SwapTypes.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";
import {SwapMode, SwapLeg, Op} from "../../src/types/SwapTypes.sol";

// ─── Minimal fork-side interfaces (jackpot integration test) ──────────

interface IAavePoolFork {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function ADDRESSES_PROVIDER() external view returns (address);
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IAddressesProviderFork {
    function getPriceOracle() external view returns (address);
}

interface IPriceOracleFork {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @dev USDT-compatible (no bool returns on transfer/approve).
interface IERC20Fork {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface IFlashRecipientFork {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/// @dev Balancer-shaped flash lender standing in for the real flash source.
/// The jackpot chain's flash (Balancer/Morpho USDT) is NOT what Task 5
/// validates — the swap chain against the REAL V4 PoolManager + Curve is.
/// This mock is passed as the executor's constructor `balancerVault_`, so the
/// executor's own `receiveFlashLoan` caller/plan-hash/amount gates all still
/// run for real. Zero fee; reverts if the executor fails to repay in full.
contract MockUsdtFlashLender {
    error FlashNotRepaid();

    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external
    {
        IERC20Fork token = IERC20Fork(tokens[0]);
        uint256 balBefore = token.balanceOf(address(this));
        token.transfer(recipient, amounts[0]);
        uint256[] memory fees = new uint256[](1); // zero-fee flash
        IFlashRecipientFork(recipient).receiveFlashLoan(tokens, amounts, fees, userData);
        if (token.balanceOf(address(this)) < balBefore) revert FlashNotRepaid();
    }
}

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
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
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
            MORPHO_BLUE,
            PARASWAP_AUGUSTUS,
            UNI_V2_ROUTER,
            UNI_V3_ROUTER,
            targets
        );
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _zeroLeg() internal pure returns (SwapLeg memory) {
        return SwapLeg({
            mode: SwapMode.PARASWAP_SINGLE,
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
            minAmountOut: 1
        });
    }

    function _basePlan(bytes memory v4Data) internal view returns (LiquidationExecutor.SwapPlan memory) {
        SwapLeg memory leg1 = SwapLeg({
            mode: SwapMode.UNI_V4,
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
            hasGenericSequence: false,
            ops: new Op[](0),
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
        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            protocolId: 1,
            data: abi.encode(
                AaveV3Action({
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
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_fork_UniV4_zeroFee_reverts() public forkOnly {
        bytes memory v4Data = abi.encode(USDC, WETH, uint24(0), int24(60), address(0));
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_fork_UniV4_zeroTickSpacing_reverts() public forkOnly {
        bytes memory v4Data = abi.encode(USDC, WETH, uint24(3000), int24(0), address(0));
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_fork_UniV4_rogueHook_reverts() public forkOnly {
        address rogueHook = address(0xdeadbeef);
        bytes memory v4Data = abi.encode(USDC, WETH, uint24(3000), int24(60), rogueHook);
        LiquidationExecutor.SwapPlan memory sp = _basePlan(v4Data);
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_fork_UniV4_malformedData_reverts() public forkOnly {
        LiquidationExecutor.SwapPlan memory sp = _basePlan(hex"aabbcc");
        bytes memory plan = _wrapInPlan(sp);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
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
        vm.expectRevert(LiquidationExecutor.TargetNotAllowed.selector);
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

    // ═══════════════════════════════════════════════════════════════════
    // Task 5 — jackpot-block integration: the FULL native-ETH V4 chain
    // against the REAL mainnet PoolManager + Curve + Aave.
    //
    //   flash USDT → Aave liquidationCall (REAL, seizes WETH)
    //     → GENERIC_SEQUENCE:
    //         op0 FLAG_WETH_UNWRAP  : seized WETH → native ETH (receive())
    //         op1 FLAG_V4_UNLOCK    : native ETH → DAI, REAL PM, ETH/DAI
    //                                 fee=3000 tickSpacing=60 hook=0 —
    //                                 pool 0x042a5b2c…, the jackpot pool
    //         op2 direct Curve call : DAI → USDT via the REAL 3pool
    //     → flash repaid from the Curve output; leftover WETH + ETH = profit
    //
    // REAL on this fork: Aave V3 Pool (liquidationCall + WETH seizure),
    // V4 PoolManager (unlock → swap → settle{value} → take), Curve 3pool,
    // WETH9.withdraw (whose ETH lands in the executor's ungated receive()).
    //
    // MOCKED (deliberately — this test proves the swap-chain mechanics, not
    // the flash source or the borrower's price path):
    //   * the USDT flash: `MockUsdtFlashLender` wired as the constructor's
    //     `balancerVault_` (zero fee, funded via `deal`). The executor's own
    //     `receiveFlashLoan` gates (caller / plan-hash / amount) run for real.
    //   * the WETH oracle price: dropped 20% via `vm.mockCall` so a synthetic
    //     100-WETH / USDT-debt borrower becomes liquidatable (HF < 0.95 →
    //     100% close factor). The real jackpot borrower (0x2269ce27…) was
    //     liquidated IN block 25256119, so post-block state has no natural
    //     position left; the synthetic one reproduces the same shape
    //     (WETH collateral / USDT debt) at a size the fork can host.
    //
    // Scale note: the winner routed 13,666 ETH (~$20.5M) through this exact
    // pool at ~2.05%; this test routes ~80 ETH (~$115k) — depth at full size
    // was de-risked separately, the CONTRACT MECHANICS are what's proven here.
    // ═══════════════════════════════════════════════════════════════════

    uint256 constant JACKPOT_BLOCK = 25_256_119;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    uint32 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint32 constant FLAG_V4_UNLOCK = 1 << 2;
    uint32 constant FLAG_WETH_UNWRAP = 1 << 3;
    /// Curve 3pool exchange(int128,int128,uint256,uint256): dx at
    /// selector(4) + i(32) + j(32) = byte 68.
    uint16 constant CURVE_DX_POS = 68;

    function test_fork_jackpot_unwrap_v4_curve_liquidate() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, JACKPOT_BLOCK);

        // ── Deploy: mock flash lender as the Balancer slot, real targets ──
        MockUsdtFlashLender flashLender = new MockUsdtFlashLender();
        address[] memory targets = new address[](2);
        targets[0] = V4_POOL_MANAGER;
        targets[1] = CURVE_3POOL;
        LiquidationExecutor exec = new LiquidationExecutor(
            owner,
            operatorAddr,
            WETH,
            AAVE_V3_POOL,
            address(flashLender),
            MORPHO_BLUE,
            PARASWAP_AUGUSTUS,
            UNI_V2_ROUTER,
            UNI_V3_ROUTER,
            targets
        );

        // ── Synthetic liquidatable position: 100 WETH collateral, USDT debt ──
        address borrower = makeAddr("jackpotBorrower");
        uint256 collateralSupply = 100 ether;
        deal(WETH, borrower, collateralSupply);

        address oracle = IAddressesProviderFork(IAavePoolFork(AAVE_V3_POOL).ADDRESSES_PROVIDER()).getPriceOracle();
        uint256 pWeth = IPriceOracleFork(oracle).getAssetPrice(WETH); // USD, 8 decimals
        uint256 pUsdt = IPriceOracleFork(oracle).getAssetPrice(USDT);

        // Borrow 73% of collateral value in USDT (under WETH's ~80.5% LTV).
        uint256 borrowAmount = (collateralSupply * pWeth * 73) / (pUsdt * 100 * 1e12); // 6 decimals
        vm.startPrank(borrower);
        IERC20Fork(WETH).approve(AAVE_V3_POOL, collateralSupply);
        IAavePoolFork(AAVE_V3_POOL).supply(WETH, collateralSupply, borrower, 0);
        IAavePoolFork(AAVE_V3_POOL).borrow(USDT, borrowAmount, 2, 0, borrower);
        vm.stopPrank();

        // Crash WETH 20% (oracle only — the V4 pool keeps its REAL price).
        // HF = LT * 0.80 / 0.73 < 0.95 for any plausible WETH LT → 100%
        // close factor, full-debt liquidation.
        uint256 mockedWethPrice = (pWeth * 80) / 100;
        vm.mockCall(
            oracle, abi.encodeWithSelector(IPriceOracleFork.getAssetPrice.selector, WETH), abi.encode(mockedWethPrice)
        );
        (,,,,, uint256 hf) = IAavePoolFork(AAVE_V3_POOL).getUserAccountData(borrower);
        assertLt(hf, 0.95e18, "borrower must be below the 100%-close-factor threshold");

        // ── Sizing (all deterministic from the prices above) ──
        // Flash a $100 buffer over the borrowed debt (covers debt-index
        // rounding wei); debtToCover = max → Aave caps at the full debt.
        uint256 loanAmount = borrowAmount + 100e6;
        // V4 exact-out DAI target: flash repay + 2% (Curve fee / DAI–USDT
        // drift buffer). 18 decimals.
        uint256 daiOut = (loanAmount * 1e12 * 102) / 100;
        // ETH to unwrap: the DAI target at the REAL oracle price + 8% margin
        // (0.3% pool fee + post-jackpot-dump pool discount + slippage).
        uint256 unwrapAmount = (daiOut * 1e8 * 108) / (pWeth * 100);
        // Expected WETH seizure at the MOCKED price with the 5% bonus — the
        // unwrap must fit inside it (per-srcToken containment cap).
        uint256 expectedSeizure = (borrowAmount * pUsdt * 1e12 * 10_500) / (mockedWethPrice * 10_000);
        assertLt(unwrapAmount, expectedSeizure, "unwrap must fit inside the seized collateral");

        deal(USDT, address(flashLender), loanAmount);

        // ── The chain: unwrap → native V4 (real PM) → Curve → repay ──
        Op[] memory ops = new Op[](3);
        // op0: seized WETH → native ETH (WETH9.withdraw → executor receive()).
        ops[0].srcToken = WETH;
        ops[0].amountIn = unwrapAmount;
        ops[0].flags = FLAG_WETH_UNWRAP;
        // op1: native ETH → DAI, exact-out, through the REAL PoolManager.
        // 5-tuple = (ETH=0x0, DAI, fee=3000, tickSpacing=60, hook=0) — the
        // jackpot pool 0x042a5b2c816d473338d6d1fff7d4e2f74a4bf6d9517e74538f3778d0693aef69.
        ops[1].target = V4_POOL_MANAGER;
        ops[1].srcToken = address(0); // native ETH
        ops[1].outToken = DAI;
        ops[1].flags = FLAG_V4_UNLOCK;
        ops[1].amountIn = daiOut; // exact-out spec
        ops[1].callData = abi.encode(address(0), DAI, uint24(3000), int24(60), address(0));
        // op2: DAI → USDT on the real Curve 3pool (i=0 DAI, j=2 USDT); dx is
        // patched at runtime with op1's realized DAI output.
        ops[2].target = CURVE_3POOL;
        ops[2].srcToken = DAI;
        ops[2].outToken = USDT;
        ops[2].flags = FLAG_USE_PREV_RETURN;
        ops[2].fromAmountPos = CURVE_DX_POS;
        ops[2].callData = abi.encodeWithSignature(
            "exchange(int128,int128,uint256,uint256)", int128(0), int128(2), uint256(0), loanAmount
        );

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            protocolId: 1,
            data: abi.encode(
                AaveV3Action({
                    actionType: 4,
                    asset: address(0),
                    amount: 0,
                    interestRateMode: 0,
                    onBehalfOf: address(0),
                    collateralAsset: WETH,
                    debtAsset: USDT,
                    user: borrower,
                    debtToCover: type(uint256).max,
                    receiveAToken: false,
                    aTokenAddress: address(0)
                })
            )
        });

        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.ops = ops;
        sp.leg1 = _zeroLeg();
        sp.leg2 = _zeroLeg();
        sp.profitToken = USDT;
        sp.minProfitAmount = 0;

        bytes memory plan = abi.encode(
            LiquidationExecutor.Plan({
                flashProviderId: 2, // FLASH_PROVIDER_BALANCER slot = the mock lender
                loanToken: USDT,
                loanAmount: loanAmount,
                maxFlashFee: 0,
                actions: actions,
                swapPlan: sp
            })
        );

        // Deltas, not absolutes — the deterministic deploy address can hold
        // pre-existing mainnet dust on a fork (it does: 1 wei of ETH).
        uint256 ethBefore = address(exec).balance;
        uint256 wethBefore = IERC20Fork(WETH).balanceOf(address(exec));

        vm.prank(operatorAddr);
        exec.execute(plan);

        // ── Asserts: chain routed, flash repaid, net WETH/ETH profit > 0 ──
        // Native ETH profit = unwrapped − settled. Its presence proves BOTH
        // that WETH9.withdraw's ETH landed in the ungated receive() AND that
        // the real PM's settle{value} took no more than the pool owed.
        uint256 ethProfit = address(exec).balance - ethBefore;
        assertGt(ethProfit, 1 ether, "native ETH left over after settle{value} (receive() exercised)");
        // WETH profit = seized collateral not consumed by the unwrap.
        uint256 wethProfit = IERC20Fork(WETH).balanceOf(address(exec)) - wethBefore;
        assertGt(wethProfit, 0, "seized WETH beyond the unwrap must remain as profit");
        // Flash fully repaid (the mock reverts otherwise — assert anyway).
        assertGe(IERC20Fork(USDT).balanceOf(address(flashLender)), loanAmount, "flash lender must be made whole");
    }
}
