// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Anchor} from "../src/Anchor.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract AnchorTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    Anchor anchor;
    MockOracle oracle;
    PoolId poolId;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Test constants
    int256 constant INITIAL_ORACLE_PRICE = 1e18; // 1:1 price for stable pool
    uint8 constant ORACLE_DECIMALS = 18;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy mock oracle
        oracle = new MockOracle(INITIAL_ORACLE_PRICE, ORACLE_DECIMALS);

        // Configure Anchor parameters
        Anchor.RiskConfig memory riskConfig = Anchor.RiskConfig({
            lowRiskThreshold: 10, // 0.1%
            mediumRiskThreshold: 50, // 0.5%
            highRiskThreshold: 100, // 1.0%
            criticalRiskThreshold: 200 // 2.0%
        });

        Anchor.FeeConfig memory feeConfig = Anchor.FeeConfig({
            baseFee: 100, // 0.01%
            mediumFee: 500, // 0.05%
            highFee: 5000, // 0.5%
            maxFee: 10000 // 1.0%
        });

        Anchor.SizeCapConfig memory sizeCapConfig = Anchor.SizeCapConfig({
            baseMaxSize: 1_000_000e18,
            mediumMaxSize: 500_000e18,
            highMaxSize: 50_000e18,
            minSize: 1_000e18
        });

        // Deploy Anchor hook
        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144));
        bytes memory constructorArgs =
            abi.encode(poolManager, IOracle(address(oracle)), riskConfig, feeConfig, sizeCapConfig);
        deployCodeTo("Anchor.sol:Anchor", constructorArgs, flags);
        anchor = Anchor(flags);

        // Create pool
        poolKey = PoolKey(currency0, currency1, 100, 1, IHooks(address(anchor)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide liquidity
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // ============ Deviation Detection Tests ============

    function testLowRiskDeviation() public {
        // Set oracle price to 0.05% deviation (below low risk threshold)
        oracle.setPrice(1_000_500_000_000_000_000); // 1.0005

        // Should allow swap with base fee
        uint256 amountIn = 1e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    function testMediumRiskDeviation() public {
        // Set oracle price to 0.3% deviation (medium risk)
        oracle.setPrice(1_003_000_000_000_000_000); // 1.003

        uint256 amountIn = 1e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    function testHighRiskDeviation() public {
        // Set oracle price to 0.8% deviation (high risk)
        oracle.setPrice(1_008_000_000_000_000_000); // 1.008

        uint256 amountIn = 1e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    function testCriticalRiskDeviation() public {
        // Set oracle price to 2.5% deviation (critical risk)
        oracle.setPrice(1_025_000_000_000_000_000); // 1.025

        uint256 amountIn = 1e18;

        vm.expectRevert("Anchor: Swap blocked due to critical deviation");
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // ============ Size Cap Tests ============

    function testSizeCapEnforcementLowRisk() public {
        oracle.setPrice(1_000_100_000_000_000_000); // 0.01% deviation

        // Should allow swap within base size cap
        uint256 amountIn = 500_000e18; // Within baseMaxSize
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    function testSizeCapEnforcementHighRisk() public {
        oracle.setPrice(1_008_000_000_000_000_000); // 0.8% deviation (high risk)

        // Should block swap exceeding high risk size cap
        uint256 amountIn = 100_000e18; // Exceeds highMaxSize (50k)

        vm.expectRevert("Anchor: Swap exceeds size cap");
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function testSizeCapWithinHighRisk() public {
        oracle.setPrice(1_008_000_000_000_000_000); // 0.8% deviation

        // Should allow swap within high risk size cap
        uint256 amountIn = 10_000e18; // Within highMaxSize

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    // ============ Oracle Tests ============

    function testStaleOracleData() public {
        // Set oracle to be stale (> 1 hour old)
        oracle.setStale(2 hours);

        uint256 amountIn = 1e18;

        vm.expectRevert("Anchor: Stale oracle data");
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function testInvalidOracleData() public {
        // Create oracle with invalid data
        MockOracle badOracle = new MockOracle(0, 18);
        badOracle.setStale(2 hours);

        // This would fail in deployment, but testing the check
        vm.expectRevert();
        badOracle.latestRoundData();
    }

    function testOraclePriceUpdate() public {
        // Initial swap
        oracle.setPrice(1_000_500_000_000_000_000);
        uint256 amountIn = 1e18;

        BalanceDelta swapDelta1 = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Update oracle price
        oracle.setPrice(1_002_000_000_000_000_000);

        // Second swap should use new oracle price
        BalanceDelta swapDelta2 = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta1.amount0()) < 0);
        assertTrue(int256(swapDelta2.amount0()) < 0);
    }

    // ============ TWAP Tests ============

    function testTWAPObservationUpdate() public {
        // Perform swap to trigger observation update
        uint256 amountIn = 1e18;

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Move time forward
        vm.warp(block.timestamp + 1 hours);

        // Perform another swap - should use updated TWAP
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function testTWAPWithMultipleSwaps() public {
        oracle.setPrice(1_000_500_000_000_000_000);

        // Perform multiple swaps to build TWAP history
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 10 minutes);

            swapRouter.swapExactTokensForTokens({
                amountIn: 1e17,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        // Final swap should use accumulated TWAP
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    // ============ Edge Cases ============

    function testZeroDeviation() public {
        // Oracle and TWAP should be equal for stable pool
        oracle.setPrice(1e18);

        uint256 amountIn = 1e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    function testNegativeDeviation() public {
        // Oracle price lower than TWAP
        oracle.setPrice(999_500_000_000_000_000); // 0.05% below

        uint256 amountIn = 1e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    function testVerySmallSwap() public {
        oracle.setPrice(1_000_100_000_000_000_000);

        // Very small swap should always pass
        uint256 amountIn = 1e15; // 0.001 tokens

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertTrue(int256(swapDelta.amount0()) < 0);
    }

    // ============ Event Tests ============

    function testDeviationDetectedEvent() public {
        oracle.setPrice(1_003_000_000_000_000_000); // 0.3% deviation

        uint256 amountIn = 1e18;

        vm.expectEmit(true, false, false, true);
        emit Anchor.DeviationDetected(
            poolId,
            1_003_000_000_000_000_000,
            0, // TWAP will be calculated
            30, // ~0.3% in bps
            500, // mediumFee
            500_000e18 // mediumMaxSize
        );

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function testSwapBlockedEvent() public {
        oracle.setPrice(1_025_000_000_000_000_000); // 2.5% deviation

        uint256 amountIn = 1e18;

        vm.expectEmit(true, true, false, true);
        emit Anchor.SwapBlocked(
            poolId,
            address(this),
            250, // 2.5% in bps
            "Critical deviation detected"
        );

        vm.expectRevert("Anchor: Swap blocked due to critical deviation");
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // ============ Integration Tests ============

    function testFullRiskProgression() public {
        // Start with low risk
        oracle.setPrice(1_000_050_000_000_000_000); // 0.005%
        uint256 amountIn = 1e18;

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Progress to medium risk
        oracle.setPrice(1_003_000_000_000_000_000); // 0.3%
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Progress to high risk
        oracle.setPrice(1_008_000_000_000_000_000); // 0.8%
        swapRouter.swapExactTokensForTokens({
            amountIn: 10_000e18, // Within high risk cap
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Finally critical risk - should block
        oracle.setPrice(1_025_000_000_000_000_000); // 2.5%
        vm.expectRevert("Anchor: Swap blocked due to critical deviation");
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }
}
