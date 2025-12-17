// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract MockUniswapV2Router02 {
    address public immutable WETH;
    address public immutable factory;

    // Mapping to simulate price: Token => Price in USD (scaled by 8 decimals)
    // Example: ETH = 2000e8 ($2000), DAI = 1e8 ($1)
    mapping(address => uint256) public tokenPrices;
    
    constructor(address _WETH, address _factory) {
        WETH = _WETH;
        factory = _factory;
        // Default prices
        tokenPrices[_WETH] = 2000e8; // $2000
    }

    function setPrice(address token, uint256 priceUSD) external {
        tokenPrices[token] = priceUSD;
    }

    // ---- CALCULATION LOGIC ----

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut; // This is usually USDT

        // We only care about the first token (Input) and last token (Output/USDT) for this mock
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        // 1. Get Decimals
        uint8 decIn = IERC20Metadata(tokenIn).decimals();
        uint8 decOut = IERC20Metadata(tokenOut).decimals();

        // 2. Get Prices (Default to $1 if not set)
        uint256 priceIn = tokenPrices[tokenIn] == 0 ? 1e8 : tokenPrices[tokenIn];
        uint256 priceOut = tokenPrices[tokenOut] == 0 ? 1e8 : tokenPrices[tokenOut];

        // 3. Calculate Exchange Rate
        // Formula: AmountIn = (AmountOut * PriceOut / DecOutScale) / (PriceIn / DecInScale)
        // Simplified: AmountIn = AmountOut * PriceOut * (10^DecIn) / (PriceIn * 10^DecOut)
        
        uint256 numerator = amountOut * priceOut * (10**decIn);
        uint256 denominator = priceIn * (10**decOut);
        
        uint256 calculatedIn = numerator / denominator;

        // Add 0.3% Uniswap Fee simulation
        amounts[0] = (calculatedIn * 1003) / 1000;
    }

    // ---- SWAP LOGIC ----

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "EXPIRED");

        // 1. Calculate how much we ACTUALLY need (re-use getAmountsIn logic)
        amounts = this.getAmountsIn(amountOut, path);
        uint256 amountNeeded = amounts[0];

        require(amountNeeded <= amountInMax, "Mock: Slippage Revert");

        // 2. Transfer Tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountNeeded);
        IERC20(path[path.length - 1]).transfer(to, amountOut);
    }

    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        require(deadline >= block.timestamp, "EXPIRED");
        require(path[0] == WETH, "INVALID_PATH");

        amounts = this.getAmountsIn(amountOut, path);
        uint256 amountNeeded = amounts[0];
        
        require(msg.value >= amountNeeded, "Mock: Insufficient ETH sent");

        // Transfer output token
        IERC20(path[path.length - 1]).transfer(to, amountOut);
        
        // Refund ETH if msg.value > amountNeeded? 
        // In real Uniswap, Router refunds. In this mock, we just keep it simple or implement refund.
        if (msg.value > amountNeeded) {
            (bool success,) = msg.sender.call{value: msg.value - amountNeeded}("");
            require(success, "Refund failed");
        }
    }
    
    // Stub for compilation
    receive() external payable {}
}