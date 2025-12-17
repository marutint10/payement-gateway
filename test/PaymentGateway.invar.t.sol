// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol"; // Required for Invariants
import {PaymentGateway} from "../src/PaymentGateway.sol";
import {Handler} from "./handlers/Handler.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockUniswapV2Router02} from "./mocks/MockUniswapV2Router02.sol";
import {MockUniswapV2Factory} from "./mocks/MockUniswapV2Factory.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

contract PaymentGatewayInvariantTest is StdInvariant, Test {
    PaymentGateway public gateway;
    Handler public handler;
    
    // Mocks
    MockUniswapV2Router02 public router;
    MockUniswapV2Factory public factory;
    MockERC20 public usdt;
    MockERC20 public dai;
    MockWETH public weth;
    MockV3Aggregator public ethOracle;
    MockV3Aggregator public daiOracle;

    address public feeRecipient = makeAddr("feeRecipient");
    address public user = makeAddr("user");

    function setUp() public {
        // --- 1. Standard Deploy Setup (Same as Unit Test) ---
        usdt = new MockERC20("USDT", "USDT", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        weth = new MockWETH();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(address(weth), address(factory));
        
        // Huge liquidity for Router so it never runs dry during random sequence
        usdt.mint(address(router), 1_000_000_000e6); 

        ethOracle = new MockV3Aggregator(8, 2000e8);
        daiOracle = new MockV3Aggregator(8, 1e8); 

        gateway = new PaymentGateway(address(router), address(usdt), feeRecipient);
        
        gateway.addSupportedToken(address(weth), address(ethOracle), 3600, 20);
        gateway.addSupportedToken(address(dai), address(daiOracle), 3600, 50);

        // --- 2. Handler Setup ---
        handler = new Handler(gateway, usdt, dai, user);

        // --- 3. Tell Foundry to use the Handler ---
        targetContract(address(handler));
    }

    // --- INVARIANT 1: No Stuck Funds ---
    // The Gateway should NEVER hold DAI. It should always swap it or refund it.
    function invariant_Protocol_NoStuckDAI() public view {
        assertEq(dai.balanceOf(address(gateway)), 0, "Gateway stuck with DAI balance");
    }

    // The Gateway should NEVER hold USDT. It should always forward it to feeRecipient.
    function invariant_Protocol_NoStuckUSDT() public view {
        assertEq(usdt.balanceOf(address(gateway)), 0, "Gateway stuck with USDT balance");
    }

    // --- INVARIANT 2: Solvency / Integrity ---
    // The amount in the FeeRecipient wallet MUST match the sum of all successful payments.
    function invariant_Protocol_FeeRecipientSolvency() public view {
        assertEq(
            usdt.balanceOf(feeRecipient), 
            handler.ghost_expectedUSDT(), 
            "Fee Recipient balance does not match total payment volume"
        );
    }
}