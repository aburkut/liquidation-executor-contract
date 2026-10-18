// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ArbExecutor} from "../../src/ArbExecutor.sol";
import {CoinbasePaymentLib} from "../../src/libraries/CoinbasePaymentLib.sol";

interface IV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

/// Fork gate for the PROFIT TAIL (version 5): a USDT cycle that pays the
/// builder from WETH bought with part of its profit, through the REAL arb
/// proxy — first as it runs today (implementation 0x51de139a…, version 4),
/// then upgraded to this build the way the Safe would (a ProxyAdmin upgrade,
/// pranked on the fork only).
///
/// A whale sells USDT for USDC straight on the Uniswap V3 USDC/USDT 0.01%
/// pool (A), so USDT is cheap there. The plan borrows USDT from Morpho:
///   USDT -> USDC on the 0.05% pool (B), USDC -> USDT on A (the cycle, in
///   USDT), then the TAIL: a literal half of the cycle's profit, USDT -> WETH
///   on the Uniswap V3 WETH/USDT 0.05% pool (W).
///
///   MAINNET_RPC_URL=https://eth.drpc.org FOUNDRY_PROFILE=arb \
///     FOUNDRY_OUT=out-arb FOUNDRY_CACHE_PATH=cache-arb \
///     forge test --match-path test/fork/ArbProfitTailFork.t.sol -vv
contract ArbProfitTailForkTest is Test {
    using SafeERC20 for IERC20;

    address constant PROXY = 0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c;
    address constant SAFE = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    address constant OPERATOR = 0x1e9e18152552609175826f3ee6F8bFD639532E37;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // token0 == USDC, token1 == USDT on both.
    address constant POOL_A = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6; // 0.01%
    address constant POOL_B = 0x7858E59e0C01EA06Df3aF3D20aC7B0003275D4Bf; // 0.05%
    // token0 == WETH, token1 == USDT.
    address constant POOL_W = 0x11b815efB8f581194ae79006d24E0d814B7697F6; // 0.05%
    uint256 constant FORK_BLOCK = 26_220_000;

    uint16 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint16 constant FLAG_V3_DIRECT = 1 << 6;
    uint160 constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
    uint256 constant LOAN = 50_000e6;
    uint256 constant WHALE = 3_000_000e6;

    address internal builder = address(0xB111D);

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(ArbExecutor(payable(PROXY)).version(), 4, "the live implementation");
        vm.coinbase(builder);
        vm.deal(OPERATOR, 1 ether);
        return true;
    }

    function _upgrade() internal {
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
        assertEq(ArbExecutor(payable(PROXY)).version(), 5, "the new implementation");
    }

    /// The whale sells USDT for USDC on A, straight on the pool.
    function _dislocate() internal {
        deal(USDT, address(this), WHALE);
        IV3Pool(POOL_A).swap(address(this), false, int256(WHALE), MAX_SQRT_MINUS_ONE, "");
    }

    /// Only A is swapped from here, USDT (token1) in. USDT returns no bool.
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20(USDC).safeTransfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(USDT).safeTransfer(msg.sender, uint256(a1));
    }

    /// The packed plan: the USDT cycle, and the tail when `tail > 0`.
    function _plan(uint256 tail, uint256 minProfit) internal pure returns (bytes memory) {
        bytes memory head = abi.encodePacked(
            uint8(1), uint8(3), USDT, uint128(LOAN), uint128(minProfit), uint128(0), uint8(tail > 0 ? 3 : 2)
        );
        bytes memory cycle = abi.encodePacked(
            abi.encodePacked(
                POOL_B, FLAG_V3_DIRECT, uint128(LOAN), uint16(0), uint16(0), USDT, USDC, uint8(0), uint160(0)
            ),
            abi.encodePacked(
                POOL_A,
                uint16(FLAG_V3_DIRECT | FLAG_USE_PREV_RETURN),
                uint128(0),
                uint16(0),
                uint16(0),
                USDC,
                USDT,
                uint8(1),
                uint160(0)
            )
        );
        if (tail == 0) return abi.encodePacked(head, cycle);
        return abi.encodePacked(
            head,
            cycle,
            abi.encodePacked(
                POOL_W, FLAG_V3_DIRECT, uint128(tail), uint16(0), uint16(0), USDT, WETH, uint8(0), uint160(0)
            )
        );
    }

    /// The cycle alone, no bid: what it makes in USDT and the gas it burns.
    function _cycleAlone() internal returns (uint256 made, uint256 gas) {
        uint256 snap = vm.snapshotState();
        uint256 u0 = IERC20(USDT).balanceOf(PROXY);
        vm.prank(OPERATOR);
        uint256 g = gasleft();
        ArbExecutor(payable(PROXY)).executePacked(_plan(0, 0));
        gas = g - gasleft();
        made = IERC20(USDT).balanceOf(PROXY) - u0;
        vm.revertToState(snap);
    }

    /// TODAY'S implementation: the shape runs — the cycle in USDT, a literal
    /// tail of USDT into WETH, the flash repaid — but any bid reverts
    /// `CoinbaseRequiresWethLoan` before the loan is taken, so the builder
    /// cannot be paid from the WETH. The bot keeps refusing these cycles
    /// until the proxy runs version 5.
    function test_fork_live_runsTheTailButRefusesItsBid() public {
        if (!_fork()) return;
        _dislocate();
        (uint256 made, uint256 gasCycle) = _cycleAlone();
        assertGt(made, 0, "the cycle pays in USDT");
        uint256 tail = made / 2;
        bytes memory plan = _plan(tail, 0);

        vm.prank(OPERATOR);
        vm.expectRevert(ArbExecutor.CoinbaseRequiresWethLoan.selector);
        ArbExecutor(payable(PROXY)).executePacked{value: 5_000}(plan);

        uint256 w0 = IERC20(WETH).balanceOf(PROXY);
        uint256 u0 = IERC20(USDT).balanceOf(PROXY);
        vm.prank(OPERATOR);
        uint256 g = gasleft();
        ArbExecutor(payable(PROXY)).executePacked(plan);
        uint256 gasTail = g - gasleft();
        uint256 bought = IERC20(WETH).balanceOf(PROXY) - w0;
        assertGt(bought, 0, "the tail bought WETH");
        assertEq(IERC20(USDT).balanceOf(PROXY) - u0, made - tail, "the USDT not sold stays");
        console2.log("cycle made (USDT units)", made);
        console2.log("tail sold (USDT units)", tail);
        console2.log("tail bought (wei)", bought);
        console2.log("gas: cycle alone", gasCycle);
        console2.log("gas: cycle + tail", gasTail);
        console2.log("gas: the tail", gasTail - gasCycle);
    }

    /// VERSION 5: the same plan bids. The builder is paid its share of the
    /// WETH the tail bought; the event counts the profit in WETH; a floor
    /// above what is left after the bid reverts; a tail past the profit
    /// reverts.
    function test_fork_upgraded_paysTheBuilderFromTheTail() public {
        if (!_fork()) return;
        _upgrade();
        _dislocate();
        (uint256 made,) = _cycleAlone();
        uint256 tail = made / 2;

        // What the tail buys, measured without a bid.
        uint256 snap = vm.snapshotState();
        uint256 w0 = IERC20(WETH).balanceOf(PROXY);
        vm.prank(OPERATOR);
        ArbExecutor(payable(PROXY)).executePacked(_plan(tail, 0));
        uint256 bought = IERC20(WETH).balanceOf(PROXY) - w0;
        vm.revertToState(snap);
        assertGt(bought, 0);

        // A floor one wei above what 50% leaves: reverts, nothing is paid.
        uint256 kept = bought - bought * 5_000 / 10_000;
        snap = vm.snapshotState();
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.InsufficientProfit.selector, kept, kept + 1));
        ArbExecutor(payable(PROXY)).executePacked{value: 5_000}(_plan(tail, kept + 1));
        vm.revertToState(snap);

        // A tail selling more than the cycle made: the flash cannot be repaid.
        snap = vm.snapshotState();
        vm.prank(OPERATOR);
        vm.expectRevert();
        ArbExecutor(payable(PROXY)).executePacked{value: 5_000}(_plan(made + 1, 0));
        vm.revertToState(snap);

        // At the floor exactly: lands, pays half of the WETH bought.
        uint256 b0 = builder.balance;
        vm.recordLogs();
        vm.prank(OPERATOR);
        ArbExecutor(payable(PROXY)).executePacked{value: 5_000}(_plan(tail, kept));
        assertEq(builder.balance - b0, bought * 5_000 / 10_000, "the builder's share of the WETH bought");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ArbExecuted(bytes32,address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == PROXY && logs[i].topics.length > 2 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), WETH, "profit counted in WETH");
                (uint256 realized, uint256 paid) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(realized, bought, "realized = WETH bought");
                assertEq(paid, bought * 5_000 / 10_000, "paid");
            }
        }
        assertTrue(found, "ArbExecuted");

        // And a USDT cycle WITHOUT the tail still cannot bid.
        vm.prank(OPERATOR);
        vm.expectRevert(ArbExecutor.CoinbaseRequiresWethLoan.selector);
        ArbExecutor(payable(PROXY)).executePacked{value: 5_000}(_plan(0, 0));
    }
}
