// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {EscrowCloneFactory} from "../src/EscrowCloneFactory.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {GhostEscrowV2CImpl} from "../src/GhostEscrowV2CImpl.sol";
import {GhostEscrowV2OpenCImpl} from "../src/GhostEscrowV2OpenCImpl.sol";

/// @dev Phase D: deploy the clone-factory stack — the FINAL triad rotation.
///      Order: registry → clone factory → court → bind (deployer one-shots) →
///      template implementations(factory, registry) → addTemplate both.
///      Usage:
///      FEE_RECIPIENT=0x… STAKING_TOKEN=0x… EXPECTED_CHAIN_ID=11155111 \
///        forge script script/DeployD.s.sol --rpc-url $SEPOLIA_RPC \
///        --private-key $PRIVATE_KEY --broadcast
///      ACTIVATION_DELAY defaults to 0 (testnet acceptance); set 172800 (48h)
///      for the mainnet profile — it is an immutable constructor constant, so
///      the runbook must verify it (and each TemplateAdded codehash) against a
///      repo-pinned reproducible build (plan D-REV-5).
contract DeployD is Script {
    struct Cfg {
        address feeRecipient;
        uint256 platformFeeBps;
        address stakingToken;
        uint256 stakeMultiple;
        uint256 unbondingDelay;
        uint256 slaDuration;
        uint256 slaSlashBps;
        uint256 overturnSlashBps;
        uint256 activationDelay;
        uint256 minStake;
        uint256 highValueThreshold;
    }

    Cfg internal cfg;
    ArbitratorRegistry internal registry;
    EscrowCloneFactory internal factory;
    AppealCourt internal court;
    GhostEscrowV2CImpl internal stdImpl;
    GhostEscrowV2OpenCImpl internal openImpl;

    function run() external {
        require(block.chainid == vm.envOr("EXPECTED_CHAIN_ID", uint256(11155111)), "wrong chain");
        cfg = Cfg({
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            platformFeeBps: vm.envOr("PLATFORM_FEE_BPS", uint256(150)),
            stakingToken: vm.envAddress("STAKING_TOKEN"),
            stakeMultiple: vm.envOr("STAKE_MULTIPLE", uint256(10)),
            unbondingDelay: vm.envOr("UNBONDING_DELAY", uint256(21 days)),
            slaDuration: vm.envOr("SLA_DURATION", uint256(7 days)),
            slaSlashBps: vm.envOr("SLA_SLASH_BPS", uint256(1000)),
            overturnSlashBps: vm.envOr("OVERTURN_SLASH_BPS", uint256(5000)),
            activationDelay: vm.envOr("ACTIVATION_DELAY", uint256(0)),
            minStake: vm.envOr("MIN_STAKE", uint256(50e6)), // F4: $50 floor vs dust sybils
            highValueThreshold: vm.envOr("HIGH_VALUE_THRESHOLD", uint256(25_000e6)) // F7: 6-dec tokens
        });

        vm.startBroadcast();
        // The broadcast wallet — NOT msg.sender, which inside a forge script is
        // the harness default sender. Gates may be overridden per-key (A3).
        (, address broadcaster,) = vm.readCallers();
        address opsDeployer = vm.envOr("REGISTRY_DEPLOYER", broadcaster);
        address curator = vm.envOr("CURATOR", broadcaster);
        registry = new ArbitratorRegistry(
            IERC20(cfg.stakingToken),
            cfg.stakeMultiple,
            cfg.unbondingDelay,
            cfg.slaDuration,
            cfg.slaSlashBps,
            cfg.overturnSlashBps,
            cfg.minStake,
            opsDeployer
        );
        factory = new EscrowCloneFactory(registry, cfg.feeRecipient, cfg.platformFeeBps, cfg.activationDelay, curator);
        court = new AppealCourt(registry);
        registry.setFactory(address(factory));
        registry.setCourt(address(court));
        stdImpl = new GhostEscrowV2CImpl(address(factory), registry, cfg.highValueThreshold);
        openImpl = new GhostEscrowV2OpenCImpl(address(factory), registry, cfg.highValueThreshold);
        factory.addTemplate(address(stdImpl));
        factory.addTemplate(address(openImpl));
        vm.stopBroadcast();

        _log();
        _record();
    }

    function _log() internal view {
        console2.log("registry:", address(registry));
        console2.log("cloneFactory:", address(factory));
        console2.log("court:", address(court));
        console2.log("stdImpl:", address(stdImpl));
        console2.log("openImpl:", address(openImpl));
        console2.log("activationDelay:", cfg.activationDelay);
    }

    function _record() internal {
        string memory head = string.concat(
            "{",
            '"chainId":', vm.toString(block.chainid), ",",
            '"registry":"', vm.toString(address(registry)), '",',
            '"cloneFactory":"', vm.toString(address(factory)), '",',
            '"court":"', vm.toString(address(court)), '",',
            '"stdImpl":"', vm.toString(address(stdImpl)), '",',
            '"openImpl":"', vm.toString(address(openImpl)), '",'
        );
        string memory tail = string.concat(
            '"stakingToken":"', vm.toString(cfg.stakingToken), '",',
            '"feeRecipient":"', vm.toString(cfg.feeRecipient), '",',
            '"platformFeeBps":', vm.toString(cfg.platformFeeBps), ",",
            '"overturnSlashBps":', vm.toString(cfg.overturnSlashBps), ",",
            '"activationDelay":', vm.toString(cfg.activationDelay),
            "}"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/deployments-v3.json"), string.concat(head, tail));
        console2.log("deployments-v3.json written");
    }
}
