// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

/// @dev Test double for a WETH9-shaped token — implements the `IWETH.withdraw`
/// shape `FLAG_WETH_UNWRAP` calls, backed by a real ETH reserve (must be
/// `vm.deal`-funded by the test, same as the real WETH9 contract holding ETH
/// 1:1 against outstanding wrapped supply).
contract MockWETH9 is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth send");
    }

    receive() external payable {}
}

/// @dev A native-IN payable router: takes `msg.value` ETH, mints `amountOut`
/// of `outToken` back to the caller. Proves a `FLAG_NATIVE_IN` op's forwarded
/// value actually reaches `op.target` as `msg.value` (not just patched into
/// calldata) and that the minted output satisfies the outToken-delta check.
contract MockPayableRouter {
    function swapNative(address outToken, uint256 amountOut) external payable {
        MockERC20(outToken).mint(msg.sender, amountOut);
    }
}

/// @dev A malicious/adversarial `FLAG_NATIVE_IN` target for
/// `test_runArb_nativeIn_overpull_reverts`. A genuine on-chain mechanism for a
/// CALLED contract to unilaterally PULL more native ETH out of the CALLER
/// than the `value` already attached to this very call does not exist: ETH
/// has no ERC20-style `transferFrom`, it can only be PUSHED by the paying
/// contract's own code. Reentering back into the executor's own
/// containment-guarded sequence executor doesn't help either — the address(0)
/// bucket's `allowed = 0` is enforced at EVERY nesting level, so any nested
/// call that legitimately produces native ETH (unwrap / native-output op) and
/// then forwards it out nets to a >= 0 balance CHANGE for the caller (it can
/// never net-decrease the caller's balance beyond what THAT nested call
/// itself produced) — see task-2-report.md for the full argument. This mock
/// therefore uses `vm.deal` (callable from any contract under `forge test`,
/// not just the top-level `Test` contract — see `forge-std/Base.sol`
/// `VM_ADDRESS`) to DIRECTLY simulate a callee that net-pulled `extraDrain`
/// wei MORE than the op's declared `amount`, isolating and proving the per-op
/// ceiling's before/after arithmetic + revert wiring — not a claim that this
/// exact drain is reachable through honest on-chain reentrancy.
contract MaliciousDrainRouter {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address public target;
    uint256 public extraDrain;

    function configure(address _target, uint256 _extraDrain) external {
        target = _target;
        extraDrain = _extraDrain;
    }

    function swapNative(address outToken, uint256 amountOut) external payable {
        if (extraDrain > 0) {
            uint256 bal = target.balance;
            vm.deal(target, bal > extraDrain ? bal - extraDrain : 0);
        }
        MockERC20(outToken).mint(msg.sender, amountOut);
    }
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
    // Mirrors of GenericSequenceLib's internal flag constants (library
    // `internal constant`s are re-declared locally per the codebase's
    // existing test convention — see `ExecutorGenericSequenceTest`).
    uint32 internal constant FLAG_USE_FULL_BALANCE = 1 << 0;
    uint32 internal constant FLAG_V4_UNLOCK = 1 << 2;
    uint32 internal constant FLAG_WETH_UNWRAP = 1 << 3;
    uint32 internal constant FLAG_V4_EXACT_IN = 1 << 4;
    uint32 internal constant FLAG_NATIVE_IN = 1 << 5;

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

    // ═══════════════════════════════════════════════════════════════
    // FLAG_NATIVE_IN — payable-DEX call{value} under containment
    // ═══════════════════════════════════════════════════════════════

    /// Happy path: flash-borrow WETH itself (loanToken == weth9), unwrap the
    /// full X into native ETH (op0, FLAG_WETH_UNWRAP), then forward that X
    /// ETH via FLAG_NATIVE_IN (op1) to a payable-only router that mints Y
    /// WETH back. Repay is satisfied from the router's output alone; asserts
    /// the ETH was ACTUALLY forwarded (router's own balance) and the WETH
    /// output was credited (not just that the call didn't revert).
    function test_runArb_nativeIn_happy() public {
        MockWETH9 weth9 = new MockWETH9();
        MockPayableRouter payableRouter = new MockPayableRouter();

        uint256 X = 1 ether;
        uint256 Y = 1.1 ether;
        weth9.mint(address(harness), X); // flash principal present (loanToken == weth9)
        vm.deal(address(weth9), X); // WETH9 must hold ETH 1:1 to honor withdraw()

        Op[] memory ops = new Op[](2);
        ops[0] = Op({
            target: address(0),
            value: 0,
            amountIn: X,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_WETH_UNWRAP,
            srcToken: address(weth9),
            outToken: address(0),
            callData: ""
        });
        ops[1] = Op({
            target: address(payableRouter),
            value: 0,
            amountIn: X,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_NATIVE_IN,
            srcToken: address(0),
            outToken: address(weth9),
            callData: abi.encodeWithSelector(MockPayableRouter.swapNative.selector, address(weth9), Y)
        });

        uint256 flashRepay = 1 ether;
        harness.exec(libAddr, ops, address(weth9), flashRepay, X, address(weth9));

        assertEq(address(payableRouter).balance, X, "native ETH actually forwarded to the router");
        assertEq(address(harness).balance, 0, "no dangling ETH left at the executor");
        assertEq(weth9.balanceOf(address(harness)), Y, "loanToken credited from the payable router");
        assertGe(weth9.balanceOf(address(harness)), flashRepay, "repay satisfied");
    }

    /// Donated/standing ETH (no preceding unwrap this tx) must NOT be
    /// spendable through a lone FLAG_NATIVE_IN op: the address(0) containment
    /// bucket's allowed-spend is unconditionally 0 for `runArb` (capToken is
    /// always the ERC20 loanToken, never address(0) — see the `t !=
    /// address(0)` guard in the containment loop), so the donated ETH must
    /// revert CollateralOverspent(spent, 0) even though the call itself
    /// succeeds and the router pays out a real loanToken credit.
    function test_runArb_nativeIn_standingEth_reverts() public {
        MockPayableRouter payableRouter = new MockPayableRouter();
        uint256 donation = 1 ether;
        vm.deal(address(harness), donation);

        Op[] memory ops = new Op[](1);
        ops[0] = Op({
            target: address(payableRouter),
            value: 0,
            amountIn: donation,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_NATIVE_IN,
            srcToken: address(0),
            outToken: address(loan),
            callData: abi.encodeWithSelector(MockPayableRouter.swapNative.selector, address(loan), 1e18)
        });

        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.CollateralOverspent.selector, donation, 0));
        harness.exec(libAddr, ops, address(loan), 0, 0, address(0));
    }

    /// Per-op ceiling: a malicious/adversarial target that net-pulls MORE
    /// native ETH than the op's declared `amount` must revert
    /// `V4InputOverspent(consumed, amount)`, the SAME per-op ceiling error
    /// `FLAG_V4_UNLOCK` exact-in legs already use. Unwraps X=1 ETH, but the
    /// op only declares `amount=0.6 ether` forwarded — leaving 0.4 ether
    /// sitting at the executor when the call lands. `MaliciousDrainRouter`
    /// additionally drains that entire 0.4 ether remainder via `vm.deal`
    /// during its callback (see the mock's NatSpec for why a GENUINE
    /// on-chain over-pull mechanism could not be constructed — the
    /// containment design provably bounds any honest reentrant path to a
    /// net->=0 balance change), so the executor ends the op with 0 ETH: a
    /// real, measured `consumed = 1 ether > amount = 0.6 ether`.
    function test_runArb_nativeIn_overpull_reverts() public {
        MockWETH9 weth9 = new MockWETH9();
        MaliciousDrainRouter evilRouter = new MaliciousDrainRouter();

        uint256 X = 1 ether;
        uint256 amount = 0.6 ether;
        uint256 extraDrain = 0.4 ether; // drains the remaining (X - amount)
        evilRouter.configure(address(harness), extraDrain);

        weth9.mint(address(harness), X);
        vm.deal(address(weth9), X);

        Op[] memory ops = new Op[](2);
        ops[0] = Op({
            target: address(0),
            value: 0,
            amountIn: X,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_WETH_UNWRAP,
            srcToken: address(weth9),
            outToken: address(0),
            callData: ""
        });
        ops[1] = Op({
            target: address(evilRouter),
            value: 0,
            amountIn: amount,
            fromAmountPos: 0,
            returnAmountPos: 0,
            flags: FLAG_NATIVE_IN,
            srcToken: address(0),
            outToken: address(weth9),
            callData: abi.encodeWithSelector(MaliciousDrainRouter.swapNative.selector, address(weth9), 0.01 ether)
        });

        uint256 consumed = X; // 0.6 ether auto-deducted by the call + 0.4 ether drained
        vm.expectRevert(abi.encodeWithSelector(GenericSequenceLib.V4InputOverspent.selector, consumed, amount));
        harness.exec(libAddr, ops, address(weth9), 0, X, address(weth9));
    }

    /// FLAG_NATIVE_IN must reject every combination with FLAG_V4_UNLOCK,
    /// FLAG_WETH_UNWRAP, FLAG_USE_FULL_BALANCE, and FLAG_V4_EXACT_IN
    /// (N-Task 5 fix 2 — the last was omitted pre-fix, so a
    /// NATIVE_IN|V4_EXACT_IN op silently ran as plain NATIVE_IN with the
    /// V4_EXACT_IN bit ignored) with InvalidPlan —
    /// REGARDLESS of callData shape (e.g. NATIVE_IN|V4_UNLOCK must not fall
    /// through into the V4_UNLOCK branch and revert only incidentally on the
    /// 160-byte v4SwapData length check).
    function test_runArb_nativeIn_flagCombo_reverts() public {
        MockPayableRouter payableRouter = new MockPayableRouter();
        uint32[4] memory combos = [
            FLAG_NATIVE_IN | FLAG_V4_UNLOCK,
            FLAG_NATIVE_IN | FLAG_WETH_UNWRAP,
            FLAG_NATIVE_IN | FLAG_USE_FULL_BALANCE,
            FLAG_NATIVE_IN | FLAG_V4_EXACT_IN
        ];
        for (uint256 i = 0; i < combos.length; ++i) {
            vm.deal(address(harness), 1 ether);
            Op[] memory ops = new Op[](1);
            ops[0] = Op({
                target: address(payableRouter),
                value: 0,
                amountIn: 1 ether,
                fromAmountPos: 0,
                returnAmountPos: 0,
                flags: combos[i],
                srcToken: address(0),
                outToken: address(loan),
                callData: abi.encodeWithSelector(MockPayableRouter.swapNative.selector, address(loan), 1e18)
            });
            vm.expectRevert(GenericSequenceLib.InvalidPlan.selector);
            harness.exec(libAddr, ops, address(loan), 0, 0, address(0));
        }
    }
}
