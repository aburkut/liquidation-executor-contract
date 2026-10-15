// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ExecutorDeploy} from "./support/ExecutorDeploy.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {GenericSequenceLib} from "../src/libraries/GenericSequenceLib.sol";
import {CoinbasePaymentLib} from "../src/libraries/CoinbasePaymentLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniV2Router} from "./mocks/MockUniV2Router.sol";
import {MockUniV3Router} from "./mocks/MockUniV3Router.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";
import {MockUniV3Pool} from "./mocks/MockDirectPools.sol";

contract BatchWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: ETH transfer failed");
    }

    receive() external payable {}
}

/// A V3 pool mock that also answers `slot0()` with a price the test sets, so
/// the batch's price gate has something to read.
contract PricedV3Pool is MockUniV3Pool {
    uint160 public sqrtPriceX96;

    constructor(address t0, address t1, uint256 rate) MockUniV3Pool(t0, t1, rate) {}

    function setPrice(uint160 p) external {
        sqrtPriceX96 = p;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}

/// A PoolManager stand-in that only answers `extsload`: a word per slot.
contract ExtsloadStub {
    mapping(bytes32 => bytes32) public words;

    function set(bytes32 slot, bytes32 word) external {
        words[slot] = word;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }
}

/// @title ArbBatchTest
/// @notice `executeBatch` (several packed WETH plans in one transaction, each
/// gated on its opening pool's price and failing alone, one coinbase payment
/// from the total) and the deadline entry points `executeBefore` /
/// `executePackedBefore`, driven through the real entry points.
contract ArbBatchTest is Test {
    ArbExecutor public exec;
    BatchWETH public weth;
    MockERC20 public tokenB;
    MockMorphoBlue public morpho;

    address public ownerAddr = address(0xA11CE);
    address public operatorAddr = address(0xB0B);
    address public builder = address(0xB111D);

    uint256 constant LOAN = 1_000e18;
    // 1.1x a hop: WETH -> B -> WETH on two such pools turns 1000 into 1210.
    uint256 constant WIN = 1.1e18;
    uint256 constant LOSE = 0.8e18;
    uint256 constant PROFIT = 210e18;

    function setUp() public {
        weth = new BatchWETH();
        tokenB = new MockERC20("B", "B", 18);
        morpho = new MockMorphoBlue();
        MockBalancerVault balancer = new MockBalancerVault(0);

        vm.prank(ownerAddr);
        exec = ExecutorDeploy.arb(
            ownerAddr,
            operatorAddr,
            address(weth),
            address(balancer),
            address(morpho),
            address(new MockParaswapAugustus(WIN)),
            address(new MockUniV2Router(WIN)),
            address(new MockUniV3Router(WIN)),
            new address[](0)
        );
        weth.mint(address(morpho), 10 * LOAN);
        vm.deal(address(weth), 10_000 ether);
        vm.deal(operatorAddr, 1 ether);
        vm.coinbase(builder);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _pool(uint256 rate) internal returns (PricedV3Pool p) {
        p = new PricedV3Pool(address(weth), address(tokenB), rate);
        weth.mint(address(p), 10 * LOAN);
        tokenB.mint(address(p), 10 * LOAN);
    }

    function _v3Op(address pool, address src, address dst, bool zeroForOne, uint256 amountIn, uint32 flags, uint160 lim)
        internal
        pure
        returns (Op memory op)
    {
        op.target = pool;
        op.srcToken = src;
        op.outToken = dst;
        op.amountIn = amountIn;
        op.flags = flags;
        op.callData = abi.encode(zeroForOne, lim);
    }

    /// WETH -> B on `open` (direct, limited at `lim`), B -> WETH on `close`.
    function _cycle(address open, address close, uint160 lim, uint256 minProfit) internal view returns (bytes memory) {
        Op[] memory ops = new Op[](2);
        ops[0] = _v3Op(open, address(weth), address(tokenB), true, LOAN, GenericSequenceLib.FLAG_V3_DIRECT, lim);
        ops[1] = _v3Op(
            close,
            address(tokenB),
            address(weth),
            false,
            0,
            GenericSequenceLib.FLAG_V3_DIRECT | GenericSequenceLib.FLAG_USE_PREV_RETURN,
            0
        );
        return _pack(address(weth), LOAN, minProfit, ops);
    }

    function _pack(address loanToken, uint256 loanAmount, uint256 minProfit, Op[] memory ops)
        internal
        pure
        returns (bytes memory b)
    {
        b = abi.encodePacked(
            uint8(1), uint8(3), loanToken, uint128(loanAmount), uint128(minProfit), uint128(0), uint8(ops.length)
        );
        for (uint256 i = 0; i < ops.length; ++i) {
            Op memory op = ops[i];
            b = abi.encodePacked(
                b,
                op.target,
                uint16(op.flags),
                uint128(op.amountIn),
                uint16(op.fromAmountPos),
                uint16(op.returnAmountPos),
                op.srcToken,
                op.outToken
            );
            if (op.flags & (GenericSequenceLib.FLAG_V3_DIRECT | GenericSequenceLib.FLAG_V3_FLASH) != 0) {
                (bool z, uint160 lim) = abi.decode(op.callData, (bool, uint160));
                b = abi.encodePacked(b, uint8(z ? 1 : 0), lim);
            } else {
                b = abi.encodePacked(b, uint16(op.callData.length), op.callData);
            }
        }
    }

    function _batch(bytes memory a) internal pure returns (bytes[] memory v) {
        v = new bytes[](1);
        v[0] = a;
    }

    // ─── Deadline ────────────────────────────────────────────────────

    /// Runs in the deadline block itself and reverts from the next one on.
    function test_executePackedBefore_runs_through_the_deadline_block_only() public {
        // Literal block numbers: under via-ir a `block.number` read in the
        // test may be moved past a `vm.roll`.
        bytes memory plan = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        vm.roll(100);
        uint256 snap = vm.snapshotState();

        vm.prank(operatorAddr);
        exec.executePackedBefore(100, plan);
        assertEq(weth.balanceOf(address(exec)), PROFIT, "lands at the deadline");

        vm.revertToState(snap);
        vm.roll(101);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.DeadlinePassed.selector, 100, 101));
        exec.executePackedBefore(100, plan);
    }

    /// The ABI-plan entry point takes the same deadline.
    function test_executeBefore_reverts_after_the_deadline() public {
        Op[] memory ops = new Op[](0);
        bytes memory plan = abi.encode(
            ArbTypes.ArbPlan({
                flashProviderId: 3,
                loanToken: address(weth),
                loanAmount: LOAN,
                maxFlashFee: 0,
                ops: ops,
                minProfitAmount: 0
            })
        );
        vm.roll(100);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.DeadlinePassed.selector, 99, 100));
        exec.executeBefore(99, plan);
    }

    /// The deadline is checked before anything else, the operator check
    /// included: a late transaction reverts as cheaply as it can.
    function test_deadline_is_checked_before_the_operator() public {
        vm.roll(100);
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.DeadlinePassed.selector, 99, 100));
        exec.executePackedBefore(99, hex"01");
    }

    // ─── Batch ───────────────────────────────────────────────────────

    /// Three plans: one pays, one loses (reverts alone), one opens on a pool
    /// whose price has not moved past its limit (skipped without running).
    /// The builder is paid once, its share of the one plan's profit.
    function test_batch_keeps_the_winner_drops_the_loser_and_skips_the_unmoved() public {
        PricedV3Pool winOpen = _pool(WIN);
        PricedV3Pool unmoved = _pool(WIN);
        // zeroForOne pushes the price DOWN: room only while price > limit.
        winOpen.setPrice(2e30);
        unmoved.setPrice(1e30);
        uint160 lim = 1.5e30;

        bytes[] memory plans = new bytes[](3);
        plans[0] = _cycle(address(_pool(WIN)), address(_pool(LOSE)), 0, 0); // loses
        plans[1] = _cycle(address(winOpen), address(_pool(WIN)), lim, 0); // pays
        plans[2] = _cycle(address(unmoved), address(_pool(WIN)), lim, 0); // gated off

        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(3, 2, 1, PROFIT, PROFIT / 2);
        vm.prank(operatorAddr);
        exec.executeBatch{value: 5_000}(block.number, 0, plans);

        assertEq(builder.balance, PROFIT / 2, "one coinbase payment, half the total");
        // The bid's own wei (5000, wei == bps) is spent first by the payment,
        // so that much less WETH is unwrapped for it.
        assertEq(weth.balanceOf(address(exec)), PROFIT / 2 + 5_000, "the rest kept");
    }

    /// Two winners: the bid is a share of the SUM.
    function test_batch_pays_the_builder_once_from_the_total() public {
        bytes[] memory plans = new bytes[](2);
        plans[0] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        plans[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);

        vm.prank(operatorAddr);
        exec.executeBatch{value: 9_000}(block.number, 0, plans);
        assertEq(builder.balance, 2 * PROFIT * 9_000 / 10_000);
        assertEq(weth.balanceOf(address(exec)), 2 * PROFIT / 10 + 9_000);
    }

    /// Nothing to take: the batch reverts, so a builder drops it.
    function test_batch_with_nothing_to_take_reverts() public {
        PricedV3Pool unmoved = _pool(WIN);
        unmoved.setPrice(1e30);
        bytes[] memory plans = new bytes[](2);
        plans[0] = _cycle(address(_pool(WIN)), address(_pool(LOSE)), 0, 0);
        plans[1] = _cycle(address(unmoved), address(_pool(WIN)), 1.5e30, 0);

        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.NoOpportunity.selector);
        exec.executeBatch{value: 9_000}(block.number, 0, plans);
    }

    /// A plan's own floor still binds inside the batch.
    function test_batch_plan_below_its_own_floor_is_dropped() public {
        bytes[] memory plans = new bytes[](2);
        plans[0] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, PROFIT + 1); // asks too much
        plans[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, PROFIT);

        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(2, 2, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans);
    }

    /// What is kept after the bid must reach `minTotalProfit`.
    function test_batch_min_total_profit_binds_after_the_bid() public {
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        uint256 kept = PROFIT - PROFIT * 9_000 / 10_000;

        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.executeBatch{value: 9_000}(block.number, kept, plans);

        vm.revertToState(snap);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(CoinbasePaymentLib.InsufficientProfit.selector, kept, kept + 1));
        exec.executeBatch{value: 9_000}(block.number, kept + 1, plans);
    }

    /// A plan that does not borrow WETH is never run: the batch measures WETH.
    function test_batch_skips_a_plan_that_does_not_borrow_weth() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        Op[] memory ops = new Op[](1);
        ops[0] = _v3Op(
            address(_pool(WIN)), address(other), address(tokenB), true, LOAN, GenericSequenceLib.FLAG_V3_DIRECT, 0
        );
        bytes[] memory plans = new bytes[](2);
        plans[0] = _pack(address(other), LOAN, 0, ops);
        plans[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);

        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(2, 1, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans);
    }

    function test_batch_takes_the_deadline() public {
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        vm.roll(100);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.DeadlinePassed.selector, 99, 100));
        exec.executeBatch(99, 0, plans);
    }

    function test_batch_is_operator_only_and_bounded() public {
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        vm.prank(address(0xDEAD));
        vm.expectRevert(ArbExecutor.UnauthorizedOperator.selector);
        exec.executeBatch(block.number, 0, plans);

        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.executeBatch(block.number, 0, new bytes[](0));

        uint256 tooMany = exec.MAX_BATCH() + 1;
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.executeBatch(block.number, 0, new bytes[](tooMany));
    }

    /// A batch leg is reachable only through the batch: called from outside
    /// it would skip the operator check.
    function test_runBatchLeg_is_self_only() public {
        bytes memory plan = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.OnlySelf.selector);
        exec.runBatchLeg(plan);
    }

    /// The V4 gate reads the pool's price from the PoolManager's own storage
    /// (`extsload` of `keccak(poolId, 6)`): an unmoved pool is skipped, a
    /// moved one runs (and here fails, alone — the stub cannot swap).
    function test_batch_v4_gate_reads_the_pool_price() public {
        ExtsloadStub pm = new ExtsloadStub();
        address t0 = address(weth) < address(tokenB) ? address(weth) : address(tokenB);
        address t1 = address(weth) < address(tokenB) ? address(tokenB) : address(weth);
        bool zeroForOne = address(weth) < address(tokenB);
        bytes32 id = keccak256(abi.encode(t0, t1, uint24(500), int24(10), address(0)));
        bytes32 slot = keccak256(abi.encode(id, uint256(6)));
        uint160 lim = 1.5e30;
        // zeroForOne needs price > limit; the other way, price < limit.
        uint160 unmoved = zeroForOne ? 1e30 : 2e30;
        uint160 moved = zeroForOne ? 2e30 : 1e30;

        Op[] memory ops = new Op[](1);
        ops[0].target = address(pm);
        ops[0].srcToken = address(weth);
        ops[0].outToken = address(tokenB);
        ops[0].amountIn = LOAN;
        ops[0].flags = GenericSequenceLib.FLAG_V4_UNLOCK | GenericSequenceLib.FLAG_V4_EXACT_IN;
        ops[0].callData = abi.encode(address(weth), address(tokenB), uint24(500), int24(10), address(0), lim);
        bytes memory v4plan = _pack(address(weth), LOAN, 0, ops);

        bytes[] memory plans = new bytes[](2);
        plans[0] = v4plan;
        plans[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);

        pm.set(slot, bytes32(uint256(unmoved)));
        uint256 snap = vm.snapshotState();
        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(2, 1, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans);

        vm.revertToState(snap);
        pm.set(slot, bytes32(uint256(moved)));
        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(2, 2, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans);
    }

    function test_version_is_4() public view {
        assertEq(exec.version(), 4);
    }
}
