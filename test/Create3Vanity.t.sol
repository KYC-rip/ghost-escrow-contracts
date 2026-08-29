// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create3Factory} from "../src/Create3Factory.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {EscrowCloneFactory} from "../src/EscrowCloneFactory.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {GhostEscrowV2CImpl} from "../src/GhostEscrowV2CImpl.sol";
import {GhostEscrowV2OpenCImpl} from "../src/GhostEscrowV2OpenCImpl.sol";
import {MockERC20} from "./utils/MockERC20.sol";

/// CREATE3 vanity-deploy path (DeployV): the whole triad through the vendored
/// factory, with the ops EOA as salt namespace + registry deployer and a
/// separate curator key — the exact mainnet key flow (A3).
contract Create3VanityTest is Test {
    Create3Factory internal c3;
    MockERC20 internal token;

    address internal ops = vm.addr(0x0A5);
    address internal curator = vm.addr(0xC0A7);

    function setUp() public {
        c3 = new Create3Factory();
        token = new MockERC20("MockUSDC", "USDC", 6);
    }

    function test_proxyInitcodeHashPinned() public view {
        // A1: derivation constant frozen — the grinder + vanity-salts.json pin
        // this exact value. If this test moves, every ground salt is void.
        assertEq(c3.PROXY_INITCODE_HASH(), keccak256(hex"67363d3d37363d34f03d5260086018f3"));
    }

    function test_predictionMatchesDeploy_andIsInitcodeIndependent() public {
        bytes32 salt = keccak256("fixture-salt");
        address predicted = c3.predict(ops, salt);
        vm.prank(ops);
        address got = c3.deploy(
            salt,
            abi.encodePacked(
                type(ArbitratorRegistry).creationCode,
                abi.encode(IERC20(address(token)), uint256(10), 21 days, 7 days, uint256(1000), uint256(5000), uint256(0), ops)
            )
        );
        assertEq(got, predicted, "predict == deploy");
        // Same salt, DIFFERENT namespace → different address (frontrun-proof).
        assertTrue(c3.predict(curator, salt) != predicted);
        // One salt, one contract, forever.
        vm.prank(ops);
        vm.expectRevert(bytes("already deployed"));
        c3.deploy(salt, abi.encodePacked(type(Create3Factory).creationCode));
    }

    function test_fullTriadThroughCreate3_gatesHeldByNamedKeys() public {
        // Deterministic addresses are known BEFORE deployment — constructor
        // args can reference each other across the sequence.
        bytes32 sReg = keccak256("registry");
        bytes32 sFac = keccak256("factory");
        bytes32 sCourt = keccak256("court");
        bytes32 sStd = keccak256("std");
        bytes32 sOpen = keccak256("open");
        address aReg = c3.predict(ops, sReg);
        address aFac = c3.predict(ops, sFac);

        vm.startPrank(ops);
        ArbitratorRegistry registry = ArbitratorRegistry(
            c3.deploy(sReg, abi.encodePacked(
                type(ArbitratorRegistry).creationCode,
                abi.encode(IERC20(address(token)), uint256(10), 21 days, 7 days, uint256(1000), uint256(5000), uint256(50e6), ops)
            ))
        );
        assertEq(address(registry), aReg);
        EscrowCloneFactory factory = EscrowCloneFactory(
            c3.deploy(sFac, abi.encodePacked(
                type(EscrowCloneFactory).creationCode,
                abi.encode(registry, address(0xFEE5), uint256(150), uint256(0), curator)
            ))
        );
        assertEq(address(factory), aFac);
        AppealCourt court = AppealCourt(
            c3.deploy(sCourt, abi.encodePacked(type(AppealCourt).creationCode, abi.encode(registry)))
        );
        GhostEscrowV2CImpl stdImpl = GhostEscrowV2CImpl(
            c3.deploy(sStd, abi.encodePacked(type(GhostEscrowV2CImpl).creationCode, abi.encode(aFac, registry, uint256(25_000e6))))
        );
        GhostEscrowV2OpenCImpl openImpl = GhostEscrowV2OpenCImpl(
            c3.deploy(sOpen, abi.encodePacked(type(GhostEscrowV2OpenCImpl).creationCode, abi.encode(aFac, registry, uint256(25_000e6))))
        );

        // Step 1 continued: the ops EOA (registry.deployer) binds.
        registry.setFactory(address(factory));
        registry.setCourt(address(court));
        vm.stopPrank();

        // Gate-holder verification (A3): the named keys hold the gates.
        assertEq(registry.deployer(), ops);
        assertEq(factory.curator(), curator);

        // Step 2: the CURATOR key (not ops) registers the templates.
        vm.prank(ops);
        vm.expectRevert(bytes("not curator"));
        factory.addTemplate(address(stdImpl));
        vm.startPrank(curator);
        factory.addTemplate(address(stdImpl));
        factory.addTemplate(address(openImpl));
        vm.stopPrank();

        // Wiring identical to the DeployD path.
        assertEq(address(registry.factory()), address(factory));
        assertEq(registry.court(), address(court));
        assertEq(stdImpl.HIGH_VALUE_THRESHOLD(), 25_000e6);
        assertEq(openImpl.FACTORY(), address(factory));
    }
}
