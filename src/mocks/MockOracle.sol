// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracle} from "../interfaces/IOracle.sol";

contract MockOracle is IOracle {
    uint80 public roundId;
    int256 public price;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint8 public decimals;

    constructor(int256 _initialPrice, uint8 _decimals) {
        price = _initialPrice;
        decimals = _decimals;
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 _roundId, int256 _price, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId, price, startedAt, updatedAt, answeredInRound);
    }

    function setPrice(int256 _price) external {
        price = _price;
        roundId++;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }

    function setStale(uint256 staleSeconds) external {
        updatedAt = block.timestamp - staleSeconds;
    }

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }
}
