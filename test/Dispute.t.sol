// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";

/// @dev Dispute lifecycle: pre-paid fee pot separation, ruling math,
///      tie-favors-opener, rationale hash, permission checks.
contract DisputeTest is GhostTestBase {
    uint256 internal fee = (AMOUNT * FEE_BPS) / 10_000;
    uint256 internal net = AMOUNT - fee;

    // ─── openDispute ──────────────────────────────────────────────────────

    function test_OpenDispute_ActiveOnly() public {
        vm.expectRevert("not active");
        vm.prank(buyer);
        escrow.openDispute();
    }

    function test_OpenDispute_PartyOnly() public {
        _fundActive();
        vm.expectRevert("not party");
        vm.prank(stranger);
        escrow.openDispute();
    }

    function test_OpenDispute_SeparatesFeePotFromDealFunds() public {
        _fundActive();
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.DisputeOpened(buyer);
        vm.prank(buyer);
        escrow.openDispute();

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Disputed));
        assertEq(escrow.disputeOpener(), buyer);
        assertEq(escrow.arbitratorFeePot(), ARB_FEE);
        assertEq(escrow.deposited(), AMOUNT); // deal funds untouched
        assertEq(escrow.depositedBy(buyer), AMOUNT); // fee NOT in depositor tally
        assertEq(token.balanceOf(address(escrow)), AMOUNT + ARB_FEE);
        // Auto-release frozen.
        assertEq(escrow.autoReleaseDeadline(), type(uint256).max);
    }

    function test_OpenDispute_NoFeeConfigured() public {
        GhostEscrow noFee =
            _deployEscrowFull(address(token), buyer, seller, arb, AMOUNT, 0, DEPOSIT_TIMEOUT, AUTO_RELEASE);
        vm.prank(buyer);
        token.mint(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(noFee), AMOUNT);
        vm.prank(buyer);
        noFee.deposit(AMOUNT);
        vm.prank(buyer);
        noFee.openDispute();
        assertEq(noFee.arbitratorFeePot(), 0);
        assertEq(uint256(noFee.state()), uint256(GhostEscrow.State.Disputed));
    }

    function test_OpenDispute_FeeOnTransferShortfallReverts() public {
        token.setFeeOnTransfer(100);
        uint256 send = (AMOUNT * 100) / 99; // credited == AMOUNT exactly
        _fund(buyer, send + ARB_FEE);
        _approveDeposit(buyer, send);
        _deposit(buyer, send);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));

        // The 1% burn on the fee transfer means the pot never reaches ARB_FEE.
        _approveDeposit(buyer, ARB_FEE);
        vm.expectRevert("fee short");
        vm.prank(buyer);
        escrow.openDispute();
    }

    function test_OpenDispute_SecondOpenReverts() public {
        _openDispute(buyer);
        vm.expectRevert("not active");
        vm.prank(seller);
        escrow.openDispute();
    }

    // ─── rule() ───────────────────────────────────────────────────────────

    function test_Rule_ArbitratorOnly() public {
        _openDispute(buyer);
        vm.expectRevert("not arbitrator");
        vm.prank(buyer);
        escrow.rule(AMOUNT, 0, bytes32("x"));
    }

    function test_Rule_DisputedOnly() public {
        _fundActive();
        vm.expectRevert("not disputed");
        vm.prank(arb);
        escrow.rule(AMOUNT, 0, bytes32("x"));
    }

    function test_Rule_SumMustEqualDealAmount() public {
        _openDispute(buyer);
        vm.expectRevert("sum != dealAmount");
        vm.prank(arb);
        escrow.rule(AMOUNT - 1, 0, bytes32("x"));
    }

    function test_Rule_FullRefundToBuyer() public {
        _openDispute(buyer);
        uint256 buyerBefore = token.balanceOf(buyer);
        vm.prank(arb);
        escrow.rule(AMOUNT, 0, keccak256("rationale"));

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
        assertEq(token.balanceOf(buyer), buyerBefore + net + ARB_FEE); // opener won: pot back
        assertEq(token.balanceOf(seller), 0);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(escrow.arbitratorFeePot(), 0);
    }

    function test_Rule_FullReleaseToSeller() public {
        _openDispute(buyer);
        vm.prank(arb);
        escrow.rule(0, AMOUNT, keccak256("rationale"));
        assertEq(token.balanceOf(seller), net);
        assertEq(token.balanceOf(buyer), 0); // opener lost: pot goes to arbitrator
        assertEq(token.balanceOf(arb), ARB_FEE);
        assertEq(token.balanceOf(feeRecipient), fee);
    }

    function test_Rule_PartialSplitMath() public {
        _openDispute(buyer);
        vm.prank(arb);
        escrow.rule(AMOUNT / 4, (3 * AMOUNT) / 4, keccak256("rationale"));

        uint256 finalBuyer = (AMOUNT / 4 * net) / AMOUNT;
        uint256 finalSeller = net - finalBuyer;
        assertEq(token.balanceOf(buyer), finalBuyer); // opener lost this ruling
        assertEq(token.balanceOf(seller), finalSeller);
        assertEq(token.balanceOf(arb), ARB_FEE); // lost pot pays the arbitrator
        // Pre-fee + post-fee consistency: everything accounted for.
        assertEq(finalBuyer + finalSeller, net);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Rule_TieFavorsOpener() public {
        // The on-record rule: an equal split counts as an opener win.
        _openDispute(buyer);
        vm.prank(arb);
        escrow.rule(AMOUNT / 2, AMOUNT / 2, keccak256("tie"));
        assertEq(token.balanceOf(buyer), (AMOUNT / 2 * net) / AMOUNT + ARB_FEE);
        assertEq(token.balanceOf(arb), 0);
    }

    function test_Rule_TieFavorsOpener_SellerOpened() public {
        _openDispute(seller);
        vm.prank(arb);
        escrow.rule(AMOUNT / 2, AMOUNT / 2, keccak256("tie"));
        assertEq(token.balanceOf(seller), (AMOUNT / 2 * net) / AMOUNT + ARB_FEE);
        assertEq(token.balanceOf(buyer), (AMOUNT / 2 * net) / AMOUNT);
        assertEq(token.balanceOf(arb), 0);
    }

    function test_Rule_EmitsRuledWithPreFeeAmountsAndRationaleHash() public {
        _openDispute(buyer);
        bytes32 rationale = keccak256("written rationale, hashed on chain");
        // Log order in rule(): StateChanged, ArbitratorFeeSettled, Split, Ruled.
        vm.prank(arb);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.Split((AMOUNT / 2 * net) / AMOUNT, net - (AMOUNT / 2 * net) / AMOUNT, fee, true);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.Ruled(AMOUNT / 2, AMOUNT / 2, fee, rationale);
        escrow.rule(AMOUNT / 2, AMOUNT / 2, rationale);
    }

    function test_Rule_SecondRuleReverts() public {
        _openDispute(buyer);
        vm.prank(arb);
        escrow.rule(AMOUNT, 0, keccak256("first"));
        vm.expectRevert("not disputed");
        vm.prank(arb);
        escrow.rule(0, AMOUNT, keccak256("second"));
    }

    function test_Rule_DustAbsorbedBySeller() public {
        // Odd pre-fee split: sellerAmount absorbs rounding dust.
        _openDispute(buyer);
        uint256 odd = 1; // 1 wei to buyer pre-fee
        vm.prank(arb);
        escrow.rule(odd, AMOUNT - odd, keccak256("dust"));
        uint256 finalBuyer = (odd * net) / AMOUNT; // 0 — the dust rule
        uint256 finalSeller = net - finalBuyer;
        assertEq(token.balanceOf(buyer), finalBuyer); // opener LOST the ruling
        assertEq(token.balanceOf(seller), finalSeller);
        assertEq(token.balanceOf(arb), ARB_FEE); // lost pot pays the arbitrator
        assertEq(finalBuyer + finalSeller, net);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _openDispute(address opener) internal {
        _fundActive();
        _fund(opener, ARB_FEE);
        _approveDeposit(opener, ARB_FEE);
        vm.prank(opener);
        escrow.openDispute();
    }
}
