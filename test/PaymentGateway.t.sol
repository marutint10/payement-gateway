// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {PaymentGateway} from "../src/PaymentGateway.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockUniswapV2Router02} from "./mocks/MockUniswapV2Router02.sol";
import {MockUniswapV2Factory} from "./mocks/MockUniswapV2Factory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PaymentGatewayTest is Test {
    PaymentGateway public gateway;
    MockUniswapV2Router02 public router;
    MockUniswapV2Factory public factory;
    MockERC20 public usdt;
    MockERC20 public dai;
    MockWETH public weth;
    MockV3Aggregator public ethOracle;
    MockV3Aggregator public daiOracle; // Renamed for clarity

    address public owner;
    address public feeRecipient;
    address public user;

    // Events for checking
    event PaymentProcessed(
        address indexed payer,
        address indexed payToken,
        uint256 amountIn,
        uint256 usdtOut,
        address indexed merchant,
        uint256 invoiceId
    );
    event TokenConfigured(address indexed token, address indexed feed, uint16 slippageBps);

    function setUp() public {
        owner = address(this);
        feeRecipient = makeAddr("feeRecipient");
        user = makeAddr("user");

        // 1. Deploy Mocks
        usdt = new MockERC20("USDT", "USDT", 6); // Real USDT has 6 decimals
        dai = new MockERC20("DAI", "DAI", 18);
        weth = new MockWETH();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(address(weth), address(factory));

        // 2. Oracles (8 decimals standard for Chainlink USD feeds)
        ethOracle = new MockV3Aggregator(8, 2000e8); // $2000
        daiOracle = new MockV3Aggregator(8, 1e8); // $1

        // 3. Deploy Gateway
        gateway = new PaymentGateway(address(router), address(usdt), feeRecipient);

        // 4. Config & Funding
        usdt.mint(address(router), 1_000_000e6); // Router liquidity
        dai.mint(user, 1_000_000_000e18); // 1 Billion DAI
        usdt.mint(user, 1_000_000_000e6); // 1 Billion USDT
        vm.deal(user, 100 ether);

        // Add supported tokens by default for most tests
        gateway.addSupportedToken(address(weth), address(ethOracle), 3600, 20);
        gateway.addSupportedToken(address(dai), address(daiOracle), 3600, 50);
    }

    function test_Admin_AddSupportedToken() public view {
        (, uint256 maxAge, uint256 slippageBps,, bool isSupported) = gateway.tokens(address(dai));
        assertEq(maxAge, 3600);
        assertEq(slippageBps, 50);
        assertTrue(isSupported);
    }

    function test_Admin_AddSupportedToken_Event() public {
        vm.expectEmit(true, true, false, true);
        emit TokenConfigured(address(dai), address(daiOracle), 50);

        // Re-add to trigger event
        gateway.addSupportedToken(address(dai), address(daiOracle), 3600, 50);

        (,,,, bool isSupported) = gateway.tokens(address(dai));
        assertTrue(isSupported);
    }

    function test_Admin_RemoveToken() public {
        gateway.removeSupportedToken(address(dai));
        (,,,, bool isSupported) = gateway.tokens(address(dai));
        assertFalse(isSupported);
    }

    function test_Admin_RescueTokens() public {
        // Send random tokens to contract
        dai.mint(address(gateway), 1000e18);

        uint256 ownerBalanceBefore = dai.balanceOf(address(this));
        gateway.rescueTokens(address(dai), address(this));

        assertEq(dai.balanceOf(address(this)), ownerBalanceBefore + 1000e18);
    }

    function test_Admin_RescueNative() public {
        vm.deal(address(gateway), 5 ether);

        uint256 recipientBalBefore = feeRecipient.balance;
        gateway.rescueNative(feeRecipient);

        assertEq(feeRecipient.balance, recipientBalBefore + 5 ether);
    }

    // Coverage for receive() fallback
    function test_ReceiveFallback() public {
        (bool success,) = address(gateway).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(gateway).balance, 1 ether);
    }

    function test_Oracle_StalePrice() public {
        // Warp time forward past maxPriceAge (3600s)
        // Set update time to now, then warp 3601 seconds
        ethOracle.updateRoundData(1, 2000e8, block.timestamp, block.timestamp);

        vm.warp(block.timestamp + 3601);

        uint256 usdAmount = 100e2; // $100

        vm.expectRevert(PaymentGateway.OracleDataStale.selector);
        gateway.quoteMaxInput(address(weth), usdAmount);
    }

    function test_Oracle_NegativePrice() public {
        ethOracle.updateAnswer(-100);
        vm.expectRevert(PaymentGateway.PriceFeedInvalid.selector);
        gateway.quoteMaxInput(address(weth), 100);
    }

    function test_Pay_USDT_Directly() public {
        // Paying in USDT (Same as base asset)
        uint256 usdAmount = 100e2; // $100
        uint256 expectedUSDT = 100e6; // 100 USDT (6 decimals)

        vm.startPrank(user);
        usdt.approve(address(gateway), expectedUSDT);

        vm.expectEmit(true, true, true, true);
        emit PaymentProcessed(user, address(usdt), expectedUSDT, expectedUSDT, feeRecipient, 1);

        gateway.pay(address(usdt), usdAmount, 1, block.timestamp);
        vm.stopPrank();

        assertEq(usdt.balanceOf(feeRecipient), expectedUSDT);
    }

    function testFuzz_Pay_ERC20(uint96 _usdAmount) public {
        // Fuzzing with random amounts
        vm.assume(_usdAmount > 100 && _usdAmount < 10_000e2); // Between $1 and $10k

        uint256 maxInput = gateway.quoteMaxInput(address(dai), _usdAmount);

        vm.startPrank(user);
        dai.approve(address(gateway), maxInput);
        gateway.pay(address(dai), _usdAmount, 99, block.timestamp);
        vm.stopPrank();

        // Check if fee recipient got the USDT
        // (Note: math conversion in contract)
        uint256 expectedUSDT = (_usdAmount * 1e6) / 100;
        assertEq(usdt.balanceOf(feeRecipient), expectedUSDT);
    }

    // Covers the branch: if (amountInMax > actualIn) refund
    function test_Pay_Refund_Dust_ERC20() public {
        uint256 usdAmount = 100e2;
        uint256 maxInput = gateway.quoteMaxInput(address(dai), usdAmount);

        // Mock the router to return a slightly better rate than oracle predicted
        // so actualIn < amountInMax
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdt);

        // We force the router to say it only needed (maxInput - 100) to get the USDT
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = maxInput - 1e18; // Used 1 less DAI
        amounts[1] = 100e6;

        vm.mockCall(
            address(router), abi.encodeWithSelector(router.swapTokensForExactTokens.selector), abi.encode(amounts)
        );

        vm.startPrank(user);
        dai.approve(address(gateway), maxInput);

        uint256 balBefore = dai.balanceOf(user);
        gateway.pay(address(dai), usdAmount, 1, block.timestamp);
        uint256 balAfter = dai.balanceOf(user);
        vm.stopPrank();

        // User should have spent (maxInput - 1e18), meaning they got 1e18 refund back relative to approval
        assertEq(balBefore - balAfter, maxInput - 1e18);
    }

    // Covers the try/catch blocks in _swapToUSDT
    function test_Swap_Path_Selection_Direct_Fails() public {
        // Scenario: Direct path (Token -> USDT) fails estimation,
        // forcing the code into the empty catch block and moving to check viaNative.

        uint256 usdAmount = 100e2;
        uint256 usdtAmount = 100e6;

        // 1. Mock getAmountsIn for Direct path to REVERT
        address[] memory directPath = new address[](2);
        directPath[0] = address(dai);
        directPath[1] = address(usdt);

        vm.mockCallRevert(
            address(router),
            abi.encodeWithSelector(router.getAmountsIn.selector, usdtAmount, directPath),
            "Route unavailable"
        );

        // 2. Mock getAmountsIn for viaNative path to SUCCEED
        address[] memory viaNative = new address[](3);
        viaNative[0] = address(dai);
        viaNative[1] = address(weth);
        viaNative[2] = address(usdt);

        uint256[] memory successAmounts = new uint256[](3);
        successAmounts[0] = 100e18; // 100 DAI

        vm.mockCall(
            address(router),
            abi.encodeWithSelector(router.getAmountsIn.selector, usdtAmount, viaNative),
            abi.encode(successAmounts)
        );

        // 3. Mock the actual swap execution to succeed
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(router.swapTokensForExactTokens.selector),
            abi.encode(successAmounts)
        );

        vm.startPrank(user);
        dai.approve(address(gateway), 200e18); // Approve plenty
        gateway.pay(address(dai), usdAmount, 1, block.timestamp);
        vm.stopPrank();
    }

    // Covers: _swapToUSDT final revert SwapFailed()
    function test_Swap_Execution_Fails() public {
        uint256 usdAmount = 100e2;

        // Force the actual swap call to revert
        vm.mockCallRevert(
            address(router), abi.encodeWithSelector(router.swapTokensForExactTokens.selector), "Uniswap Failed"
        );

        vm.startPrank(user);
        dai.approve(address(gateway), type(uint256).max);

        vm.expectRevert(PaymentGateway.SwapFailed.selector);
        gateway.pay(address(dai), usdAmount, 1, block.timestamp);
        vm.stopPrank();
    }

    function test_Pay_Native_Insufficient() public {
        uint256 usdAmount = 100e2;
        uint256 maxInput = gateway.quoteMaxInput(address(weth), usdAmount);

        vm.startPrank(user);
        vm.expectRevert(PaymentGateway.InsufficientETH.selector);
        gateway.pay{value: maxInput - 1}(address(0), usdAmount, 1, block.timestamp);
        vm.stopPrank();
    }

    function test_rescueTokens_onlyOwner_transfersAll() public {
        // Arrange: put tokens inside the gateway
        uint256 amount = 1234e18;
        dai.mint(address(gateway), amount);

        uint256 toBefore = dai.balanceOf(feeRecipient);
        uint256 gwBefore = dai.balanceOf(address(gateway));
        assertEq(gwBefore, amount);

        // Act: owner rescues
        gateway.rescueTokens(address(dai), feeRecipient);

        // Assert: gateway emptied, recipient got all
        assertEq(dai.balanceOf(address(gateway)), 0);
        assertEq(dai.balanceOf(feeRecipient), toBefore + amount);
    }

    function test_rescueNative_onlyOwner_transfersAll() public {
        // Arrange: fund gateway with ETH
        uint256 amount = 2 ether;
        vm.deal(address(this), 10 ether);
        (bool ok,) = payable(address(gateway)).call{value: amount}("");
        require(ok, "funding gateway failed");

        uint256 toBefore = feeRecipient.balance;
        assertEq(address(gateway).balance, amount);

        // Act
        gateway.rescueNative(feeRecipient);

        // Assert
        assertEq(address(gateway).balance, 0);
        assertEq(feeRecipient.balance, toBefore + amount);
    }
}
