// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {PaymentGateway} from "../src/PaymentGateway.sol";

contract DeployPaymentGateway is Script {
    function run() external returns(address Payementgateway) {
       
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address router = vm.envAddress("ROUTER_ADDRESS"); 
        address usdt = vm.envAddress("USDT_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast(deployerPrivateKey);

        PaymentGateway gateway = new PaymentGateway(
            router,
            usdt,
            feeRecipient
        );

        console.log("PaymentGateway deployed to:", address(gateway));

        vm.stopBroadcast();
        return Payementgateway = address(gateway);
    }
}