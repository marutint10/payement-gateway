// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

/// @title Payment Gateway
/// @notice Multi-chain payment settlement system with Oracle guards and MEV protection.
/// @dev Handles Native and ERC20 payments, auto-swapping to USDT.
contract PaymentGateway is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ---- Errors ----
    error ZeroAddr();
    error InvalidToken();
    error OracleDataStale();
    error InvalidRouter();
    error SwapFailed();
    error TokenDecimalsMissing();
    error PriceFeedMissing();
    error PriceFeedInvalid();
    error DeadlineExpired();
    error TokenNotWhitelisted();
    error InsufficientIn();
    error InsufficientETH();
    error RefundFailed();

    // ---- Config Structs ----
    struct TokenConfig {
        AggregatorV3Interface oracle;
        uint256 maxPriceAge; // Max age of price data in seconds
        uint16 slippageBps; // Basis points for slippage (e.g. 50 = 0.5%, 300 = 3%)
        uint8 decimals;
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
    event TokenConfigured(address indexed token, address indexed feed, uint16 slippageBps);
    event FeeRecipientSet(address indexed recipient);

    constructor(address _router, address _usdt, address _feeRecipient) Ownable(msg.sender) {
        if (_router == address(0) || _usdt == address(0) || _feeRecipient == address(0)) revert ZeroAddr();

        router = IUniswapV2Router02(_router);
        USDT = IERC20(_usdt);
        WNATIVE = IUniswapV2Router02(_router).WETH();
        feeRecipient = _feeRecipient;

        // Configure USDT as base supported token (0 slippage, direct transfer)
        (bool success, bytes memory data) = _usdt.staticcall(abi.encodeWithSignature("decimals()"));
        require(success, "USDT check failed");
        uint8 usdtDecs = abi.decode(data, (uint8));

        tokens[_usdt].decimals = usdtDecs;
        tokens[_usdt].isSupported = true;
    }

    // ---- ADMIN FUNCTIONS ----

    /// @notice Whitelist a token with specific risk parameters
    /// @param token The ERC20 token to accept
    /// @param feed Chainlink Aggregator address
    /// @param maxPriceAge Oracle maxPriceAge (e.g. 3600s)
    /// @param slippageBps Slippage tolerance in Basis Points (100 = 1%).
    function addSupportedToken(address token, address feed, uint256 maxPriceAge, uint16 slippageBps)
        external
        onlyOwner
    {
        if (token == address(0) || feed == address(0)) revert ZeroAddr();
        if (maxPriceAge == 0) revert OracleDataStale();

        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success) revert TokenDecimalsMissing();
        uint8 decimals = abi.decode(data, (uint8));

        tokens[token] = TokenConfig({
            oracle: AggregatorV3Interface(feed),
            maxPriceAge: maxPriceAge,
            slippageBps: slippageBps,
            decimals: decimals,
            isSupported: true
        });

        // NOTE: We do NOT approve infinite tokens here anymore.
        // Approval is handled Just-In-Time (JIT) in the swap function for security.

        emit TokenConfigured(token, feed, slippageBps);
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

    function pay(address payToken, uint256 usdAmount, uint256 invoiceId, uint256 deadline)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 usdtAmount = _convertCentsToUSDT(usdAmount);
        uint256 actualIn;

        if (payToken == address(0)) {
            // --- NATIVE (ETH/BNB) LOGIC ---
            TokenConfig memory config = tokens[WNATIVE];
            if (!config.isSupported) revert TokenNotWhitelisted();

            uint256 amountInMax = _getQuoteMax(usdAmount, config);
            if (msg.value < amountInMax) revert InsufficientETH();

            actualIn = _swapNativeToUSDT(amountInMax, usdtAmount, deadline);

            // Refund dust
            if (msg.value > actualIn) {
                (bool success,) = payable(msg.sender).call{value: msg.value - actualIn}("");
                if (!success) revert RefundFailed();
            }
        } else {
            // --- ERC20 LOGIC ---
            uint256 amountInMax;
            if (payToken == address(USDT)) {
                if (!tokens[payToken].isSupported) revert TokenNotWhitelisted();
                amountInMax = usdtAmount;
            } else {
                // For all other tokens, use Oracle to calculate max input
                TokenConfig memory config = tokens[payToken];
                if (!config.isSupported) revert TokenNotWhitelisted();
                amountInMax = _getQuoteMax(usdAmount, config);
            }
            // Transfer Max expected tokens to contract
            IERC20(payToken).safeTransferFrom(msg.sender, address(this), amountInMax);

            // Perform Swap
            actualIn = _swapToUSDT(payToken, amountInMax, usdtAmount, deadline);

            // Refund dust
            if (amountInMax > actualIn) {
                IERC20(payToken).safeTransfer(msg.sender, amountInMax - actualIn);
            }
        }

        emit PaymentProcessed(msg.sender, payToken, actualIn, usdtAmount, feeRecipient, invoiceId);
    }

    // ---- INTERNAL ENGINE ----

    function _swapToUSDT(address tokenIn, uint256 amountInMax, uint256 usdtAmount, uint256 deadline)
        internal
        returns (uint256 amountInUsed)
    {
        // Same asset
        if (tokenIn == address(USDT)) {
            IERC20(USDT).safeTransfer(feeRecipient, usdtAmount);
            return usdtAmount;
        }

        // Candidate paths
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = address(USDT);

        address[] memory viaNative;
        if (tokenIn == WNATIVE) {
            viaNative = new address[](2);
            viaNative[0] = WNATIVE;
            viaNative[1] = address(USDT);
        } else {
            viaNative = new address[](3);
            viaNative[0] = tokenIn;
            viaNative[1] = WNATIVE;
            viaNative[2] = address(USDT);
        }

        // Quote both paths (ignore reverts)
        uint256 directIn = type(uint256).max;
        uint256 viaIn = type(uint256).max;
        try router.getAmountsIn(usdtAmount, directPath) returns (uint256[] memory a) {
            directIn = a[0];
        } catch {}
        try router.getAmountsIn(usdtAmount, viaNative) returns (uint256[] memory b) {
            viaIn = b[0];
        } catch {}

        // Choose best available path
        address[] memory chosenPath;
        if (directIn <= viaIn) {
            // direct is cheaper or equal and available
            chosenPath = directPath;
        } else {
            // viaNative is cheaper or direct not available
            chosenPath = viaNative;
        }

        // Approve and execute swap
        IERC20(tokenIn).forceApprove(address(router), amountInMax);
        try router.swapTokensForExactTokens(usdtAmount, amountInMax, chosenPath, feeRecipient, deadline) returns (
            uint256[] memory amounts
        ) {
            amountInUsed = amounts[0];
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

    // ---- ORACLE ENGINE ----

    function quoteMaxInput(address payToken, uint256 usdAmountInCents) external view returns (uint256) {
        address target = payToken == address(0) ? WNATIVE : payToken;
        return _getQuoteMax(usdAmountInCents, tokens[target]);
    }

    function _getQuoteMax(uint256 usdAmount, TokenConfig memory config) internal view returns (uint256) {
        if (address(config.oracle) == address(0)) revert PriceFeedMissing();
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) = config.oracle.latestRoundData();

        if (price <= 0) revert PriceFeedInvalid();
        if (updatedAt == 0 || answeredInRound < roundId) revert OracleDataStale();
        if (block.timestamp > updatedAt + config.maxPriceAge) revert OracleDataStale();

        uint256 usdScaled = usdAmount * 1e16;
        uint256 priceUint = uint256(price);
        uint8 feedDecs = config.oracle.decimals();

        uint256 baseAmount;
        uint256 numerator = usdScaled * (10 ** config.decimals);
        uint256 denominator = priceUint;

        if (feedDecs <= 18) {
            denominator = denominator * (10 ** (18 - feedDecs));
        } else {
            numerator = numerator * (10 ** (feedDecs - 18));
        }

        baseAmount = numerator / denominator;

        return (baseAmount * (10000 + config.slippageBps)) / 10000;
    }

    function _convertCentsToUSDT(uint256 usdAmount) internal view returns (uint256) {
        uint8 dec = tokens[address(USDT)].decimals;
        return (usdAmount * (10 ** dec)) / 100;
    }

    function rescueTokens(address token, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    function rescueNative(address to) external onlyOwner {
        (bool s,) = payable(to).call{value: address(this).balance}("");
        require(s);
    }

    receive() external payable {}
}
