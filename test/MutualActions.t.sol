// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev Mutual actions: release, refund, mutualSplit, replaceArbitrator —
///      signature validity, deadlines, replay protection, Disputed-state exits.
contract MutualActionsTest is GhostTestBase {
    uint256 internal fee = (AMOUNT * FEE_BPS) / 10_000;
    uint256 internal net = AMOUNT - fee;

    // ─── Release ──────────────────────────────────────────────────────────

    function test_Release_BothSignaturesPaysSellerAndFee() public {
        _fundActive();
        uint256 sellerBefore = token.balanceOf(seller);
        uint256 feeBefore = token.balanceOf(feeRecipient);
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, _deadline());
        escrow.release(_deadline(), bSig, sSig);

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
        assertEq(token.balanceOf(seller), sellerBefore + net);
        assertEq(token.balanceOf(feeRecipient), feeBefore + fee);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.deposited(), 0);
        assertEq(escrow.nonce(), 1);
    }

    function test_Release_EmitsEvents() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, _deadline());
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.StateChanged(GhostEscrow.State.Active, GhostEscrow.State.Completed);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.Released(seller, net, fee);
        escrow.release(_deadline(), bSig, sSig);
    }

    function test_Release_StaleDeadlineReverts() public {
        _fundActive();
        uint256 expired = block.timestamp - 1;
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, expired);
        vm.expectRevert("sigs expired");
        escrow.release(expired, bSig, sSig);
    }

    function test_Release_DeadlineAtNowWorks() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, block.timestamp);
        escrow.release(block.timestamp, bSig, sSig);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
    }

    function test_Release_WrongBuyerSignatureReverts() public {
        _fundActive();
        bytes32 d = SigUtils.releaseDigest(address(escrow), chainId, 0, _deadline());
        (bytes memory sSig,) = _releaseSigs(0, _deadline()); // real seller sig
        bytes memory wrongBuyer = _sig(strangerPk, d);
        vm.expectRevert("bad buyer sig");
        escrow.release(_deadline(), wrongBuyer, sSig);
    }

    function test_Release_WrongSellerSignatureReverts() public {
        _fundActive();
        bytes32 d = SigUtils.releaseDigest(address(escrow), chainId, 0, _deadline());
        (bytes memory bSig,) = _releaseSigs(0, _deadline()); // real buyer sig
        bytes memory wrongSeller = _sig(strangerPk, d);
        vm.expectRevert("bad seller sig");
        escrow.release(_deadline(), bSig, wrongSeller);
    }

    function test_Release_ReplayWithSameNonceReverts() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _replaceArbSigs(newArb, 0, _deadline());
        escrow.replaceArbitrator(newArb, _deadline(), bSig, sSig); // nonce 0 -> 1

        // Re-submit the same nonce-0 signatures: the burned nonce must reject them.
        vm.expectRevert("bad buyer sig");
        escrow.replaceArbitrator(newArb, _deadline(), bSig, sSig);

        // Fresh signatures at the current nonce still work.
        (bSig, sSig) = _replaceArbSigs(arb, 1, _deadline());
        escrow.replaceArbitrator(arb, _deadline(), bSig, sSig);
        assertEq(escrow.arbitrator(), arb);
        assertEq(escrow.nonce(), 2);
    }

    function test_Release_SignatureDoesNotTransferAcrossNonce() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(1, _deadline()); // signed for future nonce
        vm.expectRevert("bad buyer sig");
        escrow.release(_deadline(), bSig, sSig);
    }

    // ─── Refund ───────────────────────────────────────────────────────────

    function test_Refund_BothSignaturesPaysBuyerAndFee() public {
        _fundActive();
        uint256 buyerBefore = token.balanceOf(buyer);
        (bytes memory bSig, bytes memory sSig) = _refundSigs(0, _deadline());
        escrow.refund(_deadline(), bSig, sSig);

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Cancelled));
        assertEq(token.balanceOf(buyer), buyerBefore + net);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.nonce(), 1);
    }

    function test_Refund_PaysPlatformFeeToo() public {
        // On-record product decision: mutual refund is not fee-free.
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _refundSigs(0, _deadline());
        escrow.refund(_deadline(), bSig, sSig);
        assertEq(token.balanceOf(feeRecipient), fee);
    }

    function test_Refund_StaleDeadlineReverts() public {
        _fundActive();
        uint256 expired = block.timestamp - 1;
        (bytes memory bSig, bytes memory sSig) = _refundSigs(0, expired);
        vm.expectRevert("sigs expired");
        escrow.refund(expired, bSig, sSig);
    }

    function test_Refund_FromDisputedReturnsFeePotToOpener() public {
        _openDisputeAs(buyer);
        uint256 buyerBefore = token.balanceOf(buyer);
        (bytes memory bSig, bytes memory sSig) = _refundSigs(0, _deadline());
        escrow.refund(_deadline(), bSig, sSig);

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Cancelled));
        // Dispute opener gets their pre-paid arbitrator fee back (no ruling).
        assertEq(token.balanceOf(buyer), buyerBefore + net + ARB_FEE);
        assertEq(token.balanceOf(arb), 0);
    }

    // ─── MutualSplit ──────────────────────────────────────────────────────

    function test_MutualSplit_HalfHalf() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _splitSigs(AMOUNT / 2, 0, _deadline());
        escrow.mutualSplit(AMOUNT / 2, _deadline(), bSig, sSig);

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
        uint256 finalBuyer = (AMOUNT / 2 * net) / AMOUNT;
        uint256 finalSeller = net - finalBuyer;
        assertEq(token.balanceOf(buyer), finalBuyer);
        assertEq(token.balanceOf(seller), finalSeller);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_MutualSplit_AllToBuyer() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _splitSigs(AMOUNT, 0, _deadline());
        escrow.mutualSplit(AMOUNT, _deadline(), bSig, sSig);
        assertEq(token.balanceOf(buyer), net);
        assertEq(token.balanceOf(seller), 0);
        assertEq(token.balanceOf(feeRecipient), fee);
    }

    function test_MutualSplit_AllToSeller() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _splitSigs(0, 0, _deadline());
        escrow.mutualSplit(0, _deadline(), bSig, sSig);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(seller), net);
        assertEq(token.balanceOf(feeRecipient), fee);
    }

    function test_MutualSplit_EmitsSplitWithPostFeeAmounts() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _splitSigs(AMOUNT / 2, 0, _deadline());
        uint256 finalBuyer = (AMOUNT / 2 * net) / AMOUNT;
        uint256 finalSeller = net - finalBuyer;
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.Split(finalBuyer, finalSeller, fee, false);
        escrow.mutualSplit(AMOUNT / 2, _deadline(), bSig, sSig);
    }

    function test_MutualSplit_OverDealAmountReverts() public {
        _fundActive();
        vm.expectRevert("over amount");
        (bytes memory bSig, bytes memory sSig) = _splitSigs(AMOUNT + 1, 0, _deadline());
        escrow.mutualSplit(AMOUNT + 1, _deadline(), bSig, sSig);
    }

    function test_MutualSplit_FromDisputedReturnsPotAndSplits() public {
        _openDisputeAs(seller);
        (bytes memory bSig, bytes memory sSig) = _splitSigs(AMOUNT / 2, 0, _deadline());
        escrow.mutualSplit(AMOUNT / 2, _deadline(), bSig, sSig);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
        assertEq(token.balanceOf(seller), (AMOUNT / 2 * net) / AMOUNT + ARB_FEE); // pot back to opener
    }

    // ─── Release from Disputed ────────────────────────────────────────────

    function test_Release_FromDisputedSettlesWithoutRuling() public {
        _openDisputeAs(buyer);
        uint256 buyerBefore = token.balanceOf(buyer);
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, _deadline());
        escrow.release(_deadline(), bSig, sSig);

        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
        assertEq(token.balanceOf(seller), net);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(token.balanceOf(buyer), buyerBefore + ARB_FEE); // fee pot returned
    }

    // ─── ReplaceArbitrator ────────────────────────────────────────────────

    function test_ReplaceArbitrator_MutualConsent() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _replaceArbSigs(newArb, 0, _deadline());
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.ArbitratorReplaced(arb, newArb);
        escrow.replaceArbitrator(newArb, _deadline(), bSig, sSig);
        assertEq(escrow.arbitrator(), newArb);
        assertEq(escrow.nonce(), 1);
    }

    function test_ReplaceArbitrator_FromDisputed() public {
        _openDisputeAs(buyer);
        (bytes memory bSig, bytes memory sSig) = _replaceArbSigs(newArb, 0, _deadline());
        escrow.replaceArbitrator(newArb, _deadline(), bSig, sSig);
        assertEq(escrow.arbitrator(), newArb);
    }

    function test_ReplaceArbitrator_RejectsPartyAsNewArb() public {
        _fundActive();
        vm.expectRevert("bad arb");
        (bytes memory bSig, bytes memory sSig) = _replaceArbSigs(buyer, 0, _deadline());
        escrow.replaceArbitrator(buyer, _deadline(), bSig, sSig);
    }

    function test_ReplaceArbitrator_StaleSignatureReverts() public {
        _fundActive();
        uint256 expired = block.timestamp - 1;
        (bytes memory bSig, bytes memory sSig) = _replaceArbSigs(newArb, 0, expired);
        vm.expectRevert("sigs expired");
        escrow.replaceArbitrator(newArb, expired, bSig, sSig);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _openDisputeAs(address opener) internal {
        _fundActive();
        _fund(opener, ARB_FEE);
        _approveDeposit(opener, ARB_FEE);
        vm.prank(opener);
        escrow.openDispute();
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Disputed));
    }
}
