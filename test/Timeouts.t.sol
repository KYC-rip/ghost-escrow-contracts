// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";

/// @dev Permissionless timeouts: deposit-window expiry (buyer push +
///      third-party claimExpired) and auto-release (fee, frozen by dispute).
contract TimeoutsTest is GhostTestBase {
    uint256 internal fee = (AMOUNT * FEE_BPS) / 10_000;
    uint256 internal net = AMOUNT - fee;

    // ─── expire ───────────────────────────────────────────────────────────

    function test_Expire_TooEarlyReverts() public {
        vm.expectRevert("too early");
        escrow.expire();
    }

    function test_Expire_AtDeadlineStillReverts() public {
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT);
        vm.expectRevert("too early");
        escrow.expire();
    }

    function test_Expire_NoDepositsClosesFeeFree() public {
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.Expired(0);
        escrow.expire();
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Expired));
        assertEq(escrow.deposited(), 0);
    }

    function test_Expire_BuyerFundsPushedInTx() public {
        _fund(buyer, AMOUNT / 2);
        _approveDeposit(buyer, AMOUNT / 2);
        _deposit(buyer, AMOUNT / 2);

        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        uint256 buyerBefore = token.balanceOf(buyer);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.Expired(AMOUNT / 2);
        escrow.expire();

        assertEq(token.balanceOf(buyer), buyerBefore + AMOUNT / 2); // pushed, no claim needed
        assertEq(escrow.deposited(), 0);
        assertEq(escrow.depositedBy(buyer), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(feeRecipient), 0); // no platform fee on expiry
    }

    function test_Expire_ThirdPartyDepositorClaimsTheirOwn() public {
        // Third party funds part of the deal; expiry must refund THEM, not the buyer.
        _fund(stranger, AMOUNT / 3);
        _approveDeposit(stranger, AMOUNT / 3);
        _deposit(stranger, AMOUNT / 3);

        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        escrow.expire();

        uint256 strangerBefore = token.balanceOf(stranger);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.ExpiredClaimed(stranger, AMOUNT / 3);
        vm.prank(stranger);
        escrow.claimExpired();
        assertEq(token.balanceOf(stranger), strangerBefore + AMOUNT / 3);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Expire_MixedDepositorsEachGetTheirOwn() public {
        _fund(buyer, AMOUNT / 2);
        _approveDeposit(buyer, AMOUNT / 2);
        _deposit(buyer, AMOUNT / 2);
        _fund(seller, AMOUNT / 4);
        _approveDeposit(seller, AMOUNT / 4);
        _deposit(seller, AMOUNT / 4);

        uint256 buyerBefore = token.balanceOf(buyer);
        uint256 sellerBefore = token.balanceOf(seller);
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        escrow.expire();

        vm.prank(seller);
        escrow.claimExpired();
        assertEq(token.balanceOf(seller), sellerBefore + AMOUNT / 4);
        assertEq(token.balanceOf(buyer), buyerBefore + AMOUNT / 2); // pushed during expire()
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Expire_ClaimExpiredNothingToClaimReverts() public {
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        escrow.expire();
        vm.expectRevert("nothing to claim");
        escrow.claimExpired();
    }

    function test_Expire_ClaimBeforeExpiryReverts() public {
        vm.expectRevert("not expired");
        escrow.claimExpired();
    }

    function test_Expire_AfterActiveReverts() public {
        _fundActive();
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        vm.expectRevert("bad state");
        escrow.expire();
    }

    function test_Expire_FromActiveReverts() public {
        _fundActive();
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        vm.expectRevert("bad state");
        escrow.expire();
    }

    function test_Expire_DoubleExpireReverts() public {
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        escrow.expire();
        vm.expectRevert("bad state");
        escrow.expire();
    }

    // ─── autoRelease ──────────────────────────────────────────────────────

    function test_AutoRelease_TooEarlyReverts() public {
        _fundActive();
        vm.expectRevert("too early");
        escrow.autoRelease();
    }

    function test_AutoRelease_AfterDelayPaysSellerAndFee() public {
        _fundActive();
        vm.warp(block.timestamp + AUTO_RELEASE);
        uint256 sellerBefore = token.balanceOf(seller);
        escrow.autoRelease();

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
        assertEq(token.balanceOf(seller), sellerBefore + net);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_AutoRelease_DeadlineAtExactlyNowWorks() public {
        _fundActive();
        vm.warp(escrow.autoReleaseDeadline());
        escrow.autoRelease();
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
    }

    function test_AutoRelease_CustomDelayRespected() public {
        GhostEscrow fast =
            _deployEscrowFull(address(token), buyer, seller, arb, AMOUNT, ARB_FEE, DEPOSIT_TIMEOUT, 1 days);
        vm.prank(buyer);
        token.mint(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(fast), AMOUNT);
        vm.prank(buyer);
        fast.deposit(AMOUNT);

        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert("too early");
        fast.autoRelease();
        vm.warp(block.timestamp + 1);
        fast.autoRelease();
        assertEq(uint256(fast.state()), uint256(GhostEscrow.State.Completed));
    }

    function test_AutoRelease_FrozenByDispute() public {
        _fundActive();
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.prank(buyer);
        escrow.openDispute();

        vm.warp(block.timestamp + AUTO_RELEASE + 30 days);
        vm.expectRevert("not active");
        escrow.autoRelease();

        // The deal can still settle via rule or mutual action.
        vm.prank(arb);
        escrow.rule(AMOUNT, 0, keccak256("after stall"));
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
    }

    function test_AutoRelease_AfterMutualReleaseReverts() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, _deadline());
        escrow.release(_deadline(), bSig, sSig);
        vm.warp(block.timestamp + AUTO_RELEASE);
        vm.expectRevert("not active");
        escrow.autoRelease();
    }
}
