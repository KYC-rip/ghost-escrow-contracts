// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBaseV2} from "./utils/GhostTestBaseV2.sol";
import {GhostEscrowV2} from "../src/GhostEscrowV2.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";

/// @dev Phase A — GhostEscrowV2: lifecycle parity with v1.1 + the
///      replaceArbitrator eligibility invariant (§1.2a locked-i).
contract GhostEscrowV2Test is GhostTestBaseV2 {
    // ─── Lifecycle parity (deposit/release/refund/dispute/rule) ────────────

    function test_lifecycle_fund_release() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        assertEq(escrowV2.arbitrator(), arb);
        (bytes memory b, bytes memory s) = _releaseSigsV2(address(escrowV2), 0, _deadline());
        vm.prank(buyer);
        escrowV2.release(_deadline(), b, s);
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));
        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(seller), AMOUNT - fee);
        assertEq(token.balanceOf(feeRecipient), fee);
    }

    function test_lifecycle_dispute_rule() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _fund(buyer, ARB_FEE);
        _approveArbFee();
        vm.prank(buyer);
        escrowV2.openDispute();
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Disputed));
        vm.prank(arb);
        escrowV2.rule(AMOUNT / 2, AMOUNT - AMOUNT / 2, keccak256("rationale"));
        // Staged ruling (Phase C): rule() parks the deal in RuledPendingAppeal;
        // funds settle only when the 48h appeal window lapses (finalize) or an
        // appeal resolves.
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.RuledPendingAppeal));
        vm.warp(block.timestamp + escrowV2.APPEAL_WINDOW() + 1);
        escrowV2.finalize();
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));
    }

    function test_constructor_requires_registry() public {
        vm.expectRevert(bytes("zero registry"));
        new GhostEscrowV2(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE,
            ArbitratorRegistry(address(0))
        );
    }

    // ─── replaceArbitrator eligibility (§1.2a) ─────────────────────────────

    function test_replace_rejects_unstaked_new_arbitrator() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), stranger, 0, _deadline());
        vm.prank(buyer);
        vm.expectRevert(bytes("arb not eligible"));
        escrowV2.replaceArbitrator(stranger, _deadline(), b, s);
        assertEq(escrowV2.arbitrator(), arb, "arbitrator unchanged");
    }

    function test_replace_rejects_understaked_new_arbitrator() public {
        _stake(arb, STAKE_FOR_AMOUNT, "arb-pk");
        _stake(newArb, (AMOUNT / STAKE_MULTIPLE) - 1e6, "new-pk"); // one unit short
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), newArb, 0, _deadline());
        vm.prank(buyer);
        vm.expectRevert(bytes("arb not eligible"));
        escrowV2.replaceArbitrator(newArb, _deadline(), b, s);
    }

    function test_replace_accepts_eligible_new_arbitrator() public {
        _stakeArbEligible();
        _stakeNewArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), newArb, 0, _deadline());
        vm.prank(buyer);
        escrowV2.replaceArbitrator(newArb, _deadline(), b, s);
        assertEq(escrowV2.arbitrator(), newArb, "eligible arb accepted");
    }

    function test_replace_works_from_disputed_state() public {
        _stakeArbEligible();
        _stakeNewArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _fund(buyer, ARB_FEE);
        _approveArbFee();
        vm.prank(buyer);
        escrowV2.openDispute();
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), newArb, 0, _deadline());
        vm.prank(buyer);
        escrowV2.replaceArbitrator(newArb, _deadline(), b, s);
        assertEq(escrowV2.arbitrator(), newArb);
    }

    function test_replace_still_rejects_bad_arb_actor() public {
        _stakeArbEligible();
        _stake(buyer, STAKE_FOR_AMOUNT, "buyer-pk"); // buyer is staked but still invalid as arb
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), buyer, 0, _deadline());
        vm.prank(buyer);
        vm.expectRevert(bytes("bad arb"));
        escrowV2.replaceArbitrator(buyer, _deadline(), b, s);
    }

    function test_replace_eligible_at_dispute_but_stake_withdrawn_later() public {
        // The eligibility check is one-time; after unbonding+withdraw the NEW
        // arb is no longer eligible, but a swap already performed holds (this
        // is the documented residual — bounded by UNBONDING_DELAY).
        _stakeArbEligible();
        _stakeNewArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), newArb, 0, _deadline());
        vm.prank(buyer);
        escrowV2.replaceArbitrator(newArb, _deadline(), b, s);
        assertEq(escrowV2.arbitrator(), newArb);
        assertFalse(registry.isEligible(newArb, AMOUNT) == false, "still eligible pre-unbond");
    }

    // ─── Documented property: codeless registry bricks replaceArbitrator ───

    function _approveArbFee() internal {
        vm.prank(buyer);
        token.approve(address(escrowV2), ARB_FEE);
    }

    function test_codeless_registry_bricks_replacement() public {
        // The real registry has no selfdestruct, so this is defensive: if the
        // registry address ever had its code removed, replaceArbitrator's view
        // call decodes empty → reverts (documented liveness property).
        GhostEscrowV2 dead = new GhostEscrowV2(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE,
            ArbitratorRegistry(address(0xbeef)) // non-zero, no code
        );
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(dead), AMOUNT);
        vm.prank(buyer);
        dead.deposit(AMOUNT);
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(dead), stranger, 0, _deadline());
        vm.prank(buyer);
        vm.expectRevert();
        dead.replaceArbitrator(stranger, _deadline(), b, s);
    }

    // ─── Gate coverage (scoped claim) ───────────────────────────────────────
    // NOTE (Phase A review): this asserts the NAMING/REPLACEMENT gates only —
    // "every arb that can rule was eligible when INSTALLED". It does NOT cover
    // withdraw-then-rule: rule() does not re-check eligibility and the
    // registry's withdraw() isn't blocked by open cases, so an arb on a
    // long-lived disputed deal can unbond → wait → withdraw → rule() with zero
    // stake. Harmless in Phase A (no slashing); Phase B adds active-case-aware
    // unbonding (registry blocks requestUnbond/withdraw while >=1 open case)
    // which closes it and delivers concurrent-exposure accounting. Do not
    // re-assert "no unstaked arb can rule at rule time" here.

    function test_installed_arb_is_eligible_via_both_gates() public {
        // Create via factory requires an eligible arb; a deal can only ever be
        // ruled by its (possibly replaced) arb, and replacement also requires
        // eligibility. Thus: any arb installed to rule was eligible at the
        // gate that installed them (creation or replacement).
        _stakeArbEligible();
        (address deal, ) = _createViaFactory(keccak256("inv"));
        GhostEscrowV2 e = GhostEscrowV2(deal);
        assertEq(e.arbitrator(), arb);
        assertTrue(registry.isEligible(e.arbitrator(), AMOUNT));
    }
}
