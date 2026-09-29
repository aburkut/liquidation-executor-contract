// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockSwapBackERC20} from "./mocks/MockSwapBackERC20.sol";
import {MockUniV2Pair} from "./mocks/MockDirectPools.sol";
import {V2SwapHarness} from "./support/V2SwapHarness.sol";

/// Where a direct V2 swap reads the pair, pinned against the two orderings it
/// replaced (see `V2SwapHarness`). Every case runs the three bodies from the
/// same state, so a difference in the result is a difference in ordering.
///
/// The FLOKI shape needs its own mock. A fee-on-transfer token only shrinks
/// what the pair receives, and #41's "measure the input after the transfer"
/// was enough for it. FLOKI's transfer also TRADES THE PAIR before crediting
/// us, so reserves read before the transfer are stale by the time we ask —
/// that is what #45 fixed, and what no unit test covered until now: #45 was
/// proven only by a fork replay whose calldata is not in the repository.
contract DirectSwapV2OrderingTest is Test {
    uint16 constant FEE = 9970; // Uniswap V2, ten-thousandths
    uint256 constant AMOUNT = 10e18;

    MockERC20 internal other;
    V2SwapHarness internal h;

    function setUp() public {
        other = new MockERC20("Other", "OTH", 18);
        h = new V2SwapHarness();
    }

    function _pair(address taxed, uint256 taxedReserve, uint256 otherReserve) internal returns (MockUniV2Pair p) {
        p = new MockUniV2Pair(address(other), taxed, FEE);
        other.mint(address(p), otherReserve);
        MockERC20(taxed).mint(address(p), taxedReserve);
        p.sync();
    }

    /// token1 (the token under test) in, token0 out.
    function _data() internal pure returns (bytes memory) {
        return abi.encode(false, FEE);
    }

    function _formula(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * FEE;
        return (inWithFee * reserveOut) / (reserveIn * 10_000 + inWithFee);
    }

    /// A plain token: the three orderings are the same swap. The fix changed
    /// nothing on the quiet path, which is every pair without a transfer hook.
    function test_plainToken_allThreeOrderingsAgree() public {
        MockERC20 t = new MockERC20("Plain", "PLN", 18);
        MockUniV2Pair p = _pair(address(t), 1_000e18, 2_000e18);
        t.mint(address(h), AMOUNT);
        uint256 expected = _formula(AMOUNT, 1_000e18, 2_000e18);

        uint256 s = vm.snapshotState();
        (uint256 outNow,) = h.swapCurrent(address(p), address(t), AMOUNT, _data());
        vm.revertToState(s);
        (uint256 outReservesFirst,) = h.swapReservesBeforeTransfer(address(p), address(t), AMOUNT, _data());
        vm.revertToState(s);
        (uint256 outOnAmount,) = h.swapPricedOnAmount(address(p), address(t), AMOUNT, _data());

        assertEq(outNow, expected, "current");
        assertEq(outReservesFirst, expected, "#41");
        assertEq(outOnAmount, expected, "original");
    }

    /// A fee-on-transfer token: only the ordering that never measured the input
    /// asks for more than the pair's K allows.
    function test_feeOnTransfer_onlyTheUnmeasuredOrderingBreaksK() public {
        MockFeeOnTransferERC20 t = new MockFeeOnTransferERC20("Taxed", "TAX", 18, 30); // 0.3%, FLOKI's rate
        MockUniV2Pair p = _pair(address(t), 1_000e18, 2_000e18);
        t.mint(address(h), AMOUNT);
        uint256 received = AMOUNT - (AMOUNT * 30) / 10_000;
        uint256 expected = _formula(received, 1_000e18, 2_000e18);

        uint256 s = vm.snapshotState();
        vm.expectRevert(bytes("mock: K"));
        h.swapPricedOnAmount(address(p), address(t), AMOUNT, _data());
        vm.revertToState(s);
        (uint256 outReservesFirst,) = h.swapReservesBeforeTransfer(address(p), address(t), AMOUNT, _data());
        vm.revertToState(s);
        (uint256 outNow,) = h.swapCurrent(address(p), address(t), AMOUNT, _data());

        assertEq(outReservesFirst, expected, "#41 measured the input: enough for a plain tax");
        assertEq(outNow, expected, "current");
    }

    /// The FLOKI shape: the transfer sells the accumulated tax into the SAME
    /// pair before crediting us. Both orderings that read reserves before the
    /// transfer break K; the current one prices on the reserves the hook left
    /// behind and the pair accepts it.
    function test_swapBack_bothPreTransferOrderingsBreakK() public {
        MockSwapBackERC20 t = new MockSwapBackERC20("SwapBack", "SWB", 18, 30);
        MockUniV2Pair p = _pair(address(t), 1_000e18, 2_000e18);
        t.setPool(address(p), FEE, address(0x7EA5));
        // Tax already on hand, as on chain: the next sell triggers the swap-back.
        uint256 taxOnHand = 5e18;
        t.mint(address(t), taxOnHand);
        t.mint(address(h), AMOUNT);

        // What the hook does to the pair before our input lands.
        uint256 sbOut = _formula(taxOnHand, 1_000e18, 2_000e18);
        uint256 reserveIn = 1_000e18 + taxOnHand;
        uint256 reserveOut = 2_000e18 - sbOut;
        uint256 received = AMOUNT - (AMOUNT * 30) / 10_000;
        uint256 expected = _formula(received, reserveIn, reserveOut);

        uint256 s = vm.snapshotState();
        vm.expectRevert(bytes("mock: K"));
        h.swapPricedOnAmount(address(p), address(t), AMOUNT, _data());
        vm.revertToState(s);
        vm.expectRevert(bytes("mock: K"));
        h.swapReservesBeforeTransfer(address(p), address(t), AMOUNT, _data());
        vm.revertToState(s);

        (uint256 outNow,) = h.swapCurrent(address(p), address(t), AMOUNT, _data());
        assertEq(t.swapBacks(), 1, "the hook traded the pair inside our transfer");
        assertEq(outNow, expected, "priced on the reserves the hook left behind");
        assertEq(other.balanceOf(address(h)), outNow, "the pair paid it");
    }
}
