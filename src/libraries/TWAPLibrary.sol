// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library TWAPLibrary {
    using PoolIdLibrary for PoolId;

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }

    // Store observations per pool - using storage pattern
    struct PoolObservations {
        Observation[] observations;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
    }

    // Storage slot for observations
    bytes32 private constant OBSERVATIONS_SLOT = keccak256("TWAPLibrary.observations");

    function getObservations(PoolId poolId) internal view returns (PoolObservations storage obs) {
        bytes32 slot = keccak256(abi.encodePacked(OBSERVATIONS_SLOT, poolId));
        assembly {
            obs.slot := slot
        }
    }

    function updateObservation(PoolId poolId, int24 tick, uint32 blockTimestamp) internal {
        PoolObservations storage obs = getObservations(poolId);

        uint16 index = obs.observationIndex;
        uint16 cardinality = obs.observationCardinality;

        // Get last observation
        Observation memory lastObservation;
        if (cardinality > 0) {
            lastObservation = obs.observations[index];
        }

        // Calculate tick cumulative
        int56 tickCumulative = lastObservation.initialized
            ? lastObservation.tickCumulative + int56(tick) * int56(int32(blockTimestamp - lastObservation.blockTimestamp))
            : int56(tick) * int56(int32(blockTimestamp));

        // Create new observation
        Observation memory newObservation =
            Observation({blockTimestamp: blockTimestamp, tickCumulative: tickCumulative, initialized: true});

        // Update or append observation
        if (index >= cardinality) {
            obs.observations.push(newObservation);
            obs.observationCardinality = uint16(obs.observations.length);
        } else {
            obs.observations[index] = newObservation;
        }

        // Update index
        obs.observationIndex = (index + 1) % obs.observationCardinality;
    }

    function getTWAP(IPoolManager poolManager, PoolId poolId, uint32 twapWindow)
        internal
        view
        returns (uint256 price)
    {
        PoolObservations storage obs = getObservations(poolId);

        if (obs.observations.length == 0) {
            // No observations, use current price
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
            return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
        }

        uint32 timeElapsed = block.timestamp - twapWindow;
        if (timeElapsed > block.timestamp) timeElapsed = 0; // Prevent underflow

        // Find observations
        (Observation memory beforeOrAt, Observation memory atOrAfter) = getSurroundingObservations(obs, timeElapsed);

        if (beforeOrAt.blockTimestamp == atOrAfter.blockTimestamp) {
            // Same observation, use current tick
            int24 tick = getTickFromCumulative(beforeOrAt.tickCumulative, 0);
            return getPriceFromTick(tick);
        }

        // Interpolate between observations
        uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
        uint32 targetDelta = block.timestamp - timeElapsed - beforeOrAt.blockTimestamp;

        int56 tickCumulativeDelta = atOrAfter.tickCumulative - beforeOrAt.tickCumulative;
        int56 targetTickCumulative = beforeOrAt.tickCumulative
            + (tickCumulativeDelta * int56(int32(targetDelta))) / int56(int32(observationTimeDelta));

        int24 tick = getTickFromCumulative(targetTickCumulative, timeElapsed);
        return getPriceFromTick(tick);
    }

    function getSurroundingObservations(PoolObservations storage obs, uint32 target)
        internal
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 len = obs.observations.length;
        if (len == 0) {
            return (beforeOrAt, atOrAfter);
        }

        // Binary search for surrounding observations
        uint256 l = 0;
        uint256 r = len;

        while (l < r) {
            uint256 m = (l + r) / 2;
            if (obs.observations[m].blockTimestamp <= target) {
                l = m + 1;
            } else {
                r = m;
            }
        }

        if (l == 0) {
            beforeOrAt = obs.observations[0];
            atOrAfter = obs.observations[0];
        } else if (l == len) {
            beforeOrAt = obs.observations[len - 1];
            atOrAfter = obs.observations[len - 1];
        } else {
            beforeOrAt = obs.observations[l - 1];
            atOrAfter = obs.observations[l];
        }
    }

    function getTickFromCumulative(int56 tickCumulative, uint32 timeElapsed) internal pure returns (int24) {
        if (timeElapsed == 0) return 0;
        return int24(tickCumulative / int56(int32(timeElapsed)));
    }

    function getPriceFromTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        // Convert sqrtPriceX96 to price (price = (sqrtPriceX96 / 2^96)^2)
        // For stable pools, we want price in terms of token1/token0
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        return priceX96;
    }
}
