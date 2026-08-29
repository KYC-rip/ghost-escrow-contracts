// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {ReentrantToken, FalseReturnToken, NoReturnToken} from "./utils/HostileTokens.sol";

/// @dev Adversarial / negative-path hardening for the fund-holding contract:
///      reentrancy, non-compliant tokens, self-dealing arbitrator, unbounded
///      deposit window, and value-conservation under hostile inputs.
contract AdversarialTest is GhostTestBase {
    // ─── Reentrancy ───────────────────────────────────────────────────────

    /// A malicious deal token that re-enters deposit() during transferFrom must
    /// be stopped by nonReentrant: the nested call fails, the outer deposit is
    /// unaffected, and no double-credit occurs.
    function test_Reentrancy_DepositCannotReenterDeposit() public {
        ReentrantToken evil = new ReentrantToken(6);
        GhostEscrow e = new GhostEscrow(
            address(evil), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );

        evil.mint(buyer, AMOUNT);
        vm.prank(buyer);
        evil.approve(address(e), AMOUNT);

        // On the transfer inside deposit(), re-enter deposit() for the rest.
        evil.arm(address(e), abi.encodeCall(GhostEscrow.deposit, (AMOUNT / 2)));

        vm.prank(buyer);
        e.deposit(AMOUNT / 2);

        assertTrue(evil.reentryAttempted(), "reentry not attempted");
        assertFalse(evil.lastReentrySucceeded(), "guard failed: reentry succeeded");
        // Exactly one credit landed — no double count.
        assertEq(e.deposited(), AMOUNT / 2);
        assertEq(e.depositedBy(buyer), AMOUNT / 2);
    }

    /// Re-entering a payout path (release settles funds via safeTransfer) must
    /// also be blocked.
    function test_Reentrancy_PayoutCannotReenter() public {
        ReentrantToken evil = new ReentrantToken(6);
        GhostEscrow e = new GhostEscrow(
            address(evil), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
        evil.mint(buyer, AMOUNT);
        vm.prank(buyer);
        evil.approve(address(e), AMOUNT);
        vm.prank(buyer);
        e.deposit(AMOUNT);

        // Arm a re-entry into autoRelease() (permissionless) during the payout transfer.
        vm.warp(block.timestamp + AUTO_RELEASE);
        evil.arm(address(e), abi.encodeCall(GhostEscrow.autoRelease, ()));
        e.autoRelease();

        assertTrue(evil.reentryAttempted());
        assertFalse(evil.lastReentrySucceeded(), "guard failed on payout");
        // Seller paid exactly once.
        (uint256 net,) = (_net(), _fee());
        assertEq(evil.balanceOf(seller), net);
    }

    // ─── Non-compliant tokens ─────────────────────────────────────────────

    /// A token that returns false (rather than reverting) must NOT let the
    /// escrow credit an unfunded deposit — SafeERC20 turns it into a revert.
    function test_HostileToken_FalseReturnRevertsDeposit() public {
        FalseReturnToken bad = new FalseReturnToken(6);
        GhostEscrow e = new GhostEscrow(
            address(bad), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
        bad.mint(buyer, AMOUNT);
        vm.prank(buyer);
        bad.approve(address(e), AMOUNT);

        vm.prank(buyer);
        vm.expectRevert(); // SafeERC20FailedOperation
        e.deposit(AMOUNT);

        assertEq(e.deposited(), 0);
        assertEq(uint256(e.state()), uint256(GhostEscrow.State.Created));
    }

    /// A USDT-style no-return token must work end-to-end (deposit → release).
    function test_HostileToken_NoReturnTokenWorksEndToEnd() public {
        NoReturnToken usdt = new NoReturnToken();
        GhostEscrow e = new GhostEscrow(
            address(usdt), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
        usdt.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdt.approve(address(e), AMOUNT);
        vm.prank(buyer);
        e.deposit(AMOUNT);
        assertEq(uint256(e.state()), uint256(GhostEscrow.State.Active));

        vm.warp(block.timestamp + AUTO_RELEASE);
        e.autoRelease();
        assertEq(usdt.balanceOf(seller), _net());
        assertEq(usdt.balanceOf(feeRecipient), _fee());
        assertEq(usdt.balanceOf(address(e)), 0);
    }

    // ─── FINDING 1: self-dealing arbitrator (constructor guard missing) ────

    /// The constructor does NOT reject arbitrator == a party, though
    /// replaceArbitrator does. FIXED (finding 1): the constructor now
    /// requires `_arbitrator != _buyer && _arbitrator != _seller`; deploying
    /// with a party as arbitrator reverts.
    function test_Finding1_ArbitratorCanBeAPartyAndSelfDeal() public {
        vm.expectRevert(bytes("bad arb"));
        new GhostEscrow(
            address(token), buyer, seller, buyer, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    // ─── FINDING 2: unbounded deposit timeout ─────────────────────────────

    /// depositTimeout is now bounded [1h, 30d] (finding 2 fix). Zero must revert
    /// at construction — the deal can never be instantly expirable.
    function test_Finding2_ZeroDepositTimeoutIsImmediatelyExpirable() public {
        vm.expectRevert(bytes("bad deposit timeout"));
        new GhostEscrow(
            address(token),
            buyer,
            seller,
            arb,
            feeRecipient,
            AMOUNT,
            FEE_BPS,
            ARB_FEE,
            0, // depositTimeout = 0 → rejected
            AUTO_RELEASE
        );
    }

    // ─── Griefing: a stranger's deposit + donation ────────────────────────

    /// A third party can push the deal to Active by depositing; a stranger
    /// donation via syncDeposit is credited to the buyer, never stealable.
    function test_Grief_StrangerDonationCreditsBuyerNotStranger() public {
        _fund(buyer, AMOUNT / 2);
        _approveDeposit(buyer, AMOUNT / 2);
        _deposit(buyer, AMOUNT / 2);

        // Stranger sends deal tokens straight to the escrow, then anyone syncs.
        token.mint(address(escrow), AMOUNT / 2);
        escrow.syncDeposit();

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        // The donation is credited to the buyer, not the stranger.
        assertEq(escrow.depositedBy(buyer), AMOUNT);
        assertEq(escrow.depositedBy(stranger), 0);
    }

    /// syncDeposit overshoot: a direct transfer beyond dealAmount refunds the
    /// excess to the buyer and leaves deposited pinned at dealAmount.
    function test_Grief_SyncOvershootRefundsExcessToBuyer() public {
        token.mint(address(escrow), AMOUNT + 999);
        uint256 buyerBefore = token.balanceOf(buyer);
        escrow.syncDeposit();
        assertEq(escrow.deposited(), AMOUNT);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        assertEq(token.balanceOf(buyer) - buyerBefore, 999);
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _fee() internal pure returns (uint256) {
        return (AMOUNT * FEE_BPS) / 10_000;
    }

    function _net() internal pure returns (uint256) {
        return AMOUNT - _fee();
    }
}
