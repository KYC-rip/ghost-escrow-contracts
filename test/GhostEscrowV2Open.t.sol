// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBaseV2} from "./utils/GhostTestBaseV2.sol";
import {GhostEscrowV2} from "../src/GhostEscrowV2.sol";
import {GhostEscrowV2Open} from "../src/GhostEscrowV2Open.sol";
import {EscrowFactoryV2} from "../src/EscrowFactoryV2.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev Open (deploy-then-join) escrow variant. Covers the set-once join gate,
///      the invite-signature auth (open + locked-to-a-joiner), the joinAndDeposit
///      griefing mitigation, cancelUnjoined recovery, and that a post-join deal
///      behaves exactly like a GhostEscrowV2 deal (happy + dispute paths).
contract GhostEscrowV2OpenTest is GhostTestBaseV2 {
    bytes32 internal constant JOIN_TYPEHASH = keccak256("Join(address deal,uint256 deadline,address joiner)");

    function _joinSig(uint256 creatorPk, address deal, uint256 deadline, address joiner)
        internal
        view
        returns (bytes memory)
    {
        bytes32 d = SigUtils.digest(deal, chainId, keccak256(abi.encode(JOIN_TYPEHASH, deal, deadline, joiner)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(creatorPk, d);
        return abi.encodePacked(r, s, v);
    }

    function _openTerms(address b, address s) internal view returns (EscrowFactoryV2.Terms memory) {
        return EscrowFactoryV2.Terms({
            token: address(token),
            buyer: b,
            seller: s,
            arbitrator: arb,
            dealAmount: AMOUNT,
            arbitratorFee: ARB_FEE,
            depositTimeout: DEPOSIT_TIMEOUT,
            autoReleaseDelay: AUTO_RELEASE
        });
    }

    /// creator = seller, open slot = buyer.
    function _deployOpenBuyer() internal returns (GhostEscrowV2Open e) {
        _stakeArbEligible();
        EscrowFactoryV2.Terms memory t = _openTerms(address(0), seller);
        e = GhostEscrowV2Open(factoryV2.createOpenEscrow(t, keccak256("open-buyer")));
    }

    /// creator = buyer, open slot = seller.
    function _deployOpenSeller() internal returns (GhostEscrowV2Open e) {
        _stakeArbEligible();
        EscrowFactoryV2.Terms memory t = _openTerms(buyer, address(0));
        e = GhostEscrowV2Open(factoryV2.createOpenEscrow(t, keccak256("open-seller")));
    }

    function _dl() internal view returns (uint256) {
        return block.timestamp + 1 hours; // <= depositDeadline (now + 72h)
    }

    // ─── CREATE2 stability ──────────────────────────────────────────────────────

    function test_predict_matches_deploy_open() public {
        _stakeArbEligible();
        EscrowFactoryV2.Terms memory t = _openTerms(address(0), seller);
        bytes32 salt = keccak256("p");
        address predicted = factoryV2.predictOpenAddress(t, salt);
        address deployed = factoryV2.createOpenEscrow(t, salt);
        assertEq(predicted, deployed, "open predict != deploy");
    }

    function test_constructor_requires_exactly_one_open() public {
        _stakeArbEligible();
        // both set -> reject
        vm.expectRevert(bytes("one open slot"));
        factoryV2.createOpenEscrow(_openTerms(buyer, seller), keccak256("both"));
        // both zero -> reject
        vm.expectRevert(bytes("one open slot"));
        factoryV2.createOpenEscrow(_openTerms(address(0), address(0)), keccak256("neither"));
    }

    // ─── join gate ──────────────────────────────────────────────────────────────

    // Plain (unfunded) join is the SELLER-open path (joiner becomes the seller).
    function test_join_sets_slot_once_then_locked() public {
        GhostEscrowV2Open e = _deployOpenSeller(); // creator = buyer, open = seller
        uint256 dl = _dl();
        bytes memory sig = _joinSig(buyerPk, address(e), dl, address(0)); // open to anyone
        vm.prank(seller);
        e.join(dl, address(0), sig);
        assertTrue(e.joined());
        assertEq(e.seller(), seller);
        // second join reverts
        vm.prank(newArb);
        vm.expectRevert(bytes("joined"));
        e.join(dl, address(0), sig);
    }

    function test_join_rejects_bad_invite() public {
        GhostEscrowV2Open e = _deployOpenSeller();
        uint256 dl = _dl();
        // signed by the WRONG key (seller, not the creator/buyer)
        bytes memory badSig = _joinSig(sellerPk, address(e), dl, address(0));
        vm.prank(seller);
        vm.expectRevert(bytes("bad invite"));
        e.join(dl, address(0), badSig);
    }

    function test_join_rejects_creator_and_arb() public {
        GhostEscrowV2Open e = _deployOpenSeller();
        uint256 dl = _dl();
        bytes memory sig = _joinSig(buyerPk, address(e), dl, address(0));
        vm.prank(buyer); // creator
        vm.expectRevert(bytes("bad joiner"));
        e.join(dl, address(0), sig);
        vm.prank(arb);
        vm.expectRevert(bytes("bad joiner"));
        e.join(dl, address(0), sig);
    }

    function test_join_locked_to_specific_joiner() public {
        GhostEscrowV2Open e = _deployOpenSeller();
        uint256 dl = _dl();
        // invite bound to `seller` only
        bytes memory sig = _joinSig(buyerPk, address(e), dl, seller);
        // a different address cannot use it
        vm.prank(stranger);
        vm.expectRevert(bytes("not invited"));
        e.join(dl, seller, sig);
        // the named joiner can
        vm.prank(seller);
        e.join(dl, seller, sig);
        assertEq(e.seller(), seller);
    }

    function test_join_deadline_after_window_reverts() public {
        GhostEscrowV2Open e = _deployOpenSeller();
        uint256 dl = e.depositDeadline() + 1; // outlasts the deposit window
        bytes memory sig = _joinSig(buyerPk, address(e), dl, address(0));
        vm.prank(seller);
        vm.expectRevert(bytes("invite outlasts window"));
        e.join(dl, address(0), sig);
    }

    // OPEN-CR-1: buyer-open must fully fund via joinAndDeposit — plain/partial blocked.
    function test_plain_join_disabled_for_buyer_open() public {
        GhostEscrowV2Open e = _deployOpenBuyer(); // open slot = buyer
        uint256 dl = _dl();
        bytes memory sig = _joinSig(sellerPk, address(e), dl, address(0));
        vm.prank(buyer);
        vm.expectRevert(bytes("buyer-open: use joinAndDeposit"));
        e.join(dl, address(0), sig);
    }

    function test_partial_joinAndDeposit_reverts() public {
        GhostEscrowV2Open e = _deployOpenBuyer();
        uint256 dl = _dl();
        bytes memory sig = _joinSig(sellerPk, address(e), dl, address(0));
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(bytes("must fully fund"));
        e.joinAndDeposit(dl, address(0), sig, AMOUNT / 2); // partial → not Active
    }

    function test_deposit_blocked_before_join() public {
        GhostEscrowV2Open e = _deployOpenBuyer();
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(bytes("not joined"));
        e.deposit(AMOUNT);
    }

    // ─── joinAndDeposit (buyer-open griefing mitigation) ─────────────────────────

    function test_joinAndDeposit_buyer_open_goes_active() public {
        GhostEscrowV2Open e = _deployOpenBuyer();
        uint256 dl = _dl();
        bytes memory sig = _joinSig(sellerPk, address(e), dl, address(0));
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), AMOUNT);
        vm.prank(buyer);
        e.joinAndDeposit(dl, address(0), sig, AMOUNT);
        assertTrue(e.joined());
        assertEq(e.buyer(), buyer);
        assertEq(uint256(e.state()), uint256(GhostEscrowV2Open.State.Active));
        assertEq(e.deposited(), AMOUNT);
    }

    function test_joinAndDeposit_rejected_when_seller_open() public {
        GhostEscrowV2Open e = _deployOpenSeller(); // creator = buyer, open = seller
        uint256 dl = _dl();
        bytes memory sig = _joinSig(buyerPk, address(e), dl, address(0));
        vm.prank(seller);
        vm.expectRevert(bytes("open slot not buyer"));
        e.joinAndDeposit(dl, address(0), sig, AMOUNT);
    }

    // ─── cancelUnjoined ─────────────────────────────────────────────────────────

    function test_cancelUnjoined_creator_only_and_prejoin() public {
        GhostEscrowV2Open e = _deployOpenBuyer(); // creator = seller
        vm.prank(stranger);
        vm.expectRevert(bytes("not creator"));
        e.cancelUnjoined();
        vm.prank(seller);
        e.cancelUnjoined();
        assertEq(uint256(e.state()), uint256(GhostEscrowV2Open.State.Cancelled));
    }

    function test_cancelUnjoined_sweeps_stray_balance() public {
        GhostEscrowV2Open e = _deployOpenBuyer(); // creator = seller
        // a mistaken direct transfer into the deal pre-join
        _fund(address(this), 1234e6);
        token.transfer(address(e), 1234e6);
        uint256 sellerBefore = token.balanceOf(seller);
        vm.prank(seller);
        e.cancelUnjoined();
        assertEq(token.balanceOf(seller), sellerBefore + 1234e6, "stray not swept to creator");
    }

    function test_cannot_cancel_after_join() public {
        GhostEscrowV2Open e = _deployOpenSeller(); // creator = buyer
        uint256 dl = _dl();
        bytes memory sig = _joinSig(buyerPk, address(e), dl, address(0));
        vm.prank(seller);
        e.join(dl, address(0), sig);
        vm.prank(buyer); // creator
        vm.expectRevert(bytes("joined"));
        e.cancelUnjoined();
    }

    // ─── post-join: behaves as a v2 deal ─────────────────────────────────────────

    function test_open_deal_full_happy_path() public {
        GhostEscrowV2Open e = _deployOpenBuyer(); // creator = seller, joiner = buyer
        uint256 dl = _dl();
        bytes memory sig = _joinSig(sellerPk, address(e), dl, address(0));
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), AMOUNT);
        vm.prank(buyer);
        e.joinAndDeposit(dl, address(0), sig, AMOUNT);

        // mutual release → seller paid (net fee)
        (bytes memory bSig, bytes memory sSig) = _releaseSigsV2(address(e), e.nonce(), _deadline());
        e.release(_deadline(), bSig, sSig);
        assertEq(uint256(e.state()), uint256(GhostEscrowV2Open.State.Completed));
        uint256 fee = AMOUNT * FEE_BPS / 10000;
        assertEq(token.balanceOf(seller), AMOUNT - fee, "seller net");
        assertEq(token.balanceOf(feeRecipient), fee, "fee once");
    }

    function test_open_deal_dispute_rule_finalize() public {
        GhostEscrowV2Open e = _deployOpenBuyer();
        uint256 dl = _dl();
        bytes memory sig = _joinSig(sellerPk, address(e), dl, address(0));
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), AMOUNT);
        vm.prank(buyer);
        e.joinAndDeposit(dl, address(0), sig, AMOUNT);

        // buyer opens a dispute (pre-pays arb fee) → arb rules → finalize
        _fund(buyer, ARB_FEE);
        vm.prank(buyer);
        token.approve(address(e), ARB_FEE);
        vm.prank(buyer);
        e.openDispute();
        vm.prank(arb);
        e.rule(AMOUNT / 2, AMOUNT / 2, keccak256("r"));
        assertEq(uint256(e.state()), uint256(GhostEscrowV2Open.State.RuledPendingAppeal));
        vm.warp(block.timestamp + e.APPEAL_WINDOW() + 1);
        e.finalize();
        assertEq(uint256(e.state()), uint256(GhostEscrowV2Open.State.Completed));
    }
}
