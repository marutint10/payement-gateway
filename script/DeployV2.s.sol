// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {PayementGatewayV2} from "../src/PayementGatewayV2.sol";

contract DeployPaymentGatewayV2 is Script {
    function run() external returns(address Payementgateway) {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address router = vm.envAddress("ROUTER_ADDRESS"); 
        address usdt = vm.envAddress("USDT_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast(deployerPrivateKey);

        // 3. Deploy
        PayementGatewayV2 gateway = new PayementGatewayV2(
            router,
            usdt,
            feeRecipient
        );

        console.log("PaymentGatewayV2 deployed to:", address(gateway));

        vm.stopBroadcast();
        return Payementgateway = address(gateway);
    }
}

