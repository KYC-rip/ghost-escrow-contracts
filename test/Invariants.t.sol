// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev Fuzz + invariant-style checks: accounting integrity across arbitrary
///      deposit sequences, ruling math, and mutual-split dust.
contract InvariantsTest is GhostTestBase {
    uint256 internal fee = (AMOUNT * FEE_BPS) / 10_000;
    uint256 internal net = AMOUNT - fee;

    // ─── Deposit-sequence accounting ──────────────────────────────────────

    function test_Fuzz_DepositSequencesNeverExceedDealAmount(uint256 depositA, uint256 depositB, uint256 depositC)
        public
    {
        depositA = bound(depositA, 1, AMOUNT);
        depositB = bound(depositB, 1, AMOUNT);
        depositC = bound(depositC, 1, AMOUNT);

        _fund(buyer, depositA + depositB + depositC);
        _approveDeposit(buyer, depositA + depositB + depositC);

        // Any deposit may legally revert once the deal is Active.
        vm.prank(buyer);
        try escrow.deposit(depositA) {} catch {}
        vm.prank(buyer);
        try escrow.deposit(depositB) {} catch {}
        vm.prank(buyer);
        try escrow.deposit(depositC) {} catch {}

        // Whatever happened, accounting never exceeds the deal amount and
        // every unit is either in the contract, refunded, or owed back.
        assertLe(escrow.deposited(), AMOUNT);
        assertEq(escrow.depositedBy(buyer), escrow.deposited());
        if (escrow.deposited() == AMOUNT) {
            assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        } else {
            assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.PartiallyDeposited));
        }
    }

    function test_Fuzz_DepositorTallySumsToDeposited(uint256 a, uint256 b) public {
        a = bound(a, 1, AMOUNT);
        b = bound(b, 1, AMOUNT);

        _fund(buyer, a);
        _approveDeposit(buyer, a);
        _deposit(buyer, a);
        if (escrow.deposited() < AMOUNT) {
            _fund(seller, b);
            _approveDeposit(seller, b);
            _deposit(seller, b);
        }

        uint256 total = escrow.depositedBy(buyer) + escrow.depositedBy(seller);
        assertEq(total, escrow.deposited());
        assertLe(escrow.deposited(), AMOUNT);
    }

    function test_Fuzz_ExpiryRefundsEveryoneExactly(uint256 a, uint256 b) public {
        a = bound(a, 1, AMOUNT);
        b = bound(b, 1, AMOUNT);

        _fund(buyer, a);
        _approveDeposit(buyer, a);
        _deposit(buyer, a);
        if (escrow.deposited() < AMOUNT) {
            _fund(seller, b);
            _approveDeposit(seller, b);
            _deposit(seller, b);
        }

        // If the deposits fully funded the deal, expiry is correctly blocked
        // (Active is not expirable) — that path is covered elsewhere.
        if (uint256(escrow.state()) == uint256(GhostEscrow.State.Active)) {
            vm.expectRevert("bad state");
            vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
            escrow.expire();
            return;
        }

        uint256 heldBefore = escrow.deposited();
        uint256 buyerOwed = escrow.depositedBy(buyer);
        uint256 sellerOwed = escrow.depositedBy(seller);
        uint256 buyerBefore = token.balanceOf(buyer);
        uint256 sellerBefore = token.balanceOf(seller);
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        escrow.expire();

        vm.prank(seller);
        escrow.claimExpired();

        // Everyone got back exactly what they put in; contract is empty.
        uint256 buyerBack = token.balanceOf(buyer) - buyerBefore;
        uint256 sellerBack = token.balanceOf(seller) - sellerBefore;
        assertEq(buyerBack, buyerOwed);
        assertEq(sellerBack, sellerOwed);
        assertEq(buyerBack + sellerBack, heldBefore);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ─── Ruling math ──────────────────────────────────────────────────────

    function test_Fuzz_RulingNeverLosesOrCreatesFunds(uint256 buyerAmount) public {
        buyerAmount = bound(buyerAmount, 0, AMOUNT);

        _fundActive();
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.prank(buyer);
        escrow.openDispute();

        vm.prank(arb);
        escrow.rule(buyerAmount, AMOUNT - buyerAmount, keccak256("fuzz"));

        uint256 escrowBalance = token.balanceOf(address(escrow));
        uint256 totalOut =
            token.balanceOf(buyer) + token.balanceOf(seller) + token.balanceOf(arb) + token.balanceOf(feeRecipient);
        assertEq(escrowBalance, 0);
        // Pre-funded amounts: AMOUNT (deal) + ARB_FEE (pot) — all conserved.
        assertEq(totalOut, AMOUNT + ARB_FEE);
    }

    function test_Fuzz_MutualSplitDustConserved(uint256 buyerAmount) public {
        buyerAmount = bound(buyerAmount, 0, AMOUNT);

        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _splitSigs(buyerAmount, 0, _deadline());
        escrow.mutualSplit(buyerAmount, _deadline(), bSig, sSig);

        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(buyer) + token.balanceOf(seller) + token.balanceOf(feeRecipient), AMOUNT);
    }

    function test_Fuzz_SplitPreservesNetRatio(uint256 buyerAmount) public {
        buyerAmount = bound(buyerAmount, 0, AMOUNT);
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _splitSigs(buyerAmount, 0, _deadline());
        escrow.mutualSplit(buyerAmount, _deadline(), bSig, sSig);

        uint256 expectedBuyer = (buyerAmount * net) / AMOUNT;
        uint256 expectedSeller = net - expectedBuyer;
        assertEq(token.balanceOf(buyer), expectedBuyer);
        assertEq(token.balanceOf(seller), expectedSeller);
    }

    function test_Fuzz_RulingSplitDustConservedWithOddAmounts(uint256 amount, uint256 buyerAmount) public {
        amount = bound(amount, 1e6, 100_000e6);
        buyerAmount = bound(buyerAmount, 0, amount);

        GhostEscrow e =
            _deployEscrowFull(address(token), buyer, seller, arb, amount, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE);
        vm.prank(buyer);
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(e), amount);
        vm.prank(buyer);
        e.deposit(amount);
        vm.prank(buyer);
        token.mint(buyer, ARB_FEE);
        vm.prank(buyer);
        token.approve(address(e), ARB_FEE);
        vm.prank(buyer);
        e.openDispute();

        vm.prank(arb);
        e.rule(buyerAmount, amount - buyerAmount, keccak256("fuzz2"));

        // All pre-funded value (deal + fee pot) is conserved somewhere.
        assertEq(token.balanceOf(address(e)), 0);
        assertEq(
            token.balanceOf(buyer) + token.balanceOf(seller) + token.balanceOf(arb) + token.balanceOf(feeRecipient),
            amount + ARB_FEE
        );
        // Platform fee is always exact; pot either returned to opener or paid to arb.
        assertEq(token.balanceOf(feeRecipient), (amount * FEE_BPS) / 10_000);
    }
}
