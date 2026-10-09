// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExecutorDeploy} from "./support/ExecutorDeploy.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {UniswapLib} from "../src/libraries/UniswapLib.sol";

/// Block 26154364, idx 0: our `(v2|v3)>v4>v4` standing cycle through CLAUS
/// (opp arbtri_26154363_v3>v4>v4_…_dafed704, tx 0xff500089…) reverted, because
/// CLAUS refuses every transfer out of the PoolManager (`InvalidTransfer()`,
/// 0x2f352531) and the first V4 hop `take`s it. The winner (0x34d82fed…, idx 2)
/// ran its V4 swaps in one unlock. Same plan, same amounts, on the state the
/// block opened on: as sent it reverts on the CLAUS take; with the two V4 hops
/// as ONE multihop op it closes in profit.
contract ArbV4MultihopForkTest is Test {
    uint256 constant FORK_BLOCK = 26_154_363;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CLAUS = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    address constant V2_WETH_USDC = 0x397FF1542f962076d0BFE58eA045FfA2d347ACa0;
    address constant V3_WETH_USDC = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;
    address constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PARASWAP_AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    uint32 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint32 constant FLAG_V4_UNLOCK = 1 << 2;
    uint32 constant FLAG_V4_EXACT_IN = 1 << 4;
    uint32 constant FLAG_V3_DIRECT = 1 << 6;
    uint32 constant FLAG_V2_DIRECT = 1 << 7;
    uint32 constant FLAG_WETH_WRAP = 1 << 10;
    uint32 constant FLAG_USE_PRODUCED = 1 << 11;

    uint256 constant LOAN = 155_578_993_600_000_000;
    uint256 constant V2_PART = 46_673_698_080_000_000;
    uint256 constant V3_PART = 108_905_295_520_000_000;

    ArbExecutor exec;
    address owner = address(0xA11CE);
    address operatorAddr = address(0xB0B);

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
        vm.createSelectFork(rpc, FORK_BLOCK);
        address[] memory targets = new address[](1);
        targets[0] = V4_POOL_MANAGER;
        exec = ExecutorDeploy.arb(
            owner,
            operatorAddr,
            WETH,
            BALANCER_VAULT,
            MORPHO_BLUE,
            PARASWAP_AUGUSTUS,
            UNI_V2_ROUTER,
            UNI_V3_ROUTER,
            targets
        );
        vm.deal(operatorAddr, 1 ether);
    }

    /// The opening split exactly as sent: WETH→USDC through the V2 pair and
    /// the V3 pool, literal parts summing to the loan.
    function _opening(Op[] memory ops) internal pure {
        ops[0].target = V2_WETH_USDC;
        ops[0].amountIn = V2_PART;
        ops[0].flags = FLAG_V2_DIRECT;
        ops[0].srcToken = WETH;
        ops[0].outToken = USDC;
        ops[0].callData = abi.encode(uint256(0), uint256(9970));
        ops[1].target = V3_WETH_USDC;
        ops[1].amountIn = V3_PART;
        ops[1].flags = FLAG_V3_DIRECT;
        ops[1].srcToken = WETH;
        ops[1].outToken = USDC;
        ops[1].callData = abi.encode(uint256(0), uint256(0));
    }

    function _wrap(Op memory op) internal pure {
        op.srcToken = address(0);
        op.outToken = WETH;
        op.flags = FLAG_WETH_WRAP | FLAG_USE_PREV_RETURN;
    }

    function _plan(Op[] memory ops) internal pure returns (bytes memory) {
        return abi.encode(
            ArbTypes.ArbPlan({
                flashProviderId: 3, loanToken: WETH, loanAmount: LOAN, maxFlashFee: 0, ops: ops, minProfitAmount: 0
            })
        );
    }

    /// As sent: two single V4 hops. The first `take`s CLAUS, which refuses.
    function test_fork_claus_asSent_revertsOnTheTake() public forkOnly {
        Op[] memory ops = new Op[](5);
        _opening(ops);
        ops[2].target = V4_POOL_MANAGER;
        ops[2].flags = FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN | FLAG_USE_PRODUCED;
        ops[2].srcToken = USDC;
        ops[2].outToken = CLAUS;
        ops[2].callData = abi.encode(USDC, CLAUS, uint24(20_000), int24(200), address(0));
        ops[3].target = V4_POOL_MANAGER;
        ops[3].flags = FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN | FLAG_USE_PREV_RETURN;
        ops[3].srcToken = CLAUS;
        ops[3].outToken = address(0);
        ops[3].callData = abi.encode(CLAUS, address(0), uint24(19_700), int24(197), address(0));
        _wrap(ops[4]);

        // The PoolManager wraps the token's refusal: WrappedError(CLAUS,
        // transfer, InvalidTransfer(), ERC20TransferFailed()) — byte for byte
        // the revert of the block-26154364 simulation.
        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(0x90bfb865),
                CLAUS,
                bytes4(0xa9059cbb),
                abi.encodePacked(bytes4(0x2f352531)),
                abi.encodePacked(bytes4(0xf27f64e4))
            )
        );
        exec.execute(_plan(ops));
    }

    /// The same cycle with the two V4 hops as one multihop op: CLAUS nets to
    /// zero inside the PoolManager and the cycle closes in WETH at a profit.
    function test_fork_claus_asMultihop_closesInProfit() public forkOnly {
        Op[] memory ops = new Op[](4);
        _opening(ops);
        UniswapLib.V4Hop[] memory hops = new UniswapLib.V4Hop[](2);
        hops[0] = UniswapLib.V4Hop({tokenOut: CLAUS, fee: 20_000, tickSpacing: 200, hook: address(0)});
        hops[1] = UniswapLib.V4Hop({tokenOut: address(0), fee: 19_700, tickSpacing: 197, hook: address(0)});
        ops[2].target = V4_POOL_MANAGER;
        ops[2].flags = FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN | FLAG_USE_PRODUCED;
        ops[2].srcToken = USDC;
        ops[2].outToken = address(0);
        ops[2].callData = abi.encode(hops);
        _wrap(ops[3]);

        uint256 before = IERC20(WETH).balanceOf(address(exec));
        vm.prank(operatorAddr);
        exec.execute(_plan(ops));
        uint256 profit = IERC20(WETH).balanceOf(address(exec)) - before;
        emit log_named_uint("profit wei", profit);
        assertGt(profit, 0, "the cycle closes in profit");
        assertEq(IERC20(CLAUS).balanceOf(address(exec)), 0, "the executor never held CLAUS");
    }
}
