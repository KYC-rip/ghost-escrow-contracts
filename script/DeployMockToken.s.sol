// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../test/utils/MockERC20.sol";

/// @dev M5 testnet demo token: deploy a mintable 6-decimal ERC20 and credit the
///      deployer with demo funds. Usage:
///      EXPECTED_CHAIN_ID=11155111 forge script script/DeployMockToken.s.sol \
///        --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
contract DeployMockToken is Script {
    function run() external returns (address token) {
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", uint256(1));
        require(block.chainid == expectedChainId, "wrong chain");

        vm.startBroadcast();
        MockERC20 t = new MockERC20("Ghost Test USD", "tUSDC", 6);
        t.mint(msg.sender, 1_000_000 * 10 ** 6);
        vm.stopBroadcast();

        token = address(t);
        console2.log("MockERC20 deployed at:", token);
        console2.log("minted to deployer:", msg.sender, "= 1,000,000.000000");
    }
}