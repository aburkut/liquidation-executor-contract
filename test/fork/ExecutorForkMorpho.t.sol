// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ExecutorDeploy} from "../support/ExecutorDeploy.sol";
import {Action, MorphoLiquidation, SwapMode, SwapLeg, Op} from "../../src/types/SwapTypes.sol";
import {MarketParams} from "../../src/interfaces/IMorphoBlue.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";

interface IMorphoFork {
    function position(bytes32 id, address user)
        external
        view
        returns (uint256, uint128 borrowShares, uint128 collateral);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @title ExecutorForkMorphoTest
/// @notice Replays a REAL Morpho Blue liquidation through this executor at the
/// point in its block where it happened — protocol 2, the seized-assets mode
/// (the only one `SwapValidationLib` accepts), which the bot now sends.
///
/// The position: 0x1a554a4b…4ba6 on the WETH/USDC 86% market 0x94b823e6…,
/// liquidated in block 26_194_900 (tx 0x6f35930c…da7b) for 26.343268732429125266
/// WETH seized against 60_073.167740 USDC repaid.
///
/// What the test proves is the code path: a Morpho flash of USDC, protocol 2
/// on the real Morpho (inside Morpho's own flash callback), an exact-out
/// Uniswap V3 leg (WETH -> USDC, 0.05%) buying back the flash, the rest of
/// the WETH as profit, the coinbase paid from it.
///
///     MAINNET_RPC_URL=<archive> forge test --match-path test/fork/ExecutorForkMorpho.t.sol
contract ExecutorForkMorphoTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    bytes32 constant LIQ_TX = 0x6f35930cde64a17471a03f1580eb2a39911d7a273c15a36c444cb43fbc08da7b;
    bytes32 constant MARKET_ID = 0x94b823e6bd8ea533b4e33fbc307faea0b307301bc48763acc4d4aa4def7636cd;
    address constant USER = 0x1a554A4B16A7d55b6522e06515Ad74CfAcF84bA6;
    uint256 constant SEIZED = 26_343_268_732_429_125_266;
    uint256 constant REPAID = 60_073_167_740;

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
        address[] memory targets = new address[](0);
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
    }

    function _market() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: USDC,
            collateralToken: WETH,
            oracle: 0x0F948CBa8231Db7898ef36A4212581Ad7b1B4580,
            irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC,
            lltv: 860_000_000_000_000_000
        });
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
            repayToken: USDC,
            minAmountOut: 0,
            bebopPartialFillOffset: 0
        });
    }

    /// Buy exactly the flash's USDC back with at most the seized WETH.
    function _buyUsdcLeg(uint256 usdcOut) internal view returns (SwapLeg memory) {
        return SwapLeg({
            mode: SwapMode.UNI_V3_BUY,
            srcToken: WETH,
            amountIn: SEIZED,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 500,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: USDC,
            minAmountOut: usdcOut,
            bebopPartialFillOffset: 0
        });
    }

    function _plan(uint256 seized, uint256 repaidShares, uint256 loan, uint256 minProfit)
        internal
        view
        returns (bytes memory)
    {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            protocolId: 2,
            data: abi.encode(
                MorphoLiquidation({
                    marketParams: _market(),
                    borrower: USER,
                    seizedAssets: seized,
                    repaidShares: repaidShares,
                    maxRepayAssets: loan
                })
            )
        });
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            hasGenericSequence: false,
            ops: new Op[](0),
            leg1: _buyUsdcLeg(loan),
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
                loanToken: USDC,
                loanAmount: loan,
                maxFlashFee: 0,
                actions: actions,
                swapPlan: sp
            })
        );
    }

    /// The bot's flash principal: the model's repay plus the accrual buffer.
    function _loan() internal pure returns (uint256) {
        return REPAID * 10_020 / 10_000;
    }

    function test_fork_morpho_realLiquidation_seizedMode_paysCoinbase() public forkOnly {
        (, uint128 sharesBefore, uint128 collBefore) = IMorphoFork(MORPHO_BLUE).position(MARKET_ID, USER);
        assertGe(collBefore, SEIZED, "the position holds the seizure");
        address builder = address(0xC0FFEE);
        vm.coinbase(builder);
        uint256 builderBefore = builder.balance;
        uint256 execBefore = IERC20Min(WETH).balanceOf(address(executor));

        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        executor.execute{value: 5_000}(_plan(SEIZED, 0, _loan(), 1));

        uint256 paid = builder.balance - builderBefore;
        uint256 kept = IERC20Min(WETH).balanceOf(address(executor)) - execBefore;
        assertGt(paid, 0, "the builder is paid");
        assertGt(kept, 0, "the executor keeps WETH");
        assertLt(kept + paid, SEIZED, "the swap paid for the loan");
        assertApproxEqAbs(paid, (kept + paid) / 2, 5_001, "builder gets half the profit");
        (, uint128 sharesAfter, uint128 collAfter) = IMorphoFork(MORPHO_BLUE).position(MARKET_ID, USER);
        assertEq(collBefore - collAfter, SEIZED, "exactly the seizure left the position");
        assertLt(sharesAfter, sharesBefore, "the borrow shares were repaid");
    }

    function test_fork_morpho_shareModeIsRefused() public forkOnly {
        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute{value: 0}(_plan(SEIZED, 1, _loan(), 1));
    }

    function test_fork_morpho_aRepayCeilingBelowTheRepayReverts() public forkOnly {
        // maxRepayAssets is the bot's guard: Morpho pulling more reverts.
        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute{value: 0}(_plan(SEIZED, 0, REPAID / 2, 1));
    }
}
