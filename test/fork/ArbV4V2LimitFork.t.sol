// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ArbExecutor, ArbTypes} from "../../src/ArbExecutor.sol";
import {Op} from "../../src/types/SwapTypes.sol";
import {CoinbasePaymentLib} from "../../src/libraries/CoinbasePaymentLib.sol";
import {IUniV3SwapRouter} from "../../src/interfaces/IUniV3SwapRouter.sol";

/// Fork gate for the new V2-direct-to-a-price shape, through the REAL arb proxy
/// with the new implementation upgraded onto it the way the owner will (a
/// ProxyAdmin upgrade, pranked as the Safe on the fork only).
///
/// Each case forks a real recent block, dislocates the canonical Uniswap V2
/// WETH/USDC pair with a real whale sale (a real cross-venue gap, the shape a
/// MEV-Share hint leaves), then backruns it through the upgraded executor: op0
/// opens on the dislocated V2 pair with a 96-byte callData carrying
/// `sqrtPriceLimitX96`, op1 closes on the real V3 0.05% pool. The limit
/// short-fills the open (asserted against the pair's balance), and the realized
/// profit G binds: `minProfit == G` lands, `G + 1` reverts.
///
///   MAINNET_RPC_URL=https://rpc-eth.blockmachine.io FOUNDRY_PROFILE=arb \
///     FOUNDRY_OUT=out-arb FOUNDRY_CACHE_PATH=cache-arb \
///     forge test --match-path test/fork/ArbV4V2LimitFork.t.sol -vv
contract ArbV4V2LimitForkTest is Test {
    address constant PROXY = 0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c;
    address constant SAFE = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    address constant OPERATOR = 0x1e9e18152552609175826f3ee6F8bFD639532E37;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Uniswap V2 WETH/USDC — token0 == USDC, token1 == WETH.
    address constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    // Uniswap V3 WETH/USDC 0.05% — the close leg (deep mirror).
    address constant V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 constant V3_FEE = 500;
    uint8 constant FLASH_MORPHO = 3;

    uint32 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint32 constant FLAG_V2_DIRECT = 1 << 7;
    uint16 constant V3_AMOUNT_POS = 132; // exactInputSingle amountIn word

    ArbExecutor internal exec;

    function _fork(uint256 blk) internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc, blk);

        // Upgrade the real proxy to the new implementation, exactly as the Safe
        // transaction will (value 0, empty call), pranked as the Safe here.
        address admin = address(uint160(uint256(vm.load(PROXY, ERC1967Utils.ADMIN_SLOT))));
        ArbExecutor live = ArbExecutor(payable(PROXY));
        address impl = address(
            new ArbExecutor(
                live.weth(),
                live.balancerVault(),
                live.morphoBlue(),
                live.paraswapAugustusV6(),
                live.uniV2Router(),
                live.uniV3Router()
            )
        );
        vm.prank(SAFE);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(PROXY), impl, "");
        exec = ArbExecutor(payable(PROXY));
        assertEq(exec.version(), 3, "the proxy must run the new implementation");
        return true;
    }

    function _plan(uint256 loan, Op[] memory ops, uint256 minProfit) internal pure returns (bytes memory) {
        return abi.encode(
            ArbTypes.ArbPlan({
                flashProviderId: FLASH_MORPHO,
                loanToken: USDC,
                loanAmount: loan,
                maxFlashFee: 0,
                ops: ops,
                minProfitAmount: minProfit
            })
        );
    }

    function _reserves() internal view returns (uint256 r0, uint256 r1) {
        (bool ok, bytes memory data) = V2_PAIR.staticcall(abi.encodeWithSignature("getReserves()"));
        require(ok, "getReserves");
        (uint112 a, uint112 b,) = abi.decode(data, (uint112, uint112, uint32));
        (r0, r1) = (uint256(a), uint256(b));
    }

    /// A whale sells `wethIn` WETH into the V2 pair, pushing WETH cheap there.
    function _dislocate(uint256 wethIn) internal {
        address whale = address(0xBEEF);
        deal(WETH, whale, wethIn);
        vm.startPrank(whale);
        IERC20(WETH).approve(V2_ROUTER, wethIn);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        (bool ok,) = V2_ROUTER.call(
            abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                wethIn,
                uint256(0),
                path,
                whale,
                block.timestamp
            )
        );
        require(ok, "whale swap");
        vm.stopPrank();
    }

    /// op0: USDC -> WETH on the dislocated V2 pair, DIRECT, 96-byte callData
    /// (zeroForOne = true: USDC is token0) with the price limit `limit`.
    function _v2OpenLimited(uint256 loan, uint160 limit) internal pure returns (Op memory op) {
        op.target = V2_PAIR;
        op.srcToken = USDC;
        op.outToken = WETH;
        op.amountIn = loan;
        op.flags = FLAG_V2_DIRECT;
        op.callData = abi.encode(true, uint16(9970), limit); // Uniswap V2 fee 0.30%
    }

    /// op1: WETH -> USDC on the V3 0.05% pool through the router, chaining off
    /// what the open really paid.
    function _v3Close() internal pure returns (Op memory op) {
        op.target = V3_ROUTER;
        op.srcToken = WETH;
        op.outToken = USDC;
        op.flags = FLAG_USE_PREV_RETURN;
        op.fromAmountPos = V3_AMOUNT_POS;
        op.callData = abi.encodeWithSelector(
            IUniV3SwapRouter.exactInputSingle.selector,
            IUniV3SwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: V3_FEE,
                recipient: PROXY,
                amountIn: 0,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// Read `realizedProfit` out of the `ArbExecuted` event of a minProfit=0 run.
    function _profitOf(uint256 loan, Op[] memory ops) internal returns (uint256) {
        vm.recordLogs();
        vm.prank(OPERATOR, OPERATOR);
        exec.execute(_plan(loan, ops, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("ArbExecuted(bytes32,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                (uint256 realized,) = abi.decode(logs[i].data, (uint256, uint256));
                return realized;
            }
        }
        revert("no ArbExecuted");
    }

    /// One case: fork `blk`, dislocate with `wethIn`, backrun with `loan`
    /// capped by the limit that restores the pair to its pre-dislocation price.
    /// Assert short fill and the G / G+1 floor.
    function _runCase(uint256 blk, uint256 wethIn, uint256 loan) internal {
        if (!_fork(blk)) {
            vm.skip(true);
            return;
        }

        // The pre-dislocation price is the restore point the open stops at:
        // sqrt(r1/r0) * 2^96 (token1/token0, i.e. WETH per USDC).
        (uint256 r0, uint256 r1) = _reserves();
        uint160 limit = uint160(Math.sqrt(Math.mulDiv(r1, 1 << 192, r0)));

        _dislocate(wethIn);

        // The clamp the open computes now, from the post-dislocation reserves.
        (uint256 pr0, uint256 pr1) = _reserves();
        uint256 rootK = Math.sqrt(pr0 * pr1);
        uint256 target = Math.mulDiv(rootK, 1 << 96, limit);
        assertGt(target, pr0, "limit must leave room after the dislocation");
        uint256 room = target - pr0;
        uint256 expectedSent = loan < room ? loan : room;
        assertLt(expectedSent, loan, "the limit must bind below the loan literal");

        Op[] memory ops = new Op[](2);
        ops[0] = _v2OpenLimited(loan, limit);
        ops[1] = _v3Close();

        uint256 pairUsdcBefore = IERC20(USDC).balanceOf(V2_PAIR);
        uint256 snap = vm.snapshotState();

        uint256 g = _profitOf(loan, ops);
        assertGt(g, 0, "the backrun must profit");
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(V2_PAIR) - pairUsdcBefore, expectedSent, 2, "the open sent only the limit's room"
        );
        vm.revertToState(snap);

        vm.prank(OPERATOR, OPERATOR);
        exec.execute(_plan(loan, ops, g)); // G lands
        vm.revertToState(snap);

        vm.prank(OPERATOR, OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(CoinbasePaymentLib.InsufficientProfit.selector, g, g + 1));
        exec.execute(_plan(loan, ops, g + 1)); // G+1 reverts
    }

    // ── Two real blocks, two dislocation sizes: ≥2 cases for the V2 shape. ──

    function test_fork_v2_limit_case_a() public {
        _runCase(26_120_000, 1_500 ether, 6_000_000e6);
    }

    function test_fork_v2_limit_case_b() public {
        _runCase(26_110_000, 900 ether, 4_000_000e6);
    }
}
