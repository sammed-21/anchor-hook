# Anchor Hook 🚨

**A deterministic risk-agent hook for Uniswap v4 stable pools that enforces guardrails against micro depegs**

Anchor is a Uniswap v4 hook designed specifically for stable pools (e.g., USDC/USDT, DAI/USDC) that implements sophisticated risk management mechanisms to protect against micro depegs and excessive price deviations. The hook monitors price deviations between external oracle feeds and Time-Weighted Average Price (TWAP) from the pool, dynamically adjusting fees and swap size caps to maintain pool stability.

## 🎯 Features

### Core Risk Management

- **Oracle vs TWAP Deviation Monitoring**: Continuously compares external oracle prices with pool TWAP to detect price anomalies
- **Dynamic Fee Adjustment**: Automatically increases swap fees when price deviations exceed thresholds to discourage arbitrage during instability
- **Size Caps**: Implements swap size limits that scale inversely with price deviation to prevent large trades during micro depegs
- **Micro-Depeg Protection**: Detects and mitigates small but significant price deviations (typically 0.1% - 1%) that can destabilize stable pools

### Deterministic Behavior

- All risk calculations are deterministic and on-chain
- No reliance on external keepers or off-chain systems
- Predictable fee and cap adjustments based on measurable price metrics

## 🏗️ Architecture

### Components

1. **Oracle Interface** (`src/interfaces/IOracle.sol`)

   - Standardized interface for external price feeds (Chainlink, Pyth, etc.)
   - Returns latest price data with timestamps

2. **TWAP Library** (`src/libraries/TWAPLibrary.sol`)

   - Calculates Time-Weighted Average Price from pool observations
   - Maintains historical price data for deviation analysis

3. **Anchor Hook** (`src/Anchor.sol`)
   - Main hook contract implementing guardrails
   - Monitors swaps and applies dynamic restrictions
   - Updates fees and size caps based on deviation metrics

### How It Works

┌─────────────────┐
│ External │
│ Oracle Feed │──┐
└─────────────────┘ │
│
┌─────────────────┐ │ ┌──────────────┐
│ Pool TWAP │──┼───▶│ Deviation │
│ Calculation │ │ │ Calculator │
└─────────────────┘ │ └──────────────┘
│ │
│ ▼
│ ┌──────────────┐
└───▶│ Risk Agent │
│ (Anchor) │
└──────────────┘
│
┌───────────────┼───────────────┐
▼ ▼ ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│ Dynamic │ │ Size │ │ Swap │
│ Fee │ │ Caps │ │ Allow/ │
│ │ │ │ │ Deny │
└──────────┘ └──────────┘ └──────────┘

### Risk Calculation Flow

1. **Price Fetch**: Hook retrieves current price from external oracle
2. **TWAP Calculation**: Computes TWAP over configured time window (e.g., 30 minutes)
3. **Deviation Analysis**: Calculates percentage deviation: `|oracle_price - twap_price| / twap_price`
4. **Risk Assessment**: Maps deviation to risk level:
   - **Low Risk** (< 0.1%): Normal operations, base fees
   - **Medium Risk** (0.1% - 0.5%): Increased fees, moderate size caps
   - **High Risk** (> 0.5%): Maximum fees, strict size caps, potential swap blocking
5. **Dynamic Adjustment**: Updates pool parameters before swap execution

## 📋 Requirements

- Foundry (stable version)
- Solidity ^0.8.26
- Uniswap v4 Core & Periphery

## 🚀 Setup

### Installation

# Install dependencies

forge install

# Build contracts

forge build

# Run tests

forge test

Configuration
Before deploying, configure the following parameters in src/Anchor.sol:
Oracle Address: External price feed contract address
TWAP Window: Time period for TWAP calculation (default: 30 minutes)
Deviation Thresholds: Price deviation percentages that trigger different risk levels
Base Fee: Starting swap fee (typically 0.01% - 0.05% for stable pools)
Max Fee: Maximum fee during high deviation (typically 0.1% - 1%)
Base Size Cap: Maximum swap size under normal conditions
Min Size Cap: Minimum swap size during high deviation

📖 Usage

# Start local Anvil node

anvil

# Deploy the hook

forge script script/00_DeployHook.s.sol \
 --rpc-url http://localhost:8545 \
 --private-key <PRIVATE_KEY> \
 --broadcast

Creating a Pool with Anchor Hook
PoolKey memory poolKey = PoolKey({
currency0: Currency.wrap(address(USDC)),
currency1: Currency.wrap(address(USDT)),
fee: 100, // 0.01% base fee (will be adjusted dynamically)
tickSpacing: 1, // Tight spacing for stable pools
hooks: IHooks(address(anchorHook))
});

poolManager.initialize(poolKey, sqrtPriceX96);

How Swaps Are Protected
When a swap is initiated:
Before Swap: Anchor hook checks current deviation
Fee Override: Returns dynamic fee based on deviation level
Size Validation: Verifies swap size is within current cap
Execution: Swap proceeds with adjusted parameters
After Swap: Hook updates TWAP observations

#Example: Deviation Response
Normal Conditions (0.05% deviation):

- Fee: 0.01% (base)
- Max Swap Size: $1,000,000

Minor Deviation (0.2% deviation):

- Fee: 0.05% (5x base)
- Max Swap Size: $500,000

Significant Deviation (0.8% deviation):

- Fee: 0.5% (50x base)
- Max Swap Size: $50,000
- Warning: Approaching swap block thresholdApproaching swap block threshold
  🧪 Testing

# Run all tests

forge test

# Run with verbosity

forge test -vvv

# Run specific test file

forge test --match-path test/Anchor.t.sol

Oracle price fetching and validation
TWAP calculation accuracy
Deviation threshold detection
Dynamic fee adjustments
Size cap enforcement
Edge cases (stale oracle, zero liquidity, etc.)
🔧 Configuration Parameters
Risk Thresholds
struct RiskConfig { uint256 lowRiskThreshold; // 0.1% deviation uint256 mediumRiskThreshold; // 0.5% deviation uint256 highRiskThreshold; // 1.0% deviation uint256 criticalRiskThreshold; // 2.0% deviation (blocks swaps)}
Fee Schedule
struct FeeConfig { uint24 baseFee; // 100 = 0.01% uint24 mediumFee; // 500 = 0.05% uint24 highFee; // 5000 = 0.5% uint24 maxFee; // 10000 = 1.0%}
Size Caps
struct SizeCapConfig { uint256 baseMaxSize; // $1,000,000 uint256 mediumMaxSize; // $500,000 uint256 highMaxSize; // $50,000 uint256 minSize; // $1,000 (minimum allowed)}
🛡️ Security Considerations
Oracle Risks
Stale Data: Hook checks oracle freshness and rejects stale prices
Manipulation: Uses TWAP as reference to detect oracle manipulation
Failover: Can be configured with multiple oracle sources
Pool Protection
Front-running: Dynamic fees make front-running unprofitable during deviations
Flash Loan Attacks: Size caps limit impact of large flash loan arbitrage
Gradual Response: Fee increases are gradual to avoid sudden pool freezing
Deterministic Behavior
All calculations are on-chain and deterministic
No external dependencies for core risk logic
Predictable responses enable better user experience
📊 Monitoring
Key Metrics to Track
Current Deviation: Real-time oracle vs TWAP deviation
Fee Multiplier: Current fee relative to base fee
Size Cap Utilization: Percentage of cap used in recent swaps
Risk Level: Current risk classification (Low/Medium/High/Critical)
TWAP Window: Effective time window for TWAP calculation
Events Emitted
event DeviationDetected( PoolId indexed poolId, uint256 oraclePrice, uint256 twapPrice, uint256 deviationBps, uint256 newFee, uint256 newSizeCap);event SwapBlocked( PoolId indexed poolId, address indexed swapper, uint256 deviationBps, string reason);
🔄 Integration
With DeFi Protocols
Anchor hook can be integrated with:
Lending Protocols: Use as price oracle with deviation warnings
Stablecoin Protocols: Monitor peg stability
Arbitrage Bots: Adjust strategies based on current fee levels
Risk Management Systems: Alert on deviation thresholds
Oracle Providers
Compatible with:
Chainlink Price Feeds
Pyth Network
Band Protocol
Custom oracle implementations
📝 License
MIT
🤝 Contributing
Contributions welcome! Please ensure:
All tests pass
Code follows Solidity style guide
Security considerations are documented
Gas optimizations are considered
📚 Additional Resources
Uniswap v4 Documentation
Uniswap v4 Core
Uniswap v4 Periphery
v4-by-example
