# Crypto Payment Gateway

**A production-grade,  payment settlement engine built in Solidity.**

This protocol allows merchants to accept payments in **Any Token** (Native ETH/BNB or ERC20s) while receiving settlement exclusively in **USDT**. It features two distinct architectural versions to handle different liquidity and pricing needs.

---

## Overview

Accepting crypto payments is hard: volatility risk, complex conversions, and gas costs.
This project solves these issues by acting as an **Auto-Settlement Layer**.

* **User Pays:** ETH, WBTC, DAI, or PEPE.
* **Protocol Actions:** Atomically swaps tokens to USDT via Uniswap V2.
* **Merchant Receives:** Stable USDT.
* **Safety:** Includes slippage protection, dust refunds, and Oracle guards.

### Architecture Versions

| Feature | **V1 (Oracle-Based)** | **V2 (DEX-Native)** |
| --- | --- | --- |
| **Pricing Source** | Chainlink Data Feeds | Uniswap V2 Spot Price |
| **Best For** | Major tokens (ETH, BTC, LINK) | Long-tail / Meme tokens (High Volatility) |
| **Security** | Oracle Staleness Checks | `maxTokenIn` Slippage Limits |
| **Gas Cost** | Higher (Oracle Read + Swap) | Lower (Direct Swap) |
| **USDT Handling** | Direct Transfer (Gas Optimized) | Direct Transfer (Gas Optimized) |

---

## Key Features

* **Auto-Settlement:** All incoming payments are instantly converted to USDT.
* **Refund Logic (V2):** If a swap uses less input than estimated (due to positive slippage), the remaining "dust" is automatically refunded to the user.
* **Sandwich Attack Protection:** V2 enforces a strict `maxTokenIn` parameter. If the pool price is manipulated beyond the user's limit, the transaction reverts.
* **Gas Optimization:** Payments made directly in USDT bypass the swap engine entirely, saving ~40% gas.
* **Audit-Ready Quality:**
* **Unit Tests:** 100% Function Coverage.
* **Fuzz Testing:** 1,000+ runs with random inputs (Solvency checks).
* **Invariant Testing:** 750+ random operational sequences to ensure zero stuck funds.



---

## Tech Stack

* **Language:** Solidity `0.8.29`
* **Framework:** Foundry (Forge)
* **Integrations:** Uniswap V2 Router, Chainlink Aggregators, OpenZeppelin.

---

## Installation & Testing

This project relies on **Foundry**. Ensure you have it installed.

```bash
# Clone the repo
git clone https://github.com/marutint10/payment-gateway.git
cd payment-gateway

# Install dependencies
forge install

# Run Unit Tests (V1 & V2)
forge test

# Run Fuzz Tests (1000 Runs)
forge test --mt testFuzz

# Run Invariant Tests (State Integrity)
forge test --mt invariant

```

### Checking Coverage

We maintain strict testing standards. To view coverage reports:

```bash
forge coverage

```

---

## Deployment

The project includes scripted deployments for both versions.

1. **Setup Environment:**
Create a `.env` file in the root directory:
```ini
PRIVATE_KEY=your_private_key
ROUTER_ADDRESS=0x...      # Uniswap V2 Router
USDT_ADDRESS=0x...        # USDT Contract Address
FEE_RECIPIENT=0x...       # Merchant Wallet
ETHERSCAN_API_KEY=...     # For verification

```


2. **Deploy V2 (Recommended):**
```bash
source .env
forge script script/DeployV2.s.sol:DeployPaymentGatewayV2 \
  --rpc-url https://rpc.sepolia.org \
  --broadcast \
  --verify

```

---

## Security

This codebase has undergone rigorous testing:

* **Solvency Check:** Verified that the merchant *always* receives the exact USDT amount expected.
* **Stuck Funds Check:** Verified via Invariant tests that the contract balance remains 0 after every transaction loop.
* **Mocking:** Custom "Smart Mocks" used to simulate realistic Uniswap pricing and failure modes.

---

**Built with ❤️ by Maruti Nandan Tiwari**