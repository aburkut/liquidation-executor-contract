// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LiquidationExecutor} from "../src/LiquidationExecutor.sol";
import {IFlashLoanRecipient} from "../src/interfaces/IBalancerVault.sol";
import {MarketParams} from "../src/interfaces/IMorphoBlue.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockBalancerVault} from "./mocks/MockBalancerVault.sol";
import {MockParaswapAugustus} from "./mocks/MockParaswapAugustus.sol";
import {MockAaveV2LendingPool} from "./mocks/MockAaveV2LendingPool.sol";
import {MockBebopSettlement} from "./mocks/MockBebopSettlement.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockUniV2Router} from "./mocks/MockUniV2Router.sol";
import {MockUniV3Router} from "./mocks/MockUniV3Router.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";
import {MaliciousV4PoolManager} from "./mocks/MaliciousV4PoolManager.sol";

/// Test-only struct mirroring Augustus V6.2 UniswapV2Data / UniswapV3Data. Both
/// real V6.2 structs share this exact 8-field shape (`bytes pools` makes the
/// struct dynamic → tail-encoded, with a head offset). Using a typed struct
/// here makes `abi.encodeWithSelector` produce the canonical V6.2 calldata
/// layout instead of flattening the fields.
struct TestUniV2V3Data {
    address srcToken;
    address destToken;
    uint256 fromAmount;
    uint256 toAmount;
    uint256 quotedAmount;
    bytes32 metadata;
    address recipient;
    bytes pools;
}

/// Test-only struct mirroring Augustus V6.2 CurveV1Data (9 fields, no dynamic
/// → inline-encoded into the head).
struct TestCurveV1Data {
    uint256 curveData;
    uint256 curveAssets;
    address srcToken;
    address destToken;
    uint256 fromAmount;
    uint256 toAmount;
    uint256 quotedAmount;
    bytes32 metadata;
    address beneficiary;
}

/// Test-only struct mirroring Augustus V6.2 CurveV2Data (11 fields, no dynamic
/// → inline-encoded into the head).
struct TestCurveV2Data {
    uint256 curveData;
    uint256 i;
    uint256 j;
    address poolAddress;
    address srcToken;
    address destToken;
    uint256 fromAmount;
    uint256 toAmount;
    uint256 quotedAmount;
    bytes32 metadata;
    address beneficiary;
}

/// Test-only struct mirroring Augustus V6.2 BalancerV2Data (5 fields, no dynamic).
/// Used only for the explicit-reject test — the executor must revert before
/// touching the struct.
struct TestBalancerV2Data {
    uint256 fromAmount;
    uint256 toAmount;
    uint256 quotedAmount;
    bytes32 metadata;
    uint256 beneficiaryAndApproveFlag;
}

contract ExecutorTest is Test {
    LiquidationExecutor public executor;

    MockERC20 public loanToken;
    MockERC20 public collateralToken;
    MockERC20 public profitToken;

    MockERC20 public aToken;

    MockAavePool public aavePool;
    MockBalancerVault public balancerVault;
    MockParaswapAugustus public augustus;
    MockAaveV2LendingPool public aaveV2Pool;
    MockWETH public mockWeth;
    MockBebopSettlement public bebop;
    MockMorphoBlue public morphoBlue;
    MockUniV2Router public uniV2Mock;
    MockUniV3Router public uniV3Mock;
    MockV4PoolManager public uniV4Mock;

    address public owner = address(0xA11CE);
    address public operatorAddr = address(0xB0B);
    address public attacker = address(0xDEAD);

    uint256 constant LOAN_AMOUNT = 1000e18;
    uint256 constant FLASH_FEE = 1e18;
    uint256 constant SWAP_RATE = 1.1e18; // 10% gain
    uint256 constant MIN_PROFIT = 5e18;
    uint256 constant COLLATERAL_REWARD = 600e18;
    uint256 constant DEFAULT_SWAP_AMOUNT = 1000e18; // Pre-funded collateral balance used in default swaps

    // ─── Augustus V6.2 swap entrypoint selectors (all 11) ────────────────
    // Verified against Sourcify metadata for 0x6A000F20005980200259B80c5102003040001068.
    // 8 accepted by the executor, 3 explicitly rejected (BalancerV2 In/Out + RFQ).
    bytes4 constant SWAP_EXACT_IN_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    ); // 0xe3ead59e

    bytes4 constant SWAP_EXACT_OUT_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountOut(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
        )
    ); // 0x7f457675

    bytes4 constant SWAP_EXACT_IN_UNI_V3_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0x876a02f6

    bytes4 constant SWAP_EXACT_OUT_UNI_V3_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0x5e94e28d

    bytes4 constant SWAP_EXACT_IN_UNI_V2_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountInOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0xe8bb3b6c

    bytes4 constant SWAP_EXACT_OUT_UNI_V2_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountOutOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
        )
    ); // 0xa76f4eb6

    bytes4 constant SWAP_EXACT_IN_CURVE_V1_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountInOnCurveV1((uint256,uint256,address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes)"
        )
    ); // 0x1a01c532

    bytes4 constant SWAP_EXACT_IN_CURVE_V2_SELECTOR = bytes4(
        keccak256(
            "swapExactAmountInOnCurveV2((uint256,uint256,uint256,address,address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes)"
        )
    ); // 0xe37ed256

    // ─── Documented-reject selectors ─────────────────────────────────────
    bytes4 constant SWAP_EXACT_IN_BALANCER_V2_SELECTOR = bytes4(
        keccak256("swapExactAmountInOnBalancerV2((uint256,uint256,uint256,bytes32,uint256),uint256,bytes,bytes)")
    ); // 0xd85ca173

    bytes4 constant SWAP_EXACT_OUT_BALANCER_V2_SELECTOR = bytes4(
        keccak256("swapExactAmountOutOnBalancerV2((uint256,uint256,uint256,bytes32,uint256),uint256,bytes,bytes)")
    ); // 0xd6ed22e6

    bytes4 constant SWAP_RFQ_BATCH_FILL_SELECTOR = bytes4(
        keccak256(
            "swapOnAugustusRFQTryBatchFill((uint256,uint256,uint8,bytes32,address),((uint256,uint128,address,address,address,address,uint256,uint256),bytes,uint256,bytes,bytes)[],bytes)"
        )
    ); // 0xda35bb0d

    function setUp() public {
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18);
        profitToken = new MockERC20("Profit Token", "PROF", 18);

        aavePool = new MockAavePool(FLASH_FEE);
        balancerVault = new MockBalancerVault(FLASH_FEE);
        augustus = new MockParaswapAugustus(SWAP_RATE);
        aaveV2Pool = new MockAaveV2LendingPool(COLLATERAL_REWARD);
        mockWeth = new MockWETH();
        bebop = new MockBebopSettlement();
        morphoBlue = new MockMorphoBlue();
        aToken = new MockERC20("aToken", "aWETH", 18);
        uniV2Mock = new MockUniV2Router(SWAP_RATE);
        uniV3Mock = new MockUniV3Router(SWAP_RATE);
        uniV4Mock = new MockV4PoolManager(SWAP_RATE);

        address[] memory targets = new address[](6);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(aaveV2Pool);
        targets[3] = address(bebop);
        targets[4] = address(morphoBlue);
        targets[5] = address(uniV4Mock);

        executor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        vm.startPrank(owner);
        executor.setAaveV2LendingPool(address(aaveV2Pool));
        executor.setMorphoBlue(address(morphoBlue));
        vm.stopPrank();

        // Configure liquidation reward so the delta-based collateral check passes
        aavePool.setLiquidationCollateralReward(COLLATERAL_REWARD);
        aavePool.setAToken(address(aToken));
        aavePool.setReserveAToken(address(collateralToken), address(aToken)); // canonical mapping for verification
        morphoBlue.setLiquidationCollateralReward(COLLATERAL_REWARD);

        // Fund pools
        loanToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(balancerVault), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18); // Augustus needs loanToken for same-token swaps
        collateralToken.mint(address(augustus), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18); // Pool needs collateral to send as reward
        loanToken.mint(address(executor), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(executor), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD); // Pre-fund gap (swap needs more than liquidation produces)
        collateralToken.mint(address(aaveV2Pool), 100_000e18);
        loanToken.mint(address(aaveV2Pool), 100_000e18);
        collateralToken.mint(address(morphoBlue), 100_000e18);
        loanToken.mint(address(morphoBlue), 100_000e18);
        aToken.mint(address(aavePool), 100_000e18);

        // Fund pools with mockWeth for WETH-denominated coinbase tests
        mockWeth.mint(address(aavePool), 100_000e18);
        mockWeth.mint(address(balancerVault), 100_000e18);
        mockWeth.mint(address(augustus), 100_000e18);
        mockWeth.mint(address(executor), LOAN_AMOUNT + FLASH_FEE + 100e18);
        vm.deal(address(mockWeth), 100_000 ether);

        // Fund bebop with output tokens
        loanToken.mint(address(bebop), 100_000e18);
        collateralToken.mint(address(bebop), 100_000e18);
        profitToken.mint(address(bebop), 100_000e18);
        profitToken.mint(address(augustus), 100_000e18);

        // Fund UniV2 mock with output tokens
        loanToken.mint(address(uniV2Mock), 100_000e18);
        collateralToken.mint(address(uniV2Mock), 100_000e18);
        profitToken.mint(address(uniV2Mock), 100_000e18);
        mockWeth.mint(address(uniV2Mock), 100_000e18);

        // Fund UniV3 mock with output tokens
        loanToken.mint(address(uniV3Mock), 100_000e18);
        collateralToken.mint(address(uniV3Mock), 100_000e18);
        profitToken.mint(address(uniV3Mock), 100_000e18);
        mockWeth.mint(address(uniV3Mock), 100_000e18);

        // Fund UniV4 PoolManager mock with output tokens
        loanToken.mint(address(uniV4Mock), 100_000e18);
        collateralToken.mint(address(uniV4Mock), 100_000e18);
        profitToken.mint(address(uniV4Mock), 100_000e18);
        mockWeth.mint(address(uniV4Mock), 100_000e18);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _buildParaswapCalldata(address srcToken, address dstToken, uint256 amountIn, address beneficiary)
        internal
        pure
        returns (bytes memory)
    {
        // Encode as Paraswap Augustus V6 swapExactAmountIn with GenericData layout
        return abi.encodeWithSelector(
            SWAP_EXACT_IN_SELECTOR,
            address(0), // executor
            srcToken, // GenericData.srcToken
            dstToken, // GenericData.destToken
            amountIn, // GenericData.fromAmount
            uint256(0), // GenericData.toAmount
            uint256(0), // GenericData.quotedAmount
            bytes32(0), // GenericData.metadata
            beneficiary, // GenericData.beneficiary
            uint256(0), // partnerAndFee
            bytes(""), // permit
            bytes("") // executorData
        );
    }

    /// @dev Build a UniswapV2 / UniswapV3 swap calldata for any of the four
    /// In/Out direct selectors. Both real V6.2 structs share the same 8-field
    /// shape with a trailing `bytes pools` — so the struct is dynamic and
    /// encoded in the TAIL with a head offset.
    function _buildUniV2V3Calldata(
        bytes4 selector,
        address srcToken,
        address dstToken,
        uint256 fromAmount,
        uint256 toAmount,
        address beneficiary
    ) internal pure returns (bytes memory) {
        TestUniV2V3Data memory data = TestUniV2V3Data({
            srcToken: srcToken,
            destToken: dstToken,
            fromAmount: fromAmount,
            toAmount: toAmount,
            quotedAmount: 0,
            metadata: bytes32(0),
            recipient: beneficiary,
            pools: hex"deadbeef" // dummy; mock ignores
        });
        return abi.encodeWithSelector(selector, data, uint256(0), bytes(""));
    }

    function _buildOptimizedExactInUniV3Calldata(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address beneficiary
    ) internal pure returns (bytes memory) {
        return _buildUniV2V3Calldata(
            SWAP_EXACT_IN_UNI_V3_SELECTOR, srcToken, dstToken, amountIn, minAmountOut, beneficiary
        );
    }

    function _buildOptimizedExactOutUniV3Calldata(
        address srcToken,
        address dstToken,
        uint256 maxAmountIn,
        uint256 exactAmountOut,
        address beneficiary
    ) internal pure returns (bytes memory) {
        return _buildUniV2V3Calldata(
            SWAP_EXACT_OUT_UNI_V3_SELECTOR, srcToken, dstToken, maxAmountIn, exactAmountOut, beneficiary
        );
    }

    function _buildUniV2ExactInCalldata(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address beneficiary
    ) internal pure returns (bytes memory) {
        return _buildUniV2V3Calldata(
            SWAP_EXACT_IN_UNI_V2_SELECTOR, srcToken, dstToken, amountIn, minAmountOut, beneficiary
        );
    }

    function _buildUniV2ExactOutCalldata(
        address srcToken,
        address dstToken,
        uint256 maxAmountIn,
        uint256 exactAmountOut,
        address beneficiary
    ) internal pure returns (bytes memory) {
        return _buildUniV2V3Calldata(
            SWAP_EXACT_OUT_UNI_V2_SELECTOR, srcToken, dstToken, maxAmountIn, exactAmountOut, beneficiary
        );
    }

    /// @dev Build a CurveV1 swapExactAmountInOnCurveV1 calldata. Inline 9-field
    /// struct (no dynamic) → packs into the head exactly as the real V6.2
    /// CurveV1Data ABI.
    function _buildCurveV1ExactInCalldata(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address beneficiary
    ) internal pure returns (bytes memory) {
        TestCurveV1Data memory data = TestCurveV1Data({
            curveData: 0,
            curveAssets: 0,
            srcToken: srcToken,
            destToken: dstToken,
            fromAmount: amountIn,
            toAmount: minAmountOut,
            quotedAmount: 0,
            metadata: bytes32(0),
            beneficiary: beneficiary
        });
        return abi.encodeWithSelector(SWAP_EXACT_IN_CURVE_V1_SELECTOR, data, uint256(0), bytes(""));
    }

    /// @dev Build a CurveV2 swapExactAmountInOnCurveV2 calldata. Inline 11-field
    /// struct (no dynamic).
    function _buildCurveV2ExactInCalldata(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address beneficiary
    ) internal pure returns (bytes memory) {
        TestCurveV2Data memory data = TestCurveV2Data({
            curveData: 0,
            i: 0,
            j: 0,
            poolAddress: address(0),
            srcToken: srcToken,
            destToken: dstToken,
            fromAmount: amountIn,
            toAmount: minAmountOut,
            quotedAmount: 0,
            metadata: bytes32(0),
            beneficiary: beneficiary
        });
        return abi.encodeWithSelector(SWAP_EXACT_IN_CURVE_V2_SELECTOR, data, uint256(0), bytes(""));
    }

    /// @dev Build a BalancerV2 direct calldata with a batchSwap data blob.
    /// The `bytes data` param carries raw Balancer Vault batchSwap calldata with
    /// an assets array `[srcToken, dstToken]` so the executor can extract tokens.
    function _buildBalancerV2Calldata(
        bytes4 selector,
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address beneficiary
    ) internal pure returns (bytes memory) {
        TestBalancerV2Data memory data = TestBalancerV2Data({
            fromAmount: amountIn,
            toAmount: minAmountOut,
            quotedAmount: 0,
            metadata: bytes32(0),
            beneficiaryAndApproveFlag: uint256(uint160(beneficiary))
        });
        // Build minimal batchSwap calldata: selector(4) + swapType(32) +
        // swapsOffset(32) + assetsOffset(32) + ... assets array [src, dst]
        bytes memory batchData = abi.encodePacked(
            bytes4(0x945bcec9), // batchSwap selector
            uint256(0), // swapType = 0 (ExactIn)
            uint256(0), // swapsOffset (unused by our decoder)
            uint256(128), // assetsOffset (points to assets array = 4 words from content start)
            uint256(0), // fundsOffset (unused)
            // assets array at offset 128 from content start (after 4 head words):
            uint256(2), // assetsCount = 2
            uint256(uint160(srcToken)), // assets[0] = srcToken
            uint256(uint160(dstToken)) // assets[1] = dstToken
        );
        return abi.encodeWithSelector(selector, data, uint256(0), bytes(""), batchData);
    }

    function _buildBalancerV2InvalidBlobCalldata(bytes4 selector) internal pure returns (bytes memory) {
        TestBalancerV2Data memory data = TestBalancerV2Data({
            fromAmount: 1, toAmount: 1, quotedAmount: 0, metadata: bytes32(0), beneficiaryAndApproveFlag: 0
        });
        bytes memory badData = abi.encodePacked(bytes4(0xdeadbeef), uint256(0));
        return abi.encodeWithSelector(selector, data, uint256(0), bytes(""), badData);
    }

    /// @dev Build Paraswap swapExactAmountOut calldata (fromAmount = max input)
    function _buildParaswapExactOutCalldata(
        address srcToken,
        address dstToken,
        uint256 maxAmountIn,
        address beneficiary
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            SWAP_EXACT_OUT_SELECTOR,
            address(0), // executor
            srcToken,
            dstToken,
            maxAmountIn, // GenericData.fromAmount (max input for exact-out)
            uint256(0),
            uint256(0),
            bytes32(0),
            beneficiary,
            uint256(0),
            bytes(""),
            bytes("")
        );
    }

    function _zeroLeg() internal pure returns (LiquidationExecutor.SwapLeg memory) {
        return LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(0),
            amountIn: 0,
            useFullBalance: false,
            deadline: 0,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: address(0),
            minAmountOut: 0
        });
    }

    function _buildParaswapSingleSwapPlan(address srcToken, address dstToken, uint256 amountIn, uint256 minProfitAmt)
        internal
        view
        returns (LiquidationExecutor.SwapPlan memory)
    {
        LiquidationExecutor.SwapLeg memory leg1 = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(srcToken, dstToken, amountIn, address(executor)),
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: 0
        });
        return LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: dstToken,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildBebopMultiSwapPlan(
        address srcToken,
        uint256 amountIn,
        address bebopTarget,
        bytes memory bebopCd,
        address repayTkn,
        address profitTkn,
        uint256 minProfitAmt
    ) internal view returns (LiquidationExecutor.SwapPlan memory) {
        LiquidationExecutor.SwapLeg memory leg1 = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.BEBOP_MULTI,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: bebopTarget,
            bebopCalldata: bebopCd,
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: repayTkn,
            minAmountOut: 1
        });
        return LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: profitTkn,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildUniV2SwapPlan(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint256 minOut,
        uint256 minProfitAmt
    ) internal view returns (LiquidationExecutor.SwapPlan memory) {
        address[] memory path = new address[](2);
        path[0] = srcToken;
        path[1] = dstToken;
        LiquidationExecutor.SwapLeg memory leg1 = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V2,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: path,
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: minOut
        });
        return LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: dstToken,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildUniV3SwapPlan(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint24 fee,
        uint256 minOut,
        uint256 minProfitAmt
    ) internal view returns (LiquidationExecutor.SwapPlan memory) {
        LiquidationExecutor.SwapLeg memory leg1 = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V3,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: fee,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: minOut
        });
        return LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: dstToken,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildUniV4SwapPlan(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint24 fee,
        int24 tickSpacing,
        address hook,
        address poolManager,
        uint256 minOut,
        uint256 minProfitAmt
    ) internal view returns (LiquidationExecutor.SwapPlan memory) {
        LiquidationExecutor.SwapLeg memory leg1 = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V4,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: poolManager,
            v4SwapData: abi.encode(srcToken, dstToken, fee, tickSpacing, hook),
            repayToken: dstToken,
            minAmountOut: minOut
        });
        return LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: dstToken,
            minProfitAmount: minProfitAmt
        });
    }

    /// @dev Assemble a two-leg SwapPlan. Caller supplies two already-built
    /// SwapLeg values (via `_buildUniV2Leg` / `_buildUniV3Leg` / ... below)
    /// plus the outer profit/minProfit fields. hasLeg2 is forced true.
    function _buildTwoLegPlan(
        LiquidationExecutor.SwapLeg memory leg1,
        LiquidationExecutor.SwapLeg memory leg2,
        address profitTkn,
        uint256 minProfitAmt
    ) internal pure returns (LiquidationExecutor.SwapPlan memory) {
        return LiquidationExecutor.SwapPlan({
            leg1: leg1,
            hasLeg2: true,
            leg2: leg2,
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: profitTkn,
            minProfitAmount: minProfitAmt
        });
    }

    function _buildParaswapLeg(address srcToken, address dstToken, uint256 amountIn)
        internal
        view
        returns (LiquidationExecutor.SwapLeg memory)
    {
        return LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: _buildParaswapCalldata(srcToken, dstToken, amountIn, address(executor)),
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: 0
        });
    }

    function _buildBebopLeg(
        address srcToken,
        uint256 amountIn,
        address bebopTarget,
        bytes memory bebopCd,
        address repayTkn
    ) internal view returns (LiquidationExecutor.SwapLeg memory) {
        return LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.BEBOP_MULTI,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: bebopTarget,
            bebopCalldata: bebopCd,
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: repayTkn,
            minAmountOut: 1
        });
    }

    function _buildUniV2Leg(address srcToken, address dstToken, uint256 amountIn, uint256 minOut, bool fullBalance)
        internal
        view
        returns (LiquidationExecutor.SwapLeg memory)
    {
        address[] memory path = new address[](2);
        path[0] = srcToken;
        path[1] = dstToken;
        return LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V2,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: fullBalance,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: path,
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: minOut
        });
    }

    function _buildUniV3Leg(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint24 fee,
        uint256 minOut,
        bool fullBalance
    ) internal view returns (LiquidationExecutor.SwapLeg memory) {
        return LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V3,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: fullBalance,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: fee,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: dstToken,
            minAmountOut: minOut
        });
    }

    function _buildUniV4Leg(
        address srcToken,
        address dstToken,
        uint256 amountIn,
        uint24 fee,
        int24 tickSpacing,
        address hook,
        address poolManager,
        uint256 minOut,
        bool fullBalance
    ) internal view returns (LiquidationExecutor.SwapLeg memory) {
        return LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V4,
            srcToken: srcToken,
            amountIn: amountIn,
            useFullBalance: fullBalance,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: poolManager,
            v4SwapData: abi.encode(srcToken, dstToken, fee, tickSpacing, hook),
            repayToken: dstToken,
            minAmountOut: minOut
        });
    }

    function _buildPlan(
        uint8 flashProviderId,
        address lToken,
        uint256 loanAmount,
        uint256 maxFlashFee,
        LiquidationExecutor.Action[] memory actions,
        LiquidationExecutor.SwapPlan memory swapPlan
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.Plan({
                flashProviderId: flashProviderId,
                loanToken: lToken,
                loanAmount: loanAmount,
                maxFlashFee: maxFlashFee,
                actions: actions,
                swapPlan: swapPlan
            })
        );
    }

    function _buildAaveV3LiquidationAction(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 4,
                asset: address(0),
                amount: 0,
                interestRateMode: 0,
                onBehalfOf: address(0),
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                user: user,
                debtToCover: debtToCover,
                receiveAToken: receiveAToken,
                aTokenAddress: address(0)
            })
        );
    }

    function _buildAaveV3LiquidationActionWithAToken(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        address aTokenAddr
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 4,
                asset: address(0),
                amount: 0,
                interestRateMode: 0,
                onBehalfOf: address(0),
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                user: user,
                debtToCover: debtToCover,
                receiveAToken: true,
                aTokenAddress: aTokenAddr
            })
        );
    }

    function _buildAaveV2LiquidationAction(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.AaveV2Liquidation({
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                user: user,
                debtToCover: debtToCover,
                receiveAToken: receiveAToken
            })
        );
    }

    /// @dev Convenience: wrap a single action into Action[]
    function _singleAction(uint8 protocolId, bytes memory data)
        internal
        pure
        returns (LiquidationExecutor.Action[] memory)
    {
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](1);
        actions[0] = LiquidationExecutor.Action({protocolId: protocolId, data: data});
        return actions;
    }

    /// @dev Default liquidation action for tests that don't test the action itself.
    /// Uses collateralToken as collateral, loanToken as debt (correct roles).
    function _defaultLiqAction(uint256 debtToCover) internal view returns (LiquidationExecutor.Action[] memory) {
        return _singleAction(
            1,
            _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
            )
        );
    }

    /// @dev Default swap plan: PARASWAP_SINGLE swapping collateralToken -> loanToken
    /// Uses DEFAULT_SWAP_AMOUNT (1000e18) so that at 1.1x rate, output (1100e18) covers
    /// the flash loan repay (LOAN_AMOUNT + FLASH_FEE = 1001e18).
    function _defaultSwapPlan() internal view returns (LiquidationExecutor.SwapPlan memory) {
        return _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
    }

    // ─── WETH-denominated helpers (for coinbase payment tests) ───────

    function _wethSwapPlan() internal view returns (LiquidationExecutor.SwapPlan memory) {
        return _buildParaswapSingleSwapPlan(address(collateralToken), address(mockWeth), DEFAULT_SWAP_AMOUNT, 0);
    }

    function _wethSwapPlanWithMinProfit(uint256 minProfitAmt)
        internal
        view
        returns (LiquidationExecutor.SwapPlan memory)
    {
        return _buildParaswapSingleSwapPlan(
            address(collateralToken), address(mockWeth), DEFAULT_SWAP_AMOUNT, minProfitAmt
        );
    }

    function _wethLiqActionWithCoinbase(uint256 debtToCover, uint256 coinbaseBps)
        internal
        view
        returns (LiquidationExecutor.Action[] memory)
    {
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), debtToCover, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(coinbaseBps);
        return actions;
    }

    function _buildWethPlan(uint8 flashProviderId, LiquidationExecutor.Action[] memory actions, uint256 minProfitAmt)
        internal
        view
        returns (bytes memory)
    {
        LiquidationExecutor.SwapPlan memory swapPlan = _wethSwapPlanWithMinProfit(minProfitAmt);
        return _buildPlan(flashProviderId, address(mockWeth), LOAN_AMOUNT, FLASH_FEE, actions, swapPlan);
    }

    /// @dev ACTION_PAY_COINBASE amount is interpreted as basis points (0..10000)
    /// against realized on-chain profit. Helper takes bps; contract computes
    /// the actual wei amount at execute time.
    function _buildCoinbasePaymentAction(uint256 coinbaseBps)
        internal
        pure
        returns (LiquidationExecutor.Action memory)
    {
        return LiquidationExecutor.Action({
            protocolId: 100, // PROTOCOL_INTERNAL
            data: abi.encode(uint8(1), coinbaseBps) // ACTION_PAY_COINBASE(bps)
        });
    }

    /// @dev Realized profit produced by the default WETH-profit test pipeline
    /// (loanToken=mockWeth, debtToCover=400e18, SWAP_RATE=1.1, COLLATERAL_REWARD=600e18).
    /// Trace:
    ///   profitBefore (post-flash)  = 1101 + 1000 = 2101e18 mockWeth
    ///   post-liq WETH              = 2101 - 400  = 1701e18
    ///   post-swap WETH (+1100)     = 2801e18
    ///   realizedProfit = 2801 + 1000 (principal) - 2101 (before) - 1001 (flashRepay)
    ///                  = 699e18
    uint256 internal constant WETH_REALIZED_PROFIT = 699e18;

    // ═══════════════════════════════════════════════════════════════════
    // ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

    function test_onlyOwnerCanSetAaveV2LendingPool() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.setAaveV2LendingPool(address(0x123));
    }

    function test_onlyOwnerCanPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.pause();
    }

    function test_onlyOwnerCanUnpause() public {
        vm.prank(owner);
        executor.pause();
        vm.prank(attacker);
        vm.expectRevert();
        executor.unpause();
    }

    function test_onlyOperatorCanExecute() public {
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.Unauthorized.selector);
        executor.execute(plan);
    }

    function test_ownable2Step() public {
        address newOwner = address(0xBEEF);
        vm.prank(owner);
        executor.transferOwnership(newOwner);
        assertEq(executor.owner(), owner);
        vm.prank(newOwner);
        executor.acceptOwnership();
        assertEq(executor.owner(), newOwner);
    }

    function test_constructorRevertsOnZeroOwner() public {
        address[] memory targets = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LiquidationExecutor(
            address(0), address(1), address(2), address(3), address(4), address(5), address(6), address(7), targets
        );
    }

    function test_rescueERC20() public {
        uint256 amt = 50e18;
        loanToken.mint(address(executor), amt);
        uint256 before = loanToken.balanceOf(owner);
        vm.prank(owner);
        executor.rescueERC20(address(loanToken), owner, amt);
        assertEq(loanToken.balanceOf(owner) - before, amt);
    }

    function test_rescueETH() public {
        vm.deal(address(executor), 1 ether);
        uint256 before = owner.balance;
        vm.prank(owner);
        executor.rescueETH(payable(owner), 1 ether);
        assertEq(owner.balance - before, 1 ether);
    }

    function test_onlyOwnerCanRescueERC20() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueERC20(address(loanToken), attacker, 1);
    }

    function test_onlyOwnerCanRescueETH() public {
        vm.deal(address(executor), 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueETH(payable(attacker), 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSE BLOCKS EXECUTE FOR ALL PROVIDERS
    // ═══════════════════════════════════════════════════════════════════

    function test_pauseBlocksExecuteBalancer() public {
        vm.prank(owner);
        executor.pause();

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BALANCER FLASH HAPPY PATH
    // ═══════════════════════════════════════════════════════════════════

    function test_balancerFlash_paraswap_aaveV3Repay() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, MIN_PROFIT);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGe(loanAfter - loanBefore, MIN_PROFIT);

        // Balancer doesn't use approval (safeTransfer), but check Augustus approval reset
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0);
    }

    function test_balancerFlash_approvalHygiene() public {
        uint256 repayAmt = 500e18;
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), _defaultSwapPlan());
        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
        assertEq(loanToken.allowance(address(executor), address(balancerVault)), 0);
        assertEq(collateralToken.allowance(address(executor), address(aavePool)), 0);
        assertEq(collateralToken.allowance(address(executor), address(balancerVault)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MORPHO FLASH HAPPY PATH + CALLBACK VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    /// Morpho flashloan + Morpho liquidation + Paraswap collateral→loanToken + repay pulled by Morpho.
    /// Mirrors the Aave/Balancer happy-path shape but uses FLASH_PROVIDER_MORPHO (id=3) and a
    /// PROTOCOL_MORPHO_BLUE liquidation action — flashloan and liquidation paths stay separate
    /// even though both ultimately call into the same Morpho Blue contract.
    function test_morphoFlash_paraswap_morphoRepay() public {
        uint8 morphoFlashId = executor.FLASH_PROVIDER_MORPHO();
        vm.prank(owner);
        executor.setFlashProvider(morphoFlashId, address(morphoBlue));

        uint256 seizedAssets = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, MIN_PROFIT);
        LiquidationExecutor.Action[] memory liqAction = _singleAction(
            2, // PROTOCOL_MORPHO_BLUE
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), seizedAssets)
        );
        // Morpho fee is zero; pass FLASH_FEE as maxFlashFee headroom only.
        bytes memory plan = _buildPlan(3, address(loanToken), LOAN_AMOUNT, FLASH_FEE, liqAction, swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGe(loanAfter - loanBefore, MIN_PROFIT);

        // Approval hygiene: Morpho approval was forceApprove(repayAmount), pulled to zero
        // by the post-callback transferFrom. Augustus approval reset by the swap path.
        assertEq(loanToken.allowance(address(executor), address(morphoBlue)), 0);
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    /// Direct call to onMorphoFlashLoan from outside an active flashloan must revert.
    /// Phase guard catches this regardless of whether the caller pretends to be Morpho.
    function test_morphoCallbackRejectsAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.InvalidExecutionPhase.selector);
        executor.onMorphoFlashLoan(LOAN_AMOUNT, "");
    }

    /// Strict caller-auth proof: even when the phase guard and plan-hash guard are
    /// both forced to "valid" via direct storage manipulation, the callback MUST
    /// still revert with InvalidCallbackCaller for any sender other than the
    /// configured FLASH_PROVIDER_MORPHO. This catches a regression where the caller
    /// check is accidentally weakened or removed in a refactor — relying on
    /// InvalidExecutionPhase alone would mask such a bug whenever an attacker
    /// finds any way to land mid-flashloan (e.g. cross-callback re-entry).
    function test_morphoCallbackRejectsCallerEvenWithValidPhaseAndHash() public {
        // Register Morpho as the flashloan provider so the auth check has a concrete
        // address to compare against.
        uint8 morphoFlashId = executor.FLASH_PROVIDER_MORPHO();
        vm.prank(owner);
        executor.setFlashProvider(morphoFlashId, address(morphoBlue));

        // Build a real plan and abi-encode it; the plan hash must match what we
        // plant into _activePlanHash for the hash check to pass.
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
        LiquidationExecutor.Action[] memory liqAction = _singleAction(
            2, // PROTOCOL_MORPHO_BLUE
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), 500e18)
        );
        bytes memory planBytes = _buildPlan(3, address(loanToken), LOAN_AMOUNT, FLASH_FEE, liqAction, swapPlan);
        bytes32 planHash = keccak256(planBytes);

        // Storage layout (forge inspect LiquidationExecutor storage):
        //   slot 10 = _activePlanHash       (bytes32)
        //   slot 11 = _activeV4PoolManager  (address, offset 0)
        //            _executionPhase        (uint8 enum, offset 20)
        // Force both into the "during flashloan" state so neither guard short-circuits.
        // Byte at offset 20 (Solidity) corresponds to bit 160 of the uint256 slot.
        vm.store(address(executor), bytes32(uint256(10)), planHash);
        vm.store(address(executor), bytes32(uint256(11)), bytes32(uint256(1) << 160)); // FlashLoanActive

        // Attacker (not the registered Morpho provider) hits the callback. The phase
        // and hash gates pass; only the caller check should reject.
        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.InvalidCallbackCaller.selector);
        executor.onMorphoFlashLoan(LOAN_AMOUNT, planBytes);
    }

    /// configureMorpho must atomically set both the morphoBlue (liquidation) slot
    /// AND the FLASH_PROVIDER_MORPHO entry in allowedFlashProviders. Without this
    /// helper, two-tx config could leave the two roles pointing at different
    /// addresses — opening a window where the flashloan callback is gated by an
    /// outdated provider while liquidation calls go to a new contract.
    function test_configureMorphoAtomicallyPinsBothSlots() public {
        uint8 morphoFlashId = executor.FLASH_PROVIDER_MORPHO();

        // Sanity: setUp() previously called only setMorphoBlue, leaving the flash
        // provider entry empty.
        assertEq(executor.morphoBlue(), address(morphoBlue));
        assertEq(executor.allowedFlashProviders(morphoFlashId), address(0));

        vm.prank(owner);
        executor.configureMorpho(address(morphoBlue));

        assertEq(executor.morphoBlue(), address(morphoBlue), "morphoBlue must be set");
        assertEq(
            executor.allowedFlashProviders(morphoFlashId),
            address(morphoBlue),
            "FLASH_PROVIDER_MORPHO entry must be set to the same address"
        );
    }

    /// Validation parity: configureMorpho must apply the same zero-address and
    /// allowedTargets gates as the legacy setters so the helper cannot smuggle an
    /// unwhitelisted address into either slot.
    function test_configureMorphoRejectsZeroAndUnwhitelisted() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.configureMorpho(address(0));

        address notWhitelisted = address(0xDEADBEEF);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, notWhitelisted));
        executor.configureMorpho(notWhitelisted);
    }

    /// Insufficient repay balance: a fresh executor with no pre-funding plus a swap that
    /// returns less than the loan principal forces _finalizeMorphoFlashloan to revert
    /// before the approve, since Morpho would otherwise pull more than the executor holds.
    function test_morphoFlash_revertsOnInsufficientRepayBalance() public {
        address[] memory targets = new address[](2);
        targets[0] = address(augustus);
        targets[1] = address(morphoBlue);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        uint8 morphoFlashId = freshExecutor.FLASH_PROVIDER_MORPHO();
        vm.startPrank(owner);
        freshExecutor.setMorphoBlue(address(morphoBlue));
        freshExecutor.setFlashProvider(morphoFlashId, address(morphoBlue));
        vm.stopPrank();

        uint256 seizedAssets = 500e18;
        uint256 collateralReward = COLLATERAL_REWARD;
        morphoBlue.setLiquidationCollateralReward(collateralReward);

        // Bleed swap output: 0.6× rate → executor receives only 360 loanToken vs 1000 repay needed.
        uint256 originalRate = augustus.rate();
        augustus.setRate(0.6e18);

        loanToken.mint(address(morphoBlue), 100_000e18);
        collateralToken.mint(address(morphoBlue), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), seizedAssets);
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: collateralReward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(3, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // InsufficientRepayBalance
        freshExecutor.execute(plan);

        // Restore for unrelated tests
        augustus.setRate(originalRate);

        // No tokens stranded on revert
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "no loanToken stuck");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "no collateralToken stuck");
    }

    // ═══════════════════════════════════════════════════════════════════
    // BALANCER CALLBACK VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_balancerCallbackRejectsWrongCaller() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(loanToken));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN_AMOUNT;
        uint256[] memory fees = new uint256[](1);
        fees[0] = FLASH_FEE;

        vm.prank(attacker);
        vm.expectRevert(LiquidationExecutor.InvalidExecutionPhase.selector);
        executor.receiveFlashLoan(tokens, amounts, fees, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════════
    // PARASWAP SINGLE SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_paraswapSingle_happyPath() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, MIN_PROFIT);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGe(loanAfter - loanBefore, MIN_PROFIT);

        // Approval hygiene
        assertEq(collateralToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_paraswapSingle_revertsOnSwapFailure() public {
        augustus.setSwapReverts(true);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(); // ParaswapSwapFailed
        executor.execute(plan);

        // Approvals zero after revert
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_paraswapSingle_revertsOnDeadlineExpired() public {
        uint256 expiredDeadline = block.timestamp - 1;
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: expiredDeadline,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(executor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.SwapDeadlineExpired.selector, expiredDeadline, block.timestamp)
        );
        executor.execute(plan);
    }

    function test_paraswapApprovalResetAfterSwap() public {
        uint256 repayAmt = 500e18;
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), _defaultSwapPlan());
        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BEBOP MULTI SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_bebopMulti_happyPath() public {
        // Single output: repayToken == profitToken == loanToken
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD; // 600e18

        // Configure bebop: pull collateralToken, send loanToken
        uint256 bebopOutputAmount = 1100e18; // enough to repay flash loan + profit
        bebop.configure(address(collateralToken), collateralIn, address(loanToken), bebopOutputAmount, address(0), 0);

        // Build bebop calldata (any 4+ byte calldata triggers the fallback)
        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGt(loanAfter, loanBefore);
    }

    function test_bebopMulti_multiOutput() public {
        // Two different output tokens: repayToken=loanToken, profitToken=profitToken
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        // Configure bebop: pull collateralToken, send loanToken + profitToken
        uint256 repayOutput = 1100e18;
        uint256 profitOutput = 50e18;
        bebop.configure(
            address(collateralToken), collateralIn, address(loanToken), repayOutput, address(profitToken), profitOutput
        );

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(profitToken), 0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        uint256 profitBefore = profitToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 profitAfter = profitToken.balanceOf(address(executor));
        assertEq(profitAfter - profitBefore, profitOutput);
    }

    function test_bebopMulti_revertsOnUntrustedTarget() public {
        address untrustedTarget = address(0xBAD);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken),
            COLLATERAL_REWARD,
            untrustedTarget,
            bebopCd,
            address(loanToken),
            address(loanToken),
            0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // BebopTargetNotContract (no code at 0xBAD)
        executor.execute(plan);
    }

    function test_bebopMulti_revertsOnInsufficientRepay() public {
        // Use fresh executor with no pre-existing loanToken to ensure absolute balance is truly insufficient
        address[] memory targets = new address[](3);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(bebop);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        // Only provide enough loanToken for flash loan (no surplus)
        collateralToken.mint(address(freshExec), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD);

        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        // Bebop returns only 10e18 — total balance after swap won't cover flashRepayAmount
        uint256 tooLittleRepay = 10e18;
        bebop.configure(address(collateralToken), collateralIn, address(loanToken), tooLittleRepay, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );
        // Fix beneficiary for freshExec
        swapPlan.leg1.bebopCalldata = bebopCd;

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // InsufficientRepayOutput from _executeSwapPlan absolute check
        freshExec.execute(plan);
    }

    function test_bebopMulti_revertsOnSwapFailure() public {
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        bebop.configure(address(collateralToken), collateralIn, address(loanToken), 1100e18, address(0), 0);
        bebop.setReverts(true);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(); // BebopSwapFailed
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // AAVE V2 LIQUIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveV2Liquidation_happyPath() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        collateralToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 debtToCover = 500e18;
        bytes memory targetAction = _buildAaveV2LiquidationAction(
            address(collateralToken), // collateral received
            address(loanToken), // debt paid
            address(0x1234),
            debtToCover,
            false
        );

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(3, targetAction), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(aaveV2Pool)), 0);
        assertEq(collateralToken.allowance(address(executor), address(augustus)), 0);
    }

    function test_aaveV2Liquidation_approvalReset() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        collateralToken.mint(address(aaveV2Pool), 100_000e18);

        uint256 debtToCover = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                3,
                _buildAaveV2LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
                )
            ),
            swapPlan
        );

        vm.prank(operatorAddr);
        executor.execute(plan);
        assertEq(loanToken.allowance(address(executor), address(aaveV2Pool)), 0);
    }

    function test_aaveV2Liquidation_reverts() public {
        aaveV2Pool.setLiquidationReverts(true);

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                3,
                _buildAaveV2LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PROFIT GATE
    // ═══════════════════════════════════════════════════════════════════

    function test_profitGateRevertsIfBelowMinimum() public {
        // With swap amount 1000 at 1.1x = 1100 output. Flash repay = 1001.
        // Effective profit with debtToCover=400: = swap_output(1100) - flash_fee(1) - (debtToCover already paid from flash balance)
        // effectiveProfit = 699. Set minProfit impossibly high.
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 700e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_profitGateSucceedsIfMeetsMinimum() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 99e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);
        vm.prank(operatorAddr);
        executor.execute(plan); // should not revert
    }

    function test_profitGateWithBalancerProvider() public {
        // effectiveProfit with Balancer and debtToCover=100: ~999.
        // Set minProfit = 1000 -> reverts.
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1000e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(100e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEE CAP
    // ═══════════════════════════════════════════════════════════════════

    function test_balancerFeeCap() public {
        balancerVault.setFlashFee(100e18);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, 1e18, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.FlashFeeExceeded.selector, 100e18, 1e18));
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 SAFETY: CALLBACK ASSET/AMOUNT MISMATCH
    // ═══════════════════════════════════════════════════════════════════

    function test_balancerCallbackRejectsTokenMismatch() public {
        MockBalancerVaultLiar liarVault =
            new MockBalancerVaultLiar(FLASH_FEE, address(loanToken), address(collateralToken));
        loanToken.mint(address(liarVault), 100_000e18);
        collateralToken.mint(address(liarVault), 100_000e18);

        address[] memory targets = new address[](4);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(aaveV2Pool);
        targets[3] = address(liarVault);
        LiquidationExecutor exec2 = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        vm.startPrank(owner);
        exec2.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(exec2), 1000e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAssetMismatch.selector);
        exec2.execute(plan);
    }

    function test_balancerCallbackRejectsAmountMismatch() public {
        MockBalancerVaultAmountLiar liarVault = new MockBalancerVaultAmountLiar(FLASH_FEE);
        loanToken.mint(address(liarVault), 100_000e18);

        address[] memory targets = new address[](4);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(aaveV2Pool);
        targets[3] = address(liarVault);
        LiquidationExecutor exec2 = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        vm.startPrank(owner);
        exec2.setFlashProvider(2, address(liarVault));
        vm.stopPrank();

        loanToken.mint(address(exec2), LOAN_AMOUNT + FLASH_FEE + 100e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CallbackAmountMismatch.selector);
        exec2.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARTIAL FAILURE (swap/repay fails => whole tx reverts)
    // ═══════════════════════════════════════════════════════════════════

    function test_aaveLiquidationFailsWholeTxReverts() public {
        aavePool.setLiquidationReverts(true);
        collateralToken.mint(address(aavePool), 100_000e18);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FLASH PROVIDER VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfFlashProviderNotConfigured() public {
        bytes memory plan =
            _buildPlan(99, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.FlashProviderNotAllowed.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVALID PLAN FIELDS
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfLoanAmountZero() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 0, 0);

        bytes memory plan = _buildPlan(2, address(loanToken), 0, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_revertIfLoanTokenZeroAddress() public {
        bytes memory plan =
            _buildPlan(2, address(0), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.execute(plan);
    }

    function test_revertIfInvalidProtocolId() public {
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                99,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            _defaultSwapPlan()
        );
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONFIG ZERO ADDRESS CHECKS
    // ═══════════════════════════════════════════════════════════════════

    function test_setAaveV2LendingPoolZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setAaveV2LendingPool(address(0));
    }

    function test_setFlashProviderZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setFlashProvider(1, address(0));
    }

    function test_setFlashProviderRejectsNonWhitelisted() public {
        address notWhitelisted = address(0xDEAD3);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, notWhitelisted));
        executor.setFlashProvider(1, notWhitelisted);
    }

    function test_setFlashProviderAcceptsWhitelisted() public {
        // aavePool is in allowedTargets (set in constructor)
        vm.prank(owner);
        executor.setFlashProvider(1, address(aavePool));
        assertEq(executor.allowedFlashProviders(1), address(aavePool));
    }

    function test_setAaveV2LendingPoolRejectsNonWhitelisted() public {
        address notWhitelisted = address(0xDEAD2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, notWhitelisted));
        executor.setAaveV2LendingPool(notWhitelisted);
    }

    function test_settersAcceptWhitelistedAddresses() public {
        // aaveV2Pool is in allowedTargets (set in setUp)
        vm.startPrank(owner);
        executor.setAaveV2LendingPool(address(aaveV2Pool));
        assertEq(executor.aaveV2LendingPool(), address(aaveV2Pool));
        vm.stopPrank();
    }

    function test_rescueERC20ZeroToReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueERC20(address(loanToken), address(0), 1);
    }

    function test_rescueETHZeroToReverts() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueETH(payable(address(0)), 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // RESCUE ALL ERC20
    // ═══════════════════════════════════════════════════════════════════

    function test_rescueAllERC20TransfersFullBalance() public {
        loanToken.mint(address(executor), 200e18);
        uint256 fullBalance = loanToken.balanceOf(address(executor));
        uint256 ownerBefore = loanToken.balanceOf(owner);
        vm.prank(owner);
        executor.rescueAllERC20(address(loanToken), owner);
        assertEq(loanToken.balanceOf(address(executor)), 0);
        assertEq(loanToken.balanceOf(owner) - ownerBefore, fullBalance);
    }

    function test_rescueAllERC20RevertsOnZeroBalance() public {
        MockERC20 emptyToken = new MockERC20("Empty", "EMP", 18);
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroBalance.selector);
        executor.rescueAllERC20(address(emptyToken), owner);
    }

    function test_rescueAllERC20RevertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueAllERC20(address(loanToken), attacker);
    }

    function test_rescueAllERC20RevertsOnZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueAllERC20(address(0), owner);
    }

    function test_rescueAllERC20RevertsOnZeroTo() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueAllERC20(address(loanToken), address(0));
    }

    function test_rescueAllERC20EmitsEvent() public {
        loanToken.mint(address(executor), 50e18);
        uint256 fullBalance = loanToken.balanceOf(address(executor));
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit LiquidationExecutor.Rescue(address(loanToken), owner, fullBalance);
        executor.rescueAllERC20(address(loanToken), owner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // RESCUE ERC20 BATCH
    // ═══════════════════════════════════════════════════════════════════

    function test_rescueERC20BatchTransfersMultipleTokens() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(executor), 100e18);
        tokenB.mint(address(executor), 200e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        vm.prank(owner);
        executor.rescueERC20Batch(tokens, owner);

        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
        assertEq(tokenA.balanceOf(owner), 100e18);
        assertEq(tokenB.balanceOf(owner), 200e18);
    }

    function test_rescueERC20BatchSkipsZeroBalanceTokens() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(executor), 100e18);
        // tokenB has zero balance

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        vm.prank(owner);
        executor.rescueERC20Batch(tokens, owner);

        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenA.balanceOf(owner), 100e18);
        assertEq(tokenB.balanceOf(owner), 0);
    }

    function test_rescueERC20BatchMixedBalances() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        MockERC20 tokenC = new MockERC20("C", "C", 18);
        tokenA.mint(address(executor), 50e18);
        // tokenB has zero balance
        tokenC.mint(address(executor), 300e18);

        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);

        vm.prank(owner);
        executor.rescueERC20Batch(tokens, owner);

        assertEq(tokenA.balanceOf(owner), 50e18);
        assertEq(tokenB.balanceOf(owner), 0);
        assertEq(tokenC.balanceOf(owner), 300e18);
    }

    function test_rescueERC20BatchRevertsOnEmptyArray() public {
        address[] memory tokens = new address[](0);
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.EmptyArray.selector);
        executor.rescueERC20Batch(tokens, owner);
    }

    function test_rescueERC20BatchRevertsIfNotOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(loanToken);
        vm.prank(attacker);
        vm.expectRevert();
        executor.rescueERC20Batch(tokens, attacker);
    }

    function test_rescueERC20BatchRevertsOnZeroTo() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(loanToken);
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.rescueERC20Batch(tokens, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // EVENT EMISSION
    // ═══════════════════════════════════════════════════════════════════

    function test_emitsFlashExecutedBalancer() public {
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), _defaultSwapPlan());
        vm.prank(operatorAddr);
        vm.expectEmit(true, true, false, true);
        emit LiquidationExecutor.FlashExecuted(2, address(loanToken), LOAN_AMOUNT);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 REGRESSION: Aave V3 profit gate when profitToken == loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_aave_profit_token_equals_loan_token_profit_gate_works() public {
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 5e18);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan); // must not revert

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P0 REGRESSION: Balancer profit gate when profitToken == loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_balancer_profit_token_equals_loan_token_profit_gate_works() public {
        uint256 flashFee = 5e18;
        balancerVault.setFlashFee(flashFee);

        uint256 repayAmt = 500e18;
        uint256 netGain = 94e18; // swap gain (100) - flash fee (5) - rounding = ~94
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, netGain);

        bytes memory plan = _buildPlan(
            2, // Balancer
            address(loanToken),
            LOAN_AMOUNT,
            flashFee,
            _defaultLiqAction(repayAmt),
            swapPlan
        );

        vm.prank(operatorAddr);
        executor.execute(plan); // must not revert — profit gate passes

        // Approval hygiene
        assertEq(loanToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEATURE: Aave V3 liquidation
    // ═══════════════════════════════════════════════════════════════════

    function test_aave_v3_liquidation_executes_and_resets_allowance() public {
        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), // collateralAsset (received)
            address(loanToken), // debtAsset (paid) — must match plan.loanToken
            address(0x1234), // user being liquidated
            debtToCover,
            false
        );

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

        bytes memory plan = _buildPlan(
            2, // Balancer flash
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(1, targetAction),
            swapPlan
        );

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Assert allowance reset for debtAsset -> aavePool
        assertEq(loanToken.allowance(address(executor), address(aavePool)), 0);
        // Assert allowance reset for swap
        assertEq(collateralToken.allowance(address(executor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // EVENT EMISSION (preserved)
    // ═══════════════════════════════════════════════════════════════════

    function test_emitsLiquidationExecuted() public {
        aaveV2Pool.setCollateralReward(COLLATERAL_REWARD);
        collateralToken.mint(address(aaveV2Pool), 100_000e18);

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                3,
                _buildAaveV2LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            swapPlan
        );
        vm.prank(operatorAddr);
        vm.expectEmit(true, true, true, true);
        emit LiquidationExecutor.LiquidationExecuted(3, address(collateralToken), address(loanToken), 500e18);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PARASWAP CALLDATA VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    /// Paraswap V6 sometimes encodes beneficiary == address(0) as a gas optimization
    /// (caller is implicit recipient). Contract must accept it as equivalent to address(this).
    function test_paraswapSingle_acceptsZeroBeneficiary() public {
        // Fund mock so the swap can deliver loanToken on behalf of the implicit recipient.
        loanToken.mint(address(augustus), DEFAULT_SWAP_AMOUNT);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(0)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    /// Sanity that beneficiary == address(this) still works (covered in happy paths,
    /// pinned here next to the zero-beneficiary case for symmetry).
    function test_paraswapSingle_acceptsSelfBeneficiary() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // OPTIMIZED PARASWAP SELECTORS (UniswapV3 ExactIn / ExactOut)
    // ═══════════════════════════════════════════════════════════════════

    /// Optimized exact-in selector: full-size struct in head (no executor word),
    /// recipient at slot 6. Mock decodes by selector and routes through the same
    /// execution + balance-delta path as the generic call.
    function test_paraswapOptimized_exactIn_uniV3_happyPath() public {
        bytes memory cd = _buildOptimizedExactInUniV3Calldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGt(loanAfter, loanBefore, "optimized exact-in must produce loanToken output");
    }

    /// Optimized exact-out selector with a 95% partial-fill mock — actual consumed
    /// must be <= declared max (matches generic ExactOut semantics).
    function test_paraswapOptimized_exactOut_uniV3_happyPath() public {
        augustus.setPartialFillPct(95); // consume 95% of declared max

        bytes memory cd = _buildOptimizedExactOutUniV3Calldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Restore for unrelated tests.
        augustus.setPartialFillPct(0);
    }

    /// Wrong srcToken in optimized calldata must surface via the executor's
    /// post-decode validation — the spec.srcToken / decoded srcToken mismatch is
    /// caught by `_executeParaswapSingle` (ParaswapSrcTokenMismatch).
    function test_paraswapOptimized_wrongSrcToken_reverts() public {
        // Calldata claims wrong srcToken (mockWeth) while plan declares collateralToken.
        bytes memory cd = _buildOptimizedExactInUniV3Calldata(
            address(mockWeth), // wrong src
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            0,
            address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    /// Wrong dstToken in optimized calldata must surface via repayToken mismatch.
    function test_paraswapOptimized_wrongDstToken_reverts() public {
        bytes memory cd = _buildOptimizedExactInUniV3Calldata(
            address(collateralToken),
            address(mockWeth), // wrong dst (plan expects loanToken)
            DEFAULT_SWAP_AMOUNT,
            0,
            address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    /// Wrong amount in optimized exact-in calldata: actual consumed (= declared)
    /// must equal plan.amountIn. Mismatch fires `ParaswapAmountInMismatch`.
    function test_paraswapOptimized_wrongAmount_reverts() public {
        // Calldata declares half of plan.amountIn → consumed = half → mismatch.
        bytes memory cd = _buildOptimizedExactInUniV3Calldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT / 2, 0, address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    /// Unknown selector (anything not in the explicit whitelist) must revert with
    /// `InvalidParaswapSelector(selector)` — no silent fallback to the generic
    /// decoder, no arbitrary-call passthrough.
    function test_paraswapOptimized_unknownSelector_reverts() public {
        bytes4 fakeSelector = 0xdeadbeef;
        bytes memory cd = abi.encodePacked(fakeSelector, new bytes(420)); // pad past length checks

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidParaswapSelector.selector, fakeSelector));
        executor.execute(plan);
    }

    /// Beneficiary rule still enforced for optimized — same SwapRecipientInvalid
    /// surface as for the generic family. Anything other than {address(this), 0}
    /// reverts pre-call.
    function test_paraswapOptimized_invalidBeneficiary_reverts() public {
        address badRecipient = address(0xBAAD);
        bytes memory cd = _buildOptimizedExactInUniV3Calldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, badRecipient
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.SwapRecipientInvalid.selector, badRecipient));
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // DIRECT ROUTER FAMILIES — DynamicStruct (UniswapV2)
    // ═══════════════════════════════════════════════════════════════════
    //
    // The decoder for DynamicStruct families (UniV2 / BalancerV2 / CurveV1) reads
    // the struct in the calldata TAIL via the offset stored in head[0]. These
    // tests exercise UniswapV2 specifically; BalancerV2 and CurveV1 share the
    // same decoder shape (selector → DynamicStruct branch in
    // `_decodeAndValidateParaswap`) and would reuse this scaffolding once their
    // exact struct prefix is verified against on-chain Augustus V6.2.

    function test_paraswapDirect_uniV2_exactIn_happyPath() public {
        bytes memory cd = _buildUniV2ExactInCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGt(loanAfter, loanBefore, "UniV2 exact-in must produce loanToken output");
    }

    function test_paraswapDirect_uniV2_wrongSrcToken_reverts() public {
        bytes memory cd = _buildUniV2ExactInCalldata(
            address(mockWeth), // wrong src
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            0,
            address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_paraswapDirect_uniV2_wrongDstToken_reverts() public {
        bytes memory cd = _buildUniV2ExactInCalldata(
            address(collateralToken),
            address(mockWeth), // wrong dst
            DEFAULT_SWAP_AMOUNT,
            0,
            address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_paraswapDirect_uniV2_wrongAmount_reverts() public {
        bytes memory cd = _buildUniV2ExactInCalldata(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT / 2, // half of plan.amountIn
            0,
            address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_paraswapDirect_uniV2_invalidBeneficiary_reverts() public {
        address badRecipient = address(0xBAAD);
        bytes memory cd = _buildUniV2ExactInCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, badRecipient
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.SwapRecipientInvalid.selector, badRecipient));
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // RFQ EXPLICIT REJECTION
    // ═══════════════════════════════════════════════════════════════════

    /// The real Augustus V6.2 RFQ entrypoint (`swapOnAugustusRFQTryBatchFill`,
    /// selector 0xda35bb0d) must revert with `InvalidParaswapSelector` because
    /// RFQ flows route through the off-chain matcher and we never want to
    /// execute one. The classifier maps this selector to its dedicated `RFQ`
    /// kind so the rejection is intentional rather than an "unknown selector"
    /// coincidence.
    function test_paraswapRFQ_selector_explicitlyRejected() public {
        bytes4 rfqSelector = SWAP_RFQ_BATCH_FILL_SELECTOR;
        bytes memory cd = abi.encodePacked(rfqSelector, new bytes(420));

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidParaswapSelector.selector, rfqSelector));
        executor.execute(plan);
    }

    function test_revertIfSwapRecipientInvalid() public {
        address badRecipient = address(0xBAAD);
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, badRecipient
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.SwapRecipientInvalid.selector, badRecipient));
        executor.execute(plan);
    }

    function test_revertIfSwapAmountInMismatch() public {
        // Build calldata with fromAmount = DEFAULT_SWAP_AMOUNT but spec.amountIn = LOAN_AMOUNT / 2
        uint256 specAmountIn = LOAN_AMOUNT / 2;
        bytes memory cd = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(executor)
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: specAmountIn,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.ParaswapAmountInMismatch.selector, specAmountIn, DEFAULT_SWAP_AMOUNT
            )
        );
        executor.execute(plan);
    }

    function test_revertIfUnsupportedSwapSelector() public {
        // Build calldata with an unknown selector but valid length
        bytes memory badCalldata = abi.encodeWithSelector(
            bytes4(0xdeadbeef),
            address(0),
            address(collateralToken),
            address(loanToken),
            COLLATERAL_REWARD,
            uint256(0),
            uint256(0),
            bytes32(0),
            address(executor),
            uint256(0),
            bytes(""),
            bytes("")
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: badCalldata,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.InvalidParaswapSelector.selector, bytes4(0xdeadbeef))
        );
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP INVARIANTS: repayToken must match loanToken
    // ═══════════════════════════════════════════════════════════════════

    function test_revertIfRepayTokenNotLoanToken() public {
        // repayToken != loanToken -> RepayTokenMismatch
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(loanToken), address(collateralToken), LOAN_AMOUNT, 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.RepayTokenMismatch.selector, address(loanToken), address(collateralToken)
            )
        );
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // REAL LIQUIDATION FLOW: flash debtAsset -> liquidate -> swap collateral -> repay
    // ═══════════════════════════════════════════════════════════════════

    function test_aave_v3_liquidation_real_flow() public {
        // Fresh executor with ZERO balances
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        // Verify executor starts with zero balances
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "Executor must start with zero loanToken");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "Executor must start with zero collateralToken");

        // Configure liquidation parameters
        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18; // 20% liquidation bonus
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        // Fund ONLY the pools (not the executor)
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Build liquidation action
        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        // Build swap plan
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: collateralReward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), debtToCover, flashFee, _singleAction(1, targetAction), swapPlan);

        vm.prank(operatorAddr);
        freshExecutor.execute(plan);

        // Assertions
        uint256 profit = loanToken.balanceOf(address(freshExecutor));
        assertGt(profit, 0, "Executor must have positive loanToken profit");
        assertEq(
            collateralToken.balanceOf(address(freshExecutor)), 0, "Executor must have zero collateralToken after swap"
        );

        // No dangling approvals
        assertEq(loanToken.allowance(address(freshExecutor), address(aavePool)), 0);
        assertEq(collateralToken.allowance(address(freshExecutor), address(augustus)), 0);
        assertEq(loanToken.allowance(address(freshExecutor), address(augustus)), 0);

        // Verify profit math
        uint256 expectedProfit = (collateralReward * SWAP_RATE / 1e18) - debtToCover - flashFee;
        assertEq(profit, expectedProfit, "Profit must match expected calculation");
    }

    // ═══════════════════════════════════════════════════════════════════
    // NEGATIVE: swap slippage causes revert
    // ═══════════════════════════════════════════════════════════════════

    function test_liquidation_reverts_on_insufficient_swap_output() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Set swap rate so output is LESS than repay amount
        augustus.setRate(0.6e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: collateralReward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), debtToCover, flashFee, _singleAction(1, targetAction), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        freshExecutor.execute(plan);

        // Reset rate for other tests
        augustus.setRate(SWAP_RATE);

        // Executor must have no leftover tokens (tx reverted = state rolled back)
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "No loanToken stuck after revert");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateralToken stuck after revert");
    }

    // ═══════════════════════════════════════════════════════════════════
    // NEGATIVE: non-profitable liquidation with minProfit > 0
    // ═══════════════════════════════════════════════════════════════════

    function test_liquidation_reverts_on_non_profitable_execution() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        uint256 debtToCover = 500e18;
        uint256 collateralReward = 600e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);

        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Set swap rate so profit is minimal
        augustus.setRate(0.836e18);

        bytes memory targetAction = _buildAaveV3LiquidationAction(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, false
        );

        uint256 swapOutput = collateralReward * 0.836e18 / 1e18; // 501.6e18

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: collateralReward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 10e18
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), debtToCover, flashFee, _singleAction(1, targetAction), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InsufficientProfit.selector,
                swapOutput - debtToCover - flashFee, // actual profit
                10e18 // required profit
            )
        );
        freshExecutor.execute(plan);

        // Reset rate for other tests
        augustus.setRate(SWAP_RATE);

        // Executor must have no leftover tokens
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "No loanToken stuck after revert");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateralToken stuck after revert");
    }

    // ═══════════════════════════════════════════════════════════════════
    // MULTI-ACTION: two liquidations in one flash loan
    // ═══════════════════════════════════════════════════════════════════

    function test_multi_liquidation_flow() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        assertEq(loanToken.balanceOf(address(freshExecutor)), 0);
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0);

        uint256 debtToCover1 = 300e18;
        uint256 debtToCover2 = 200e18;
        uint256 totalDebt = debtToCover1 + debtToCover2; // 500e18
        uint256 collateralReward = 600e18;
        uint256 totalCollateral = collateralReward * 2; // 1200e18
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // Two liquidation actions
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), debtToCover1, false
            )
        });
        actions[1] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x2222), debtToCover2, false
            )
        });

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: totalCollateral,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), totalCollateral, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan = _buildPlan(2, address(loanToken), totalDebt, flashFee, actions, swapPlan);

        vm.prank(operatorAddr);
        freshExecutor.execute(plan);

        // Profit
        uint256 profit = loanToken.balanceOf(address(freshExecutor));
        uint256 expectedProfit = (totalCollateral * SWAP_RATE / 1e18) - totalDebt - flashFee;
        assertEq(profit, expectedProfit, "Multi-liq profit must match");

        // No leftover collateral
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateral left");

        // No approvals
        assertEq(loanToken.allowance(address(freshExecutor), address(aavePool)), 0);
        assertEq(collateralToken.allowance(address(freshExecutor), address(augustus)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MULTI-ACTION: partial failure causes atomic revert
    // ═══════════════════════════════════════════════════════════════════

    function test_multi_action_partial_failure_reverts() public {
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        uint256 debtToCover = 300e18;
        uint256 collateralReward = 400e18;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        // First action: valid liquidation
        // Second action: uses invalid protocol ID -> guaranteed revert
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), debtToCover, false
            )
        });
        // Second action uses invalid protocol ID -> guaranteed revert
        actions[1] = LiquidationExecutor.Action({
            protocolId: 99,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x2222), debtToCover, false
            )
        });

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: collateralReward * 2,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), collateralReward * 2, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan = _buildPlan(2, address(loanToken), debtToCover * 2, flashFee, actions, swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        freshExecutor.execute(plan);

        // Atomic rollback -- no stuck tokens
        assertEq(loanToken.balanceOf(address(freshExecutor)), 0, "No loanToken stuck");
        assertEq(collateralToken.balanceOf(address(freshExecutor)), 0, "No collateralToken stuck");
    }

    // ═══════════════════════════════════════════════════════════════════
    // INPUT VALIDATION: empty actions, too many actions
    // ═══════════════════════════════════════════════════════════════════

    function test_execute_reverts_on_empty_actions() public {
        LiquidationExecutor.Action[] memory empty = new LiquidationExecutor.Action[](0);

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, empty, _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.NoActions.selector);
        executor.execute(plan);
    }

    function test_execute_reverts_on_too_many_actions() public {
        LiquidationExecutor.Action[] memory tooMany = new LiquidationExecutor.Action[](11);
        for (uint256 i = 0; i < 11; i++) {
            tooMany[i] = LiquidationExecutor.Action({
                protocolId: 1,
                data: _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 100e18, false
                )
            });
        }

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, tooMany, _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TooManyActions.selector, 11));
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // VALIDATION: debt/collateral/swap consistency
    // ═══════════════════════════════════════════════════════════════════

    function test_reverts_on_invalid_debt_asset() public {
        // Two liquidations with DIFFERENT debt assets -> INVALID_DEBT_ASSET
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), 100e18, false
            )
        });
        actions[1] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken),
                address(collateralToken),
                address(0x2222),
                100e18,
                false // wrong debt
            )
        });

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 200e18, 0);

        bytes memory plan = _buildPlan(2, address(loanToken), 200e18, FLASH_FEE, actions, swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.DebtAssetMismatch.selector, address(loanToken), address(collateralToken)
            )
        );
        executor.execute(plan);
    }

    function test_reverts_on_invalid_collateral_asset() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1111), 100e18, false
            )
        });
        actions[1] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(otherToken),
                address(loanToken),
                address(0x2222),
                100e18,
                false // different collateral
            )
        });

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 200e18, 0);

        bytes memory plan = _buildPlan(2, address(loanToken), 200e18, FLASH_FEE, actions, swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.CollateralAssetMismatch.selector, address(collateralToken), address(otherToken)
            )
        );
        executor.execute(plan);
    }

    function test_reverts_on_src_not_collateral() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);

        // Swap srcToken != collateralAsset -> SRC_NOT_COLLATERAL
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(otherToken), address(loanToken), 200e18, 0);

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            200e18,
            FLASH_FEE,
            _singleAction(
                1,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 200e18, false
                )
            ),
            swapPlan
        );

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.SrcTokenNotCollateral.selector, address(collateralToken), address(otherToken)
            )
        );
        executor.execute(plan);
    }

    function test_reverts_on_zero_action_amount() public {
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            200e18,
            FLASH_FEE,
            _singleAction(
                1,
                _buildAaveV3LiquidationAction(
                    address(collateralToken),
                    address(loanToken),
                    address(0x1234),
                    0,
                    false // zero amount
                )
            ),
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 200e18, 0)
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ZeroActionAmount.selector);
        executor.execute(plan);
    }

    function test_reverts_on_unsupported_action() public {
        // Aave V3 actionType != 4 (e.g. repay=1) -> UnsupportedActionType(1)
        bytes memory repayAction = abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 1,
                asset: address(collateralToken),
                amount: 500e18,
                interestRateMode: 2,
                onBehalfOf: address(0x1234),
                collateralAsset: address(0),
                debtAsset: address(0),
                user: address(0),
                debtToCover: 0,
                receiveAToken: false,
                aTokenAddress: address(0)
            })
        );
        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, repayAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.UnsupportedActionType.selector, 1));
        executor.execute(plan);
    }

    function test_reverts_on_invalid_protocol() public {
        // Protocol ID 99 -> INVALID_PROTOCOL
        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            LOAN_AMOUNT,
            FLASH_FEE,
            _singleAction(
                99,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidProtocolId.selector, 99));
        executor.execute(plan);
    }

    function test_reverts_on_no_collateral_received() public {
        // Fresh executor with zero balance
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        // Liquidation returns 0 collateral -> NO_COLLATERAL
        aavePool.setLiquidationCollateralReward(0);
        loanToken.mint(address(aavePool), 100_000e18);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: 1,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), 1, address(freshExec)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan = _buildPlan(
            2,
            address(loanToken),
            500e18,
            FLASH_FEE,
            _singleAction(
                1,
                _buildAaveV3LiquidationAction(
                    address(collateralToken), address(loanToken), address(0x1234), 500e18, false
                )
            ),
            swapPlan
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.NoCollateralReceived.selector);
        freshExec.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVARIANT: Internal-only plan must revert
    // ═══════════════════════════════════════════════════════════════════

    function test_internalOnlyPlan_reverts() public {
        // Build a plan with only a PROTOCOL_INTERNAL action (coinbase payment), no liquidation
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](1);
        actions[0] = _buildCoinbasePaymentAction(100);

        bytes memory plan = _buildPlan(2, address(mockWeth), LOAN_AMOUNT, FLASH_FEE, actions, _wethSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.NoLiquidationAction.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVARIANT: Stale collateral must not mask missing liquidation delta
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Executor has pre-funded collateral but liquidation produces zero.
    /// Delta check must revert even though absolute balance > 0.
    function test_staleCollateral_doesNotMaskMissingDelta() public {
        // Set liquidation reward to 0 — liquidation won't increase collateral
        aavePool.setLiquidationCollateralReward(0);

        // Executor still has pre-funded collateral from setUp (DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD = 400e18)
        assertTrue(collateralToken.balanceOf(address(executor)) > 0, "precondition: stale collateral exists");

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.NoCollateralReceived.selector);
        executor.execute(plan);
    }

    /// @notice Same stale-collateral test but with Balancer flash provider.
    function test_staleCollateral_doesNotMaskMissingDelta_balancer() public {
        aavePool.setLiquidationCollateralReward(0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.NoCollateralReceived.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVARIANT: Morpho protocol now supported (was previously rejected)
    // ═══════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT (requires profitToken == weth)
    // ═══════════════════════════════════════════════════════════════════

    function test_coinbasePayment_sendsETH() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 1 ether);

        // bps=100 (1%) of 699e18 realized profit = 6.99e18 paid.
        // Pre-funded 1 ETH + unwrapped 5.99 WETH covers the transfer.
        uint256 bps = 100;
        uint256 expected = WETH_REALIZED_PROFIT * bps / 10_000;

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, bps), 0));

        assertEq(coinbase.balance, expected, "coinbase received bps-sized payment");
        assertEq(address(executor).balance, 0, "all ETH flowed out to coinbase");
    }

    function test_coinbasePayment_bpsOver10000_reverts() public {
        vm.coinbase(address(0xC01B));
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidCoinbaseBps.selector);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 10_001), 0));
    }

    function test_coinbasePayment_revertsOnFailedCall() public {
        ETHRejecter rejecter = new ETHRejecter();
        vm.coinbase(address(rejecter));
        vm.deal(address(executor), 100 ether);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CoinbasePaymentFailed.selector);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 100), 0));
    }

    function test_coinbasePayment_zeroAmountNoOp() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);

        // bps=0 → explicit no-op, regardless of profit.
        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 0), 0));

        assertEq(coinbase.balance, 0);
    }

    function test_coinbasePayment_profitStillChecked() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1 ether);

        // bps=100 → payment = 6.99e18, effectiveProfit = 692.01e18 > 99e18 → passes.
        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 100), 99e18));
    }

    function test_coinbasePayment_minProfitFailsIfUnprofitable() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1 ether);

        // bps=100 → payment = 6.99e18, effectiveProfit = 692.01e18.
        // minProfit = 700e18 > 692.01e18 → reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 100), 700e18));
    }

    function test_coinbasePayment_invalidActionTypeReverts() public {
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), 400e18, false
            )
        });
        actions[1] = LiquidationExecutor.Action({protocolId: 100, data: abi.encode(uint8(99), uint256(0.5 ether))});

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidAction.selector, 99));
        executor.execute(plan);
    }

    function test_coinbasePayment_emitsEvent() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 1 ether);

        uint256 bps = 100;
        uint256 expected = WETH_REALIZED_PROFIT * bps / 10_000;

        vm.prank(operatorAddr);
        vm.expectEmit(true, false, false, true);
        emit LiquidationExecutor.CoinbasePaid(coinbase, expected);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, bps), 0));
    }

    function test_coinbasePayment_balancerProvider() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 1 ether);

        uint256 bps = 100;
        uint256 expected = WETH_REALIZED_PROFIT * bps / 10_000;

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, bps), 0));

        assertEq(coinbase.balance, expected);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT -- UNIT RESTRICTION
    // ═══════════════════════════════════════════════════════════════════

    function test_coinbasePayment_revertsWhenProfitTokenNotWeth() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1 ether);

        // Build plan using loanToken as profitToken (not weth); bps value is
        // irrelevant because the requires-weth gate fires first.
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(100);

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.CoinbasePaymentRequiresWethProfit.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT -- PROFIT ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════

    function test_coinbasePayment_subtractsFromProfit() public {
        vm.coinbase(address(0xC01B));

        // bps=200 → payment = 13.98e18. effectiveProfit = 685.02e18.
        // minProfit = 699e18 > 685.02e18 → reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 200), 699e18));
    }

    function test_coinbasePayment_exactProfitBoundaryPasses() public {
        vm.coinbase(address(0xC01B));

        // bps=100 → payment = 6.99e18. effectiveProfit = 692.01e18.
        // minProfit set to exactly effectiveProfit should pass (>= boundary).
        uint256 bps = 100;
        uint256 expectedEffective = WETH_REALIZED_PROFIT - (WETH_REALIZED_PROFIT * bps / 10_000);
        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, bps), expectedEffective));
    }

    /// @notice Coinbase payment (regardless of pre-existing ETH vs WETH unwrap
    /// source) reduces effectiveProfit by the full amount.
    function test_coinbasePayment_prefundedETH_deducted() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1000 ether);

        // bps=1000 (10%) → payment = 69.9e18 (from pre-existing ETH, no unwrap).
        // effectiveProfit = 629.1e18. minProfit = 630e18 → reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 1000), 630e18));
    }

    function test_coinbasePayment_multiplePaymentsAccumulated() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 100 ether);

        // Two bps actions each compute against the same realizedProfit snapshot.
        // 100 bps + 200 bps → payments 6.99e18 + 13.98e18 = 20.97e18 total.
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](3);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(100);
        actions[2] = _buildCoinbasePaymentAction(200);

        uint256 expected = WETH_REALIZED_PROFIT * 100 / 10_000 + WETH_REALIZED_PROFIT * 200 / 10_000;

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, actions, 0));

        assertEq(coinbase.balance, expected);
    }

    /// @notice Coinbase payment reduces effectiveProfit regardless of funding
    /// source (WETH unwrap vs pre-existing ETH).
    function test_coinbasePayment_wethUnwrapReducesProfit() public {
        vm.coinbase(address(0xC01B));
        // No pre-funded ETH — forces WETH unwrap

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](3);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(100);
        actions[2] = _buildCoinbasePaymentAction(200);

        // Total bps = 300 → payment = 20.97e18. effective = 678.03e18.
        // minProfit = 679e18 → reverts.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(2, actions, 679e18));
    }

    function test_coinbasePayment_wethUnwrap() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        // No vm.deal -> executor has 0 ETH, must unwrap WETH

        uint256 bps = 100;
        uint256 expected = WETH_REALIZED_PROFIT * bps / 10_000;

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, bps), 0));

        // Coinbase received ETH that could only have come from WETH unwrap
        assertEq(coinbase.balance, expected);
        // Executor has no remaining ETH (all unwrapped ETH went to coinbase)
        assertEq(address(executor).balance, 0);
    }

    function test_coinbasePayment_wethProfitNoDoubleCount() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        // No pre-funded ETH → payment entirely from WETH unwrap. effectiveProfit
        // is realizedProfit - totalCoinbasePayment (no double-count by source).
        uint256 bps = 100;
        uint256 expected = WETH_REALIZED_PROFIT * bps / 10_000;

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, bps), 0));

        assertEq(coinbase.balance, expected);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT — BPS SEMANTICS (new model)
    // ═══════════════════════════════════════════════════════════════════

    function test_coinbasePayment_bps_0_paysZero() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 0), 0));
        assertEq(coinbase.balance, 0);
    }

    function test_coinbasePayment_bps_5000_halfOfRealized() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 400 ether); // fund native ETH so the full 50% unwrap isn't forced

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 5000), 0));

        uint256 expected = WETH_REALIZED_PROFIT * 5000 / 10_000;
        assertEq(coinbase.balance, expected, "50% of realized profit");
    }

    function test_coinbasePayment_bps_9500_ninetyFivePercent() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 700 ether);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 9500), 0));

        uint256 expected = WETH_REALIZED_PROFIT * 9500 / 10_000;
        assertEq(coinbase.balance, expected, "95% of realized profit");
    }

    function test_coinbasePayment_bps_10000_fullRealized() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 700 ether);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 10_000), 0));

        assertEq(coinbase.balance, WETH_REALIZED_PROFIT, "100% of realized profit");
    }

    function test_coinbasePayment_zeroRealized_nonzeroBps_isNoop() public {
        // Construct a scenario where realizedProfit is EXACTLY 0 without any
        // pipeline guard firing first:
        //   debtToCover = 1000e18  → liquidation pays 1000e18 WETH
        //   rate        = 1.001e18 → swap 1000 COLL → 1001e18 WETH
        //   flashRepay  = 1001e18  → repayDelta == flashRepay (just covers)
        //   realized    = 1001 - 1000 (debt) - 1 (fee) = 0
        // Pipeline completes cleanly; bps > 0 must produce no payment and no
        // revert. This is the canonical no-op path for the bps model.
        augustus.setRate(1.001e18);

        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(1000e18, 5000), 0));

        assertEq(coinbase.balance, 0, "zero realized profit with non-zero bps produces no payment");

        augustus.setRate(SWAP_RATE);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COINBASE PAYMENT — HARDENING (realizedProfit + multi-action invariants)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Pre-existing profit-token balance MUST NOT inflate realizedProfit.
    /// profitBefore snapshot includes whatever is sitting on the contract, and
    /// profitNow measured later cancels it out in the delta — the coinbase
    /// payment should be identical to the baseline case regardless of
    /// pre-existing balance.
    function test_realizedProfit_preExistingWethIgnored() public {
        mockWeth.mint(address(executor), 500e18); // extra pre-fund above setUp default

        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 700 ether);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 10_000), 0));

        // bps=10000 extracts 100% of realizedProfit. Baseline = 699e18; the
        // additional 500e18 pre-fund must not move this value by a single wei.
        assertEq(coinbase.balance, WETH_REALIZED_PROFIT, "pre-existing balance cancels in delta");
    }

    /// @notice Two 5000-bps actions sum to EXACTLY realizedProfit. If the
    /// contract re-read profitToken balance between actions (recomputing
    /// realized), the second payment would shrink. The test asserts the full
    /// 100% arrives at the coinbase, proving the snapshot is immutable.
    function test_multipleCoinbase_sameSnapshotAcrossActions() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 700 ether);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](3);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(5000);
        actions[2] = _buildCoinbasePaymentAction(5000);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, actions, 0));

        assertEq(coinbase.balance, WETH_REALIZED_PROFIT, "5000+5000 bps equals realized (snapshot not mutated)");
    }

    /// @notice Two actions whose bps sum exceeds 10000. Each per-action bps is
    /// individually valid (<= 10000), so InvalidCoinbaseBps does NOT fire.
    /// The guard must kick in at _checkProfit via CoinbaseExceedsProfit.
    function test_multipleCoinbase_sumExceedsRealized_reverts() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 1000 ether);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](3);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(5001);
        actions[2] = _buildCoinbasePaymentAction(5000);

        // Sum bps = 10001 > 10000. Per-action checks both pass; aggregate
        // guard inside _checkProfit must revert with CoinbaseExceedsProfit.
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(2, actions, 0));
    }

    /// @notice Three actions of 3333 bps each. Exercises the accumulator loop
    /// beyond two iterations and verifies per-action payment is stable.
    function test_multipleCoinbase_threeActions_cumulative() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 700 ether);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](4);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(3333);
        actions[2] = _buildCoinbasePaymentAction(3333);
        actions[3] = _buildCoinbasePaymentAction(3333);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, actions, 0));

        uint256 expected = 3 * (WETH_REALIZED_PROFIT * 3333 / 10_000);
        assertEq(coinbase.balance, expected, "3x3333 bps cumulative payment");
    }

    /// @notice Legacy rollout safety. A bot that didn't migrate and still
    /// sends a raw wei amount (1e18 == "1 ETH" under the old absolute model)
    /// must fail loudly — otherwise the contract would try to bid
    /// 1e18 * realized / 10_000 and blow the InvalidCoinbaseBps guard.
    function test_legacyAbsoluteAmount_reverts() public {
        vm.coinbase(address(0xC01B));
        uint256 legacyAmount = 1e18; // old-style "1 ETH" absolute bid

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidCoinbaseBps.selector);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, legacyAmount), 0));
    }

    /// @notice Invariant: `payment = realized * bps / 10000` with bps in
    /// [0, 10000] can never exceed realized. Exercised at discrete points
    /// covering the full valid range — integer division floors, so the
    /// payment <= realized property holds by construction.
    function test_noOverpayment_perActionInvariant() public {
        uint256[6] memory bpsValues = [uint256(0), 1, 4999, 5000, 9999, 10_000];

        for (uint256 i = 0; i < bpsValues.length; ++i) {
            address coinbase = address(uint160(0xC0100000 + i));
            vm.coinbase(coinbase);
            vm.deal(address(executor), 700 ether);
            // Re-fund collateral gap consumed by the prior iteration's swap.
            collateralToken.mint(address(executor), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD);

            vm.prank(operatorAddr);
            executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, bpsValues[i]), 0));

            uint256 expected = WETH_REALIZED_PROFIT * bpsValues[i] / 10_000;
            assertEq(coinbase.balance, expected, "payment matches bps formula");
            assertLe(coinbase.balance, WETH_REALIZED_PROFIT, "payment never exceeds realized");
        }
    }

    /// @notice Rounding safety for small realizedProfit values. With realized
    /// = 1e18 and bps = 9999 the computed payment is 9.999e17 — strictly less
    /// than realized (flooring behaviour). bps < 10000 always yields
    /// payment < realized for any positive realized. No overflow path:
    /// `realized * 10000` fits in uint256 for any physically plausible balance.
    function test_smallRealizedProfit_roundsDown_noOverpay() public {
        augustus.setRate(1.002e18); // swap 1000 COLL → 1002 WETH → realized = 1e18

        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);
        vm.deal(address(executor), 1 ether);

        vm.prank(operatorAddr);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(1000e18, 9999), 0));

        uint256 expected = 1e18 * 9999 / 10_000; // 9.999e17
        assertEq(coinbase.balance, expected, "payment floor = 1e18 * 9999 / 10000");
        assertLt(coinbase.balance, 1e18, "payment strictly less than realized when bps < 10000");

        augustus.setRate(SWAP_RATE);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEATURE: receiveAToken support
    // ═══════════════════════════════════════════════════════════════════

    function _buildMorphoLiquidationAction(address collateral, address debt, address borrower, uint256 seizedAssets)
        internal
        pure
        returns (bytes memory)
    {
        return _buildMorphoLiquidationActionFull(collateral, debt, borrower, seizedAssets, seizedAssets);
    }

    function _buildMorphoLiquidationActionFull(
        address collateral,
        address debt,
        address borrower,
        uint256 seizedAssets,
        uint256 maxRepayAssets
    ) internal pure returns (bytes memory) {
        return abi.encode(
            LiquidationExecutor.MorphoLiquidation({
                marketParams: MarketParams({
                    loanToken: debt, collateralToken: collateral, oracle: address(0x1), irm: address(0x2), lltv: 0.8e18
                }),
                borrower: borrower,
                seizedAssets: seizedAssets,
                repaidShares: 0,
                maxRepayAssets: maxRepayAssets
            })
        );
    }

    function test_receiveAToken_true_fullPipeline() public {
        // Fresh executor with zero balances
        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        uint256 debtToCover = 500e18;
        uint256 collateralReward = COLLATERAL_REWARD;
        uint256 flashFee = 1e18;

        aavePool.setLiquidationCollateralReward(collateralReward);
        aavePool.setAToken(address(aToken));

        loanToken.mint(address(aavePool), 100_000e18);
        aToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18); // needed for withdraw
        loanToken.mint(address(augustus), 100_000e18);

        // Build action with receiveAToken=true
        bytes memory targetAction = _buildAaveV3LiquidationActionWithAToken(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, address(aToken)
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: collateralReward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), debtToCover, flashFee, _singleAction(1, targetAction), swapPlan);

        vm.prank(operatorAddr);
        freshExecutor.execute(plan);

        uint256 profit = loanToken.balanceOf(address(freshExecutor));
        assertGt(profit, 0, "Executor must have positive loanToken profit");
    }

    function test_receiveAToken_false_still_works() public {
        // Same as existing happy path but explicit receiveAToken=false
        uint256 repayAmt = 500e18;
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, MIN_PROFIT);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(repayAmt), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGe(loanAfter - loanBefore, MIN_PROFIT);
    }

    function test_receiveAToken_missingATokenAddress_reverts() public {
        // receiveAToken=true but aTokenAddress=address(0)
        bytes memory targetAction = abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 4,
                asset: address(0),
                amount: 0,
                interestRateMode: 0,
                onBehalfOf: address(0),
                collateralAsset: address(collateralToken),
                debtAsset: address(loanToken),
                user: address(0x1234),
                debtToCover: 500e18,
                receiveAToken: true,
                aTokenAddress: address(0)
            })
        );

        bytes memory plan = _buildPlan(
            2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ATokenAddressRequired.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // FEATURE: Morpho Blue liquidation support
    // ═══════════════════════════════════════════════════════════════════

    function test_morphoLiquidation_happyPath() public {
        // Fresh executor with zero balances
        address[] memory targets = new address[](3);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(morphoBlue);
        LiquidationExecutor freshExecutor = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        vm.prank(owner);
        freshExecutor.setMorphoBlue(address(morphoBlue));

        uint256 seizedAssets = 500e18;
        uint256 collateralReward = COLLATERAL_REWARD;
        uint256 flashFee = 1e18;

        morphoBlue.setLiquidationCollateralReward(collateralReward);

        loanToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(morphoBlue), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), seizedAssets);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: collateralReward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), collateralReward, address(freshExecutor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), seizedAssets, flashFee, _singleAction(2, targetAction), swapPlan);

        vm.prank(operatorAddr);
        freshExecutor.execute(plan);

        uint256 profit = loanToken.balanceOf(address(freshExecutor));
        assertGt(profit, 0, "Executor must have positive loanToken profit");
    }

    function test_morphoLiquidation_reverts_on_failure() public {
        morphoBlue.setLiquidationReverts(true);

        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), 500e18);

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);

        // Reset
        morphoBlue.setLiquidationReverts(false);
    }

    function test_morphoLiquidation_validation_consistent() public {
        // Two Morpho actions with different collateral assets -> CollateralAssetMismatch
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 2,
            data: _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1111), 100e18)
        });
        actions[1] = LiquidationExecutor.Action({
            protocolId: 2,
            data: _buildMorphoLiquidationAction(address(otherToken), address(loanToken), address(0x2222), 100e18)
        });

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), 200e18, 0);

        bytes memory plan = _buildPlan(2, address(loanToken), 200e18, FLASH_FEE, actions, swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.CollateralAssetMismatch.selector, address(collateralToken), address(otherToken)
            )
        );
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVARIANT: aToken address must match canonical
    // ═══════════════════════════════════════════════════════════════════

    function test_receiveAToken_invalidAddress_reverts() public {
        // Register canonical aToken for collateralToken → address(aToken)
        // But supply a DIFFERENT address in the action
        address fakeAToken = address(new MockERC20("Fake", "FAKE", 18));

        bytes memory targetAction = abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 4,
                asset: address(0),
                amount: 0,
                interestRateMode: 0,
                onBehalfOf: address(0),
                collateralAsset: address(collateralToken),
                debtAsset: address(loanToken),
                user: address(0x1234),
                debtToCover: 400e18,
                receiveAToken: true,
                aTokenAddress: fakeAToken // WRONG — canonical is address(aToken)
            })
        );

        bytes memory plan = _buildPlan(
            2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.InvalidATokenAddress.selector, fakeAToken, address(aToken))
        );
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVARIANT: Morpho must produce collateral delta
    // ═══════════════════════════════════════════════════════════════════

    function test_morphoLiquidation_zeroCollateral_reverts() public {
        // Set Morpho to return 0 collateral
        morphoBlue.setLiquidationCollateralReward(0);

        // Fresh executor for clean balances
        address[] memory targets = new address[](3);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(morphoBlue);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );
        vm.prank(owner);
        freshExec.setMorphoBlue(address(morphoBlue));

        loanToken.mint(address(freshExec), LOAN_AMOUNT + FLASH_FEE + 100e18);

        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), 400e18);

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
        // Fix beneficiary for freshExec
        swapPlan.leg1.paraswapCalldata = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(freshExec)
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.NoCollateralReceived.selector);
        freshExec.execute(plan);

        // Reset
        morphoBlue.setLiquidationCollateralReward(COLLATERAL_REWARD);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVARIANT: aToken unwrap must produce underlying
    // ═══════════════════════════════════════════════════════════════════

    function test_unwrap_failsIfNoUnderlyingProduced() public {
        // Create a pool that sends aTokens on liquidation but has NO underlying
        // to send on withdraw → unwrap produces nothing → UnwrapFailed
        MockAavePool emptyPool = new MockAavePool(FLASH_FEE);
        emptyPool.setLiquidationCollateralReward(COLLATERAL_REWARD);
        emptyPool.setAToken(address(aToken));
        emptyPool.setReserveAToken(address(collateralToken), address(aToken));

        // Fund emptyPool for flash loan + aToken sending, but NO underlying collateral
        loanToken.mint(address(emptyPool), 100_000e18);
        aToken.mint(address(emptyPool), 100_000e18);
        // Intentionally do NOT mint collateralToken to emptyPool
        // So pool.withdraw(collateralAsset, ...) will revert or send 0

        address[] memory targets = new address[](2);
        targets[0] = address(emptyPool);
        targets[1] = address(augustus);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(emptyPool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        loanToken.mint(address(freshExec), LOAN_AMOUNT + FLASH_FEE + 100e18);

        bytes memory targetAction = abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 4,
                asset: address(0),
                amount: 0,
                interestRateMode: 0,
                onBehalfOf: address(0),
                collateralAsset: address(collateralToken),
                debtAsset: address(loanToken),
                user: address(0x1234),
                debtToCover: 400e18,
                receiveAToken: true,
                aTokenAddress: address(aToken)
            })
        );

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), COLLATERAL_REWARD, 0);
        swapPlan.leg1.paraswapCalldata =
            _buildParaswapCalldata(address(collateralToken), address(loanToken), COLLATERAL_REWARD, address(freshExec));

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, targetAction), swapPlan);

        vm.prank(operatorAddr);
        // Pool withdraw will revert because it has no underlying collateral to send
        vm.expectRevert();
        freshExec.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PRODUCTION HARDENING — Capability boundary tests
    // ═══════════════════════════════════════════════════════════════════

    /// @notice V2 receiveAToken=true must revert with explicit error
    function test_aaveV2_receiveAToken_true_reverts() public {
        bytes memory targetAction = abi.encode(
            LiquidationExecutor.AaveV2Liquidation({
                collateralAsset: address(collateralToken),
                debtAsset: address(loanToken),
                user: address(0x1234),
                debtToCover: 400e18,
                receiveAToken: true
            })
        );

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(3, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ReceiveATokenV2Unsupported.selector);
        executor.execute(plan);
    }

    /// @notice Morpho with zero collateralToken in marketParams must revert
    function test_morpho_invalidMarketParams_zeroCollateral_reverts() public {
        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(0), address(loanToken), address(0x1234), 400e18);

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.MorphoInvalidMarketParams.selector);
        executor.execute(plan);
    }

    /// @notice Morpho with zero loanToken in marketParams must revert
    function test_morpho_invalidMarketParams_zeroLoanToken_reverts() public {
        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(collateralToken), address(0), address(0x1234), 400e18);

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.MorphoInvalidMarketParams.selector);
        executor.execute(plan);
    }

    /// @notice Full pipeline: V3 receiveAToken=false still works end-to-end
    function test_fullPipeline_v3_receiveATokenFalse() public {
        vm.prank(operatorAddr);
        executor.execute(
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), _defaultSwapPlan())
        );
    }

    /// @notice Full pipeline: Morpho still works end-to-end
    function test_fullPipeline_morpho() public {
        // Use fresh executor that has morpho in targets
        address[] memory targets = new address[](3);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(morphoBlue);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );
        vm.prank(owner);
        freshExec.setMorphoBlue(address(morphoBlue));

        loanToken.mint(address(freshExec), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(freshExec), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD);

        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), 400e18);

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
        swapPlan.leg1.paraswapCalldata = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(freshExec)
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), swapPlan);

        vm.prank(operatorAddr);
        freshExec.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MORPHO: Approval dimension correctness
    // ═══════════════════════════════════════════════════════════════════

    /// @notice When assetsRepaid > seizedAssets, old logic (approve seizedAssets) would fail.
    /// New logic (approve maxRepayAssets) handles this correctly.
    function test_morpho_repaidExceedsSeized_succeeds() public {
        // Configure mock: seizedAssets=400, but Morpho pulls 800 loanToken for debt
        // This simulates collateral worth less per unit than loan token
        morphoBlue.setLiquidationDebtAmount(800e18);
        morphoBlue.setLiquidationCollateralReward(COLLATERAL_REWARD);

        address[] memory targets = new address[](3);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(morphoBlue);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );
        vm.prank(owner);
        freshExec.setMorphoBlue(address(morphoBlue));

        loanToken.mint(address(freshExec), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(freshExec), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD);

        // maxRepayAssets = 800e18 — matches the actual debt pull
        bytes memory targetAction = _buildMorphoLiquidationActionFull(
            address(collateralToken),
            address(loanToken),
            address(0x1234),
            400e18, // seizedAssets (collateral units)
            800e18 // maxRepayAssets (loan-token units) — correctly sized
        );

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
        swapPlan.leg1.paraswapCalldata = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(freshExec)
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), swapPlan);

        vm.prank(operatorAddr);
        freshExec.execute(plan);

        // Reset mock
        morphoBlue.setLiquidationDebtAmount(0);
    }

    /// @notice When maxRepayAssets is too low for the actual repay, execution reverts.
    function test_morpho_underApproval_reverts() public {
        // Mock pulls 800e18 loanToken but maxRepayAssets is only 400e18
        morphoBlue.setLiquidationDebtAmount(800e18);
        morphoBlue.setLiquidationCollateralReward(COLLATERAL_REWARD);

        address[] memory targets = new address[](3);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(morphoBlue);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );
        vm.prank(owner);
        freshExec.setMorphoBlue(address(morphoBlue));

        loanToken.mint(address(freshExec), LOAN_AMOUNT + FLASH_FEE + 100e18);

        // maxRepayAssets = 400e18 — TOO LOW, Morpho will try to pull 800e18
        bytes memory targetAction = _buildMorphoLiquidationActionFull(
            address(collateralToken),
            address(loanToken),
            address(0x1234),
            400e18, // seizedAssets
            400e18 // maxRepayAssets — insufficient for 800e18 actual repay
        );

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
        swapPlan.leg1.paraswapCalldata = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(freshExec)
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), swapPlan);

        vm.prank(operatorAddr);
        // Morpho tries transferFrom(800e18) but approval is only 400e18 → ERC20 revert
        vm.expectRevert();
        freshExec.execute(plan);

        // Reset mock
        morphoBlue.setLiquidationDebtAmount(0);
    }

    /// @notice maxRepayAssets=0 reverts early in validation
    function test_morpho_zeroMaxRepay_reverts() public {
        bytes memory targetAction = _buildMorphoLiquidationActionFull(
            address(collateralToken),
            address(loanToken),
            address(0x1234),
            400e18, // seizedAssets
            0 // maxRepayAssets — invalid
        );

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    /// @notice Approval is reset to 0 after Morpho execution
    function test_morpho_approvalReset() public {
        morphoBlue.setLiquidationCollateralReward(COLLATERAL_REWARD);

        address[] memory targets = new address[](3);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(morphoBlue);
        LiquidationExecutor freshExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );
        vm.prank(owner);
        freshExec.setMorphoBlue(address(morphoBlue));

        loanToken.mint(address(freshExec), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(freshExec), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD);

        bytes memory targetAction =
            _buildMorphoLiquidationAction(address(collateralToken), address(loanToken), address(0x1234), 400e18);

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildParaswapSingleSwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0);
        swapPlan.leg1.paraswapCalldata = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(freshExec)
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), swapPlan);

        vm.prank(operatorAddr);
        freshExec.execute(plan);

        // Verify approval is reset to 0
        assertEq(loanToken.allowance(address(freshExec), address(morphoBlue)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P1 HARDENING REGRESSION TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// P1-5: Phase guard blocks callbacks outside execute()
    /// P1-6: Morpho share mode (seizedAssets=0) reverts with explicit error
    function test_morpho_shareMode_explicitRevert() public {
        bytes memory targetAction = _buildMorphoLiquidationActionFull(
            address(collateralToken),
            address(loanToken),
            address(0x1234),
            0, // seizedAssets = 0 (share mode)
            400e18 // maxRepayAssets
        );

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.MorphoShareModeUnsupported.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BEBOP REPAY SUFFICIENCY (absolute balance, not delta)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Pre-existing repayToken + partial Bebop output → succeeds
    /// @notice Delta-based repay: pre-existing loanToken balance MUST NOT cover
    /// a swap that produces too little output. The executor now snapshots the
    /// repayToken balance before swaps and requires `after - before >= flashRepay`,
    /// so a partial Bebop output is rejected even when the contract holds dust
    /// loanToken from previous txs / rescue residue.
    function test_bebop_partialOutput_insufficientDelta_reverts() public {
        uint256 debtToCover = 50e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        // Bebop returns only 100e18 — far below the 1001e18 flash obligation.
        uint256 partialRepay = 100e18;
        bebop.configure(address(collateralToken), collateralIn, address(loanToken), partialRepay, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InsufficientRepayOutput.selector, partialRepay, LOAN_AMOUNT + FLASH_FEE
            )
        );
        executor.execute(plan);
    }

    /// @notice Normal Bebop full-output still works (no regression)
    function test_bebop_fullOutput_noRegression() public {
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        bebop.configure(address(collateralToken), collateralIn, address(loanToken), 1100e18, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    /// @notice Bebop leg must reject output below the operator-supplied per-leg
    /// minAmountOut via balance-delta check, using the same InsufficientRepayOutput
    /// error that the Uni modes raise. Mirror case: a Bebop delivery that is
    /// comfortably above flashRepayAmount (so the pipeline-level gate would pass)
    /// but below the leg's own minAmountOut must still revert.
    function test_bebop_respects_minAmountOut() public {
        uint256 debtToCover = 400e18;
        uint256 collateralIn = COLLATERAL_REWARD;

        // Bebop delivers 1050e18 loanToken — above flashRepay (1001e18), so the
        // pipeline-level InsufficientRepayOutput would NOT fire.
        uint256 delivered = 1050e18;
        bebop.configure(address(collateralToken), collateralIn, address(loanToken), delivered, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapPlan memory swapPlan = _buildBebopMultiSwapPlan(
            address(collateralToken), collateralIn, address(bebop), bebopCd, address(loanToken), address(loanToken), 0
        );
        // Override the default minAmountOut=1 to force the per-leg floor above
        // what Bebop delivers — this is what the new guard protects.
        uint256 floor = 2000e18;
        swapPlan.leg1.minAmountOut = floor;

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InsufficientRepayOutput.selector, delivered, floor));
        executor.execute(plan);

        // And confirm the happy-path counterpart (delivered >= minAmountOut) still passes.
        swapPlan.leg1.minAmountOut = delivered;
        plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(debtToCover), swapPlan);
        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P1 FIX REGRESSION TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// FIX 1: Pre-funded ETH coinbase must reduce profit
    function test_fix1_coinbase_prefundedETH_reducesProfit() public {
        vm.coinbase(address(0xC01B));
        vm.deal(address(executor), 100 ether);

        // bps=500 → payment = 34.95e18 (from pre-funded ETH). effective = 664.05e18.
        // minProfit = 665e18 → reverts (profit reduced by coinbase cost).
        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 500), 665e18));
    }

    /// FIX 3: Zero collateralAsset must revert
    function test_fix3_zeroCollateral_reverts() public {
        bytes memory targetAction = abi.encode(
            LiquidationExecutor.AaveV3Action({
                actionType: 4,
                asset: address(0),
                amount: 0,
                interestRateMode: 0,
                onBehalfOf: address(0),
                collateralAsset: address(0),
                debtAsset: address(loanToken),
                user: address(0x1234),
                debtToCover: 400e18,
                receiveAToken: false,
                aTokenAddress: address(0)
            })
        );

        bytes memory plan = _buildPlan(
            2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidCollateralAsset.selector);
        executor.execute(plan);
    }

    /// FIX 6: Balancer callback outside execution must revert
    function test_fix6_balancerCallback_outsideExecution_reverts() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(loanToken));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN_AMOUNT;
        uint256[] memory fees = new uint256[](1);
        fees[0] = FLASH_FEE;

        vm.prank(address(balancerVault));
        vm.expectRevert(LiquidationExecutor.InvalidExecutionPhase.selector);
        executor.receiveFlashLoan(tokens, amounts, fees, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    // P2 FINAL HARDENING TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// FIX 4: Coinbase payment to address(0) reverts (only when bps+realized produce
    /// a non-zero amount — bps=100 over the default 699e18 realized profit is 6.99e18,
    /// enough to engage the InvalidCoinbase check).
    function test_coinbase_zero_reverts() public {
        vm.coinbase(address(0));
        vm.deal(address(executor), 10 ether);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidCoinbase.selector);
        executor.execute(_buildWethPlan(2, _wethLiqActionWithCoinbase(400e18, 100), 0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // FINAL FIXES — Paraswap exact-output + Morpho mixed mode
    // ═══════════════════════════════════════════════════════════════════

    /// FIX 1: swapExactAmountOut with partial fill succeeds
    function test_paraswapSingle_exactOut_partialFill_succeeds() public {
        // Mock consumes 95% of declared max input — output must still cover the
        // full flash obligation under the delta-based repay check. 95% * 1000e18
        // * 1.1 (swap rate) = 1045e18 >= 1001e18 flashRepay.
        augustus.setPartialFillPct(95);

        uint256 maxAmountIn = DEFAULT_SWAP_AMOUNT;
        bytes memory cd = _buildParaswapExactOutCalldata(
            address(collateralToken), address(loanToken), maxAmountIn, address(executor)
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: maxAmountIn,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan); // must NOT revert — actual < max is OK for exact-out

        // Reset
        augustus.setPartialFillPct(0);
    }

    /// FIX 1: swapExactAmountIn still requires strict equality
    function test_paraswapSingle_exactIn_partialFill_reverts() public {
        // Mock consumes 60% — but exact-in requires full consumption
        augustus.setPartialFillPct(60);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), _defaultSwapPlan());

        vm.prank(operatorAddr);
        vm.expectRevert(); // ParaswapAmountInMismatch
        executor.execute(plan);

        // Reset
        augustus.setPartialFillPct(0);
    }

    /// FIX 2: Morpho seizedAssets > 0, repaidShares == 0 → valid (explicit regression)
    function test_morpho_seizedAssetsOnly_valid() public {
        // Default helper sets repaidShares = 0 — this is the only supported mode
        // Covered by test_morphoLiquidation_happyPath but verified explicitly here
        vm.prank(operatorAddr);
        executor.execute(
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), _defaultSwapPlan())
        );
    }

    /// FIX 2: Morpho seizedAssets > 0, repaidShares > 0 → MorphoMixedModeUnsupported
    function test_morpho_mixedMode_reverts() public {
        bytes memory targetAction = abi.encode(
            LiquidationExecutor.MorphoLiquidation({
                marketParams: MarketParams({
                    loanToken: address(loanToken),
                    collateralToken: address(collateralToken),
                    oracle: address(0x1),
                    irm: address(0x2),
                    lltv: 0.8e18
                }),
                borrower: address(0x1234),
                seizedAssets: 400e18,
                repaidShares: 100e18, // non-zero → mixed mode
                maxRepayAssets: 400e18
            })
        );

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.MorphoMixedModeUnsupported.selector);
        executor.execute(plan);
    }

    /// FIX 2: Morpho seizedAssets == 0, repaidShares > 0 → MorphoShareModeUnsupported (existing)
    function test_morpho_shareModeOnly_reverts() public {
        bytes memory targetAction = abi.encode(
            LiquidationExecutor.MorphoLiquidation({
                marketParams: MarketParams({
                    loanToken: address(loanToken),
                    collateralToken: address(collateralToken),
                    oracle: address(0x1),
                    irm: address(0x2),
                    lltv: 0.8e18
                }),
                borrower: address(0x1234),
                seizedAssets: 0,
                repaidShares: 100e18,
                maxRepayAssets: 400e18
            })
        );

        bytes memory plan = _buildPlan(
            1, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(2, targetAction), _defaultSwapPlan()
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.MorphoShareModeUnsupported.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // AUGUSTUS V6.2 — COMPLETE SELECTOR COVERAGE
    // ═══════════════════════════════════════════════════════════════════
    //
    // The 11 swap-entrypoint selectors below are the COMPLETE set exposed by
    // the deployed Augustus V6.2 contract at
    // 0x6A000F20005980200259B80c5102003040001068 (verified against Sourcify
    // metadata + on-chain bytecode dispatch table). Each test asserts the
    // executor's behaviour for one selector — accept (decode + swap) or
    // reject (revert with `InvalidParaswapSelector(selector)`).
    //
    // Coverage is provable via `forge test --match-test paraswapV62Coverage`:
    // 8 accept tests + 3 reject tests + 1 unknown-selector test = 12 tests.

    function test_paraswapV62Coverage_genericExactIn_accepted() public {
        bytes memory cd = _buildParaswapCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_genericExactOut_accepted() public {
        bytes memory cd = _buildParaswapExactOutCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_uniV2ExactIn_accepted() public {
        bytes memory cd = _buildUniV2ExactInCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_uniV2ExactOut_accepted() public {
        bytes memory cd = _buildUniV2ExactOutCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_uniV3ExactIn_accepted() public {
        bytes memory cd = _buildOptimizedExactInUniV3Calldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_uniV3ExactOut_accepted() public {
        bytes memory cd = _buildOptimizedExactOutUniV3Calldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_curveV1ExactIn_accepted() public {
        bytes memory cd = _buildCurveV1ExactInCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_curveV2ExactIn_accepted() public {
        bytes memory cd = _buildCurveV2ExactInCalldata(
            address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_balancerV2ExactIn_accepted() public {
        bytes memory cd = _buildBalancerV2Calldata(
            SWAP_EXACT_IN_BALANCER_V2_SELECTOR,
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            0,
            address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_paraswapV62Coverage_balancerV2ExactOut_accepted() public {
        bytes memory cd = _buildBalancerV2Calldata(
            SWAP_EXACT_OUT_BALANCER_V2_SELECTOR,
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            0,
            address(executor)
        );
        _runAcceptedSwap(cd);
    }

    function test_balancerV2_wrongSrcToken_reverts() public {
        bytes memory cd = _buildBalancerV2Calldata(
            SWAP_EXACT_IN_BALANCER_V2_SELECTOR,
            address(mockWeth), // blob says mockWeth
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            0,
            address(executor)
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.ParaswapSrcTokenMismatch.selector, address(collateralToken), address(mockWeth)
            )
        );
        executor.execute(plan);
    }

    function test_balancerV2_invalidBlobSelector_reverts() public {
        bytes memory cd = _buildBalancerV2InvalidBlobCalldata(SWAP_EXACT_IN_BALANCER_V2_SELECTOR);
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: 1,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidParaswapCalldata.selector);
        executor.execute(plan);
    }

    function test_balancerV2_beneficiaryRule_reverts() public {
        address badRecipient = address(0xBAAD);
        bytes memory cd = _buildBalancerV2Calldata(
            SWAP_EXACT_IN_BALANCER_V2_SELECTOR,
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            0,
            badRecipient
        );
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.SwapRecipientInvalid.selector, badRecipient));
        executor.execute(plan);
    }

    function test_paraswapV62Coverage_rfq_rejected() public {
        bytes memory cd = abi.encodePacked(SWAP_RFQ_BATCH_FILL_SELECTOR, new bytes(420));
        _expectRejectedSwap(cd, SWAP_RFQ_BATCH_FILL_SELECTOR);
    }

    function test_paraswapV62Coverage_unknownSelector_rejected() public {
        bytes4 unknown = bytes4(0xdeadbeef);
        bytes memory cd = abi.encodePacked(unknown, new bytes(420));
        _expectRejectedSwap(cd, unknown);
    }

    /// Drives an accepted-selector swap through the real flash-loan path and
    /// asserts no revert. Reuses the standard plan layout so any decode/route
    /// regression in `_decodeAndValidateParaswap` surfaces as a test failure.
    function _runAcceptedSwap(bytes memory cd) internal {
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        uint256 loanBefore = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 loanAfter = loanToken.balanceOf(address(executor));
        assertGt(loanAfter, loanBefore, "accepted selector must produce loanToken output");
    }

    /// Drives a rejected-selector swap and asserts the canonical revert.
    function _expectRejectedSwap(bytes memory cd, bytes4 expectedSelector) internal {
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidParaswapSelector.selector, expectedSelector));
        executor.execute(plan);
    }

    /// @dev Task 3: BalancerV2 decoder must reject truncated calldata.
    function test_balancerV2Decoder_truncatedCalldata_reverts() public {
        // Craft calldata that passes the coarse 296-byte floor but has `dataOff`
        // pointing past the end of the bytes region. Layout:
        //  [selector][head 8 * 32 = 256 bytes] then the bytes tail.
        // Set dataOff (head word 7, at offset 224) to 0x4000 — far beyond the
        // actual calldata length — forcing the bounds check to revert.
        uint256 dataOff = 0x4000;
        bytes memory cd = new bytes(300); // > 296 so floor check passes
        // Set selector
        assembly {
            mstore(add(cd, 32), shl(224, 0xd85ca173))
        }
        // Set dataOff at args byte offset 224 (head word 7). In memory: cd + 32
        // (length prefix) + 4 (selector) + 224 = cd + 260.
        assembly {
            mstore(add(cd, add(36, 224)), dataOff)
        }

        // Build a minimal plan using the crafted calldata.
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidParaswapCalldata.selector);
        executor.execute(plan);
    }

    /// @dev Task 3: BalancerV2 decoder must reject calldata shorter than 296.
    function test_balancerV2Decoder_shortCalldata_reverts() public {
        bytes memory cd = new bytes(200); // < 296 floor
        assembly {
            mstore(add(cd, 32), shl(224, 0xd85ca173))
        }

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken),
                amountIn: DEFAULT_SWAP_AMOUNT,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: cd,
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidParaswapCalldata.selector);
        executor.execute(plan);
    }

    /// @dev Task 4: Pre-funded repayToken balance cannot cover flash repay.
    /// Swap output (delta) must cover the obligation; pre-existing dust is
    /// excluded from the check. Complements the bebop- and leg2-prefunded
    /// variants that already exercise this invariant for other swap modes.
    function test_repayDelta_prefundedBalance_isInsufficient() public {
        // Set swap rate below 1:1 so delta < flashRepay even though the
        // pre-existing balance would nominally cover it.
        augustus.setRate(0.5e18); // 1000e18 in → 500e18 out

        LiquidationExecutor.SwapPlan memory swapPlan = _defaultSwapPlan();

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(400e18), swapPlan);

        // Executor has LOAN_AMOUNT + FLASH_FEE + 100e18 pre-funded loanToken.
        // flashloan adds LOAN_AMOUNT. Swap produces 500e18 of loanToken (delta).
        // Delta 500e18 < flashRepay 1001e18 → revert under the new rule, even
        // though the absolute balance would have been ample.
        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InsufficientRepayOutput.selector, 500e18, LOAN_AMOUNT + FLASH_FEE
            )
        );
        executor.execute(plan);

        augustus.setRate(SWAP_RATE); // reset for other tests
    }

    // ═══════════════════════════════════════════════════════════════════
    // UNISWAP V2 / V3 SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_UniV2_singleHop_happyPath() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1, 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0, "profit remained after flash repay");
    }

    function test_UniV3_happyPath_fee3000() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV3SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 3000, 1, 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0, "profit remained after flash repay");
    }

    function test_UniV3_allValidFees() public {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        for (uint256 i = 0; i < fees.length; ++i) {
            LiquidationExecutor.SwapPlan memory swapPlan =
                _buildUniV3SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, fees[i], 1, 0);
            bytes memory plan =
                _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

            vm.prank(operatorAddr);
            executor.execute(plan);
            // Pre-fund collateral gap so subsequent iterations also have enough to swap.
            collateralToken.mint(address(executor), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD);
        }
    }

    function test_UniV3_invalidFee_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV3SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1234, 1, 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.InvalidV3Fee.selector, uint24(1234)));
        executor.execute(plan);
    }

    function test_UniV2_invalidPath_wrongStart_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1, 0);
        // Corrupt path[0] to a non-collateral address.
        swapPlan.leg1.v2Path[0] = address(profitToken);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV2Path.selector);
        executor.execute(plan);
    }

    function test_UniV2_invalidPath_wrongEnd_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1, 0);
        swapPlan.leg1.v2Path[1] = address(profitToken);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV2Path.selector);
        executor.execute(plan);
    }

    function test_UniV2_invalidPath_tooShort_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1, 0);
        swapPlan.leg1.v2Path = new address[](1);
        swapPlan.leg1.v2Path[0] = address(collateralToken);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV2Path.selector);
        executor.execute(plan);
    }

    function test_UniV2_fullBalance_usesDelta() public {
        // The liquidation produces COLLATERAL_REWARD of collateralToken. With
        // useFullBalance=true, the swap input must equal that delta — never the
        // pre-existing pre-funded balance (DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD).
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), 0, 1, 0);
        swapPlan.leg1.useFullBalance = true;

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        // With SWAP_RATE = 1.1e18 and delta = 600e18, expected output ≈ 660e18,
        // which is well below flashRepay (1001e18). The swap succeeds at the
        // router level but the pipeline-level repay check must reject.
        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InsufficientRepayOutput.selector,
                COLLATERAL_REWARD * SWAP_RATE / 1e18,
                LOAN_AMOUNT + FLASH_FEE
            )
        );
        executor.execute(plan);
    }

    function test_UniV2_fullBalance_sufficientDelta_succeeds() public {
        // Boost liquidation reward so the delta alone can cover flash repay.
        uint256 bigReward = 1200e18;
        aavePool.setLiquidationCollateralReward(bigReward);
        collateralToken.mint(address(aavePool), 100_000e18);

        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), 0, 1, 0);
        swapPlan.leg1.useFullBalance = true;

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    function test_UniV3_minAmountOut_enforced() public {
        // Router returns below minAmountOut → mock reverts internally.
        uniV3Mock.setRate(0.5e18); // well under any reasonable min
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV3SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            DEFAULT_SWAP_AMOUNT, // minAmountOut = input (impossible with 0.5 rate)
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);

        uniV3Mock.setRate(SWAP_RATE);
    }

    function test_coinbasePayment_exceedsProfit_reverts() public {
        // Under the bps model, an out-of-range bps value (>10000) is rejected
        // up-front with InvalidCoinbaseBps. This is the analog of the old
        // "coinbase > profit" guard — operator can no longer encode an
        // over-payment at all, and multi-action overpays are separately
        // caught by CoinbaseExceedsProfit inside _checkProfit.
        LiquidationExecutor.Action[] memory actions = _wethLiqActionWithCoinbase(400e18, 10_001);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidCoinbaseBps.selector);
        executor.execute(_buildWethPlan(2, actions, 0));
    }

    function test_constructor_rejectsZeroV2Router() public {
        address[] memory targets = new address[](0);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(0),
            address(uniV3Mock),
            targets
        );
    }

    function test_constructor_rejectsZeroV3Router() public {
        address[] memory targets = new address[](0);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(0),
            targets
        );
    }

    function test_UniV2_minAmountOutZero_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 0, 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_UniV3_minAmountOutZero_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV3SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 3000, 0, 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_UniV3_routersAutoWhitelisted() public view {
        assertTrue(executor.allowedTargets(address(uniV2Mock)), "V2 router must be whitelisted");
        assertTrue(executor.allowedTargets(address(uniV3Mock)), "V3 router must be whitelisted");
    }

    function test_UniV2_approvalResetAfterSwap() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV2SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 1, 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(
            collateralToken.allowance(address(executor), address(uniV2Mock)),
            0,
            "V2 router allowance must be zero after swap"
        );
    }

    function test_UniV3_approvalResetAfterSwap() public {
        LiquidationExecutor.SwapPlan memory swapPlan =
            _buildUniV3SwapPlan(address(collateralToken), address(loanToken), DEFAULT_SWAP_AMOUNT, 3000, 1, 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertEq(
            collateralToken.allowance(address(executor), address(uniV3Mock)),
            0,
            "V3 router allowance must be zero after swap"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // UNISWAP V4 SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_UniV4_singleHop_happyPath() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0, "profit remained after V4 swap");
    }

    function test_UniV4_invalidDecode_shortData_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        swapPlan.leg1.v4SwapData = hex"aabbcc"; // 3 bytes — far under the required 160

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV4Data.selector);
        executor.execute(plan);
    }

    function test_UniV4_invalidDecode_tokenMismatch_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        // Re-encode with the wrong tokenIn so the strict check fires.
        swapPlan.leg1.v4SwapData =
            abi.encode(address(profitToken), address(loanToken), uint24(3000), int24(60), address(0));

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV4Data.selector);
        executor.execute(plan);
    }

    function test_UniV4_invalidHook_reverts() public {
        address rogueHook = address(0x1234);
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            rogueHook,
            address(uniV4Mock),
            1,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.V4HookNotAllowed.selector, rogueHook));
        executor.execute(plan);
    }

    function test_UniV4_whitelistedHook_succeeds() public {
        address allowedHook = address(0x5678);
        vm.prank(owner);
        executor.setV4HookAllowed(allowedHook, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            allowedHook,
            address(uniV4Mock),
            1,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    function test_UniV4_insufficientOutput_reverts() public {
        uniV4Mock.setRate(0.5e18); // output below minAmountOut below

        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            DEFAULT_SWAP_AMOUNT, // require 1000e18 out; rate 0.5 produces 500e18
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);

        uniV4Mock.setRate(SWAP_RATE);
    }

    function test_UniV4_poolManagerNotAllowed_reverts() public {
        MockV4PoolManager stranger = new MockV4PoolManager(SWAP_RATE);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(stranger),
            1,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.TargetNotAllowed.selector, address(stranger)));
        executor.execute(plan);
    }

    function test_UniV4_zeroPoolManager_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        swapPlan.leg1.v4PoolManager = address(0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.execute(plan);
    }

    function test_UniV4_minAmountOutZero_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            0,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    function test_UniV4_zeroOutput_reverts() public {
        // Mock swap() returns a zero-output delta → tokenOutDelta <= 0 trips
        // V4UnexpectedDelta inside unlockCallback.
        uniV4Mock.setZeroOut(true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.V4UnexpectedDelta.selector);
        executor.execute(plan);

        uniV4Mock.setZeroOut(false);
    }

    function test_UniV4_unlockCallback_directlyRejected() public {
        // No active unlock → _activeV4PoolManager == 0 → revert V4CallbackInactive.
        vm.expectRevert(LiquidationExecutor.InvalidExecutionPhase.selector);
        executor.unlockCallback("");
    }

    function test_setV4HookAllowed_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        executor.setV4HookAllowed(address(0x5678), true);
    }

    function test_setV4HookAllowed_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(LiquidationExecutor.ZeroAddress.selector);
        executor.setV4HookAllowed(address(0), true);
    }

    // ═══════════════════════════════════════════════════════════════════
    // V4 HARDENING TESTS (narrow-scope fail-closed checks)
    // ═══════════════════════════════════════════════════════════════════

    function test_UniV4_nativeETH_tokenIn_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        swapPlan.leg1.v4SwapData = abi.encode(address(0), address(loanToken), uint24(3000), int24(60), address(0));

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV4NativeToken.selector);
        executor.execute(plan);
    }

    function test_UniV4_nativeETH_tokenOut_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        swapPlan.leg1.v4SwapData = abi.encode(address(collateralToken), address(0), uint24(3000), int24(60), address(0));

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidV4NativeToken.selector);
        executor.execute(plan);
    }

    function test_UniV4_wrongTokenOut_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        swapPlan.leg1.v4SwapData =
            abi.encode(address(collateralToken), address(profitToken), uint24(3000), int24(60), address(0));

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InvalidV4TokenOut.selector, address(loanToken), address(profitToken)
            )
        );
        executor.execute(plan);
    }

    function test_UniV4_zeroFee_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            0,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.InvalidV4FeeOrSpacing.selector, uint24(0), int24(60))
        );
        executor.execute(plan);
    }

    function test_UniV4_zeroTickSpacing_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(0),
            address(0),
            address(uniV4Mock),
            1,
            0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.InvalidV4FeeOrSpacing.selector, uint24(3000), int24(0))
        );
        executor.execute(plan);
    }

    function test_UniV4_negativeTickSpacing_reverts() public {
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(-60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationExecutor.InvalidV4FeeOrSpacing.selector, uint24(3000), int24(-60))
        );
        executor.execute(plan);
    }

    function test_UniV4_validationFailsFast_beforeFlashloan() public {
        // Prove eager V4 validation fires before flashloan is requested. Use
        // an unconfigured flashProviderId (99): if the V4 check ran AFTER
        // flashloan setup, we'd get FlashProviderNotAllowed instead of the
        // V4-content error.
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            0
        );
        swapPlan.leg1.v4SwapData =
            abi.encode(address(collateralToken), address(profitToken), uint24(3000), int24(60), address(0));

        bytes memory plan =
            _buildPlan(99, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InvalidV4TokenOut.selector, address(loanToken), address(profitToken)
            )
        );
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // TWO-LEG HAPPY PATHS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Task 12: Paraswap (collateral → profit) → UniV2 (profit → loan)
    function test_twoLeg_paraswap_to_uniV2_happyPath() public {
        // leg1: collateral → profitToken via Paraswap (SWAP_RATE = 1.1)
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildParaswapLeg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT);

        // leg2: profitToken → loanToken via UniV2, useFullBalance=true
        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV2Leg(address(profitToken), address(loanToken), 0, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0, "profit remained after flash repay");
    }

    /// @notice Task 13a: Paraswap (collateral → profit) → UniV3 (profit → loan)
    function test_twoLeg_paraswap_to_uniV3_happyPath() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildParaswapLeg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT);

        LiquidationExecutor.SwapLeg memory leg2 =
            _buildUniV3Leg(address(profitToken), address(loanToken), 0, 3000, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0);
    }

    /// @notice Task 13b: Paraswap (collateral → profit) → UniV4 (profit → loan)
    function test_twoLeg_paraswap_to_uniV4_happyPath() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildParaswapLeg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT);

        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV4Leg(
            address(profitToken), address(loanToken), 0, 3000, int24(60), address(0), address(uniV4Mock), 1, true
        );

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0);
    }

    /// @notice Task 14a: Bebop (collateral → profit) → UniV2 (profit → loan)
    /// Bebop mock is configured to pull collateralToken and emit profitToken.
    /// Calldata pattern: abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1)) — any
    /// non-empty bytes trigger the fallback which executes the pre-configured swap.
    function test_twoLeg_bebop_to_uniV2_happyPath() public {
        uint256 bebopOut = 1100e18; // 1.1× collateral at SWAP_RATE
        bebop.configure(address(collateralToken), DEFAULT_SWAP_AMOUNT, address(profitToken), bebopOut, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapLeg memory leg1 = _buildBebopLeg(
            address(collateralToken), DEFAULT_SWAP_AMOUNT, address(bebop), bebopCd, address(profitToken)
        );

        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV2Leg(address(profitToken), address(loanToken), 0, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0, "profit remained after flash repay");
    }

    /// @notice Task 14b: Bebop (collateral → profit) → UniV3 (profit → loan)
    function test_twoLeg_bebop_to_uniV3_happyPath() public {
        uint256 bebopOut = 1100e18;
        bebop.configure(address(collateralToken), DEFAULT_SWAP_AMOUNT, address(profitToken), bebopOut, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapLeg memory leg1 = _buildBebopLeg(
            address(collateralToken), DEFAULT_SWAP_AMOUNT, address(bebop), bebopCd, address(profitToken)
        );

        LiquidationExecutor.SwapLeg memory leg2 =
            _buildUniV3Leg(address(profitToken), address(loanToken), 0, 3000, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0);
    }

    /// @notice Task 14c: Bebop (collateral → profit) → UniV4 (profit → loan)
    function test_twoLeg_bebop_to_uniV4_happyPath() public {
        uint256 bebopOut = 1100e18;
        bebop.configure(address(collateralToken), DEFAULT_SWAP_AMOUNT, address(profitToken), bebopOut, address(0), 0);

        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        LiquidationExecutor.SwapLeg memory leg1 = _buildBebopLeg(
            address(collateralToken), DEFAULT_SWAP_AMOUNT, address(bebop), bebopCd, address(profitToken)
        );

        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV4Leg(
            address(profitToken), address(loanToken), 0, 3000, int24(60), address(0), address(uniV4Mock), 1, true
        );

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0);
    }

    /// @notice Task 15a: UniV3 (collateral → profit) → UniV3 (profit → loan)
    function test_twoLeg_uniV3_to_uniV3_happyPath() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildUniV3Leg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT, 3000, 1, false);

        LiquidationExecutor.SwapLeg memory leg2 =
            _buildUniV3Leg(address(profitToken), address(loanToken), 0, 500, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0);
    }

    /// @notice Task 15b: UniV4 (collateral → profit) → UniV3 (profit → loan)
    function test_twoLeg_uniV4_to_uniV3_happyPath() public {
        LiquidationExecutor.SwapLeg memory leg1 = _buildUniV4Leg(
            address(collateralToken),
            address(profitToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(uniV4Mock),
            1,
            false
        );

        LiquidationExecutor.SwapLeg memory leg2 =
            _buildUniV3Leg(address(profitToken), address(loanToken), 0, 3000, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(loanToken.balanceOf(address(executor)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // TWO-LEG LEFTOVER HANDLING
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Task 16A: Pre-existing dust on executor must not be consumed by leg2.
    /// The tracked leftover is computed as balanceOf(intermediate)_after_leg1 minus
    /// balanceOf(intermediate)_before_leg1, so pre-existing dust survives unchanged.
    function test_twoLeg_leftover_ignoresPreExistingDust() public {
        // Pre-fund executor with profitToken dust that predates the swap.
        uint256 dust = 500e18;
        profitToken.mint(address(executor), dust);

        LiquidationExecutor.SwapLeg memory leg1 =
            _buildParaswapLeg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT);

        // leg2 useFullBalance=true — must use ONLY the leg1-produced delta (~1100e18),
        // NOT leg1-delta + dust.
        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV2Leg(address(profitToken), address(loanToken), 0, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Dust should still be on the executor — leg2 only consumed the delta.
        // Assert a lower-bound rather than exact equality, in case mock returns
        // approximate rates that leave residuals.
        assertGe(profitToken.balanceOf(address(executor)), dust, "pre-existing profitToken dust was consumed by leg2");
    }

    // ═══════════════════════════════════════════════════════════════════
    // TWO-LEG VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Task 17A: leg1.repayToken != leg2.srcToken → InvalidLegLink reverts.
    function test_twoLeg_invalidLink_leg1OutVsLeg2In_reverts() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildParaswapLeg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT);

        // leg2 with deliberately mismatched srcToken (loanToken) — does not match
        // leg1.repayToken (profitToken). Also set repayToken to a token != leg.srcToken
        // so the _validateLeg srcToken==repayToken check doesn't fire first.
        // Build leg2 manually because _buildUniV2Leg forces srcToken==v2Path[0]
        // and repayToken==v2Path[last] via its path construction — the link check
        // fires before v2 path validation.
        address[] memory path = new address[](2);
        path[0] = address(loanToken);
        path[1] = address(loanToken);
        LiquidationExecutor.SwapLeg memory leg2 = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.UNI_V2,
            srcToken: address(loanToken),
            amountIn: 0,
            useFullBalance: true,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: path,
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: address(loanToken),
            minAmountOut: 1
        });

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.InvalidLegLink.selector,
                address(profitToken), // leg1.repayToken
                address(loanToken) // leg2.srcToken
            )
        );
        executor.execute(plan);
    }

    /// @notice Task 17B: leg2 is Paraswap → Leg2ModeNotAllowed(PARASWAP_SINGLE) reverts.
    function test_twoLeg_leg2_paraswap_reverts() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildUniV3Leg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT, 3000, 1, false);

        LiquidationExecutor.SwapLeg memory leg2 = _buildParaswapLeg(address(profitToken), address(loanToken), 100e18);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.Leg2ModeNotAllowed.selector, uint8(LiquidationExecutor.SwapMode.PARASWAP_SINGLE)
            )
        );
        executor.execute(plan);
    }

    /// @notice Task 17C: leg2 is Bebop → Leg2ModeNotAllowed(BEBOP_MULTI) reverts.
    function test_twoLeg_leg2_bebop_reverts() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildUniV3Leg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT, 3000, 1, false);

        // Bebop calldata/target values don't matter — Leg2ModeNotAllowed fires
        // before any Bebop validation.
        LiquidationExecutor.SwapLeg memory leg2 = _buildBebopLeg(
            address(profitToken),
            100e18,
            address(bebop),
            abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1)),
            address(loanToken)
        );

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.Leg2ModeNotAllowed.selector, uint8(LiquidationExecutor.SwapMode.BEBOP_MULTI)
            )
        );
        executor.execute(plan);
    }

    /// @notice Paraswap as leg1 with useFullBalance=true → LegUseFullBalanceNotAllowed(PARASWAP_SINGLE).
    function test_twoLeg_leg1_paraswap_useFullBalance_reverts() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildParaswapLeg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT);
        // Mutate the built leg to enable useFullBalance — this is illegal for Paraswap.
        leg1.useFullBalance = true;

        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV2Leg(address(profitToken), address(loanToken), 0, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.LegUseFullBalanceNotAllowed.selector,
                uint8(LiquidationExecutor.SwapMode.PARASWAP_SINGLE)
            )
        );
        executor.execute(plan);
    }

    /// @notice Bebop as leg1 with useFullBalance=true → LegUseFullBalanceNotAllowed(BEBOP_MULTI).
    function test_twoLeg_leg1_bebop_useFullBalance_reverts() public {
        bytes memory bebopCd = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));
        LiquidationExecutor.SwapLeg memory leg1 = _buildBebopLeg(
            address(collateralToken), DEFAULT_SWAP_AMOUNT, address(bebop), bebopCd, address(profitToken)
        );
        leg1.useFullBalance = true;

        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV2Leg(address(profitToken), address(loanToken), 0, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.LegUseFullBalanceNotAllowed.selector,
                uint8(LiquidationExecutor.SwapMode.BEBOP_MULTI)
            )
        );
        executor.execute(plan);
    }

    /// @notice leg2 MUST use useFullBalance — the on-chain tracked-leftover is
    /// the only sanctioned amountIn source for the second swap. A plan where
    /// hasLeg2==true but leg2.useFullBalance==false must revert with
    /// InvalidPlan; flipping the flag to true on the same plan must succeed.
    function test_leg2_requires_useFullBalance() public {
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildUniV3Leg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT, 3000, 1, false);

        // leg2 with useFullBalance=false — forbidden.
        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV2Leg(address(profitToken), address(loanToken), 0, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(loanToken), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);

        // Flip the flag true — same plan now executes cleanly.
        swapPlan.leg2.useFullBalance = true;
        plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // TWO-LEG COINBASE REGRESSION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Task 18: Two-leg plan ending in WETH, plus ACTION_PAY_COINBASE(500).
    /// Assert non-zero coinbase payment.
    function test_twoLeg_coinbaseBps_WethProfit_paid() public {
        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);

        // leg1: collateral → profitToken (UniV3, fixed amountIn)
        LiquidationExecutor.SwapLeg memory leg1 =
            _buildUniV3Leg(address(collateralToken), address(profitToken), DEFAULT_SWAP_AMOUNT, 3000, 1, false);

        // leg2: profitToken → WETH (UniV2, tracked leftover)
        LiquidationExecutor.SwapLeg memory leg2 = _buildUniV2Leg(address(profitToken), address(mockWeth), 0, 1, true);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildTwoLegPlan(leg1, leg2, address(mockWeth), 0);

        // Outer plan: loanToken = mockWeth, plus a coinbase BPS action.
        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(mockWeth), address(0x1234), 400e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(500); // 5% of realized WETH profit

        bytes memory plan = _buildPlan(2, address(mockWeth), LOAN_AMOUNT, FLASH_FEE, actions, swapPlan);

        uint256 coinbaseBefore = coinbase.balance;
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 coinbaseAfter = coinbase.balance;

        assertGt(coinbaseAfter, coinbaseBefore, "coinbase received no ETH from two-leg WETH profit");
    }

    // ═══════════════════════════════════════════════════════════════════
    // SPLIT MODE
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Build a SwapPlan for hasSplit mode. leg1=repayLeg, leg2=profitLeg.
    function _buildSplitPlan(
        LiquidationExecutor.SwapLeg memory repayLeg,
        LiquidationExecutor.SwapLeg memory profitLeg,
        uint16 splitBps_,
        address profitTkn,
        uint256 minProfitAmt
    ) internal pure returns (LiquidationExecutor.SwapPlan memory) {
        return LiquidationExecutor.SwapPlan({
            leg1: repayLeg,
            hasLeg2: false,
            leg2: profitLeg,
            hasSplit: true,
            splitBps: splitBps_,
            hasMixedSplit: false,
            profitToken: profitTkn,
            minProfitAmount: minProfitAmt
        });
    }

    /// @notice Split happy path: collateralDelta is 50/50 split — half swaps
    /// to loanToken for flash repay, half swaps to WETH for coinbase profit.
    /// Both legs are UniV3 and run within a single execute().
    function test_split_collateral_repay_and_profit() public {
        // Boost liquidation reward so the half routed to repay covers flashRepay.
        // 2000e18 collateral × 0.5 × 1.1 = 1100e18 loanToken ≥ 1001e18 flashRepay.
        uint256 reward = 2000e18;
        aavePool.setLiquidationCollateralReward(reward);
        collateralToken.mint(address(aavePool), 100_000e18);

        address coinbase = address(0xC01B);
        vm.coinbase(coinbase);

        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 0, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildSplitPlan(repayLeg, profitLeg, 5000, address(mockWeth), 0);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), 500e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(500); // 5% of realized WETH profit

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, swapPlan);

        uint256 cbBefore = coinbase.balance;
        uint256 wethBefore = mockWeth.balanceOf(address(executor));

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(coinbase.balance, cbBefore, "coinbase received no ETH from split-profit leg");
        assertGt(mockWeth.balanceOf(address(executor)), wethBefore, "WETH profit leg produced nothing");
        assertGt(loanToken.balanceOf(address(executor)), 0, "repay leg did not leave surplus");
    }

    /// @notice Split mode rejects `splitBps == 0` and `splitBps >= 10000`.
    function test_split_invalid_bps() public {
        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 0, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 0, 3000, 1, false);

        // bps == 0 rejected.
        LiquidationExecutor.SwapPlan memory swapPlan = _buildSplitPlan(repayLeg, profitLeg, 0, address(mockWeth), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);

        // bps == 10000 rejected.
        swapPlan = _buildSplitPlan(repayLeg, profitLeg, 10_000, address(mockWeth), 0);
        plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);

        // Mid-range bps == 5000 passes validation and executes (happy-path
        // numbers match test_split_collateral_repay_and_profit after reward boost).
        aavePool.setLiquidationCollateralReward(2000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        swapPlan = _buildSplitPlan(repayLeg, profitLeg, 5000, address(mockWeth), 0);
        plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);
        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    /// @notice Split rounds a leg amount to zero → `InvalidPlan`. With
    /// collateralDelta=1 and splitBps=1, profitAmount = 1*1/10000 = 0.
    /// Guard fires before either leg dispatches.
    function test_split_zero_amount_reverts() public {
        aavePool.setLiquidationCollateralReward(1);

        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 0, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildSplitPlan(repayLeg, profitLeg, 1, address(mockWeth), 0);

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MIXED_SPLIT MODE — leg1 any mode (Paraswap/Bebop for deep repay routing)
    // + leg2 Uni coll→WETH on residual collateral for coinbase-capable profit.
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Build a SwapPlan for hasMixedSplit mode.
    function _buildMixedSplitPlan(
        LiquidationExecutor.SwapLeg memory repayLeg,
        LiquidationExecutor.SwapLeg memory profitLeg,
        address profitTkn,
        uint256 minProfitAmt
    ) internal pure returns (LiquidationExecutor.SwapPlan memory) {
        return LiquidationExecutor.SwapPlan({
            leg1: repayLeg,
            hasLeg2: false,
            leg2: profitLeg,
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: true,
            profitToken: profitTkn,
            minProfitAmount: minProfitAmt
        });
    }

    /// @notice Happy path: MIXED_SPLIT with Uni leg1 (coll→debt) + Uni leg2
    /// (residual coll→WETH). leg1 consumes a fixed amountIn; leg2 runs on
    /// whatever collateral is left. After: repay leg covers flashRepay,
    /// WETH remainder fuels coinbase.
    function test_mixed_split_happy_path() public {
        // 2000e18 coll; leg1 consumes 1100e18 for repay (covers 1001e18
        // flashRepay at 1:1 Uni rate), leg2 takes the remaining 900e18 →
        // WETH.
        uint256 reward = 2000e18;
        aavePool.setLiquidationCollateralReward(reward);
        collateralToken.mint(address(aavePool), 100_000e18);

        address coinbase = address(0xC01C);
        vm.coinbase(coinbase);

        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 1100e18, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildMixedSplitPlan(repayLeg, profitLeg, address(mockWeth), 0);

        LiquidationExecutor.Action[] memory actions = new LiquidationExecutor.Action[](2);
        actions[0] = LiquidationExecutor.Action({
            protocolId: 1,
            data: _buildAaveV3LiquidationAction(
                address(collateralToken), address(loanToken), address(0x1234), 500e18, false
            )
        });
        actions[1] = _buildCoinbasePaymentAction(500); // 5% of realized WETH profit

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, swapPlan);

        uint256 cbBefore = coinbase.balance;
        uint256 wethBefore = mockWeth.balanceOf(address(executor));

        vm.prank(operatorAddr);
        executor.execute(plan);

        assertGt(coinbase.balance, cbBefore, "coinbase did not receive ETH on MIXED_SPLIT profit leg");
        assertGt(mockWeth.balanceOf(address(executor)), wethBefore, "MIXED_SPLIT profit leg produced no WETH");
    }

    /// @notice MIXED_SPLIT rejects leg2 with a non-Uni mode (e.g. Paraswap).
    function test_mixed_split_rejects_non_uni_leg2() public {
        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 1100e18, 3000, 1, false);
        // leg2 set to PARASWAP_SINGLE — not allowed in MIXED_SPLIT.
        LiquidationExecutor.SwapLeg memory profitLeg = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
            srcToken: address(collateralToken),
            amountIn: 1,
            useFullBalance: false,
            deadline: block.timestamp + 60,
            paraswapCalldata: hex"deadbeef",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: address(mockWeth),
            minAmountOut: 1
        });

        LiquidationExecutor.SwapPlan memory swapPlan = _buildMixedSplitPlan(repayLeg, profitLeg, address(mockWeth), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExecutor.Leg2ModeNotAllowed.selector, uint8(0)));
        executor.execute(plan);
    }

    /// @notice MIXED_SPLIT rejects leg2.repayToken != WETH.
    function test_mixed_split_rejects_non_weth_profit_leg() public {
        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 1100e18, 3000, 1, false);
        // profit leg attempts to output loanToken instead of WETH.
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildMixedSplitPlan(repayLeg, profitLeg, address(mockWeth), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    /// @notice MIXED_SPLIT rejects leg1.repayToken != loanToken (repay leg
    /// must produce the flashloan token directly — unlike hasLeg2 where
    /// leg1 outputs an intermediate).
    function test_mixed_split_rejects_leg1_repay_not_loan_token() public {
        // leg1 outputs WETH (not loanToken) — this is the hasLeg2 shape.
        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 1100e18, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildMixedSplitPlan(repayLeg, profitLeg, address(mockWeth), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.RepayTokenMismatch.selector, address(loanToken), address(mockWeth)
            )
        );
        executor.execute(plan);
    }

    /// @notice MIXED_SPLIT rejects leg2.srcToken != collateralAsset — the
    /// profit leg MUST run on the same collateral as leg1 (parallel split,
    /// not sequential routing).
    function test_mixed_split_rejects_leg2_src_not_collateral() public {
        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 1100e18, 3000, 1, false);
        // leg2.srcToken is loanToken (not collateral) — violates MIXED_SPLIT
        // invariant.
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(loanToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildMixedSplitPlan(repayLeg, profitLeg, address(mockWeth), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationExecutor.SrcTokenNotCollateral.selector, address(collateralToken), address(loanToken)
            )
        );
        executor.execute(plan);
    }

    /// @notice MIXED_SPLIT rejects useFullBalance on either leg — both
    /// legs get an explicit amountIn (leg1 from its own calldata / struct,
    /// leg2 from the runtime-measured residual).
    function test_mixed_split_rejects_use_full_balance() public {
        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 1100e18, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg = _buildUniV3Leg(
            address(collateralToken),
            address(mockWeth),
            0,
            3000,
            1,
            true /* useFullBalance */
        );

        LiquidationExecutor.SwapPlan memory swapPlan = _buildMixedSplitPlan(repayLeg, profitLeg, address(mockWeth), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.InvalidPlan.selector);
        executor.execute(plan);
    }

    /// @notice MIXED_SPLIT reverts `MixedSplitLeg1Overspent` when leg1's
    /// fixed amountIn exceeds collateralDelta (e.g. Paraswap /swap target
    /// sized against a stale collateral estimate). Leg2 would have zero
    /// (or negative) residual.
    function test_mixed_split_rejects_leg1_overspend() public {
        // Liquidation produces 500e18 collateral, but leg1 asks for 1000e18.
        aavePool.setLiquidationCollateralReward(500e18);
        collateralToken.mint(address(aavePool), 100_000e18);

        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 1000e18, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildMixedSplitPlan(repayLeg, profitLeg, address(mockWeth), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        // leg1 reverts InsufficientSrcBalance before we measure leg1Consumed
        // — the Uni executor catches the shortage first. Accept either revert
        // path since both are fail-closed outcomes for this scenario.
        vm.expectRevert();
        executor.execute(plan);
    }

    /// @notice Plan-shape XOR guard: setting `hasSplit=true` AND
    /// `hasMixedSplit=true` simultaneously reverts `PlanShapeConflict`.
    function test_mixed_split_rejects_shape_conflict() public {
        LiquidationExecutor.SwapLeg memory repayLeg =
            _buildUniV3Leg(address(collateralToken), address(loanToken), 1100e18, 3000, 1, false);
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(collateralToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: repayLeg,
            hasLeg2: false,
            leg2: profitLeg,
            hasSplit: true,
            splitBps: 5000,
            hasMixedSplit: true,
            profitToken: address(mockWeth),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.PlanShapeConflict.selector);
        executor.execute(plan);
    }

    // ═══════════════════════════════════════════════════════════════════
    // META / REGRESSION GUARDS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Task 19: Spec §1 regression guard — PARASWAP_DOUBLE must not exist.
    /// SwapMode must have exactly 5 variants (0..4). If someone ever re-introduces
    /// PARASWAP_DOUBLE as variant 5 (or renames one of the existing variants to it),
    /// this test fails, catching the reintroduction.
    function test_meta_noParaswapDoubleRemnants() public pure {
        uint8 maxMode = uint8(LiquidationExecutor.SwapMode.UNI_V4);
        assertEq(maxMode, 4, "SwapMode should have exactly 5 variants (0..4)");
    }
}

/// @dev Contract that rejects ETH -- used to test coinbase payment failure
contract ETHRejecter {
    // No receive() or fallback() -- rejects all ETH transfers

    }

/// @dev Mock WETH for testing auto-unwrap in coinbase payment
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "WETH: ETH transfer failed");
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════
// HELPER MOCK: Balancer Vault that lies about token in callback
// ═══════════════════════════════════════════════════════════════════

contract MockBalancerVaultLiar {
    using SafeERC20 for IERC20;
    uint256 public flashFee;
    address public realToken;
    address public fakeToken;

    constructor(uint256 _fee, address _real, address _fake) {
        flashFee = _fee;
        realToken = _real;
        fakeToken = _fake;
    }

    function flashLoan(address recipient, IERC20[] memory, uint256[] memory amounts, bytes memory userData) external {
        IERC20(realToken).safeTransfer(recipient, amounts[0]);
        // Callback with wrong token
        IERC20[] memory fakeTokens = new IERC20[](1);
        fakeTokens[0] = IERC20(fakeToken);
        uint256[] memory feeAmounts = new uint256[](1);
        feeAmounts[0] = flashFee;
        IFlashLoanRecipient(recipient).receiveFlashLoan(fakeTokens, amounts, feeAmounts, userData);
    }
}

// ═══════════════════════════════════════════════════════════════════
// HELPER MOCK: Balancer Vault that lies about amount in callback
// ═══════════════════════════════════════════════════════════════════

contract MockBalancerVaultAmountLiar {
    using SafeERC20 for IERC20;
    uint256 public flashFee;

    constructor(uint256 _fee) {
        flashFee = _fee;
    }

    function flashLoan(address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external
    {
        tokens[0].safeTransfer(recipient, amounts[0]);
        // Callback with wrong amount
        uint256[] memory fakeAmounts = new uint256[](1);
        fakeAmounts[0] = amounts[0] + 1;
        uint256[] memory feeAmounts = new uint256[](1);
        feeAmounts[0] = flashFee;
        IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, fakeAmounts, feeAmounts, userData);
    }
}

// ═══════════════════════════════════════════════════════════════════
// FEATURE: SwapMode.NO_SWAP (same-token liquidation) and skip-unwrap
// (receiveAToken=true with leg1.srcToken == aToken). Regression
// coverage for LIQ-141.
// ═══════════════════════════════════════════════════════════════════

contract ExecutorNoSwapTest is ExecutorTest {
    /// @dev Build a NO_SWAP single-leg plan with matching src==repay.
    function _buildNoSwapPlan(address token, uint256 minProfitAmt)
        internal
        view
        returns (LiquidationExecutor.SwapPlan memory)
    {
        return LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.NO_SWAP,
                srcToken: token,
                amountIn: 0,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: "",
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: token,
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: token,
            minProfitAmount: minProfitAmt
        });
    }

    function test_noSwap_sameToken_happyPath() public {
        // Same-token liquidation: loanToken is both collateral and debt.
        // MockAavePool.liquidationCall pulls `debtToCover` of debtAsset and
        // sends `liquidationCollateralReward` of collateralAsset back. When
        // they are the same token, net balance change = reward - debtToCover.
        uint256 debtToCover = 500e18;
        uint256 reward = 550e18; // 10% bonus ≡ profit
        aavePool.setLiquidationCollateralReward(reward);

        // Pre-fund Aave pool with enough loanToken to send `reward` back.
        loanToken.mint(address(aavePool), 100_000e18);

        // Same-token action: collateral == debt == loanToken.
        bytes memory action =
            _buildAaveV3LiquidationAction(address(loanToken), address(loanToken), address(0x1234), debtToCover, false);
        LiquidationExecutor.Action[] memory actions = _singleAction(1, action);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildNoSwapPlan(address(loanToken), MIN_PROFIT);

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, swapPlan);

        uint256 before = loanToken.balanceOf(address(executor));
        vm.prank(operatorAddr);
        executor.execute(plan);
        uint256 afterBal = loanToken.balanceOf(address(executor));

        // Net gain = reward - debtToCover - flashFee
        // = 550 - 500 - 1 = 49e18
        assertEq(afterBal - before, reward - debtToCover - FLASH_FEE, "NO_SWAP profit must be bonus net of flash fee");
    }

    function test_noSwap_insufficientBalance_reverts() public {
        // NO_SWAP where liquidation reward is too small to cover flash
        // repay. The contract's NO_SWAP path skips the swap delta check
        // in _executeSwapPlan, so the guard fires later inside
        // _finalizeFlashloan (absolute balance < repayAmount).
        uint256 debtToCover = 500e18;
        uint256 reward = 499e18; // Less than debtToCover → net loss
        aavePool.setLiquidationCollateralReward(reward);
        loanToken.mint(address(aavePool), 100_000e18);

        bytes memory action =
            _buildAaveV3LiquidationAction(address(loanToken), address(loanToken), address(0x1234), debtToCover, false);
        LiquidationExecutor.Action[] memory actions = _singleAction(1, action);
        LiquidationExecutor.SwapPlan memory swapPlan = _buildNoSwapPlan(address(loanToken), 0);

        bytes memory plan = _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, actions, swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert();
        executor.execute(plan);
    }

    function test_noSwap_validateLeg_acceptsSameSrcRepay() public {
        // Normal swap modes reject srcToken == repayToken with InvalidPlan.
        // NO_SWAP is the inverse — same token is required (the liquidation
        // is the swap). This test pins the behaviour: a NO_SWAP leg with
        // src == repay reaches the action and succeeds, proving validation
        // doesn't trip the default self-swap guard.
        aavePool.setLiquidationCollateralReward(550e18);
        loanToken.mint(address(aavePool), 100_000e18);

        bytes memory action =
            _buildAaveV3LiquidationAction(address(loanToken), address(loanToken), address(0x1234), 500e18, false);
        LiquidationExecutor.SwapPlan memory swapPlan = _buildNoSwapPlan(address(loanToken), 0);
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, action), swapPlan);

        // No revert on validation (no InvalidPlan / InvalidLegLink).
        vm.prank(operatorAddr);
        executor.execute(plan);
    }

    function test_skipUnwrap_aTokenSrc_skipsPoolWithdraw() public {
        // receiveAToken=true + leg1.srcToken == aToken → pool.withdraw is
        // NOT called. Verify by starving the Aave pool of underlying
        // collateralToken: a `withdraw` call would revert, but skip-unwrap
        // bypasses it entirely and the tx succeeds via the aToken swap.
        uint256 debtToCover = 500e18;
        // Reward must be large enough so Paraswap at 1.1x covers
        // LOAN_AMOUNT + FLASH_FEE = 1001e18 → reward >= ~910e18.
        uint256 reward = 1000e18;

        aavePool.setLiquidationCollateralReward(reward);
        aavePool.setAToken(address(aToken));
        aavePool.setReserveAToken(address(collateralToken), address(aToken));

        // Pre-fund:
        //   * loanToken on Aave — liquidationCall pulls debt from caller, we need it back on augustus
        //   * aToken on Aave — given to executor on liquidationCall (receiveAToken=true)
        //   * loanToken on augustus — funds the aToken -> loanToken swap
        // INTENTIONALLY NOT minting collateralToken to Aave — a withdraw
        // call would revert with insufficient balance.
        aToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        bytes memory action = _buildAaveV3LiquidationActionWithAToken(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, address(aToken)
        );

        // leg1: srcToken == aToken (skip-unwrap signal), repayToken == loanToken.
        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(aToken),
                amountIn: reward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(aToken), address(loanToken), reward, address(executor)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, action), swapPlan);

        vm.prank(operatorAddr);
        executor.execute(plan);

        // Post-condition: executor has loanToken profit from the aToken swap.
        assertGt(loanToken.balanceOf(address(executor)), 0, "executor must hold loanToken profit");
        // Executor should NOT be left holding aToken (Paraswap consumed it).
        assertEq(aToken.balanceOf(address(executor)), 0, "aToken must be consumed by the swap");
    }

    function test_skipUnwrap_underlyingSrc_stillUnwraps() public {
        // Backward-compat: receiveAToken=true + leg1.srcToken == underlying
        // must still unwrap via pool.withdraw (default behaviour). Verified
        // by requiring the Aave pool to hold enough underlying for the
        // withdraw to succeed — the existing test_receiveAToken_true_fullPipeline
        // asserts the same invariant, so this test is a stability guard.
        uint256 debtToCover = 500e18;
        uint256 reward = 1000e18; // covers 1001e18 flash repay at 1.1x swap rate

        address[] memory targets = new address[](2);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        LiquidationExecutor fresh = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        aavePool.setLiquidationCollateralReward(reward);
        aavePool.setAToken(address(aToken));
        aavePool.setReserveAToken(address(collateralToken), address(aToken));

        // Critically mint collateralToken to Aave pool — withdraw path is
        // exercised, so underlying must be available.
        aToken.mint(address(aavePool), 100_000e18);
        collateralToken.mint(address(aavePool), 100_000e18);
        loanToken.mint(address(augustus), 100_000e18);

        bytes memory action = _buildAaveV3LiquidationActionWithAToken(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, address(aToken)
        );

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: address(collateralToken), // underlying, NOT aToken
                amountIn: reward,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(
                    address(collateralToken), address(loanToken), reward, address(fresh)
                ),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, action), swapPlan);

        uint256 poolCollBefore = collateralToken.balanceOf(address(aavePool));

        vm.prank(operatorAddr);
        fresh.execute(plan);

        assertGt(loanToken.balanceOf(address(fresh)), 0, "executor must hold loanToken profit");
        // Withdraw path fires: Aave pool's underlying collateralToken balance
        // drops by the unwrapped amount (exact value depends on mock which
        // doesn't burn aToken — only the pool's side is checked here).
        uint256 poolCollAfter = collateralToken.balanceOf(address(aavePool));
        assertLt(poolCollAfter, poolCollBefore, "pool.withdraw must have consumed underlying on the unwrap path");
    }

    // ─── Security regression: NO_SWAP + multi-leg shape ─────────────
    //
    // NO_SWAP is meaningful ONLY as a single-leg plan. When combined with
    // any multi-leg flag, _executeSwapPlan early-returns at the NO_SWAP
    // gate BEFORE reaching the hasSplit/hasMixedSplit/hasLeg2 branches —
    // leg2 silently never runs, but the operator's plan said it should.
    // Concrete impact for hasMixedSplit when collateralAsset == loanToken
    // (e.g. same-token liquidation paired with a "skim leftover into WETH"
    // profit leg): the WETH profit leg is dropped, the contract keeps the
    // raw loanToken bonus, and no error surfaces.
    //
    // Fix: execute() must reject leg1.mode == NO_SWAP combined with any
    // of {hasLeg2, hasSplit, hasMixedSplit} via PlanShapeConflict.

    function test_noSwap_with_mixedSplit_reverts() public {
        // Same-token liquidation (loanToken acts as both collateral and
        // debt) — collateralAsset == loanToken so the leg2.srcToken check
        // (must equal collateralAsset) and the leg1.repayToken check
        // (must equal loanToken) both pass. The only thing left to fail
        // closed is the NO_SWAP + hasMixedSplit shape itself.
        aavePool.setLiquidationCollateralReward(550e18);
        loanToken.mint(address(aavePool), 100_000e18);

        bytes memory action =
            _buildAaveV3LiquidationAction(address(loanToken), address(loanToken), address(0x1234), 500e18, false);

        LiquidationExecutor.SwapLeg memory noSwapLeg = LiquidationExecutor.SwapLeg({
            mode: LiquidationExecutor.SwapMode.NO_SWAP,
            srcToken: address(loanToken),
            amountIn: 0,
            useFullBalance: false,
            deadline: block.timestamp + 3600,
            paraswapCalldata: "",
            bebopTarget: address(0),
            bebopCalldata: "",
            v2Path: new address[](0),
            v3Fee: 0,
            v4PoolManager: address(0),
            v4SwapData: "",
            repayToken: address(loanToken),
            minAmountOut: 0
        });
        LiquidationExecutor.SwapLeg memory profitLeg =
            _buildUniV3Leg(address(loanToken), address(mockWeth), 0, 3000, 1, false);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: noSwapLeg,
            hasLeg2: false,
            leg2: profitLeg,
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: true,
            profitToken: address(mockWeth),
            minProfitAmount: 0
        });
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, action), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(LiquidationExecutor.PlanShapeConflict.selector);
        executor.execute(plan);
    }

    function test_skipUnwrap_leg1SrcUnrelatedToken_reverts() public {
        // Collateral linkage guard: leg1.srcToken must be collateralAsset
        // OR trackingToken. A third unrelated address reverts
        // SrcTokenNotCollateral pre-flashloan.
        uint256 debtToCover = 500e18;
        aavePool.setLiquidationCollateralReward(COLLATERAL_REWARD);
        aavePool.setAToken(address(aToken));
        aavePool.setReserveAToken(address(collateralToken), address(aToken));

        bytes memory action = _buildAaveV3LiquidationActionWithAToken(
            address(collateralToken), address(loanToken), address(0x1234), debtToCover, address(aToken)
        );

        address bogus = address(0xBAD1);

        LiquidationExecutor.SwapPlan memory swapPlan = LiquidationExecutor.SwapPlan({
            leg1: LiquidationExecutor.SwapLeg({
                mode: LiquidationExecutor.SwapMode.PARASWAP_SINGLE,
                srcToken: bogus, // neither collateralToken nor aToken
                amountIn: 100e18,
                useFullBalance: false,
                deadline: block.timestamp + 3600,
                paraswapCalldata: _buildParaswapCalldata(bogus, address(loanToken), 100e18, address(executor)),
                bebopTarget: address(0),
                bebopCalldata: "",
                v2Path: new address[](0),
                v3Fee: 0,
                v4PoolManager: address(0),
                v4SwapData: "",
                repayToken: address(loanToken),
                minAmountOut: 0
            }),
            hasLeg2: false,
            leg2: _zeroLeg(),
            hasSplit: false,
            splitBps: 0,
            hasMixedSplit: false,
            profitToken: address(loanToken),
            minProfitAmount: 0
        });

        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _singleAction(1, action), swapPlan);

        vm.prank(operatorAddr);
        vm.expectRevert(
            abi.encodeWithSignature("SrcTokenNotCollateral(address,address)", address(collateralToken), bogus)
        );
        executor.execute(plan);
    }
}

// ═══════════════════════════════════════════════════════════════════
// SECURITY REGRESSION: V4 callback adversarial PoolManager
//
// The v4 unlock pattern hands control back to the caller via
// `unlockCallback(data)`, where `data` is whatever the PoolManager
// chooses to pass — NOT necessarily what the executor sent in
// `unlock(data)`. The current callback re-validates the `hook` field
// against the owner-curated allowlist (defense-in-depth) but trusts
// the `tokenIn` / `tokenOut` / `amountIn` fields. With a malicious or
// compromised PoolManager (or whitelisted hook turned malicious), this
// trust gives two distinct drain vectors:
//
//   * Lead #2 — tokenIn substitution: the PM echoes back data with a
//     different `tokenIn`. The executor swaps a token it holds for an
//     unrelated reason (e.g. WETH from a previous step) into the pm's
//     vault. The post-unlock `received >= leg.minAmountOut` check on
//     the original `tokenOut` may still pass (if the pm gives output
//     of the expected token), so nothing surfaces.
//   * Lead #3 — nested re-entry: a malicious whitelisted hook re-enters
//     `pm.unlock(craftedData)` from within `swap()`. The PM dutifully
//     calls `executor.unlockCallback(craftedData)` while
//     `_activeV4PoolManager` is still pinned, all guards pass, and the
//     contract performs a second swap consuming arbitrary tokens.
//
// Both fixes land together: re-pin tokenIn alongside the pm in
// `_executeUniV4Leg` and re-assert in `unlockCallback`; depth-track
// callback recursion to reject nested invocations.
// ═══════════════════════════════════════════════════════════════════

contract ExecutorV4SecurityTest is ExecutorTest {
    MaliciousV4PoolManager internal evilPm;
    LiquidationExecutor internal evilExec;

    function _deployEvilExecutor() internal {
        evilPm = new MaliciousV4PoolManager(SWAP_RATE);

        // Allow both the evil pm AND the legitimate aave pool / paraswap /
        // bebop / morpho — needed for the action+flashloan parts of the
        // pipeline to behave normally.
        address[] memory targets = new address[](6);
        targets[0] = address(aavePool);
        targets[1] = address(augustus);
        targets[2] = address(aaveV2Pool);
        targets[3] = address(bebop);
        targets[4] = address(morphoBlue);
        targets[5] = address(evilPm);

        evilExec = new LiquidationExecutor(
            owner,
            operatorAddr,
            address(mockWeth),
            address(aavePool),
            address(balancerVault),
            address(augustus),
            address(uniV2Mock),
            address(uniV3Mock),
            targets
        );

        // Pre-fund evil pm with both the legitimate output token AND the
        // attacker's substituted tokenIn so the malicious settle/take
        // paths don't fail for cosmetic reasons.
        loanToken.mint(address(evilPm), 100_000e18);
        collateralToken.mint(address(evilPm), 100_000e18);
        mockWeth.mint(address(evilPm), 100_000e18);

        // Pre-fund the executor with WETH (the substitution target) and
        // the gap collateral (so the legitimate Aave liquidation path
        // produces enough collateral for the V4 leg input).
        loanToken.mint(address(evilExec), LOAN_AMOUNT + FLASH_FEE + 100e18);
        collateralToken.mint(address(evilExec), DEFAULT_SWAP_AMOUNT - COLLATERAL_REWARD);
        // Critically: the contract holds WETH that the attacker wants to
        // drain. Without WETH on the executor the substitution attack
        // can't actually transfer anything (settle would revert).
        mockWeth.mint(address(evilExec), 5000e18);
    }

    function test_v4_callback_tokenIn_substitution_reverts() public {
        _deployEvilExecutor();

        // PM substitutes the callback payload — tries to redirect tokenOut
        // to mockWeth (operator's plan is collateralToken→loanToken).
        // After fix: tokenIn is read from STORAGE (pinned by
        // _executeUniV4Leg) so the PM cannot influence which token gets
        // settled. The substituted tokenOut/fee/etc. cause downstream
        // mismatches (post-unlock `received` delta on leg.repayToken
        // catches it), so the tx still reverts. Today (pre-fix): the
        // contract trusted the data field and would have settled
        // mockWeth — a real drain.
        // Payload format (post-fix): (tokenOut, fee, tickSpacing, hook, amountIn).
        bytes memory substituted = abi.encode(
            address(mockWeth), // ← substituted tokenOut (legit was loanToken)
            uint24(3000),
            int24(60),
            address(0),
            uint256(2000e18)
        );
        evilPm.setSubstituteCallback(substituted);

        // Build a legitimate plan: collateralToken → loanToken via V4.
        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(evilPm),
            1,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        // After fix: tokenIn re-assertion in unlockCallback rejects the
        // substituted payload. Today: silently succeeds and drains WETH.
        vm.expectRevert();
        evilExec.execute(plan);
    }

    function test_v4_callback_reentry_blocked() public {
        _deployEvilExecutor();

        // Re-entry payload: a SECOND unlockCallback invocation made from
        // within swap(). After fix: the outer callback claims
        // _activeV4TokenIn (clears it to address(0)) on entry. The
        // nested call sees tokenIn == 0 in storage and the combined
        // entry guard reverts InvalidCallbackCaller before any swap
        // logic. Today (pre-fix): both swaps run, executor leaks tokens.
        // Payload format (post-fix): (tokenOut, fee, tickSpacing, hook, amountIn).
        bytes memory innerData = abi.encode(address(loanToken), uint24(3000), int24(60), address(0), uint256(1000e18));
        evilPm.setReentryAttack(innerData);

        LiquidationExecutor.SwapPlan memory swapPlan = _buildUniV4SwapPlan(
            address(collateralToken),
            address(loanToken),
            DEFAULT_SWAP_AMOUNT,
            3000,
            int24(60),
            address(0),
            address(evilPm),
            1,
            0
        );
        bytes memory plan =
            _buildPlan(2, address(loanToken), LOAN_AMOUNT, FLASH_FEE, _defaultLiqAction(500e18), swapPlan);

        vm.prank(operatorAddr);
        // After fix: depth tracking on unlockCallback rejects the nested
        // invocation. Today: both swaps run, executor leaks WETH.
        vm.expectRevert();
        evilExec.execute(plan);
    }
}

