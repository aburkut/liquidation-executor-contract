// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenericSequenceLib} from "../src/libraries/GenericSequenceLib.sol";
import {Op} from "../src/types/SwapTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {GenericSequenceLibWrapper} from "./support/GenericSequenceLibWrapper.sol";
import {MockRouter} from "./support/Mocks.sol";

/// @dev Test double for a router that outputs NATIVE ETH instead of an
/// ERC20 — pulls `amountIn` of `srcToken` (transferFrom, so the caller must
/// have approved it — the same op-driven approve every direct-call op
/// does) and sends `amountOut` wei of native ETH back to the caller. Proves
/// an op's `outToken == address(0)` leg is credited via `_balOf`
/// (`address(this).balance`), not the hardcoded-0 delta.
contract MockNativeRouter {
    function swap(address srcToken, uint256 amountIn, uint256 amountOut) external {
        IERC20(srcToken).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = msg.sender.call{value: amountOut}("");
        require(ok, "eth send");
    }

    receive() external payable {}
}

/// Delegatecalls runArb so library sstore/balance ops hit THIS contract.
contract ArbSeqHarness {
    function exec(address lib, Op[] memory ops, address loanToken, uint256 flashRepay, uint256 loanAmount, address weth)
        external
    {
        (bool ok, bytes memory ret) = lib.delegatecall(
            abi.encodeWithSignature(
                "runArb((address,uint256,uint256,uint16,uint16,uint32,address,address,bytes)[],address,uint256,uint256,address)",
                ops,
                loanToken,
                flashRepay,
                loanAmount,
                weth
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// Accepts native ETH sent back by a native-output op (e.g.
    /// `MockNativeRouter.swap`) — the executor's own `receive()` equivalent.
    receive() external payable {}
}

contract ArbGenericSequenceTest is Test {
    MockERC20 loan;
    MockERC20 mid;
    MockRouter router;
    ArbSeqHarness harness;
    address libAddr;

    function setUp() public {
        loan = new MockERC20("Loan", "LOAN", 18);
        mid = new MockERC20("Mid", "MID", 18);
        router = new MockRouter();
        harness = new ArbSeqHarness();
        libAddr = address(new GenericSequenceLibWrapper());
    }

    function _swapOp(address srcToken, uint256 amountIn, address outToken, uint256 amountOut)
        internal
        view
        returns (Op memory)
    {
        bytes memory cd = abi.encodeWithSignature(
            "swap(address,uint256,address,uint256)", srcToken, amountIn, outToken, amountOut
        );
        return Op({
            target: address(router),
            value: 0,
            amountIn: amountIn,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: 0,
            srcToken: srcToken,
            outToken: outToken,
            callData: cd
        });
    }

    /// A profitable arb: loan 100 LOAN → 100 MID → 110 LOAN. flashRepay 100.
    /// loanAfter = 100 (start) - 100 (op1 spend) + 110 (op2) = 110 >= 100. Pass.
    function test_runArb_multihop_repays_and_profits() public {
        loan.mint(address(harness), 100e18); // flash principal present
        Op[] memory ops = new Op[](2);
        ops[0] = _swapOp(address(loan), 100e18, address(mid), 100e18);
        ops[1] = _swapOp(address(mid), 100e18, address(loan), 110e18);
        harness.exec(libAddr, ops, address(loan), 100e18, 100e18, address(0));
        assertEq(loan.balanceOf(address(harness)), 110e18, "profit retained");
    }

    /// Standing intermediate-token spend must revert: op0 spends MID the
    /// harness already holds (not produced by this sequence) → cap for MID
    /// is 0 → CollateralOverspent.
    function test_runArb_standingIntermediateSpend_reverts() public {
        loan.mint(address(harness), 100e18);
        mid.mint(address(harness), 50e18); // STANDING mid balance
        Op[] memory ops = new Op[](1);
        // Op spends 50 MID (standing) → outputs LOAN. MID cap = 0 → revert.
        ops[0] = _swapOp(address(mid), 50e18, address(loan), 100e18);
        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.CollateralOverspent.selector, 50e18, 0));
        harness.exec(libAddr, ops, address(loan), 100e18, 100e18, address(0));
    }

    /// Repay shortfall must revert on the ABSOLUTE gate: sequence ends with
    /// loanAfter = 90 < flashRepay 100.
    function test_runArb_repayShortfall_reverts() public {
        loan.mint(address(harness), 100e18);
        Op[] memory ops = new Op[](2);
        ops[0] = _swapOp(address(loan), 100e18, address(mid), 100e18);
        ops[1] = _swapOp(address(mid), 100e18, address(loan), 90e18); // under-produces
        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.InsufficientRepayOutput.selector, 90e18, 100e18));
        harness.exec(libAddr, ops, address(loan), 100e18, 100e18, address(0));
    }

    /// A single op whose `outToken == address(0)` (native ETH) must be
    /// credited via `_balOf` (`address(this).balance`), not the
    /// hardcoded-0 delta that unconditionally rejects native output with
    /// `OpOutputNotReceived`. Op0 spends only PART of the flash principal
    /// (20 of 100 LOAN) to buy native ETH from `MockNativeRouter`; the
    /// UNSPENT remainder (80 LOAN) alone satisfies the ABSOLUTE repay gate
    /// (`loanAfter >= flashRepay`) — by design, per `RepayGate.Absolute`'s
    /// own doc, the flash principal is present at entry and the gate is
    /// absolute, not "must increase" — so no second (reconverging) op is
    /// needed to isolate the native-output delta path under test. Before
    /// the `_balOf` fix this reverts `OpOutputNotReceived(0)` regardless of
    /// the real ETH credit, because both `outBefore` and `outBal` are
    /// hardcoded to 0 for `outToken == address(0)`.
    function test_nativeOutput_singleOp_creditsViaBalOf() public {
        MockNativeRouter nativeRouter = new MockNativeRouter();
        vm.deal(address(nativeRouter), 1 ether);

        loan.mint(address(harness), 100e18); // flash principal present
        Op[] memory ops = new Op[](1);
        ops[0] = Op({
            target: address(nativeRouter),
            value: 0,
            amountIn: 20e18,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: 0,
            srcToken: address(loan),
            outToken: address(0), // native ETH output
            callData: abi.encodeWithSignature("swap(address,uint256,uint256)", address(loan), 20e18, 1 ether)
        });

        assertEq(address(harness).balance, 0, "starts with no ETH");
        // loanAfter = 100e18 - 20e18 = 80e18 >= flashRepay 80e18 — ABSOLUTE
        // gate satisfied by the unspent remainder alone.
        harness.exec(libAddr, ops, address(loan), 80e18, 100e18, address(0));
        assertEq(address(harness).balance, 1 ether, "native output credited to executor via _balOf");
    }
}
