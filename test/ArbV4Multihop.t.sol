// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ExecutorDeploy} from "./support/ExecutorDeploy.sol";

import {ArbExecutor, ArbTypes} from "../src/ArbExecutor.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {GenericSequenceLib} from "../src/libraries/GenericSequenceLib.sol";
import {CoinbasePaymentLib} from "../src/libraries/CoinbasePaymentLib.sol";
import {UniswapLib} from "../src/libraries/UniswapLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniV2Router} from "./mocks/MockUniV2Router.sol";
import {MockUniV3Router} from "./mocks/MockUniV3Router.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";
import {MockWETHFull} from "./ArbV4V2Limit.t.sol";

/// A token that refuses every transfer OUT of the PoolManager — the shape of
/// CLAUS (0x1b54e762…), whose `transfer` reverts `InvalidTransfer()` from the
/// PoolManager to any recipient. It can be traded only between two V4 hops of
/// ONE unlock, where it nets to zero in the PoolManager's ledger and never moves.
contract MockPmLockedToken is MockERC20 {
    error InvalidTransfer();

    address public immutable pm;

    constructor(address pm_) MockERC20("Claus", "CLAUS", 18) {
        pm = pm_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == pm) revert InvalidTransfer();
        super._update(from, to, value);
    }
}

/// @title ArbV4MultihopTest
/// @notice The V4 exact-in MULTIHOP op (`abi.encode(V4Hop[])`, 2..10 hops in
/// one unlock), driven through the real `ArbExecutor` entrypoint like
/// production. Block 26154364: our `v3>v4>v4` cycle through CLAUS reverted on
/// the first V4 hop's `take`; the winner ran both V4 swaps in one unlock.
/// Deterministic rate mocks (+10% per hop), so the profit `G` is exact and the
/// floor binds at `G` / `G + 1`.
contract ArbV4MultihopTest is Test {
    ArbExecutor public exec;

    MockERC20 public tokenA;
    MockERC20 public tokenC;
    MockPmLockedToken public locked;
    MockWETHFull public weth;

    MockMorphoBlue public morpho;
    MockBalancerVault public balancerFlash;
    MockUniV2Router public uniV2;
    MockUniV3Router public uniV3;
    MockParaswapAugustus public augustus;
    MockV4PoolManager public v4pm;

    address public ownerAddr = address(0xA11CE);
    address public operatorAddr = address(0xB0B);

    uint256 constant LOAN = 1_000e18;
    uint256 constant RATE = 1.1e18;

    uint32 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint32 constant FLAG_V4_UNLOCK = 1 << 2;
    uint32 constant FLAG_WETH_UNWRAP = 1 << 3;
    uint32 constant FLAG_V4_EXACT_IN = 1 << 4;

    uint16 constant V2_AMOUNT_POS = 4;

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenC = new MockERC20("C", "C", 18);
        weth = new MockWETHFull();

        morpho = new MockMorphoBlue();
        balancerFlash = new MockBalancerVault(0);
        uniV2 = new MockUniV2Router(RATE);
        uniV3 = new MockUniV3Router(RATE);
        augustus = new MockParaswapAugustus(RATE);
        v4pm = new MockV4PoolManager(RATE);
        locked = new MockPmLockedToken(address(v4pm));

        address[] memory allowed = new address[](1);
        allowed[0] = address(v4pm);

        vm.prank(ownerAddr);
        exec = ExecutorDeploy.arb(
            ownerAddr,
            operatorAddr,
            address(weth),
            address(balancerFlash),
            address(morpho),
            address(augustus),
            address(uniV2),
            address(uniV3),
            allowed
        );

        tokenA.mint(address(morpho), 100 * LOAN);
        weth.mint(address(morpho), 100 * LOAN);
        tokenA.mint(address(uniV2), 100 * LOAN);
        weth.mint(address(uniV2), 100 * LOAN);
        tokenC.mint(address(v4pm), 100 * LOAN);
        locked.mint(address(v4pm), 100 * LOAN);

        vm.deal(address(weth), 10_000 ether);
        vm.deal(operatorAddr, 1 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _planMorpho(address loanToken, uint256 amount, Op[] memory ops, uint256 minProfit)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ArbTypes.ArbPlan({
                flashProviderId: 3,
                loanToken: loanToken,
                loanAmount: amount,
                maxFlashFee: 0,
                ops: ops,
                minProfitAmount: minProfit
            })
        );
    }

    /// A V4 multihop op: `src` through every `outs[i]` (hook `hooks[i]`), in
    /// one unlock. Its output is the last hop's token.
    function _multihopOp(address src, address[] memory outs, address[] memory hooks, uint256 amountIn, uint32 extra)
        internal
        view
        returns (Op memory op)
    {
        UniswapLib.V4Hop[] memory hops = new UniswapLib.V4Hop[](outs.length);
        for (uint256 i = 0; i < outs.length; i++) {
            hops[i] = UniswapLib.V4Hop({tokenOut: outs[i], fee: 500, tickSpacing: 10, hook: hooks[i]});
        }
        op.target = address(v4pm);
        op.srcToken = src;
        op.outToken = outs[outs.length - 1];
        op.amountIn = amountIn;
        op.flags = FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN | extra;
        op.callData = abi.encode(hops);
    }

    function _v4Single(address src, address dst, uint256 amountIn, uint32 extra) internal view returns (Op memory op) {
        op.target = address(v4pm);
        op.srcToken = src;
        op.outToken = dst;
        op.amountIn = amountIn;
        op.flags = FLAG_V4_UNLOCK | FLAG_V4_EXACT_IN | extra;
        op.callData = abi.encode(src, dst, uint24(500), int24(10), address(0));
    }

    function _routerClose(address src, address dst) internal view returns (Op memory op) {
        address[] memory path = new address[](2);
        path[0] = src;
        path[1] = dst;
        op.target = address(uniV2);
        op.srcToken = src;
        op.outToken = dst;
        op.flags = FLAG_USE_PREV_RETURN;
        op.fromAmountPos = V2_AMOUNT_POS;
        op.callData = abi.encodeWithSelector(
            MockUniV2Router.swapExactTokensForTokens.selector,
            uint256(0),
            uint256(1),
            path,
            address(exec),
            block.timestamp
        );
    }

    function _two(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _assertLandsAndFloorBinds(address loanToken, Op[] memory ops, uint256 g) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(loanToken, LOAN, ops, g));
        vm.revertToState(snap);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(CoinbasePaymentLib.InsufficientProfit.selector, g, g + 1));
        exec.execute(_planMorpho(loanToken, LOAN, ops, g + 1));
        vm.revertToState(snap);
    }

    // ─── The CLAUS shape ─────────────────────────────────────────────

    /// tokenA → CLAUS → tokenC in ONE unlock, closed through the router. CLAUS
    /// never leaves the PoolManager, so the cycle lands and the floor binds.
    function test_multihop_tradesATokenThatNeverLeavesThePoolManager() public {
        Op[] memory ops = new Op[](2);
        ops[0] =
            _multihopOp(address(tokenA), _two(address(locked), address(tokenC)), _two(address(0), address(0)), LOAN, 0);
        ops[1] = _routerClose(address(tokenC), address(tokenA));

        uint256 g = ((LOAN * RATE / 1e18) * RATE / 1e18) * RATE / 1e18 - LOAN;
        uint256 lockedInPm = locked.balanceOf(address(v4pm));
        _assertLandsAndFloorBinds(address(tokenA), ops, g);

        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
        assertEq(locked.balanceOf(address(v4pm)), lockedInPm, "CLAUS never moved");
        assertEq(locked.balanceOf(address(exec)), 0, "the executor never held CLAUS");
    }

    /// The same cycle as two single hops — what the bot sends today — reverts on
    /// the first hop's `take`, exactly as block 26154364 did.
    function test_twoSingleHopsThroughTheLockedTokenRevert() public {
        Op[] memory ops = new Op[](3);
        ops[0] = _v4Single(address(tokenA), address(locked), LOAN, 0);
        ops[1] = _v4Single(address(locked), address(tokenC), 0, FLAG_USE_PREV_RETURN);
        ops[2] = _routerClose(address(tokenC), address(tokenA));

        vm.prank(operatorAddr);
        vm.expectRevert(MockPmLockedToken.InvalidTransfer.selector);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
    }

    /// A multihop chained off the previous op (a middle hop of a cycle).
    function test_multihop_chainsOffThePreviousOp() public {
        tokenA.mint(address(v4pm), 100 * LOAN);
        // tokenA → tokenC (single), then tokenC → CLAUS → tokenA in one unlock,
        // spending what the first op produced; the multihop closes the cycle.
        Op[] memory ops = new Op[](2);
        ops[0] = _v4Single(address(tokenA), address(tokenC), LOAN, 0);
        ops[1] = _multihopOp(
            address(tokenC),
            _two(address(locked), address(tokenA)),
            _two(address(0), address(0)),
            0,
            FLAG_USE_PREV_RETURN
        );

        uint256 g = ((LOAN * RATE / 1e18) * RATE / 1e18) * RATE / 1e18 - LOAN;
        _assertLandsAndFloorBinds(address(tokenA), ops, g);
    }

    /// Native ETH in: unwrap, then ETH → CLAUS → tokenC in one unlock, settled
    /// by value; closed to WETH through the router.
    function test_multihop_nativeIn_settlesByValue() public {
        Op[] memory ops = new Op[](3);
        ops[0].srcToken = address(weth);
        ops[0].amountIn = LOAN;
        ops[0].flags = FLAG_WETH_UNWRAP;
        ops[1] = _multihopOp(
            address(0), _two(address(locked), address(tokenC)), _two(address(0), address(0)), 0, FLAG_USE_PREV_RETURN
        );
        ops[2] = _routerClose(address(tokenC), address(weth));

        uint256 g = ((LOAN * RATE / 1e18) * RATE / 1e18) * RATE / 1e18 - LOAN;
        _assertLandsAndFloorBinds(address(weth), ops, g);
    }

    // ─── Guards ──────────────────────────────────────────────────────

    /// Every hop's hook meets the blocklist, not only the first.
    function test_multihop_blockedHookOnAnyHopReverts() public {
        address hook = address(0xBEEF);
        Op[] memory ops = new Op[](2);
        ops[0] = _multihopOp(address(tokenA), _two(address(locked), address(tokenC)), _two(address(0), hook), LOAN, 0);
        ops[1] = _routerClose(address(tokenC), address(tokenA));

        // Not blocked: lands.
        uint256 snap = vm.snapshotState();
        vm.prank(operatorAddr);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
        vm.revertToState(snap);

        vm.prank(ownerAddr);
        exec.setV4HookBlocked(hook, true);
        vm.prank(operatorAddr);
        vm.expectRevert(ArbExecutor.InvalidV4CallbackHook.selector);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
    }

    /// A multihop blob is admitted on exact-in ops only.
    function test_multihop_withoutExactInReverts() public {
        Op[] memory ops = new Op[](2);
        ops[0] =
            _multihopOp(address(tokenA), _two(address(locked), address(tokenC)), _two(address(0), address(0)), LOAN, 0);
        ops[0].flags = FLAG_V4_UNLOCK;
        ops[1] = _routerClose(address(tokenC), address(tokenA));

        vm.prank(operatorAddr);
        vm.expectRevert(GenericSequenceLib.InvalidPlan.selector);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
    }

    /// Eleven hops, and a blob that is not whole hops, are refused before any
    /// swap.
    function test_multihop_shapeBounds() public {
        address[] memory outs = new address[](11);
        address[] memory hooks = new address[](11);
        for (uint256 i = 0; i < 11; i++) {
            outs[i] = i % 2 == 0 ? address(locked) : address(tokenC);
        }
        Op[] memory ops = new Op[](2);
        ops[0] = _multihopOp(address(tokenA), outs, hooks, LOAN, 0);
        ops[1] = _routerClose(address(tokenC), address(tokenA));
        vm.prank(operatorAddr);
        vm.expectRevert(GenericSequenceLib.InvalidPlan.selector);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));

        ops[0] =
            _multihopOp(address(tokenA), _two(address(locked), address(tokenC)), _two(address(0), address(0)), LOAN, 0);
        ops[0].callData = abi.encodePacked(ops[0].callData, bytes1(0));
        vm.prank(operatorAddr);
        vm.expectRevert(GenericSequenceLib.InvalidPlan.selector);
        exec.execute(_planMorpho(address(tokenA), LOAN, ops, 0));
    }
}
