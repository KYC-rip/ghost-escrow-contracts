// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {GhostEscrow} from "../../src/GhostEscrow.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @dev Drives random NO-SIGNATURE action sequences against one escrow, so the
///      stateful invariant engine can hammer the v1.1 accounting paths
///      (depositedBy, syncDeposit, expire/claimExpired, dispute fee-pot,
///      permissionless timeouts). Signed mutual actions are excluded here —
///      their math is covered by the stateless fuzz suite.
contract EscrowHandler is CommonBase, StdUtils {
    GhostEscrow public escrow;
    MockERC20 public token;
    uint256 public dealAmount;
    uint256 public arbFee;

    address[4] public actors;
    address internal arb;

    /// Ghost accounting: every unit of the deal token ever put into the system.
    uint256 public totalMintedIn;

    constructor(GhostEscrow escrow_, MockERC20 token_, address[4] memory actors_, address arb_) {
        escrow = escrow_;
        token = token_;
        actors = actors_;
        arb = arb_;
        dealAmount = escrow_.dealAmount();
        arbFee = escrow_.arbitratorFee();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ─── Actions ──────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) public {
        address who = _actor(actorSeed);
        amount = bound(amount, 1, dealAmount);
        token.mint(who, amount);
        totalMintedIn += amount;
        vm.startPrank(who);
        token.approve(address(escrow), amount);
        try escrow.deposit(amount) {} catch {}
        vm.stopPrank();
    }

    function syncDirect(uint256 amount) public {
        amount = bound(amount, 1, dealAmount);
        token.mint(address(escrow), amount);
        totalMintedIn += amount;
        try escrow.syncDeposit() {} catch {}
    }

    function openDispute(uint256 actorSeed) public {
        // Only buyer/seller may open; fund the fee first.
        address who = actorSeed % 2 == 0 ? actors[0] : actors[1];
        token.mint(who, arbFee);
        totalMintedIn += arbFee;
        vm.startPrank(who);
        token.approve(address(escrow), arbFee);
        try escrow.openDispute() {} catch {}
        vm.stopPrank();
    }

    function rule(uint256 buyerAmount) public {
        buyerAmount = bound(buyerAmount, 0, dealAmount);
        vm.prank(arb);
        try escrow.rule(buyerAmount, dealAmount - buyerAmount, keccak256("inv")) {} catch {}
    }

    function warp(uint256 secs) public {
        secs = bound(secs, 1, 20 days);
        vm.warp(block.timestamp + secs);
    }

    function expire() public {
        try escrow.expire() {} catch {}
    }

    function claimExpired(uint256 actorSeed) public {
        vm.prank(_actor(actorSeed));
        try escrow.claimExpired() {} catch {}
    }

    function autoRelease() public {
        try escrow.autoRelease() {} catch {}
    }

    // ─── Views for invariants ─────────────────────────────────────────────

    function sumDepositedBy() external view returns (uint256 s) {
        for (uint256 i = 0; i < actors.length; i++) {
            s += escrow.depositedBy(actors[i]);
        }
    }
}
