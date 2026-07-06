// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecutorTest} from "./Executor.t.sol";
import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IV3Cb {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IMini {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// A Uniswap-V3-style pool with NO constructor args (so its init-code-hash is a
/// constant), deployed via CREATE2 by MockV3Factory. `swap` sends the output
/// optimistically then calls back for payment — exactly the real V3 shape.
contract MockV3Pool {
    address public token0;
    address public token1;
    uint256 public rate; // outAmount = inAmount * rate / 1e18

    function init(address t0, address t1, uint256 r) external {
        token0 = t0;
        token1 = t1;
        rate = r;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified); // exact-in (positive)
        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;
        uint256 amountOut = (amountIn * rate) / 1e18;

        IMini(tokenOut).transfer(recipient, amountOut); // optimistic output
        if (zeroForOne) {
            amount0 = int256(amountIn);
            amount1 = -int256(amountOut);
        } else {
            amount1 = int256(amountIn);
            amount0 = -int256(amountOut);
        }

        uint256 balBefore = IMini(tokenIn).balanceOf(address(this));
        IV3Cb(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IMini(tokenIn).balanceOf(address(this)) >= balBefore + amountIn, "IIA");
    }
}

contract MockV3Factory {
    function createPool(address a, address b, uint24 fee, uint256 rate) external returns (address pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pool = address(new MockV3Pool{salt: keccak256(abi.encode(t0, t1, fee))}());
        MockV3Pool(pool).init(t0, t1, rate);
    }

    function poolInitCodeHash() external pure returns (bytes32) {
        return keccak256(type(MockV3Pool).creationCode);
    }
}

/// A rogue "pool" NOT deployed by the factory — its address will not match the
/// CREATE2 recomputation, so its callback must be rejected.
contract RoguePool {
    function swap(address, bool, int256, uint160, bytes calldata data) external returns (int256, int256) {
        IV3Cb(msg.sender).uniswapV3SwapCallback(int256(1), int256(0), data);
        return (0, 0);
    }
}

contract ExecutorGenericSequenceV3Test is ExecutorTest {
    MockV3Factory internal factory;
    MockV3Pool internal pool;
    uint24 internal constant FEE = 3000;
    uint32 internal constant FLAG_FULL_BALANCE = 1 << 0;
    uint32 internal constant FLAG_IS_V3_CALLBACK = 1 << 2;
    uint16 internal constant AMOUNT_SPEC_POS = 68; // offset of amountSpecified in swap(...)

    function setUp() public virtual override {
        super.setUp();
        factory = new MockV3Factory();
        // collateral → loanToken pool at 1.1×.
        address p = factory.createPool(address(collateralToken), address(loanToken), FEE, 1.1e18);
        pool = MockV3Pool(p);
        // Fund the pool with output (loanToken) so it can pay out.
        loanToken.mint(p, 1_000_000e18);

        // Read the init-code-hash BEFORE the prank — passing it as an inline
        // call argument would consume vm.prank on that call instead.
        bytes32 initHash = factory.poolInitCodeHash();
        vm.prank(owner);
        executor.setV3Factory(address(factory), initHash);
    }

    function _sorted() internal view returns (address t0, address t1) {
        (t0, t1) = address(collateralToken) < address(loanToken)
            ? (address(collateralToken), address(loanToken))
            : (address(loanToken), address(collateralToken));
    }

    function _v3Op(address target) internal view returns (LiquidationExecutor.Op memory op) {
        (address t0, address t1) = _sorted();
        bool zeroForOne = address(collateralToken) == t0; // paying collateral (token in)
        bytes memory cbData = abi.encode(address(collateralToken), address(factory), t0, t1, FEE);
        op.target = target;
        op.srcToken = address(collateralToken);
        op.outToken = address(loanToken);
        op.flags = FLAG_IS_V3_CALLBACK | FLAG_FULL_BALANCE;
        op.fromAmountPos = AMOUNT_SPEC_POS;
        op.callData = abi.encodeWithSelector(
            MockV3Pool.swap.selector, address(executor), zeroForOne, int256(0), uint160(0), cbData
        );
    }

    function _plan(LiquidationExecutor.Op memory op) internal view returns (bytes memory) {
        LiquidationExecutor.Op[] memory ops = new LiquidationExecutor.Op[](1);
        ops[0] = op;
        LiquidationExecutor.SwapPlan memory sp;
        sp.hasGenericSequence = true;
        sp.ops = ops;
        sp.profitToken = address(loanToken);
        sp.minProfitAmount = 1e18;
        return _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), sp);
    }

    // ── happy path: real factory pool authenticates + pays in callback ──
    function test_V3_HappyPath() public {
        bytes memory plan = _plan(_v3Op(address(pool)));
        uint256 before = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        assertGe(loanToken.balanceOf(address(executor)), before, "profit retained");
    }

    // ── authenticity: a rogue pool (not CREATE2-derived) is rejected ──
    function test_V3_FakePool_Reverts() public {
        RoguePool rogue = new RoguePool();
        // Same callback data (points at the real factory/tokens) but the caller
        // is the rogue, whose address != computePool → UnexpectedCallback.
        bytes memory plan = _plan(_v3Op(address(rogue)));
        vm.prank(operatorAddr);
        vm.expectRevert(); // UnexpectedCallback (bubbled through the swap call)
        executor.execute(plan);
    }

    // ── unregistered factory in callback data is rejected ──
    function test_V3_UnregisteredFactory_Reverts() public {
        vm.prank(owner);
        executor.setV3Factory(address(factory), bytes32(0)); // deregister
        bytes memory plan = _plan(_v3Op(address(pool)));
        vm.prank(operatorAddr);
        vm.expectRevert(); // V3FactoryNotRegistered
        executor.execute(plan);
    }

    // ── direct callback outside an armed op is rejected ──
    function test_V3_DirectCallbackNotArmed_Reverts() public {
        (address t0, address t1) = _sorted();
        bytes memory cbData = abi.encode(address(collateralToken), address(factory), t0, t1, FEE);
        vm.expectRevert(LiquidationExecutor.UnexpectedCallback.selector);
        executor.uniswapV3SwapCallback(int256(1), int256(0), cbData);
    }
}
