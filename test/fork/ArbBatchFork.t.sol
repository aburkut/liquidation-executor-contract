// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ArbExecutor} from "../../src/ArbExecutor.sol";

interface IV3PoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

/// Fork gate for `executeBatch` and the deadline entry points (version 4),
/// through the REAL arb proxy upgraded to the new implementation the way the
/// Safe will (a ProxyAdmin upgrade, pranked on the fork only).
///
/// A whale buys WETH with USDC on the Uniswap V3 USDC/WETH 0.3% pool (A), so
/// WETH is dear there. Three packed WETH plans go in one batch:
///   * WIN  — WETH -> USDC on A, limited at A's price before the whale (a
///            loan far bigger than the move: the limit sizes it), then
///            USDC -> WETH on the 0.05% pool (B);
///   * IDLE — the same shape opening on B, limited where B already is: the
///            price gate skips it without running;
///   * LOSE — WETH -> USDC on B, USDC -> WETH on A (buys WETH where it is
///            dear): runs and reverts alone.
/// The batch must make exactly what WIN makes alone, pay the builder once,
/// and report (3 plans, 2 ran, 1 landed).
///
///   MAINNET_RPC_URL=https://rpc-eth.blockmachine.io FOUNDRY_PROFILE=arb \
///     FOUNDRY_OUT=out-arb FOUNDRY_CACHE_PATH=cache-arb \
///     forge test --match-path test/fork/ArbBatchFork.t.sol -vv
contract ArbBatchForkTest is Test {
    address constant PROXY = 0x0AA6f2988722c1f5eF8d1e2f2fbb75676093358c;
    address constant SAFE = 0xC338094Bb79AA610E9c57166fc4FA959db6234Ab;
    address constant OPERATOR = 0x1e9e18152552609175826f3ee6F8bFD639532E37;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // token0 == USDC, token1 == WETH on both.
    address constant POOL_A = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8; // 0.3%
    address constant POOL_B = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 0.05%
    uint256 constant FORK_BLOCK = 26_197_000;

    uint16 constant FLAG_USE_PREV_RETURN = 1 << 1;
    uint16 constant FLAG_V3_DIRECT = 1 << 6;
    uint256 constant LOAN = 300 ether;

    ArbExecutor internal exec;
    address internal builder = address(0xB111D);

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc, FORK_BLOCK);
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
        assertEq(exec.version(), 4);
        vm.coinbase(builder);
        vm.deal(OPERATOR, 1 ether);
        return true;
    }

    function _price(address pool) internal view returns (uint160 p) {
        (p,,,,,,) = IV3PoolSlot0(pool).slot0();
    }

    /// The whale buys WETH with `usdcIn` USDC on A, straight on the pool.
    function _dislocate(uint256 usdcIn) internal {
        deal(USDC, address(this), usdcIn);
        IV3PoolSlot0(POOL_A).swap(address(this), true, int256(usdcIn), 4_295_128_740, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20(USDC).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(WETH).transfer(msg.sender, uint256(a1));
    }

    /// WETH -> USDC on `open` (zeroForOne false: WETH is token1), limited at
    /// `lim`; USDC -> WETH on `close` with the previous op's output.
    function _cycle(address open, address close, uint160 lim) internal pure returns (bytes memory) {
        return abi.encodePacked(
            abi.encodePacked(uint8(1), uint8(3), WETH, uint128(LOAN), uint128(0), uint128(0), uint8(2)),
            abi.encodePacked(open, FLAG_V3_DIRECT, uint128(LOAN), uint16(0), uint16(0), WETH, USDC, uint8(0), lim),
            abi.encodePacked(
                close,
                uint16(FLAG_V3_DIRECT | FLAG_USE_PREV_RETURN),
                uint128(0),
                uint16(0),
                uint16(0),
                USDC,
                WETH,
                uint8(1),
                uint160(0)
            )
        );
    }

    function test_fork_batch_makes_what_the_winner_makes_alone() public {
        if (!_fork()) return;
        uint160 before = _price(POOL_A);
        _dislocate(5_000_000e6);
        assertLt(_price(POOL_A), before, "the whale made WETH dear on A");

        bytes memory win = _cycle(POOL_A, POOL_B, before);
        // B has not moved: a limit on the side it would have to move past
        // first leaves it nothing to do (zeroForOne false: room only while
        // price < limit, and the limit sits below the price).
        bytes memory idle = _cycle(POOL_B, POOL_A, _price(POOL_B) - 1);
        bytes memory lose = _cycle(POOL_B, POOL_A, 0);

        uint256 snap = vm.snapshotState();
        uint256 w0 = IERC20(WETH).balanceOf(PROXY);
        vm.prank(OPERATOR);
        exec.executePacked(win);
        uint256 alone = IERC20(WETH).balanceOf(PROXY) - w0;
        assertGt(alone, 0, "the winner pays on its own");
        emit log_named_decimal_uint("winner alone, WETH", alone, 18);

        vm.revertToState(snap);
        bytes[] memory plans = new bytes[](3);
        // IDLE before WIN: WIN closes on B and moves it, and a plan after it
        // on B would rightly see room.
        plans[0] = lose;
        plans[1] = idle;
        plans[2] = win;
        uint256 b0 = builder.balance;
        vm.recordLogs();
        vm.prank(OPERATOR);
        exec.executeBatch{value: 9_000}(block.number, 0, plans);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("BatchExecuted(uint256,uint256,uint256,uint256,uint256)");
        bool seen;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != PROXY || logs[i].topics[0] != topic) continue;
            (uint256 n, uint256 ran, uint256 landed, uint256 profit, uint256 paid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertEq(n, 3);
            assertEq(ran, 2, "the idle plan is gated off");
            assertEq(landed, 1, "only the winner lands");
            assertEq(profit, alone, "the batch makes what the winner makes alone");
            assertEq(paid, alone * 9_000 / 10_000, "one payment, 90% of the total");
            seen = true;
        }
        assertTrue(seen, "BatchExecuted");
        assertEq(builder.balance - b0, alone * 9_000 / 10_000);
    }

    function test_fork_deadline_stops_a_late_plan() public {
        if (!_fork()) return;
        uint160 before = _price(POOL_A);
        _dislocate(5_000_000e6);
        bytes memory win = _cycle(POOL_A, POOL_B, before);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.DeadlinePassed.selector, FORK_BLOCK - 1, FORK_BLOCK));
        exec.executePackedBefore(FORK_BLOCK - 1, win);

        vm.prank(OPERATOR);
        exec.executePackedBefore(FORK_BLOCK, win);
    }

    function test_fork_batch_with_nothing_to_take_reverts() public {
        if (!_fork()) return;
        bytes[] memory plans = new bytes[](2);
        plans[0] = _cycle(POOL_B, POOL_A, _price(POOL_B) - 1);
        plans[1] = _cycle(POOL_A, POOL_B, _price(POOL_A) - 1);
        vm.prank(OPERATOR);
        vm.expectRevert(ArbExecutor.NoOpportunity.selector);
        exec.executeBatch{value: 9_000}(block.number, 0, plans);
    }
}
