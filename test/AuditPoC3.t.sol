// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {SigUtils} from "./utils/SigUtils.sol";

contract AuditPoC3 is Test {
    uint256 constant BUYER_PK = 0xA11CE;
    uint256 constant SELLER_PK = 0xB0BEEF;
    address buyer = vm.addr(BUYER_PK);
    address seller = vm.addr(SELLER_PK);
    address arb = address(0xA4B);
    address feeRecipient = address(0xFEE5);
    uint256 constant AMOUNT = 4200e6;

    /// Same escrow address on two chains (deterministic factory) must NOT share sigs.
    function test_crossChainReplayIsBlocked() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, 150, 50e6, 72 hours, 14 days
        );
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);
        vm.stopPrank();

        uint256 dl = block.timestamp + 1 days;
        // Sign for a DIFFERENT chain id (chain 137) against the same address+nonce.
        bytes32 d = SigUtils.releaseDigest(address(e), 137, e.nonce(), dl);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(BUYER_PK, d);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(SELLER_PK, d);

        vm.expectRevert(bytes("bad buyer sig"));
        e.release(dl, abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));
    }

    /// A smart-contract wallet buyer (Safe/4337) makes every mutual path dead.
    function test_contractWalletBuyer_killsAllMutualPaths() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        address scWallet = address(new MockERC20("wallet", "W", 18)); // any contract
        GhostEscrow e = new GhostEscrow(
            address(token), scWallet, seller, arb, feeRecipient, AMOUNT, 150, 50e6, 72 hours, 14 days
        );
        token.mint(address(this), AMOUNT);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);

        uint256 dl = block.timestamp + 1 days;
        bytes32 d = SigUtils.releaseDigest(address(e), block.chainid, e.nonce(), dl);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(SELLER_PK, d);
        bytes memory ss = abi.encodePacked(r2, s2, v2);
        // No EOA key can ever produce a signature recovering to the wallet address.
        vm.expectRevert(bytes("bad buyer sig"));
        e.release(dl, ss, ss);
        // Only escapes left: autoRelease (pays seller) or the arbitrator.
    }
}
