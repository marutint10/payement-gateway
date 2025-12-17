// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockUniswapV2Router02} from "./mocks/MockUniswapV2Router02.sol";
import {MockUniswapV2Factory} from "./mocks/MockUniswapV2Factory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PayementGatewayV2} from "../src/PayementGatewayV2.sol";

contract PaymentGatewayTest is Test {
    PayementGatewayV2 public gateway;
    MockUniswapV2Router02 public router;
    MockUniswapV2Factory public factory;
    MockERC20 public usdt;
    MockERC20 public dai;
    MockWETH public weth;

    address public feeRecipient = makeAddr("feeRecipient");
    address public user = makeAddr("user");

    function setUp() public {
        usdt = new MockERC20("USDT", "USDT", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        weth = new MockWETH();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(address(weth), address(factory));

        router.setPrice(address(dai), 1e8);      // $1
        router.setPrice(address(usdt), 1e8);     // $1
        router.setPrice(address(weth), 2000e8);  // $2000
        
        // 2. Fund Router with USDT (Liquidity)
        usdt.mint(address(router), 1_000_000_000e6); 

        gateway = new PayementGatewayV2(address(router), address(usdt), feeRecipient);

        // 3. Add Tokens with Slippage Config
        // WETH: 0.2% Slippage
        gateway.addSupportedToken(address(weth), address(0), 20); 
        // DAI: 0.5% Slippage
        gateway.addSupportedToken(address(dai), address(0), 50);
    }

    function test_pay_DAI() public {
        uint256 usdAmount = 100e2; // $100.00

        uint256 daiQuote = gateway.getQuote(address(dai), usdAmount);
        dai.mint(user, daiQuote);

        vm.startPrank(user);
        dai.approve(address(gateway), daiQuote);

        uint256 feeRecipientBalBefore = usdt.balanceOf(feeRecipient);
        console.log("Fee Recipient USDT Balance Before:", feeRecipientBalBefore);

        //  function pay(address payToken, uint256 usdAmount, uint256 maxTokenIn, uint256 invoiceId, uint256 deadline
        gateway.pay(address(dai), usdAmount, daiQuote, 1, block.timestamp+1);
        vm.stopPrank();

        uint256 feeRecipientBalAfter = usdt.balanceOf(feeRecipient);
        console.log("Fee Recipient USDT Balance After:", feeRecipientBalAfter);
        assertEq(feeRecipientBalAfter - feeRecipientBalBefore, 100e6); // $100 in USDT (6 decimals)
    }

    function test_pay_ETH() public {
        vm.deal(user, 1 ether);
        uint256 usdAmount = 100e2; // $100.00

        uint256 wethQuote = gateway.getQuote(address(0), usdAmount);
        vm.startPrank(user);
        uint256 feeRecipientBalBefore = usdt.balanceOf(feeRecipient);
        console.log("Fee Recipient USDT Balance Before:", feeRecipientBalBefore);

        gateway.pay{value: wethQuote}(address(0), usdAmount, wethQuote, 1, block.timestamp+1);
        vm.stopPrank();
        uint256 feeRecipientBalAfter = usdt.balanceOf(feeRecipient);
        console.log("Fee Recipient USDT Balance After:", feeRecipientBalAfter);
        assertEq(feeRecipientBalAfter - feeRecipientBalBefore, 100e6); // $100 in USDT (6 decimals)
    }

    function test_pay_DAI_WithRefund() public {
        uint256 usdAmount = 100e2; // $100.00
        
        // 1. Get Quote (Includes 0.5% Buffer)
        // Mock Math: 100 USDT -> Needs 100.3 DAI (0.3% fee)
        // Buffer: 100.3 * 1.005 = ~100.8 DAI Quote
        uint256 daiQuote = gateway.getQuote(address(dai), usdAmount);

        // 2. Setup User
        dai.mint(user, daiQuote);
        vm.startPrank(user);
        dai.approve(address(gateway), daiQuote);

        // 3. Pay
        gateway.pay(address(dai), usdAmount, daiQuote, 1, block.timestamp + 1);
        vm.stopPrank();

        // 4. CHECK 1: Merchant got paid
        assertEq(usdt.balanceOf(feeRecipient), 100e6, "Merchant did not get USDT");

        // 5. CHECK 2: Refund Logic (Crucial!)
        // User sent ~100.8 DAI. Router only used ~100.3 DAI.
        // User should have ~0.5 DAI left in their wallet.
        uint256 userBalanceAfter = dai.balanceOf(user);
        console.log("User Refunded Amount:", userBalanceAfter);
        
        assertTrue(userBalanceAfter > 0, "No refund received");
        // Ensure the contract didn't keep it
        assertEq(dai.balanceOf(address(gateway)), 0, "Gateway kept dust");
    }

    function test_pay_ETH_WithRefund() public {
        uint256 usdAmount = 100e2; // $100.00
        uint256 wethQuote = gateway.getQuote(address(0), usdAmount);
        
        // Give user slightly MORE than quote to test strict ETH refunding too
        uint256 sentAmount = wethQuote + 0.1 ether;
        vm.deal(user, sentAmount);

        vm.startPrank(user);
        uint256 userEthBefore = user.balance;

        gateway.pay{value: sentAmount}(address(0), usdAmount, wethQuote, 1, block.timestamp + 1);
        vm.stopPrank();

        // CHECK: Refund
        // Used: ~0.05 ETH. Sent: ~0.15 ETH. Refund should be ~0.1 ETH.
        uint256 userEthAfter = user.balance;
        uint256 totalUsed = userEthBefore - userEthAfter;
        
        console.log("ETH Actually Used:", totalUsed);
        // Should be roughly 0.05 ETH (approx $100)
        // Verification: $100 / $2000 = 0.05 ETH. 
        // Allow small delta for fees
        assertApproxEqAbs(totalUsed, 0.05 ether + 0.0002 ether, 0.0005 ether); 
    }

    function test_pay_USDT_Exact() public {
        // USDT checks allow 0 slippage logic usually, or just direct transfer
        uint256 usdAmount = 100e2; // $100.00
        uint256 exactAmount = 100e6; 

        usdt.mint(user, exactAmount);

        vm.startPrank(user);
        usdt.approve(address(gateway), exactAmount);
        
        // MaxTokenIn = Exact Amount because 1 USD = 1 USDT
        gateway.pay(address(usdt), usdAmount, exactAmount, 1, block.timestamp + 1);
        vm.stopPrank();

        assertEq(usdt.balanceOf(feeRecipient), 100e6);
    }

    function test_Revert_SlippageExceeded() public {
        uint256 usdAmount = 100e2; 
        uint256 realQuote = gateway.getQuote(address(dai), usdAmount);

        // Scenario: User opens frontend, sees quote of 100 DAI.
        // While approving, price crashes. New quote is 150 DAI.
        // User sends tx with maxTokenIn = 110 DAI.
        
        uint256 userMaxLimit = realQuote - 1 ether; // User sets limit LOWER than current need

        vm.startPrank(user);
        
        // Expect specific error
        vm.expectRevert(
            abi.encodeWithSelector(
                PayementGatewayV2.SlippageExceeded.selector, 
                realQuote,   // Needed
                userMaxLimit // Allowed
            )
        );
        
        gateway.pay(address(dai), usdAmount, userMaxLimit, 1, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_Revert_DeadlineExpired() public {
        uint256 usdAmount = 100e2;
        uint256 quote = gateway.getQuote(address(dai), usdAmount);

        vm.startPrank(user);
        vm.warp(2000); // Advance time
        
        vm.expectRevert(PayementGatewayV2.DeadlineExpired.selector);
        // Deadline is in the past (1999)
        gateway.pay(address(dai), usdAmount, quote, 1, 1999);
        vm.stopPrank();
    }

    function test_PrintQuotes() public view {
        console.log("--- QUOTES FOR $100 ---");
        console.log("DAI:", gateway.getQuote(address(dai), 100e2));
        console.log("ETH:", gateway.getQuote(address(0), 100e2));
    }

    function test_Admin_AllFunctions() public {
        // 1. Remove Token
        gateway.removeSupportedToken(address(dai));
        (,, bool isSupported) = gateway.tokens(address(dai));
        assertFalse(isSupported);

        // 2. Set Fee Recipient
        address newRecipient = makeAddr("newRecipient");
        gateway.setFeeRecipient(newRecipient);
        assertEq(gateway.feeRecipient(), newRecipient);
        
        // 3. Revert: Set Fee Recipient to Zero
        vm.expectRevert(PayementGatewayV2.ZeroAddr.selector);
        gateway.setFeeRecipient(address(0));

        // 4. Revert: Add Zero Address Token
        vm.expectRevert(PayementGatewayV2.ZeroAddr.selector);
        gateway.addSupportedToken(address(0), address(0), 50);
    }

    function test_Admin_Rescue() public {
        address user2 = makeAddr("makeAddr");
        // Rescue Native
        vm.deal(address(gateway), 1 ether);
        uint256 ownerEthBefore = address(user2).balance;
        vm.prank(gateway.owner());
        gateway.rescueNative(user2);
        assertEq(address(user2).balance, ownerEthBefore + 1 ether);

        dai.mint(address(gateway), 1000e18);
        uint256 ownerDaiBefore = dai.balanceOf(address(user2));
        vm.prank(gateway.owner());
        gateway.rescueTokens(address(dai), address(user2));
        assertEq(dai.balanceOf(address(user2)), ownerDaiBefore + 1000e18);
    }

    function test_Pay_With_Intermediate_Path() public {
        // Scenario: Pay with BTC, which routes BTC -> WETH -> USDT
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        wbtc.mint(user, 1e8); // 1 BTC

        // Configure WBTC to route via WETH
        gateway.addSupportedToken(address(wbtc), address(weth), 50);

        // Mock Prices: BTC = $50,000. WETH = $2000. USDT = $1.
        router.setPrice(address(wbtc), 50_000e8);
        
        // Frontend Quote for $100 payment
        // $100 = 0.002 BTC. 
        uint256 quote = gateway.getQuote(address(wbtc), 100e2);
        
        vm.startPrank(user);
        wbtc.approve(address(gateway), quote);
        
        // This triggers the 'else' block in _getUniswapQuote and _swapToUSDT
        // creating the `path = [WBTC, WETH, USDT]` array
        gateway.pay(address(wbtc), 100e2, quote, 1, block.timestamp);
        vm.stopPrank();

        assertEq(usdt.balanceOf(feeRecipient), 100e6);
    }

    function test_Revert_NoLiquidity() public {
        // We simulate a Router error during 'getAmountsIn'
        // This hits the 'catch { revert NoLiquidity(); }' block
        
        // Create a fake token with no price data in Mock Router
        MockERC20 junk = new MockERC20("JUNK", "JUNK", 18);
        gateway.addSupportedToken(address(junk), address(0), 50);

        // Mock the Router to REVERT when asked for price
        vm.mockCallRevert(
            address(router),
            abi.encodeWithSelector(router.getAmountsIn.selector),
            "Uniswap: PAIR_NOT_FOUND"
        );

        vm.expectRevert(PayementGatewayV2.NoLiquidity.selector);
        gateway.getQuote(address(junk), 100e2);
    }
}