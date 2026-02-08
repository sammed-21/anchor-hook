// Interface for external price feeds (Chainlink, Pyth, etc.)
interface IOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
