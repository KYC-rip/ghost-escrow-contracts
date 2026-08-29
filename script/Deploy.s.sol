// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";

/// @dev Deploy the GhostEscrow factory (feeRecipient + platformFeeBps from env):
///      FEE_RECIPIENT=0x... PLATFORM_FEE_BPS=150 forge script script/Deploy.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
///
///      Chain guard: EXPECTED_CHAIN_ID (default 1 = Ethereum mainnet) must
///      match the RPC's chain — a wrong RPC_URL must never broadcast to the
///      wrong network. Set EXPECTED_CHAIN_ID=11155111 for Sepolia testnet.
contract Deploy is Script {
    function run() external returns (EscrowFactory factory) {
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 platformFeeBps = vm.envUint("PLATFORM_FEE_BPS");
        require(platformFeeBps <= 1000, "fee too high");

        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", uint256(1));
        uint256 actualChainId = block.chainid;
        require(actualChainId == expectedChainId, "wrong chain");

        vm.startBroadcast();
        factory = new EscrowFactory(feeRecipient, platformFeeBps);
        vm.stopBroadcast();

        console2.log("EscrowFactory deployed at:", address(factory));
        console2.log("chainId:", actualChainId);
        console2.log("feeRecipient:", feeRecipient);
        console2.log("platformFeeBps:", platformFeeBps);

        // Write deployments.json in the repo root (overwrites the committed
        // stub only when a broadcast actually happened — safe by default).
        string memory chainKey = vm.toString(actualChainId);
        string memory json = string.concat(
            "{",
            '"chainId":', chainKey, ",",
            '"factory":', '"', vm.toString(address(factory)), '",',
            '"feeRecipient":', '"', vm.toString(feeRecipient), '",',
            '"platformFeeBps":', vm.toString(platformFeeBps),
            "}"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/deployments.json"), json);
        console2.log("deployments.json written (chainId", chainKey, ")");
    }
}