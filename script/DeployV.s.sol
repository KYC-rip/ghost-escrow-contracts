// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create3Factory} from "../src/Create3Factory.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {EscrowCloneFactory} from "../src/EscrowCloneFactory.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {GhostEscrowV2CImpl} from "../src/GhostEscrowV2CImpl.sol";
import {GhostEscrowV2OpenCImpl} from "../src/GhostEscrowV2OpenCImpl.sol";

/// @dev Step 0 of the vanity deploy (ops manual §A.2 / vanity plan A2):
///      the BOOTSTRAP key deploys the Create3Factory at its nonce 0, once per
///      chain, and never signs anything else — even a 0-value self-send would
///      permanently break the cross-chain factory address. The nonce guard
///      makes a second use fail loudly instead of silently diverging.
///      Usage: forge script script/DeployV.s.sol:DeployC3Factory \
///        --rpc-url <chain> --private-key $BOOTSTRAP_KEY --broadcast
contract DeployC3Factory is Script {
    function run() external {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(vm.getNonce(broadcaster) == 0, "bootstrap key already used on this chain");
        Create3Factory c3 = new Create3Factory();
        vm.stopBroadcast();
        console2.log("create3 factory:", address(c3));
        console2.log("proxy initcode hash:");
        console2.logBytes32(c3.PROXY_INITCODE_HASH());
    }
}

/// @dev The vanity triad deploy — CREATE3 path (replaces DeployD for mainnet).
///      Broadcast with the OPS key (salt namespace + registry deployer + binds).
///      Salts come from the ground vanity-salts.json via env; a zero salt is
///      accepted for rehearsals (address simply isn't vanity).
///
///      Two-step key flow (A3): this script deploys + binds as ops; template
///      registration runs separately with the CURATOR key (AddTemplates below)
///      unless ops == curator (testnet rehearsal), in which case it's inlined.
///
///      Usage:
///      CREATE3_FACTORY=0x… STAKING_TOKEN=0x… FEE_RECIPIENT=0x… CURATOR=0x… \
///      SALT_REGISTRY=0x… SALT_FACTORY=0x… SALT_COURT=0x… SALT_STD=0x… SALT_OPEN=0x… \
///      EXPECTED_CHAIN_ID=<id> ACTIVATION_DELAY=172800 \
///        forge script script/DeployV.s.sol:DeployV --rpc-url <chain> \
///        --private-key $OPS_KEY --broadcast
contract DeployV is Script {
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
    Create3Factory internal c3;
    address internal ops;
    address internal curator;
    ArbitratorRegistry internal registry;
    EscrowCloneFactory internal factory;
    AppealCourt internal court;
    address internal stdImpl;
    address internal openImpl;

    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "wrong chain");
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
            minStake: vm.envOr("MIN_STAKE", uint256(50e6)),
            highValueThreshold: vm.envOr("HIGH_VALUE_THRESHOLD", uint256(25_000e6))
        });
        c3 = Create3Factory(vm.envAddress("CREATE3_FACTORY"));
        // The wrapper's code participates in every address derivation — refuse
        // to deploy through a factory that doesn't match this repo's build
        // (vanity plan A1: frozen proxy bytecode, pinned derivation).
        require(
            address(c3).codehash == keccak256(type(Create3Factory).runtimeCode),
            "create3 factory codehash != repo build"
        );

        vm.startBroadcast();
        (, ops,) = vm.readCallers();
        curator = vm.envOr("CURATOR", ops);

        bytes32 sReg = vm.envOr("SALT_REGISTRY", bytes32(0));
        bytes32 sFac = vm.envOr("SALT_FACTORY", bytes32(0));
        bytes32 sCourt = vm.envOr("SALT_COURT", bytes32(0));
        bytes32 sStd = vm.envOr("SALT_STD", bytes32(0));
        bytes32 sOpen = vm.envOr("SALT_OPEN", bytes32(0));

        // Addresses are known before deployment — later constructors reference
        // earlier contracts by prediction, and every deploy asserts the match.
        address pReg = c3.predict(ops, sReg);
        address pFac = c3.predict(ops, sFac);

        // A1 (review): a wrong --private-key or a typoed salt would still pass
        // every `address == prediction` check and deploy NON-VANITY addresses
        // silently on mainnet — the exact divergence the scheme exists to stop.
        // When salts are ground for a specific ops namespace, pin it; and when
        // a salt is in use, assert its predicted address carries the signed-off
        // suffix. Rehearsals (all-zero salts) skip both.
        address expectedOps = vm.envOr("OPS", address(0));
        require(expectedOps == address(0) || ops == expectedOps, "ops key != salt namespace");
        _requireSuffix(pReg, sReg, 0x5afe, "registry");
        _requireSuffix(pFac, sFac, 0xfac7, "factory");
        _requireSuffix(c3.predict(ops, sCourt), sCourt, 0x5ea1, "court");
        _requireSuffix(c3.predict(ops, sStd), sStd, 0xdea1, "stdImpl");
        _requireSuffix(c3.predict(ops, sOpen), sOpen, 0xdea1, "openImpl");

        registry = ArbitratorRegistry(
            _deploy(sReg, abi.encodePacked(
                type(ArbitratorRegistry).creationCode,
                abi.encode(
                    IERC20(cfg.stakingToken), cfg.stakeMultiple, cfg.unbondingDelay,
                    cfg.slaDuration, cfg.slaSlashBps, cfg.overturnSlashBps, cfg.minStake, ops
                )
            ), pReg)
        );
        factory = EscrowCloneFactory(
            _deploy(sFac, abi.encodePacked(
                type(EscrowCloneFactory).creationCode,
                abi.encode(registry, cfg.feeRecipient, cfg.platformFeeBps, cfg.activationDelay, curator)
            ), pFac)
        );
        court = AppealCourt(
            _deploy(sCourt, abi.encodePacked(type(AppealCourt).creationCode, abi.encode(registry)), c3.predict(ops, sCourt))
        );
        stdImpl = _deploy(
            sStd,
            abi.encodePacked(type(GhostEscrowV2CImpl).creationCode, abi.encode(pFac, registry, cfg.highValueThreshold, uint256(100), uint256(5e6), uint256(1), uint256(1e5))),
            c3.predict(ops, sStd)
        );
        openImpl = _deploy(
            sOpen,
            abi.encodePacked(type(GhostEscrowV2OpenCImpl).creationCode, abi.encode(pFac, registry, cfg.highValueThreshold, uint256(100), uint256(5e6), uint256(1), uint256(1e5))),
            c3.predict(ops, sOpen)
        );

        registry.setFactory(address(factory));
        registry.setCourt(address(court));

        if (curator == ops) {
            factory.addTemplate(stdImpl);
            factory.addTemplate(openImpl);
        }
        vm.stopBroadcast();

        // Gate-holder verification (A3): fail the run, not the postmortem.
        require(registry.deployer() == ops, "registry deployer != ops");
        require(factory.curator() == curator, "factory curator != intended");
        require(address(registry.factory()) == address(factory), "factory not bound");
        require(registry.court() == address(court), "court not bound");

        _log();
        _record();
        if (curator != ops) {
            console2.log("NEXT: run AddTemplates with the CURATOR key (FACTORY/STD_IMPL/OPEN_IMPL env).");
        }
    }

    /// @dev When `salt` is non-zero (a real ground salt, not a rehearsal), the
    ///      predicted address MUST end in the signed-off 2-byte suffix.
    function _requireSuffix(address predicted, bytes32 salt, uint16 suffix, string memory what) internal pure {
        if (salt == bytes32(0)) return;
        require(uint16(uint160(predicted)) == suffix, string.concat("vanity suffix mismatch: ", what));
    }

    function _deploy(bytes32 salt, bytes memory creationCode, address predicted) internal returns (address a) {
        a = c3.deploy(salt, creationCode);
        require(a == predicted, "address != prediction");
    }

    function _log() internal view {
        console2.log("create3Factory:", address(c3));
        console2.log("registry:", address(registry));
        console2.log("cloneFactory:", address(factory));
        console2.log("court:", address(court));
        console2.log("stdImpl:", stdImpl);
        console2.log("openImpl:", openImpl);
        console2.log("ops (registry.deployer):", ops);
        console2.log("curator:", curator);
    }

    function _record() internal {
        string memory head = string.concat(
            "{",
            '"chainId":', vm.toString(block.chainid), ",",
            '"create3Factory":"', vm.toString(address(c3)), '",',
            '"registry":"', vm.toString(address(registry)), '",',
            '"cloneFactory":"', vm.toString(address(factory)), '",',
            '"court":"', vm.toString(address(court)), '",',
            '"stdImpl":"', vm.toString(stdImpl), '",',
            '"openImpl":"', vm.toString(openImpl), '",'
        );
        string memory tail = string.concat(
            '"stakingToken":"', vm.toString(cfg.stakingToken), '",',
            '"feeRecipient":"', vm.toString(cfg.feeRecipient), '",',
            '"curator":"', vm.toString(curator), '",',
            '"platformFeeBps":', vm.toString(cfg.platformFeeBps), ",",
            '"minStake":', vm.toString(cfg.minStake), ",",
            '"highValueThreshold":', vm.toString(cfg.highValueThreshold), ",",
            '"activationDelay":', vm.toString(cfg.activationDelay), ",",
            '"registryCodehash":"', vm.toString(address(registry).codehash), '",',
            '"factoryCodehash":"', vm.toString(address(factory).codehash), '",',
            '"courtCodehash":"', vm.toString(address(court).codehash), '",',
            '"stdImplCodehash":"', vm.toString(stdImpl.codehash), '",',
            '"openImplCodehash":"', vm.toString(openImpl.codehash), '"',
            "}"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/deployments-vanity.json"), string.concat(head, tail));
        console2.log("deployments-vanity.json written");
    }
}

/// @dev Step 2 of the two-key flow: template registration by the CURATOR key.
///      Usage: FACTORY=0x… STD_IMPL=0x… OPEN_IMPL=0x… \
///        forge script script/DeployV.s.sol:AddTemplates --rpc-url <chain> \
///        --private-key $CURATOR_KEY --broadcast
contract AddTemplates is Script {
    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "wrong chain");
        EscrowCloneFactory factory = EscrowCloneFactory(vm.envAddress("FACTORY"));
        vm.startBroadcast();
        factory.addTemplate(vm.envAddress("STD_IMPL"));
        factory.addTemplate(vm.envAddress("OPEN_IMPL"));
        vm.stopBroadcast();
        console2.log("templates added; activation delay:", factory.activationDelay());
    }
}
