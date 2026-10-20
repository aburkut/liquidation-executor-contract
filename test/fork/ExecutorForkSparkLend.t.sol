// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ExecutorDeploy} from "../support/ExecutorDeploy.sol";
import {Action, AaveV2Liquidation, SwapMode, SwapLeg, Op} from "../../src/types/SwapTypes.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";

interface ISparkPoolFork {
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256 totalDebtBase, uint256, uint256, uint256, uint256 healthFactor);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @title ExecutorForkSparkLendTest
/// @notice Replays a REAL SparkLend liquidation through this executor at the
/// point in its block where it happened.
///
/// The position: 0xb2313d01…cb9d on SparkLend, WETH collateral and DAI debt,
/// liquidated in block 25_661_831 (tx index 3, 0xed6388a1…6998) by
/// 0x98a21b06…22ef for 1152.113350978690438779 DAI of debt and
/// 0.653645496911972546 WETH of collateral, receiveAToken = false.
///
/// The executor is built from this tree (implementation + Genesis + proxy, as
/// production). What the test proves is the code path: a Morpho flash of DAI,
/// protocol 4 (`_executeAaveV2Liquidation` against `sparkLendPool`) on the
/// real SparkLend Pool, an exact-out Uniswap V3 leg (WETH -> DAI, 0.05%)
/// buying back the loan, the rest of the WETH as profit, the coinbase paid
/// from it.
///
/// Mainnet needs TWO owner calls after this implementation is live:
/// `setAllowedTarget(0xC13e21B648A5Ee794902342038FF3aDAB66BE987, true)` and
/// `setSparkLendPool(0xC13e21B648A5Ee794902342038FF3aDAB66BE987)`.
///
///     MAINNET_RPC_URL=https://eth.drpc.org forge test --match-path test/fork/ExecutorForkSparkLend.t.sol
contract ExecutorForkSparkLendTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /// Fork AT the liquidation tx: state after every earlier tx of its block.
    bytes32 constant LIQ_TX = 0xed6388a145945eb55e0a54d18aec85f16140f8f260281e87178d82c6a6406998;
    address constant USER = 0xB2313d010c56305Cd8389CD3D78Eecf5632ecB9d;
    uint256 constant DEBT_TO_COVER = 1_152_113_350_978_690_438_779;
    uint256 constant COLLATERAL_SEIZED = 653_645_496_911_972_546;

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
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, LIQ_TX);

        address[] memory targets = new address[](1);
        targets[0] = SPARK_POOL;
        executor = ExecutorDeploy.liquidation(
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
        vm.prank(owner);
        executor.setSparkLendPool(SPARK_POOL);
    }

    function _noSwapLeg() internal pure returns (SwapLeg memory) {
        return SwapLeg({
            mode: SwapMode.NO_SWAP,
            srcToken: WETH,
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
            repayToken: DAI,
            minAmountOut: 0,
            bebopPartialFillOffset: 0
        });
    }

    /// Buy exactly the loan's DAI back with at most the seized WETH.
    function _buyDaiLeg(uint256 daiOut) internal view returns (SwapLeg memory) {
        return SwapLeg({
            mode: SwapMode.UNI_V3_BUY,
            srcToken: WETH,
            amountIn: COLLATERAL_SEIZED,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 500,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: DAI,
            minAmountOut: daiOut,
            bebopPartialFillOffset: 0
        });
    }

    function _plan(uint8 protocolId, uint256 debtToCover, uint256 minProfit) internal view returns (bytes memory) {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            protocolId: protocolId,
            data: abi.encode(
                AaveV2Liquidation({
                    collateralAsset: WETH, debtAsset: DAI, user: USER, debtToCover: debtToCover, receiveAToken: false
                })
            )
        });
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            hasGenericSequence: false,
            ops: new Op[](0),
            leg1: _buyDaiLeg(debtToCover),
            hasLeg2: false,
            leg2: _noSwapLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: WETH,
            minProfitAmount: minProfit
        });
        return abi.encode(
            LiquidationExecutor.Plan({
                flashProviderId: 3, // Morpho: zero fee
                loanToken: DAI,
                loanAmount: debtToCover,
                maxFlashFee: 0,
                actions: actions,
                swapPlan: sp
            })
        );
    }

    function test_fork_sparkLend_realLiquidation_wethDai_paysCoinbase() public forkOnly {
        (, uint256 debtBefore,,,, uint256 hfBefore) = ISparkPoolFork(SPARK_POOL).getUserAccountData(USER);
        assertLt(hfBefore, 1e18, "position must be liquidatable before the tx");

        address builder = address(0xC0FFEE);
        vm.coinbase(builder);
        uint256 builderBefore = builder.balance;
        uint256 execBefore = IERC20Min(WETH).balanceOf(address(executor));

        // 50% of the profit to the builder (wei == bps).
        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        executor.execute{value: 5_000}(_plan(4, DEBT_TO_COVER, 1));

        uint256 paid = builder.balance - builderBefore;
        uint256 kept = IERC20Min(WETH).balanceOf(address(executor)) - execBefore;
        assertGt(paid, 0, "the builder is paid");
        assertGt(kept, 0, "the executor keeps WETH");
        // Profit = seized WETH minus what buying the DAI back cost: under the
        // whole seized amount, and the builder got half of it.
        assertLt(kept + paid, COLLATERAL_SEIZED, "the swap paid for the loan");
        assertApproxEqAbs(paid, (kept + paid) / 2, 5_001, "builder gets half the profit");

        (, uint256 debtAfter,,,, uint256 hfAfter) = ISparkPoolFork(SPARK_POOL).getUserAccountData(USER);
        assertLt(debtAfter, debtBefore, "the DAI debt was repaid");
        assertGt(hfAfter, hfBefore, "the position is healthier");
    }

    function test_fork_sparkLend_withoutThePoolSet_reverts() public forkOnly {
        // What the live proxy does until the owner sets the pool.
        vm.store(address(executor), _sparkPoolSlot(), bytes32(0));
        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.execute{value: 0}(_plan(4, DEBT_TO_COVER, 1));
    }

    function test_fork_sparkLend_asProtocol3_hitsTheV2PoolNotSpark() public forkOnly {
        // The same action sent as protocol 3 goes to Aave V2 (unset here):
        // the two ids never share a pool.
        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.execute{value: 0}(_plan(3, DEBT_TO_COVER, 1));
    }

    /// Locate `sparkLendPool` in proxy storage by probing for its value.
    function _sparkPoolSlot() internal view returns (bytes32) {
        for (uint256 i = 0; i < 400; i++) {
            if (vm.load(address(executor), bytes32(i)) == bytes32(uint256(uint160(SPARK_POOL)))) {
                return bytes32(i);
            }
        }
        revert("sparkLendPool slot not found");
    }
}
