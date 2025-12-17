// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {PaymentGateway} from "../../src/PaymentGateway.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract Handler is Test {
    PaymentGateway public gateway;
    MockERC20 public usdt;
    MockERC20 public dai;
    
    address public user;

    uint256 public ghost_expectedUSDT;

    constructor(PaymentGateway _gateway, MockERC20 _usdt, MockERC20 _dai, address _user) {
        gateway = _gateway;
        usdt = _usdt;
        dai = _dai;
        user = _user;
    }

    // The Fuzzer will call THIS function with random data
    function pay(uint96 amount) public {
        // 1. Bound inputs to realistic values (avoid 0 or overflow)
        // limit to $1M per tx to avoid total supply overflows
        amount = uint96(bound(amount, 100, 1_000_000e2)); 

        // 2. Setup the state so the call succeeds
        uint256 maxInput = gateway.quoteMaxInput(address(dai), amount);
        
        vm.startPrank(user);
        dai.mint(user, maxInput); // Give user money
        dai.approve(address(gateway), maxInput); // User approves gateway

        // 3. Make the call
        try gateway.pay(address(dai), amount, 123, block.timestamp) {
            // If call succeeds, update our "Ghost" expectation
            uint256 expectedOut = (uint256(amount) * 1e6) / 100;
            ghost_expectedUSDT += expectedOut;
        } catch {
            // If it reverts (e.g. slippage), we don't increase expectation
        }
        vm.stopPrank();
    }
}