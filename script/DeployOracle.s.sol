// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice Deploys a mock oracle for testing/development
/// @dev For production, use Chainlink or other oracle providers
contract DeployOracleScript is Script {
    function run() public returns (address oracleAddress) {
        // For stable pools, initial price is typically 1:1
        int256 initialPrice = 1e18; // 1.0 with 18 decimals
        uint8 decimals = 18;

        vm.startBroadcast();
        MockOracle oracle = new MockOracle(initialPrice, decimals);
        vm.stopBroadcast();

        console.log("MockOracle deployed at:", address(oracle));
        console.log("Initial price:", initialPrice);
        console.log("Decimals:", decimals);

        return address(oracle);
    }
}

/// @notice Deploy Chainlink-compatible oracle (for production)
/// @dev Update with actual Chainlink feed addresses
contract DeployChainlinkOracleScript is Script {
    // Mainnet Chainlink ETH/USD feed (example)
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function run() public view returns (address) {
        // For production, use existing Chainlink feeds
        // This script just returns the address
        console.log("Using Chainlink feed at:", CHAINLINK_ETH_USD);
        return CHAINLINK_ETH_USD;
    }
}
