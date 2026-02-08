// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {Anchor} from "../src/Anchor.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";

contract DeployHookScript is BaseScript {
    function run() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Configure Anchor parameters
        IOracle oracle = IOracle(0x8A753747A1Fa494EC906cE90E9f37563A8AF630e); // Your oracle address

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

        bytes memory constructorArgs = abi.encode(poolManager, oracle, riskConfig, feeConfig, sizeCapConfig);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(Anchor).creationCode, constructorArgs);

        vm.startBroadcast();
        Anchor anchor = new Anchor{salt: salt}(poolManager, oracle, riskConfig, feeConfig, sizeCapConfig);
        vm.stopBroadcast();

        require(address(anchor) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
