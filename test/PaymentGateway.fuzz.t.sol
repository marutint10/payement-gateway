// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {PaymentGatewayTest} from "./PaymentGateway.t.sol"; 

contract PaymentGatewayFuzzTest is PaymentGatewayTest {

    function testFuzz_Pay_ERC20_Solvency(uint96 _usdAmount) public {
        // 1. Bound inputs: Test between $1 and $1 Billion USD
        vm.assume(_usdAmount > 100 && _usdAmount < 1_000_000_000e2); 
        
        uint256 maxInput = gateway.quoteMaxInput(address(dai), _usdAmount);
        uint256 expectedUSDT = (_usdAmount * 1e6) / 100;

        dai.mint(user, maxInput); 

        // The router needs enough USDT to pay out the swap result
        usdt.mint(address(router), expectedUSDT);

        vm.startPrank(user);
        dai.approve(address(gateway), maxInput);
        
        uint256 userBalBefore = dai.balanceOf(user);
        uint256 feeRecipientBalBefore = usdt.balanceOf(feeRecipient);

        // 3. Action
        gateway.pay(address(dai), _usdAmount, 99, block.timestamp);
        vm.stopPrank();

        // 4. Assertions 
        assertEq(usdt.balanceOf(feeRecipient), feeRecipientBalBefore + expectedUSDT);

        uint256 userSpent = userBalBefore - dai.balanceOf(user);
        assertTrue(userSpent <= maxInput, "User spent more than max quoted");
    }
}