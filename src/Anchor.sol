// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {TWAPLibrary} from "./libraries/TWAPLibrary.sol";

contract Anchor is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // Configuration
    struct RiskConfig {
        uint256 lowRiskThreshold; // 10 bps (0.1%)
        uint256 mediumRiskThreshold; // 50 bps (0.5%)
        uint256 highRiskThreshold; // 100 bps (1.0%)
        uint256 criticalRiskThreshold; // 200 bps (2.0%)
    }

    struct FeeConfig {
        uint24 baseFee; // 100 = 0.01%
        uint24 mediumFee; // 500 = 0.05%
        uint24 highFee; // 5000 = 0.5%
        uint24 maxFee; // 10000 = 1.0%
    }

    struct SizeCapConfig {
        uint256 baseMaxSize; // $1,000,000
        uint256 mediumMaxSize; // $500,000
        uint256 highMaxSize; // $50,000
        uint256 minSize; // $1,000
    }

    // State
    IOracle public immutable oracle;
    RiskConfig public riskConfig;
    FeeConfig public feeConfig;
    SizeCapConfig public sizeCapConfig;
    uint32 public constant TWAP_WINDOW = 30 minutes;

    // Per-pool state
    mapping(PoolId => TWAPLibrary.Observation[]) public observations;

    // Events
    event DeviationDetected(
        PoolId indexed poolId,
        uint256 oraclePrice,
        uint256 twapPrice,
        uint256 deviationBps,
        uint24 newFee,
        uint256 newSizeCap
    );

    event SwapBlocked(PoolId indexed poolId, address indexed swapper, uint256 deviationBps, string reason);

    constructor(
        IPoolManager _poolManager,
        IOracle _oracle,
        RiskConfig memory _riskConfig,
        FeeConfig memory _feeConfig,
        SizeCapConfig memory _sizeCapConfig
    ) BaseHook(_poolManager) {
        oracle = _oracle;
        riskConfig = _riskConfig;
        feeConfig = _feeConfig;
        sizeCapConfig = _sizeCapConfig;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Need to check deviation and apply fees/caps
            afterSwap: true, // Update TWAP observations
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // 1. Get oracle price
        uint256 oraclePrice = getOraclePrice(key);

        // 2. Calculate TWAP
        uint256 twapPrice = TWAPLibrary.getTWAP(poolManager, poolId, TWAP_WINDOW);

        // 3. Calculate deviation
        uint256 deviationBps = calculateDeviation(oraclePrice, twapPrice);

        // 4. Determine risk level
        RiskLevel risk = assessRisk(deviationBps);

        // 5. Get dynamic fee
        uint24 dynamicFee = getDynamicFee(risk);

        // 6. Check size cap
        uint256 swapSize = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);

        uint256 maxSize = getSizeCap(risk);
        require(swapSize <= maxSize, "Anchor: Swap exceeds size cap");

        // 7. Block if critical
        if (risk == RiskLevel.CRITICAL) {
            emit SwapBlocked(poolId, sender, deviationBps, "Critical deviation detected");
            revert("Anchor: Swap blocked due to critical deviation");
        }

        // 8. Emit event
        emit DeviationDetected(poolId, oraclePrice, twapPrice, deviationBps, dynamicFee, maxSize);

        // Return with dynamic fee override
        return (
            BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        // Update TWAP observation
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        TWAPLibrary.updateObservation(poolId, tick, uint32(block.timestamp));

        return (BaseHook.afterSwap.selector, 0);
    }

    // Helper functions
    function getOraclePrice(PoolKey calldata key) internal view returns (uint256) {
        (, int256 price,, uint256 updatedAt,) = oracle.latestRoundData();
        require(updatedAt > 0, "Anchor: Invalid oracle data");
        require(block.timestamp - updatedAt < 1 hours, "Anchor: Stale oracle data");
        return uint256(price);
    }

    function calculateDeviation(uint256 oraclePrice, uint256 twapPrice) internal pure returns (uint256) {
        if (twapPrice == 0) return type(uint256).max;
        uint256 diff = oraclePrice > twapPrice ? oraclePrice - twapPrice : twapPrice - oraclePrice;
        return (diff * 10000) / twapPrice; // Return in basis points
    }

    enum RiskLevel {
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    function assessRisk(uint256 deviationBps) internal view returns (RiskLevel) {
        if (deviationBps >= riskConfig.criticalRiskThreshold) return RiskLevel.CRITICAL;
        if (deviationBps >= riskConfig.highRiskThreshold) return RiskLevel.HIGH;
        if (deviationBps >= riskConfig.mediumRiskThreshold) return RiskLevel.MEDIUM;
        return RiskLevel.LOW;
    }

    function getDynamicFee(RiskLevel risk) internal view returns (uint24) {
        if (risk == RiskLevel.CRITICAL) return feeConfig.maxFee;
        if (risk == RiskLevel.HIGH) return feeConfig.highFee;
        if (risk == RiskLevel.MEDIUM) return feeConfig.mediumFee;
        return feeConfig.baseFee;
    }

    function getSizeCap(RiskLevel risk) internal view returns (uint256) {
        if (risk == RiskLevel.CRITICAL) return sizeCapConfig.minSize;
        if (risk == RiskLevel.HIGH) return sizeCapConfig.highMaxSize;
        if (risk == RiskLevel.MEDIUM) return sizeCapConfig.mediumMaxSize;
        return sizeCapConfig.baseMaxSize;
    }
}
