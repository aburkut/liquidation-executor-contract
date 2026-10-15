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

/// A view the generic gate reads: three words the test sets, or a revert.
contract GateStub {
    uint256 public w0;
    uint256 public w1;
    uint256 public w2;
    bool public broken;

    function set(uint256 a, uint256 b, uint256 c) external {
        (w0, w1, w2) = (a, b, c);
    }

    function breakIt() external {
        broken = true;
    }

    function read() external view returns (uint256, uint256, uint256) {
        require(!broken, "stub: broken");
        return (w0, w1, w2);
    }

    function one() external pure returns (uint256) {
        return 1;
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

    function _noGates() internal pure returns (ArbTypes.BatchGate[] memory g) {
        g = new ArbTypes.BatchGate[](0);
    }

    function _gate(address target, bytes memory data, uint16 word, uint256 threshold, bool above)
        internal
        pure
        returns (ArbTypes.BatchGate memory g)
    {
        g = ArbTypes.BatchGate({
            target: target, data: data, word: word, shift: 0, mask: 0, threshold: threshold, above: above
        });
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
        exec.executeBatch{value: 5_000}(block.number, 0, plans, _noGates());

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
        exec.executeBatch{value: 9_000}(block.number, 0, plans, _noGates());
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
        exec.executeBatch{value: 9_000}(block.number, 0, plans, _noGates());
    }

    /// A plan's own floor still binds inside the batch.
    function test_batch_plan_below_its_own_floor_is_dropped() public {
        bytes[] memory plans = new bytes[](2);
        plans[0] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, PROFIT + 1); // asks too much
        plans[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, PROFIT);

        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(2, 2, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans, _noGates());
    }

    /// What is kept after the bid must reach `minTotalProfit`.
    function test_batch_min_total_profit_binds_after_the_bid() public {
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        uint256 kept = PROFIT - PROFIT * 9_000 / 10_000;

        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.executeBatch{value: 9_000}(block.number, kept, plans, _noGates());

        vm.revertToState(snap);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(CoinbasePaymentLib.InsufficientProfit.selector, kept, kept + 1));
        exec.executeBatch{value: 9_000}(block.number, kept + 1, plans, _noGates());
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
        exec.executeBatch(block.number, 0, plans, _noGates());
    }

    function test_batch_takes_the_deadline() public {
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        vm.roll(100);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.DeadlinePassed.selector, 99, 100));
        exec.executeBatch(99, 0, plans, _noGates());
    }

    function test_batch_is_operator_only_and_bounded() public {
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        vm.prank(address(0xDEAD));
        vm.expectRevert(ArbExecutor.UnauthorizedOperator.selector);
        exec.executeBatch(block.number, 0, plans, _noGates());

        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.executeBatch(block.number, 0, new bytes[](0), _noGates());

        uint256 tooMany = exec.MAX_BATCH() + 1;
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.executeBatch(block.number, 0, new bytes[](tooMany), _noGates());
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
        exec.executeBatch(block.number, 0, plans, _noGates());

        vm.revertToState(snap);
        pm.set(slot, bytes32(uint256(moved)));
        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(2, 2, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans, _noGates());
    }

    // ─── Generic gates ───────────────────────────────────────────────

    /// One plan per gate: the one whose view passes runs, the other is skipped
    /// before anything is called.
    function test_a_generic_gate_runs_or_skips_its_plan() public {
        GateStub q = new GateStub();
        q.set(10, 500, 7);
        bytes[] memory plans = new bytes[](2);
        plans[0] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        plans[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        ArbTypes.BatchGate[] memory gates = new ArbTypes.BatchGate[](2);
        bytes memory read = abi.encodeWithSelector(GateStub.read.selector);
        gates[0] = _gate(address(q), read, 1, 499, true); // 500 > 499: runs
        gates[1] = _gate(address(q), read, 1, 500, true); // 500 > 500: no

        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(2, 1, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans, gates);
    }

    /// `above = false` passes below the threshold; `word` picks the word.
    function test_a_generic_gate_reads_the_word_it_names_either_way() public {
        GateStub q = new GateStub();
        q.set(10, 500, 7);
        bytes memory read = abi.encodeWithSelector(GateStub.read.selector);
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        ArbTypes.BatchGate[] memory gates = new ArbTypes.BatchGate[](1);

        uint256 snap = vm.snapshotState();
        gates[0] = _gate(address(q), read, 2, 8, false); // word 2 = 7 < 8: runs
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans, gates);

        vm.revertToState(snap);
        gates[0] = _gate(address(q), read, 0, 10, false); // word 0 = 10 < 10: no
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.NoOpportunity.selector);
        exec.executeBatch(block.number, 0, plans, gates);
    }

    /// `shift` and `mask` cut a packed word, as a V4 `slot0` packs its price
    /// in the low 160 bits under the tick and fees.
    function test_a_generic_gate_cuts_a_packed_word() public {
        GateStub q = new GateStub();
        uint256 price = 2e30;
        uint256 packed = (uint256(0xABCDEF) << 160) | price;
        q.set(packed, 0, 0);
        bytes[] memory plans = _batch(_cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0));
        ArbTypes.BatchGate[] memory gates = new ArbTypes.BatchGate[](1);
        gates[0] = ArbTypes.BatchGate({
            target: address(q),
            data: abi.encodeWithSelector(GateStub.read.selector),
            word: 0,
            shift: 0,
            mask: type(uint160).max,
            threshold: 1.5e30,
            above: true
        });
        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans, gates);

        // Without the mask the high bits would make any price pass; with a
        // threshold over the price it must not.
        vm.revertToState(snap);
        gates[0].threshold = 3e30;
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.NoOpportunity.selector);
        exec.executeBatch(block.number, 0, plans, gates);

        // A shift reads a field above the low bits: 0xABCDEF.
        vm.revertToState(snap);
        gates[0].shift = 160;
        gates[0].mask = 0xFFFFFF;
        gates[0].threshold = 0xABCDEE;
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans, gates);
    }

    /// A gate that cannot be read — it reverts, or answers fewer words than
    /// asked — keeps its plan out.
    function test_an_unreadable_gate_keeps_its_plan_out() public {
        GateStub q = new GateStub();
        q.set(1, 1, 1);
        bytes[] memory plans = new bytes[](3);
        plans[0] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        plans[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        plans[2] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        ArbTypes.BatchGate[] memory gates = new ArbTypes.BatchGate[](3);
        gates[0] = _gate(address(q), abi.encodeWithSelector(GateStub.one.selector), 1, 0, true); // one word only
        gates[1] = _gate(address(q), hex"deadbeef", 0, 0, true); // no such function
        gates[2] = _gate(address(q), abi.encodeWithSelector(GateStub.read.selector), 0, 0, true); // passes
        vm.expectEmit(address(exec));
        emit ArbExecutor.BatchExecuted(3, 1, 1, PROFIT, 0);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, plans, gates);

        q.breakIt();
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.NoOpportunity.selector);
        exec.executeBatch(block.number, 0, _batch(plans[2]), _one(gates[2]));
    }

    /// An explicit gate takes the place of the built-in check; `target == 0`
    /// keeps the built-in one.
    function test_an_explicit_gate_replaces_the_builtin_check() public {
        PricedV3Pool unmoved = _pool(WIN);
        unmoved.setPrice(1e30);
        bytes memory plan = _cycle(address(unmoved), address(_pool(WIN)), 1.5e30, 0);
        GateStub q = new GateStub();
        q.set(1, 1, 1);
        ArbTypes.BatchGate[] memory gates = new ArbTypes.BatchGate[](1);

        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.NoOpportunity.selector);
        exec.executeBatch(block.number, 0, _batch(plan), gates); // target 0: built-in, unmoved

        vm.revertToState(snap);
        gates[0] = _gate(address(q), abi.encodeWithSelector(GateStub.read.selector), 0, 0, true);
        vm.prank(operatorAddr);
        exec.executeBatch(block.number, 0, _batch(plan), gates);
        assertEq(weth.balanceOf(address(exec)), PROFIT, "the explicit gate let it run");
    }

    /// A gate cannot let a plan that does not borrow WETH run, and the gate
    /// array is all or nothing.
    function test_a_gate_is_no_way_around_the_batch_rules() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        GateStub q = new GateStub();
        q.set(1, 1, 1);
        Op[] memory ops = new Op[](1);
        ops[0] = _v3Op(
            address(_pool(WIN)), address(other), address(tokenB), true, LOAN, GenericSequenceLib.FLAG_V3_DIRECT, 0
        );
        bytes[] memory plans = _batch(_pack(address(other), LOAN, 0, ops));
        ArbTypes.BatchGate[] memory gates = new ArbTypes.BatchGate[](1);
        gates[0] = _gate(address(q), abi.encodeWithSelector(GateStub.read.selector), 0, 0, true);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.NoOpportunity.selector);
        exec.executeBatch(block.number, 0, plans, gates);

        bytes[] memory two = new bytes[](2);
        two[0] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        two[1] = two[0];
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidPlan.selector);
        exec.executeBatch(block.number, 0, two, gates);
    }

    function _one(ArbTypes.BatchGate memory g) internal pure returns (ArbTypes.BatchGate[] memory v) {
        v = new ArbTypes.BatchGate[](1);
        v[0] = g;
    }

    function test_version_is_4() public view {
        assertEq(exec.version(), 4);
    }
}
