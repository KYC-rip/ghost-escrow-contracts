// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBaseV2} from "./utils/GhostTestBaseV2.sol";
import {GhostEscrowV2} from "../src/GhostEscrowV2.sol";
import {EscrowFactoryV2} from "../src/EscrowFactoryV2.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Phase C: appeals + panels. Exercises the AppealCourt end-to-end against
///      the staged-ruling escrow — uphold, overturn (+slash, +bond refund),
///      window-expiry finalize, high-value first-ruling panel (final), panel
///      draw exclusion, double-appeal / window guards, deployer-gated setCourt,
///      court-only overturn slash, and the two-token (bond vs USDC) accounting.
contract AppealCourtTest is GhostTestBaseV2 {
    uint256 internal p1pk = 0x9A5E01;
    uint256 internal p2pk = 0x9A5E02;
    uint256 internal p3pk = 0x9A5E03;
    address internal p1;
    address internal p2;
    address internal p3;

    uint256 internal constant PANEL_STAKE = 500e6; // > arb 420e6, eligible for $4200
    uint256 internal constant BOND = AMOUNT / 5; // 20% = 840e6

    function setUp() public override {
        super.setUp();
        p1 = vm.addr(p1pk);
        p2 = vm.addr(p2pk);
        p3 = vm.addr(p3pk);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _stakePanel() internal {
        _stake(p1, PANEL_STAKE, "p1");
        _stake(p2, PANEL_STAKE, "p2");
        _stake(p3, PANEL_STAKE, "p3");
    }

    /// Fund + open dispute (buyer) + arb rules the given split → RuledPendingAppeal.
    function _ruleTo(uint256 buyerAmt, uint256 sellerAmt) internal {
        _fundActiveV2();
        _openDisputeV2(); // buyer opens, pays ARB_FEE
        vm.prank(arb);
        escrowV2.rule(buyerAmt, sellerAmt, keccak256("r"));
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.RuledPendingAppeal));
    }

    /// A party posts the 20% appeal bond and appeals.
    function _appeal(address who) internal {
        _fund(who, BOND);
        vm.prank(who);
        token.approve(address(escrowV2), BOND);
        vm.prank(who);
        escrowV2.appeal();
    }

    function _draw() internal {
        vm.roll(block.number + court.DRAW_DELAY() + 1);
        court.drawPanel(address(escrowV2));
        (, uint8 len) = court.panelOf(address(escrowV2));
        assertEq(len, 3, "panel not drawn");
    }

    function _panelVote(address member, uint256 b, uint256 s) internal {
        vm.prank(member);
        court.vote(address(escrowV2), b, s, keccak256("v"));
    }

    // ─── uphold ──────────────────────────────────────────────────────────────

    function test_appeal_uphold_bond_to_panel_ruling_stands() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);

        _appeal(seller); // seller appeals
        _draw();

        // Two members vote the SAME split as the original → UPHOLD.
        _panelVote(p1, AMOUNT / 2, AMOUNT / 2);
        _panelVote(p2, AMOUNT / 2, AMOUNT / 2);

        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));

        // Original ruling settled: 50/50 net of the 1.5% fee.
        uint256 fee = AMOUNT * FEE_BPS / 10000;
        uint256 remaining = AMOUNT - fee;
        uint256 fb = (AMOUNT / 2) * remaining / AMOUNT;
        assertEq(token.balanceOf(buyer), fb + ARB_FEE, "buyer split+fee"); // buyer=opener won (>=) → fee pot
        assertEq(token.balanceOf(seller), remaining - fb, "seller split");
        assertEq(token.balanceOf(feeRecipient), fee, "platform fee once");

        // Bond (deal token) → panel, appellant loses it. arb NOT slashed.
        uint256 third = BOND / 3;
        assertEq(token.balanceOf(p1), third + (BOND - third * 3), "p1 bond share+dust");
        assertEq(token.balanceOf(p2), third, "p2 bond share");
        assertEq(token.balanceOf(p3), third, "p3 bond share");
        assertEq(registry.stakeOf(arb), STAKE_FOR_AMOUNT, "arb stake untouched on uphold");
    }

    // ─── overturn ──────────────────────────────────────────────────────────────

    function test_appeal_overturn_slash_resettle_refund() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);

        _appeal(seller);
        _draw();

        // Two members vote a DIFFERENT split (all to buyer) → OVERTURN.
        _panelVote(p1, AMOUNT, 0);
        _panelVote(p2, AMOUNT, 0);

        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));

        // Re-settled per the panel: buyer gets all (net fee), seller 0.
        uint256 fee = AMOUNT * FEE_BPS / 10000;
        uint256 remaining = AMOUNT - fee;
        assertEq(token.balanceOf(feeRecipient), fee, "platform fee once");

        // arb slashed by OVERTURN_SLASH_BPS; proceeds → panel (USDC).
        uint256 slash = STAKE_FOR_AMOUNT * OVERTURN_SLASH_BPS / 10000;
        assertEq(registry.stakeOf(arb), STAKE_FOR_AMOUNT - slash, "arb slashed by overturn bps");
        uint256 third = slash / 3;
        // Appellant (seller) bond refunded in full (deal token) → net cost 0.
        // seller also gets 0 from the re-settle. So seller balance == BOND refund.
        assertEq(token.balanceOf(seller), BOND, "appellant bond refunded");
        // buyer: re-settled share (all of remaining) + arb fee pot (opener won).
        assertEq(token.balanceOf(buyer), remaining + ARB_FEE, "buyer resettle+fee");
        // panel each got a slash third (USDC).
        assertEq(token.balanceOf(p1), third + (slash - third * 3), "p1 slash share+dust");
        assertEq(token.balanceOf(p2), third, "p2 slash share");
        assertEq(token.balanceOf(p3), third, "p3 slash share");
    }

    // ─── finalize (no appeal) ──────────────────────────────────────────────────

    function test_finalize_after_window_no_appeal() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);

        vm.warp(block.timestamp + escrowV2.APPEAL_WINDOW() + 1);
        escrowV2.finalize();
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));
        uint256 fee = AMOUNT * FEE_BPS / 10000;
        assertEq(token.balanceOf(feeRecipient), fee, "fee once");
    }

    function test_finalize_before_window_reverts() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        vm.expectRevert(bytes("too early"));
        escrowV2.finalize();
    }

    // ─── guards ────────────────────────────────────────────────────────────────

    function test_appeal_after_window_reverts() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        vm.warp(block.timestamp + escrowV2.APPEAL_WINDOW() + 1);
        _fund(seller, BOND);
        vm.prank(seller);
        token.approve(address(escrowV2), BOND);
        vm.prank(seller);
        vm.expectRevert(bytes("appeal closed"));
        escrowV2.appeal();
    }

    function test_double_appeal_reverts() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _appeal(seller);
        _fund(buyer, BOND);
        vm.prank(buyer);
        token.approve(address(escrowV2), BOND);
        vm.prank(buyer);
        vm.expectRevert(bytes("already appealed"));
        escrowV2.appeal();
    }

    function test_nonparty_cannot_appeal() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _fund(stranger, BOND);
        vm.prank(stranger);
        token.approve(address(escrowV2), BOND);
        vm.prank(stranger);
        vm.expectRevert(bytes("not party"));
        escrowV2.appeal();
    }

    // ─── panel draw ─────────────────────────────────────────────────────────────

    function test_draw_excludes_parties_and_original_arb() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _appeal(seller);
        _draw();
        (address[3] memory panel,) = court.panelOf(address(escrowV2));
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(panel[i] != buyer && panel[i] != seller && panel[i] != arb, "excluded party on panel");
            assertTrue(panel[i] == p1 || panel[i] == p2 || panel[i] == p3, "non-candidate on panel");
        }
        assertTrue(panel[0] != panel[1] && panel[1] != panel[2] && panel[0] != panel[2], "dup panel member");
    }

    function test_drawPanel_too_early_reverts() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _appeal(seller);
        vm.expectRevert(bytes("too early"));
        court.drawPanel(address(escrowV2));
    }

    function test_nonmember_cannot_vote() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _appeal(seller);
        _draw();
        vm.prank(stranger);
        vm.expectRevert(bytes("not member"));
        court.vote(address(escrowV2), AMOUNT / 2, AMOUNT / 2, keccak256("v"));
    }

    // ─── setCourt / slash auth ──────────────────────────────────────────────────

    function test_setCourt_non_deployer_reverts() public {
        // A second registry the test did not "deploy" as msg.sender? The test IS
        // the deployer here; a stranger prank must fail.
        vm.prank(stranger);
        vm.expectRevert(bytes("not deployer"));
        registry.setCourt(address(0xBEEF));
    }

    function test_setCourt_rebind_reverts() public {
        vm.expectRevert(bytes("locked"));
        registry.setCourt(address(0xBEEF)); // already bound in setUp
    }

    function test_slashOnOverturn_only_court() public {
        _stakeArbEligible();
        vm.prank(stranger);
        vm.expectRevert(bytes("not court"));
        registry.slashOnOverturn(arb);
    }

    // ─── high-value first-ruling panel (C-2, FINAL) ─────────────────────────────

    uint256 internal constant HV_AMOUNT = 30_000e6;
    uint256 internal constant HV_ARB_STAKE = 3_000e6;
    uint256 internal constant HV_PANEL_STAKE = 3_500e6;

    function _createHVDeal() internal returns (GhostEscrowV2 e) {
        EscrowFactoryV2.Terms memory t = EscrowFactoryV2.Terms({
            token: address(token),
            buyer: buyer,
            seller: seller,
            arbitrator: arb,
            dealAmount: HV_AMOUNT,
            arbitratorFee: ARB_FEE,
            depositTimeout: DEPOSIT_TIMEOUT,
            autoReleaseDelay: AUTO_RELEASE
        });
        e = GhostEscrowV2(factoryV2.createEscrow(t, keccak256("hv")));
    }

    function test_highvalue_requires_panel_and_is_final() public {
        _stake(arb, HV_ARB_STAKE, "arb");
        _stake(p1, HV_PANEL_STAKE, "p1");
        _stake(p2, HV_PANEL_STAKE, "p2");
        _stake(p3, HV_PANEL_STAKE, "p3");
        escrowV2 = _createHVDeal();

        // fund active + open dispute (buyer) with HV amounts.
        _fund(buyer, HV_AMOUNT);
        vm.prank(buyer);
        token.approve(address(escrowV2), HV_AMOUNT);
        vm.prank(buyer);
        escrowV2.deposit(HV_AMOUNT);
        _fund(buyer, ARB_FEE);
        vm.prank(buyer);
        token.approve(address(escrowV2), ARB_FEE);
        vm.prank(buyer);
        escrowV2.openDispute();
        assertEq(registry.openCases(arb), 1, "arb assigned at open");

        // Single-arb rule() is BLOCKED above the threshold.
        vm.prank(arb);
        vm.expectRevert(bytes("panel required"));
        escrowV2.rule(HV_AMOUNT / 2, HV_AMOUNT / 2, keccak256("x"));

        // The first-ruling panel draws and rules.
        _draw();
        _panelVote(p1, HV_AMOUNT / 2, HV_AMOUNT / 2);
        _panelVote(p2, HV_AMOUNT / 2, HV_AMOUNT / 2);
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.RuledPendingAppeal));
        // Escrow-B: the bypassed named arb's SLA case is cleared (not slashable).
        assertEq(registry.openCases(arb), 0, "arb SLA case cleared by panel");
        // Fee pot split 3-ways to the panel (deal token) — exact, dust to panel[0]
        // (order is seed-dependent, so assert the total across the panel).
        assertEq(token.balanceOf(p1) + token.balanceOf(p2) + token.balanceOf(p3), ARB_FEE, "fee split total");

        // A high-value first-panel ruling is FINAL — appeal is blocked.
        _fund(seller, HV_AMOUNT / 5);
        vm.prank(seller);
        token.approve(address(escrowV2), HV_AMOUNT / 5);
        vm.prank(seller);
        vm.expectRevert(bytes("panel final"));
        escrowV2.appeal();

        // Only finalize (after the window) settles it.
        vm.warp(block.timestamp + escrowV2.APPEAL_WINDOW() + 1);
        escrowV2.finalize();
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));
    }

    // ─── B6: cross-token (deal token != USDC) bond vs slash ─────────────────────

    function test_overturn_cross_token_no_conflation() public {
        MockERC20 dealTok = new MockERC20("DEAL", "DEAL", 6);
        _stakeArbEligible(); // stakes are USDC (base token)
        _stakePanel();

        EscrowFactoryV2.Terms memory t = EscrowFactoryV2.Terms({
            token: address(dealTok),
            buyer: buyer,
            seller: seller,
            arbitrator: arb,
            dealAmount: AMOUNT,
            arbitratorFee: ARB_FEE,
            depositTimeout: DEPOSIT_TIMEOUT,
            autoReleaseDelay: AUTO_RELEASE
        });
        escrowV2 = GhostEscrowV2(factoryV2.createEscrow(t, keccak256("xtok")));

        // fund + dispute + rule, all in the DEAL token.
        dealTok.mint(buyer, AMOUNT + ARB_FEE);
        vm.startPrank(buyer);
        dealTok.approve(address(escrowV2), AMOUNT + ARB_FEE);
        escrowV2.deposit(AMOUNT);
        escrowV2.openDispute();
        vm.stopPrank();
        vm.prank(arb);
        escrowV2.rule(AMOUNT / 2, AMOUNT / 2, keccak256("r"));

        // seller appeals: bond in the DEAL token.
        dealTok.mint(seller, BOND);
        vm.startPrank(seller);
        dealTok.approve(address(escrowV2), BOND);
        escrowV2.appeal();
        vm.stopPrank();

        _draw();
        _panelVote(p1, AMOUNT, 0); // overturn
        _panelVote(p2, AMOUNT, 0);

        // Slash proceeds are USDC (base token) → panel; arb slashed by the bps.
        uint256 slash = STAKE_FOR_AMOUNT * OVERTURN_SLASH_BPS / 10000;
        uint256 third = slash / 3;
        assertEq(token.balanceOf(p1), third + (slash - third * 3), "p1 USDC slash");
        assertEq(token.balanceOf(p2), third, "p2 USDC slash");
        assertEq(registry.stakeOf(arb), STAKE_FOR_AMOUNT - slash, "arb slashed by overturn bps");
        // Bond (deal token) refunded to the appellant — NOT to the panel.
        assertEq(dealTok.balanceOf(seller), BOND, "appellant dealTok bond refund");
        assertEq(dealTok.balanceOf(p1), 0, "panel got no dealTok on overturn");
        // Re-settle in the deal token.
        uint256 fee = AMOUNT * FEE_BPS / 10000;
        assertEq(dealTok.balanceOf(feeRecipient), fee, "fee once (deal token)");
    }

    // ─── draw re-arm (C-1 256-block horizon miss) ───────────────────────────────

    function test_drawPanel_rearm_after_horizon_miss() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _appeal(seller);

        // Miss the 256-block horizon → re-arm (not drawn), no revert.
        vm.roll(block.number + court.DRAW_DELAY() + 300);
        court.drawPanel(address(escrowV2));
        (,, bool drawn,,,,,) = court.caseOf(address(escrowV2));
        assertFalse(drawn, "should re-arm, not draw, past horizon");

        // A fresh draw within the horizon succeeds.
        vm.roll(block.number + court.DRAW_DELAY() + 1);
        court.drawPanel(address(escrowV2));
        (,, drawn,,,,,) = court.caseOf(address(escrowV2));
        assertTrue(drawn, "draw after re-arm");
    }

    // ─── C-REV-1: pool-too-small never-drawn timeout (no fund freeze) ───────────

    function test_appeal_pool_too_small_times_out_and_refunds_bond() public {
        _stakeArbEligible();
        _stake(p1, PANEL_STAKE, "p1"); // only ONE eligible-higher candidate → pool < 3
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _appeal(seller);

        // Panel can't be seated → drawPanel reverts, deal would otherwise freeze.
        vm.roll(block.number + court.DRAW_DELAY() + 1);
        vm.expectRevert(bytes("pool too small"));
        court.drawPanel(address(escrowV2));

        // Before the timeout, dismiss is not yet allowed.
        vm.expectRevert(bytes("too early"));
        court.dismiss(address(escrowV2));

        // After requestedAt + SLA_DURATION, anyone dismisses → UPHOLD + bond refund.
        vm.warp(block.timestamp + registry.SLA_DURATION() + 1);
        court.dismiss(address(escrowV2));
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed), "unfrozen to Completed");

        // Original ruling stands (50/50 net fee); appellant bond fully refunded; arb untouched.
        uint256 fee = AMOUNT * FEE_BPS / 10000;
        uint256 remaining = AMOUNT - fee;
        uint256 fb = (AMOUNT / 2) * remaining / AMOUNT;
        assertEq(token.balanceOf(seller), (remaining - fb) + BOND, "seller split + bond refund");
        assertEq(token.balanceOf(feeRecipient), fee, "fee once");
        assertEq(registry.stakeOf(arb), STAKE_FOR_AMOUNT, "arb not slashed on timeout uphold");
    }

    // ─── no-majority timeout dismiss ────────────────────────────────────────────

    function test_dismiss_no_majority_upholds() public {
        _stakeArbEligible();
        _stakePanel();
        escrowV2 = _deployV2Escrow();
        _ruleTo(AMOUNT / 2, AMOUNT / 2);
        _appeal(seller);
        _draw();

        // Only one vote → no 2/3 majority.
        _panelVote(p1, AMOUNT, 0);
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.RuledPendingAppeal));

        // After the panel SLA, anyone can dismiss → UPHOLD (bond → panel).
        vm.warp(block.timestamp + registry.SLA_DURATION() + 1);
        court.dismiss(address(escrowV2));
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));
        uint256 third = BOND / 3;
        assertEq(token.balanceOf(p1), third + (BOND - third * 3), "p1 bond share on dismiss");
    }
}
