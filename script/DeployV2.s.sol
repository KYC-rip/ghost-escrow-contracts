// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {EscrowFactoryV2} from "../src/EscrowFactoryV2.sol";
import {AppealCourt} from "../src/AppealCourt.sol";

/// @dev Deploy the Arbitrator Model v2 stack (registry → factory → court) and
///      bind the ownerless one-time refs (setFactory + setCourt by the deployer).
///      Usage:
///      FEE_RECIPIENT=0x… STAKING_TOKEN=0x… EXPECTED_CHAIN_ID=11155111 \
///        forge script script/DeployV2.s.sol --rpc-url $SEPOLIA_RPC \
///        --private-key $PRIVATE_KEY --broadcast
///      Params (defaults): STAKE_MULTIPLE=10, UNBONDING_DELAY=21d, SLA_DURATION=7d,
///      SLA_SLASH_BPS=1000 (10%), OVERTURN_SLASH_BPS=5000 (50% — operator decision).
contract DeployV2 is Script {
    function _broadcaster() internal returns (address b) {
        (, b,) = vm.readCallers();
    }

    function run() external {
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", uint256(11155111));
        require(block.chainid == expectedChainId, "wrong chain");

        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 platformFeeBps = vm.envOr("PLATFORM_FEE_BPS", uint256(150));
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        uint256 stakeMultiple = vm.envOr("STAKE_MULTIPLE", uint256(10));
        uint256 unbondingDelay = vm.envOr("UNBONDING_DELAY", uint256(21 days));
        uint256 slaDuration = vm.envOr("SLA_DURATION", uint256(7 days));
        uint256 slaSlashBps = vm.envOr("SLA_SLASH_BPS", uint256(1000));
        uint256 overturnSlashBps = vm.envOr("OVERTURN_SLASH_BPS", uint256(5000));

        vm.startBroadcast();
        // Legacy script (frozen templates) — MIN_STAKE=0 keeps its behavior.
        ArbitratorRegistry registry = new ArbitratorRegistry(
            IERC20(stakingToken), stakeMultiple, unbondingDelay, slaDuration, slaSlashBps, overturnSlashBps, 0, _broadcaster()
        );
        EscrowFactoryV2 factory = new EscrowFactoryV2(registry, feeRecipient, platformFeeBps);
        AppealCourt court = new AppealCourt(registry);
        registry.setFactory(address(factory));
        registry.setCourt(address(court));
        vm.stopBroadcast();

        console2.log("registry:", address(registry));
        console2.log("factoryV2:", address(factory));
        console2.log("court:", address(court));
        console2.log("stakingToken:", stakingToken);
        console2.log("feeRecipient:", feeRecipient);
        console2.log("platformFeeBps:", platformFeeBps);
        console2.log("stakeMultiple:", stakeMultiple);
        console2.log("unbondingDelay:", unbondingDelay);
        console2.log("slaDuration:", slaDuration);
        console2.log("slaSlashBps:", slaSlashBps, "overturnSlashBps:", overturnSlashBps);

        _record(address(registry), address(factory), address(court), stakingToken, feeRecipient, platformFeeBps, overturnSlashBps);
    }

    function _record(
        address registry_,
        address factory_,
        address court_,
        address stakingToken_,
        address feeRecipient_,
        uint256 platformFeeBps_,
        uint256 overturnSlashBps_
    ) internal {
        string memory json = string.concat(
            "{",
            '"chainId":', vm.toString(block.chainid), ",",
            '"registry":', '"', vm.toString(registry_), '",',
            '"factoryV2":', '"', vm.toString(factory_), '",',
            '"court":', '"', vm.toString(court_), '",',
            '"stakingToken":', '"', vm.toString(stakingToken_), '",',
            '"feeRecipient":', '"', vm.toString(feeRecipient_), '",',
            '"platformFeeBps":', vm.toString(platformFeeBps_), ",",
            '"overturnSlashBps":', vm.toString(overturnSlashBps_),
            "}"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/deployments-v2.json"), json);
        console2.log("deployments-v2.json written");
    }
}
