// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ExecutorDeploy} from "../support/ExecutorDeploy.sol";
import {Action, AaveV2Liquidation, SwapMode, SwapLeg, Op} from "../../src/types/SwapTypes.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";

interface IV2PoolFork {
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256 healthFactor);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @title ExecutorForkAaveV2Test
/// @notice Replays a REAL Aave V2 liquidation through this executor at the
/// point in its block where it happened.
///
/// The position: 0x9c9555e2…0520 on V2, WETH collateral and WETH debt,
/// liquidated in block 25_902_932 by 0x271e…c83e (tx 0xdb81b11e…acb5) for
/// 92.968712171619570160 WETH of debt and 97.617147780200548668 WETH of
/// collateral (bonus 10500 = 5%). The V2 collateral manager at that block
/// (0xcc96…, since 23_425_206) has no close factor, so the whole debt is
/// liquidatable in one call.
///
/// The executor is built from this tree (implementation + Genesis + proxy, as
/// production) — the live proxy 0x875a5cf5… did not exist yet at 25_902_932.
/// What the test proves is the code path: Morpho flash of WETH, protocol 3
/// (`_executeAaveV2Liquidation`) against the real V2 LendingPool, NO_SWAP
/// close (same asset), profit in WETH, coinbase paid from it.
///
/// Mainnet needs ONE owner call before the bot can use this path:
/// `setAaveV2LendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9)` (the
/// pool is already in `allowedTargets` on the live proxy; `aaveV2LendingPool`
/// reads 0x0 there today).
///
///     MAINNET_RPC_URL=https://... forge test --match-path test/fork/ExecutorForkAaveV2.t.sol
contract ExecutorForkAaveV2Test is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_V2_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /// Fork AT the liquidation tx: state after every earlier tx of block
    /// 25_902_932. At the end of 25_902_931 the position was still at HF
    /// 1.000348 — an oracle update earlier in 25_902_932 (the DAI collateral)
    /// tipped it, and the liquidator backran it. That is the race the bot runs.
    bytes32 constant LIQ_TX = 0xdb81b11ea25639d6bce06a10a2f4b86ee75453fa0100535e3b7acbd14536acb5;
    address constant USER = 0x9c9555e24b3fcE7FE3A1187f0273FB6689EF0520;
    uint256 constant DEBT_TO_COVER = 92_968_712_171_619_570_160;
    uint256 constant COLLATERAL_SEIZED = 97_617_147_780_200_548_668;

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
        targets[0] = AAVE_V2_POOL;
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
        executor.setAaveV2LendingPool(AAVE_V2_POOL);
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
            repayToken: WETH,
            minAmountOut: 0,
            bebopPartialFillOffset: 0
        });
    }

    function _plan(uint256 debtToCover, uint256 minProfit) internal pure returns (bytes memory) {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            protocolId: 3,
            data: abi.encode(
                AaveV2Liquidation({
                    collateralAsset: WETH, debtAsset: WETH, user: USER, debtToCover: debtToCover, receiveAToken: false
                })
            )
        });
        LiquidationExecutor.SwapPlan memory sp = LiquidationExecutor.SwapPlan({
            hasGenericSequence: false,
            ops: new Op[](0),
            leg1: _noSwapLeg(),
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
                loanToken: WETH,
                loanAmount: debtToCover,
                maxFlashFee: 0,
                actions: actions,
                swapPlan: sp
            })
        );
    }

    function test_fork_aaveV2_realLiquidation_wethWeth_paysCoinbase() public forkOnly {
        (, uint256 debtBefore,,,, uint256 hfBefore) = IV2PoolFork(AAVE_V2_POOL).getUserAccountData(USER);
        assertLt(hfBefore, 1e18, "position must be liquidatable before the tx");

        address builder = address(0xC0FFEE);
        vm.coinbase(builder);
        uint256 builderBefore = builder.balance;
        uint256 execBefore = IERC20Min(WETH).balanceOf(address(executor));

        // 50% of the profit to the builder (wei == bps).
        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        executor.execute{value: 5_000}(_plan(DEBT_TO_COVER, 1));

        uint256 profit = COLLATERAL_SEIZED - DEBT_TO_COVER; // 4.648435608580978508 WETH
        uint256 paid = builder.balance - builderBefore;
        uint256 kept = IERC20Min(WETH).balanceOf(address(executor)) - execBefore;
        assertApproxEqAbs(paid, profit / 2, 1, "builder gets half the bonus");
        // The 5_000 wei of msg.value (the bid in bps) is dust spent into the
        // bribe, so it shows up on the builder's side of the ledger.
        assertEq(kept + paid, profit + 5_000, "the executor seized exactly what the rival did");

        (, uint256 debtAfter,,,,) = IV2PoolFork(AAVE_V2_POOL).getUserAccountData(USER);
        // The WETH debt is gone; what is left (~1.5 ETH) is the user's debt in
        // other reserves, untouched.
        assertApproxEqAbs(debtBefore - debtAfter, DEBT_TO_COVER, 1e12, "WETH debt repaid");
    }

    function test_fork_aaveV2_withoutThePoolSet_reverts() public forkOnly {
        // What the live proxy does today: aaveV2LendingPool == 0.
        vm.store(address(executor), _aaveV2PoolSlot(), bytes32(0));
        vm.deal(operatorAddr, 1 ether);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute{value: 0}(_plan(DEBT_TO_COVER, 1));
    }

    /// Locate `aaveV2LendingPool` in proxy storage by probing for its value.
    function _aaveV2PoolSlot() internal view returns (bytes32) {
        for (uint256 i = 0; i < 400; i++) {
            if (vm.load(address(executor), bytes32(i)) == bytes32(uint256(uint160(AAVE_V2_POOL)))) {
                return bytes32(i);
            }
        }
        // ERC-7201 namespaced layouts: fall back to scanning is not possible;
        // fail loudly so the test is fixed rather than silently passing.
        revert("aaveV2LendingPool slot not found");
    }
}
