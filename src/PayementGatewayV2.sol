// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

/// @title Uniswap-Native Payment Gateway V2
/// @notice Settlement via Uniswap V2 Liquidity Pools with Slippage Protection.
contract PayementGatewayV2 is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ---- Errors ----
    error ZeroAddr();
    error InvalidToken();
    error SwapFailed();
    error TokenDecimalsMissing();
    error DeadlineExpired();
    error TokenNotWhitelisted();
    error InsufficientIn(); 
    error SlippageExceeded(uint256 needed, uint256 maxAllowed); // New Error
    error InsufficientETH();
    error RefundFailed();
    error NoLiquidity();

    // ---- Config Structs ----
    struct TokenConfig {
        address intermediateToken; // e.g. WETH. Use address(0) for direct pairs (Token->USDT)
        uint16 defaultSlippageBps; // Suggested buffer (e.g. 50 = 0.5%)
        bool isSupported;
    }

    // ---- State ----
    IERC20 public immutable USDT;
    IUniswapV2Router02 public router;
    address public immutable WNATIVE;
    address public feeRecipient;

    // Token Address => Configuration
    mapping(address => TokenConfig) public tokens;

    // ---- Events ----
    event PaymentProcessed(
        address indexed payer,
        address indexed payToken,
        uint256 amountIn,
        uint256 usdtOut,
        address indexed merchant,
        uint256 invoiceId
    );
    event TokenConfigured(address indexed token, uint16 slippageBps);
    event FeeRecipientSet(address indexed recipient);

    constructor(address _router, address _usdt, address _feeRecipient) Ownable(msg.sender) {
        if (_router == address(0) || _usdt == address(0) || _feeRecipient == address(0)) revert ZeroAddr();

        router = IUniswapV2Router02(_router);
        USDT = IERC20(_usdt);
        WNATIVE = IUniswapV2Router02(_router).WETH();
        feeRecipient = _feeRecipient;

        // Configure USDT base support
        tokens[_usdt].isSupported = true;
    }

    // ---- ADMIN FUNCTIONS ----

    function addSupportedToken(address token, address intermediate, uint16 slippageBps) external onlyOwner {
        if (token == address(0)) revert ZeroAddr();
        tokens[token] = TokenConfig({
            intermediateToken: intermediate, 
            defaultSlippageBps: slippageBps, 
            isSupported: true
        });
        emit TokenConfigured(token, slippageBps);
    }

    function removeSupportedToken(address token) external onlyOwner {
        delete tokens[token];
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddr();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    // ---- CORE PAYMENT LOGIC ----

    /// @notice Pay an invoice using Uniswap Spot Price
    /// @param payToken Address of token to pay with
    /// @param usdAmount Invoice amount in USD cents (e.g. 1000 = $10.00)
    /// @param maxTokenIn MAX tokens user is willing to spend (Protects against price spikes)
    /// @param invoiceId Metadata
    /// @param deadline Uniswap deadline
    function pay(
        address payToken,
        uint256 usdAmount,
        uint256 maxTokenIn,
        uint256 invoiceId,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 usdtAmount = _convertCentsToUSDT(usdAmount);
        uint256 actualIn;

        // --- OPTIMIZATION: PAY WITH USDT ---
        if (payToken == address(USDT)) {
             if (!tokens[payToken].isSupported) revert TokenNotWhitelisted();
             // Direct transfer, no swap needed
             // Check if user allowed enough (sanity check)
             if (usdtAmount > maxTokenIn) revert SlippageExceeded(usdtAmount, maxTokenIn);
             
             IERC20(USDT).safeTransferFrom(msg.sender, feeRecipient, usdtAmount);
             actualIn = usdtAmount;
        }
        // --- NATIVE (ETH/BNB) LOGIC ---
        else if (payToken == address(0)) {
            TokenConfig memory config = tokens[WNATIVE];
            if (!config.isSupported) revert TokenNotWhitelisted();

            // 1. Get Quote
            uint256 amountNeeded = _getUniswapQuote(WNATIVE, usdtAmount, config);

            // 2. Safety Check (User protection)
            if (amountNeeded > maxTokenIn) revert SlippageExceeded(amountNeeded, maxTokenIn);
            if (msg.value < amountNeeded) revert InsufficientETH();

            // 3. Swap
            actualIn = _swapNativeToUSDT(amountNeeded, usdtAmount, deadline);

            // 4. Refund
            if (msg.value > actualIn) {
                (bool success,) = payable(msg.sender).call{value: msg.value - actualIn}("");
                if (!success) revert RefundFailed();
            }
        } 
        // --- ERC20 LOGIC ---
        else {
            TokenConfig memory config = tokens[payToken];
            if (!config.isSupported) revert TokenNotWhitelisted();

            // 1. Get Quote
            uint256 amountNeeded = _getUniswapQuote(payToken, usdtAmount, config);

            // 2. Safety Check (User protection)
            if (amountNeeded > maxTokenIn) revert SlippageExceeded(amountNeeded, maxTokenIn);

            // 3. Transfer Exact Needed
            IERC20(payToken).safeTransferFrom(msg.sender, address(this), amountNeeded);

            // 4. Swap
            actualIn = _swapToUSDT(payToken, amountNeeded, usdtAmount, deadline, config);

            // 5. Refund (If positive slippage occurred)
            if (amountNeeded > actualIn) {
                IERC20(payToken).safeTransfer(msg.sender, amountNeeded - actualIn);
            }
        }

        emit PaymentProcessed(msg.sender, payToken, actualIn, usdtAmount, feeRecipient, invoiceId);
    }

    function _getUniswapQuote(address tokenIn, uint256 usdtOut, TokenConfig memory config)
        internal
        view
        returns (uint256 amountInMax)
    {
        // Construct Path
        address[] memory path;
        if (config.intermediateToken == address(0)) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = address(USDT);
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = config.intermediateToken;
            path[2] = address(USDT);
        }

        try router.getAmountsIn(usdtOut, path) returns (uint256[] memory amounts) {
            uint256 spotAmount = amounts[0];
            // Add slippage buffer for the transfer amount
            amountInMax = (spotAmount * (10000 + config.defaultSlippageBps)) / 10000;
        } catch {
            revert NoLiquidity();
        }
    }

    function _swapToUSDT(
        address tokenIn,
        uint256 amountInMax,
        uint256 usdtAmount,
        uint256 deadline,
        TokenConfig memory config
    ) internal returns (uint256 amountInUsed) {
        
        address[] memory path;
        if (config.intermediateToken == address(0)) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = address(USDT);
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = config.intermediateToken;
            path[2] = address(USDT);
        }

        // Approve Router to spend tokens
        IERC20(tokenIn).forceApprove(address(router), amountInMax);

        // Swap Tokens for Exact USDT
        try router.swapTokensForExactTokens(usdtAmount, amountInMax, path, feeRecipient, deadline) returns (
            uint256[] memory amounts
        ) {
            amountInUsed = amounts[0]; // The actual amount of input tokens used
        } catch {
            IERC20(tokenIn).forceApprove(address(router), 0);
            revert SwapFailed();
        }
        
        IERC20(tokenIn).forceApprove(address(router), 0);
    }

    function _swapNativeToUSDT(uint256 amountInMax, uint256 usdtAmount, uint256 deadline)
        internal
        returns (uint256 amountInUsed)
    {
        address[] memory path = new address[](2);
        path[0] = WNATIVE;
        path[1] = address(USDT);

        try router.swapETHForExactTokens{value: amountInMax}(usdtAmount, path, feeRecipient, deadline) returns (
            uint256[] memory amounts
        ) {
            amountInUsed = amounts[0];
        } catch {
            revert SwapFailed();
        }
    }

    function _convertCentsToUSDT(uint256 usdAmount) internal view returns (uint256) {
        uint8 dec = IERC20Metadata(address(USDT)).decimals(); 
        return (usdAmount * (10 ** dec)) / 100;
    }

    // ---- FRONTEND HELPER ----

    /// @notice Returns the ESTIMATED input required.
    /// @dev Frontend should call this, then add a small user-buffer (e.g. +1%) 
    ///      and pass that as 'maxTokenIn' to the pay() function.
    function getQuote(address payToken, uint256 usdAmount) external view returns (uint256 expectedInput) {
        address target = payToken == address(0) ? WNATIVE : payToken;
        TokenConfig memory config = tokens[target];
        if (!config.isSupported) revert TokenNotWhitelisted();

        uint256 usdtAmount = _convertCentsToUSDT(usdAmount);
        
        // Return the quote including the default contract slippage buffer
        return _getUniswapQuote(target, usdtAmount, config);
    }

    // ---- SAFETY ----
    function rescueTokens(address token, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    function rescueNative(address to) external onlyOwner {
        (bool s,) = payable(to).call{value: address(this).balance}("");
        require(s);
    }

    receive() external payable {}
}