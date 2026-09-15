// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExecutorDeploy} from "../support/ExecutorDeploy.sol";
import {LiquidationExecutor} from "../../src/LiquidationExecutor.sol";
import {GenericSequenceLib} from "../../src/libraries/GenericSequenceLib.sol";
import {Action, AaveV3Action, SwapMode, SwapLeg, Op} from "../../src/types/SwapTypes.sol";
import {FluidPools} from "../../script/FluidPools.sol";

interface IAaveAccountData {
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

/// Fork proof: the liquidator executes the shape a competitor won with.
///
/// 2026-09-15, block 25_980_901, tx 0xe77f7513… (index 0). Whale 0x40E93a52
/// (Aave V3 eMode 3, rsETH collateral / WETH debt). The competitor flash-
/// borrowed 168.826… WETH from Morpho, called `liquidationCall`, received
/// 157.707… rsETH and sold it into the Fluid DEX rsETH/ETH pool 0x27608452
/// (token0 rsETH, token1 native ETH), wrapped the ETH and repaid. Our live
/// liquidator could not: the pool was not in its `allowedTargets`.
///
/// This test forks the state just before that transaction and runs the same
/// plan through a liquidation executor built with the real mainnet immutables:
///   Morpho flash WETH → Aave V3 liquidationCall (real) →
///   op0 direct call `swapIn(true, <seized rsETH>, minOut, executor)` on the
///       real Fluid pool, which pays native ETH →
///   op1 FLAG_WETH_WRAP | FLAG_USE_PREV_RETURN wraps exactly that ETH →
///   Morpho pulls the principal; the remaining WETH is the residual.
///
///   MAINNET_RPC_URL=https://rpc-eth.blockmachine.io forge test \
///     --match-path test/fork/LiquidationViaFluid.t.sol -vv
contract LiquidationViaFluidTest is Test {
    bytes32 constant COMPETITOR_TX = 0xe77f7513547d917e86e2ac8457b00e9f4336fee3908b9a674095603d467cde66;
    address constant WHALE = 0x40E93a52F6Af9fCD3b476aeDADD7FeABD9f7AbA8;
    address constant RSETH = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address constant FLUID_POOL = FluidPools.RSETH_ETH;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /// The competitor's flash principal and `debtToCover`. Aave pulls at most
    /// this, so the actions never spend more loanToken than the loan.
    uint256 constant DEBT_TO_COVER = 168_826_021_073_773_773_928;
    /// From the competitor's receipt: rsETH Aave sent it, and ETH Fluid paid.
    uint256 constant COMPETITOR_SEIZED_RSETH = 157_707_108_663_118_059_797;
    uint256 constant COMPETITOR_ETH_OUT = 169_833_880_906_699_000_000;

    /// `cast sig "swapIn(bool,uint256,uint256,address)"` — the bot's arb encoder
    /// (`FLUID_SWAP_IN_SELECTOR`) and test/ArbExecutorFork.t.sol use the same.
    bytes4 constant FLUID_SWAP_IN_SELECTOR = 0x2668dfaa;
    /// `amountIn_` offset: selector(4) + the `swap0to1_` word.
    uint16 constant FLUID_AMOUNT_IN_POS = 4 + 32;
    /// DexT1 `Swap(bool swap0to1, uint256 amountIn, uint256 amountOut, address to)`,
    /// emitted by the pool address (topic 0xdc004dbc… in the competitor's receipt).
    bytes32 constant FLUID_SWAP_TOPIC = keccak256("Swap(bool,uint256,uint256,address)");
    bytes32 constant WETH_DEPOSIT_TOPIC = keccak256("Deposit(address,uint256)");

    address owner = address(0xA11CE);
    address operatorAddr = address(0xB0B);

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, COMPETITOR_TX);
        forked = true;
    }

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
            minAmountOut: 1,
            bebopPartialFillOffset: 0
        });
    }

    function _plan(address exec) internal pure returns (bytes memory) {
        Op[] memory ops = new Op[](2);
        // op0: sell ALL the seized rsETH (FULL_BALANCE on the collateral asset
        // = min(balance, collateralDelta)) into the Fluid pool. token0 is rsETH,
        // so swap0to1 = true; the pool pays native ETH to the executor.
        // outToken address(0): the library measures this op's output as the
        // executor's native balance delta.
        ops[0] = Op({
            target: FLUID_POOL,
            value: 0,
            amountIn: 0,
            fromAmountPos: FLUID_AMOUNT_IN_POS,
            returnAmountPos: 0,
            flags: GenericSequenceLib.FLAG_USE_FULL_BALANCE,
            srcToken: RSETH,
            outToken: address(0),
            callData: abi.encodeWithSelector(FLUID_SWAP_IN_SELECTOR, true, uint256(0), DEBT_TO_COVER, exec)
        });
        // op1: wrap exactly the ETH op0 produced. No target: the library calls
        // the pinned `weth.deposit` itself.
        ops[1] = Op({
            target: address(0),
            value: 0,
            amountIn: 0,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: GenericSequenceLib.FLAG_WETH_WRAP | GenericSequenceLib.FLAG_USE_PREV_RETURN,
            srcToken: address(0),
            outToken: WETH,
            callData: ""
        });

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
                    collateralAsset: RSETH,
                    debtAsset: WETH,
                    user: WHALE,
                    debtToCover: DEBT_TO_COVER,
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
        sp.profitToken = WETH;
        sp.minProfitAmount = 0;

        return abi.encode(
            LiquidationExecutor.Plan({
                flashProviderId: 3, // FLASH_PROVIDER_MORPHO
                loanToken: WETH,
                loanAmount: DEBT_TO_COVER,
                maxFlashFee: 0,
                actions: actions,
                swapPlan: sp
            })
        );
    }

    function test_fork_liquidation_sells_seized_rsETH_through_fluid() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        assertEq(FLUID_SWAP_IN_SELECTOR, bytes4(keccak256("swapIn(bool,uint256,uint256,address)")), "swapIn selector");

        address[] memory targets = new address[](1);
        targets[0] = FLUID_POOL;
        LiquidationExecutor exec = ExecutorDeploy.liquidation(
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
        assertTrue(exec.allowedTargets(FLUID_POOL), "Fluid pool allowlisted");

        (, uint256 debtBefore,,,, uint256 hfBefore) = IAaveAccountData(AAVE_V3_POOL).getUserAccountData(WHALE);
        assertLt(hfBefore, 1e18, "whale is liquidatable in the pre-state");

        // Deltas, not absolutes: the fresh deploy address may hold fork dust.
        uint256 morphoWethBefore = IERC20(WETH).balanceOf(MORPHO_BLUE);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(exec));
        uint256 ethBefore = address(exec).balance;
        uint256 rsethBefore = IERC20(RSETH).balanceOf(address(exec));

        vm.recordLogs();
        vm.prank(operatorAddr);
        exec.execute(_plan(address(exec))); // msg.value 0 = bid 0
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // ── What the Fluid pool did, and what WETH wrapped ──
        bool swapSeen;
        bool swap0to1;
        uint256 fluidIn;
        uint256 fluidOut;
        address fluidTo;
        uint256 wrapped;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == FLUID_POOL && logs[i].topics[0] == FLUID_SWAP_TOPIC) {
                assertFalse(swapSeen, "one Fluid swap");
                swapSeen = true;
                (swap0to1, fluidIn, fluidOut, fluidTo) = abi.decode(logs[i].data, (bool, uint256, uint256, address));
            } else if (
                logs[i].emitter == WETH && logs[i].topics[0] == WETH_DEPOSIT_TOPIC
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(exec))))
            ) {
                wrapped += abi.decode(logs[i].data, (uint256));
            }
        }
        assertTrue(swapSeen, "Fluid swap emitted");
        assertTrue(swap0to1, "sold token0 (rsETH)");
        assertEq(fluidTo, address(exec), "Fluid paid the executor");
        // Same pre-state as the competitor: the liquidation seizes the same
        // rsETH, all of it is sold, and the pool pays the same ETH.
        assertEq(fluidIn, COMPETITOR_SEIZED_RSETH, "sold exactly the seized rsETH");
        assertEq(fluidOut, COMPETITOR_ETH_OUT, "Fluid paid what it paid the competitor");
        // The ETH arrived in the executor and the wrap op wrapped exactly it.
        assertEq(wrapped, fluidOut, "wrap op deposited exactly the ETH Fluid paid");
        assertEq(address(exec).balance, ethBefore, "no native ETH left behind");
        assertEq(IERC20(RSETH).balanceOf(address(exec)), rsethBefore, "no rsETH left behind");

        // ── Flash repaid, position reduced, residual positive ──
        assertEq(IERC20(WETH).balanceOf(MORPHO_BLUE), morphoWethBefore, "Morpho flash repaid");
        (, uint256 debtAfter,,,,) = IAaveAccountData(AAVE_V3_POOL).getUserAccountData(WHALE);
        assertLt(debtAfter, debtBefore, "whale debt reduced");
        uint256 residual = IERC20(WETH).balanceOf(address(exec)) - wethBefore;
        assertEq(residual, fluidOut - DEBT_TO_COVER, "residual = Fluid ETH - flash principal");
        assertGt(residual, 0, "positive WETH residual");

        emit log_named_decimal_uint("seized rsETH sold to Fluid", fluidIn, 18);
        emit log_named_decimal_uint("native ETH paid by Fluid", fluidOut, 18);
        emit log_named_decimal_uint("ETH wrapped to WETH", wrapped, 18);
        emit log_named_decimal_uint("WETH residual profit (bid 0)", residual, 18);
    }
}
