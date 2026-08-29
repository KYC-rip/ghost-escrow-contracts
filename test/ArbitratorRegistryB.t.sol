// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBaseV2} from "./utils/GhostTestBaseV2.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {EscrowFactoryV2} from "../src/EscrowFactoryV2.sol";
import {GhostEscrowV2} from "../src/GhostEscrowV2.sol";

/// @dev Phase B — assignment hooks + active-case unbonding + SLA-timeout slash
///      (design §5g + fold-ins), driven through the escrow lifecycle.
contract ArbitratorRegistryBTest is GhostTestBaseV2 {
    function _assignOf(address deal)
        internal
        view
        returns (bool assigned, address arb_, address escrow_, address opener_, uint256 assignedAt)
    {
        return registry.assignmentOf(deal);
    }

    // ─── openCases lifecycle ────────────────────────────────────────────────

    function test_openCases_inc_on_dispute_dec_on_rule() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        assertEq(registry.openCases(arb), 0);
        _openDisputeV2();
        assertEq(registry.openCases(arb), 1, "open case incremented");
        (bool assigned, , , , ) = _assignOf(address(escrowV2));
        assertTrue(assigned, "deal assigned");
        vm.prank(arb);
        escrowV2.rule(AMOUNT / 2, AMOUNT - AMOUNT / 2, keccak256("r"));
        assertEq(registry.openCases(arb), 0, "resolved on rule");
        (assigned, , , , ) = _assignOf(address(escrowV2));
        assertFalse(assigned, "assignment cleared");
    }

    function test_openCases_dec_on_mutual_release_from_disputed() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        assertEq(registry.openCases(arb), 1);
        (bytes memory b, bytes memory s) = _releaseSigsV2(address(escrowV2), 0, _deadline());
        vm.prank(buyer);
        escrowV2.release(_deadline(), b, s);
        assertEq(registry.openCases(arb), 0, "resolved on mutual release from Disputed");
    }

    function test_openCases_dec_on_mutual_refund_from_disputed() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        (bytes memory b, bytes memory s) = _refundSigsV2(address(escrowV2), 0, _deadline());
        vm.prank(buyer);
        escrowV2.refund(_deadline(), b, s);
        assertEq(registry.openCases(arb), 0, "resolved on mutual refund from Disputed");
    }

    function test_openCases_dec_on_mutual_split_from_disputed() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        (bytes memory b, bytes memory s) = _splitSigsV2(address(escrowV2), AMOUNT / 2, 0, _deadline());
        vm.prank(buyer);
        escrowV2.mutualSplit(AMOUNT / 2, _deadline(), b, s);
        assertEq(registry.openCases(arb), 0, "resolved on mutual split from Disputed");
    }

    function test_active_only_terminal_no_underflow() public {
        // release from ACTIVE (never disputed): onResolved no-ops (guarded by
        // assigned[deal]) — openCases must not underflow and stays 0.
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        (bytes memory b, bytes memory s) = _releaseSigsV2(address(escrowV2), 0, _deadline());
        vm.prank(buyer);
        escrowV2.release(_deadline(), b, s);
        assertEq(registry.openCases(arb), 0, "no underflow on Active-only terminal");
    }

    function test_replace_in_disputed_reanchors_assignment() public {
        _stakeArbEligible();
        _stakeNewArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        assertEq(registry.openCases(arb), 1);
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), newArb, 0, _deadline());
        vm.prank(buyer);
        escrowV2.replaceArbitrator(newArb, _deadline(), b, s);
        assertEq(registry.openCases(arb), 0, "old arb's case closed on replace");
        assertEq(registry.openCases(newArb), 1, "new arb assigned");
        (, , , , uint256 assignedAt) = _assignOf(address(escrowV2));
        assertEq(assignedAt, block.timestamp, "SLA clock reset for the new arb");
    }

    function test_replace_in_active_no_assignment_change() public {
        _stakeArbEligible();
        _stakeNewArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), newArb, 0, _deadline());
        vm.prank(buyer);
        escrowV2.replaceArbitrator(newArb, _deadline(), b, s);
        assertEq(registry.openCases(arb), 0);
        assertEq(registry.openCases(newArb), 0, "Active replace: no case opened");
        (bool assigned, , , , ) = _assignOf(address(escrowV2));
        assertFalse(assigned);
    }

    // ─── Unbonding blocked by open cases ────────────────────────────────────

    function test_unbond_blocked_while_open_case() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        vm.prank(arb);
        vm.expectRevert(bytes("open cases"));
        registry.requestUnbond(1e6);
    }

    function test_unbond_allowed_after_resolve() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        vm.prank(arb);
        escrowV2.rule(AMOUNT / 2, AMOUNT - AMOUNT / 2, keccak256("r"));
        vm.prank(arb);
        registry.requestUnbond(1e6);
        (uint256 pending, ) = registry.pendingUnbondOf(arb);
        assertEq(pending, 1e6);
    }

    function test_withdraw_blocked_while_open_case() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        // request unbond FIRST (requires openCases==0), then open the dispute
        vm.prank(arb);
        registry.requestUnbond(1e6);
        _openDisputeV2(); // openCases[arb] = 1 now
        vm.warp(UNBONDING + 1);
        vm.prank(arb);
        vm.expectRevert(bytes("open cases"));
        registry.withdraw();
    }

    // ─── SLA-timeout slash ──────────────────────────────────────────────────

    function test_slash_requires_sla_elapsed() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        vm.warp(block.timestamp + SLA_DURATION); // at exactly the boundary — must still be too early
        vm.prank(stranger);
        vm.expectRevert(bytes("too early"));
        escrowV2.slashForTimeout();
    }

    function test_slash_after_sla() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        uint256 stakeBefore = registry.stakeOf(arb);
        uint256 slash = (stakeBefore * SLA_SLASH_BPS) / 10000;
        uint256 buyerBefore = token.balanceOf(buyer);
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(stranger);
        escrowV2.slashForTimeout();
        assertEq(registry.stakeOf(arb), stakeBefore - slash, "stake slashed");
        assertEq(token.balanceOf(buyer) - buyerBefore, slash + ARB_FEE, "opener gets slash proceeds + fee pot back");
        assertEq(escrowV2.arbitrator(), address(0), "arbitrator cleared");
        assertEq(escrowV2.arbitratorFeePot(), 0, "fee pot returned");
        assertEq(registry.openCases(arb), 0, "case resolved on slash");
    }

    function test_slash_fee_pot_returns_to_opener() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2(); // buyer pays ARB_FEE into the pot
        uint256 buyerBefore = token.balanceOf(buyer);
        uint256 stakeBefore = registry.stakeOf(arb);
        uint256 slash = (stakeBefore * SLA_SLASH_BPS) / 10000;
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(stranger);
        escrowV2.slashForTimeout();
        // buyer receives: slash proceeds (from stake) + the ARB_FEE pot back.
        assertEq(token.balanceOf(buyer) - buyerBefore, slash + ARB_FEE, "opener compensated: slash + fee pot");
    }

    function test_slash_double_slash_reverts() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(stranger);
        escrowV2.slashForTimeout();
        vm.prank(stranger);
        vm.expectRevert(bytes("already slashed"));
        escrowV2.slashForTimeout();
    }

    function test_slash_then_late_rule_reverts() public {
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(stranger);
        escrowV2.slashForTimeout();
        vm.prank(arb);
        vm.expectRevert(bytes("not arbitrator")); // arbitrator cleared → rule() reverts
        escrowV2.rule(AMOUNT / 2, AMOUNT - AMOUNT / 2, keccak256("late"));
    }

    function test_slash_then_replace_works() public {
        _stakeArbEligible();
        _stakeNewArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(stranger);
        escrowV2.slashForTimeout();
        assertEq(escrowV2.arbitrator(), address(0));
        // parties replace to the eligible new arb → re-assigns + resets SLA clock
        (bytes memory b, bytes memory s) = _replaceArbSigsV2(address(escrowV2), newArb, 0, _deadline());
        vm.prank(buyer);
        escrowV2.replaceArbitrator(newArb, _deadline(), b, s);
        assertEq(escrowV2.arbitrator(), newArb);
        assertEq(registry.openCases(newArb), 1, "new arb assigned");
        (bool assigned, , , , uint256 assignedAt) = _assignOf(address(escrowV2));
        assertTrue(assigned);
        assertEq(assignedAt, block.timestamp);
    }

    function test_rule_before_sla_still_valid() public {
        // rule() is valid through the deadline — SLA is a floor, not a hard cut.
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        vm.warp(block.timestamp + SLA_DURATION - 1);
        vm.prank(arb);
        escrowV2.rule(AMOUNT / 2, AMOUNT - AMOUNT / 2, keccak256("on time"));
        // Staged ruling (Phase C): rule() → RuledPendingAppeal and clears the
        // SLA case immediately (onResolved); final settlement is via finalize().
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.RuledPendingAppeal));
        assertEq(registry.openCases(arb), 0);
        vm.warp(block.timestamp + escrowV2.APPEAL_WINDOW() + 1);
        escrowV2.finalize();
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Completed));
    }

    // ─── Caller auth ────────────────────────────────────────────────────────

    function test_hooks_reject_non_escrow() public {
        _stakeArbEligible();
        vm.prank(stranger);
        vm.expectRevert(bytes("not escrow"));
        registry.onDisputeOpened(arb, buyer);
        vm.prank(stranger);
        vm.expectRevert(bytes("not escrow"));
        registry.onResolved(arb, address(0x123));
        vm.prank(stranger);
        vm.expectRevert(bytes("not escrow"));
        registry.onAssigned(arb, address(0x123));
    }

    function test_factory_isEscrow_records_deployed_only() public {
        _stakeArbEligible();
        (address deal, ) = _createViaFactory(keccak256("esc"));
        assertTrue(factoryV2.isEscrow(deal), "deployed escrow recorded");
        assertFalse(factoryV2.isEscrow(stranger), "non-escrow not recorded");
    }

    function test_setFactory_once() public {
        // Bound in setUp (deployer = test contract). Any re-bind reverts.
        vm.prank(stranger);
        vm.expectRevert(bytes("not deployer"));
        registry.setFactory(stranger);
        vm.expectRevert(bytes("locked"));
        registry.setFactory(address(0x123));
    }

    function test_slash_requires_owning_escrow() public {
        // The registry scopes slashTimeoutStake to the deal's OWN escrow: a
        // different genuine escrow cannot slash this deal's case (defense-in-
        // depth — each escrow's slashForTimeout only ever targets address(this),
        // so a cross-deal slash is impossible through the escrow interface).
        _stakeArbEligible();
        escrowV2 = _deployV2Escrow();
        _fundActiveV2();
        _openDisputeV2();
        address firstDeal = address(escrowV2);
        (address otherDeal, ) = _createViaFactory(keccak256("other"));
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(otherDeal); // a genuine escrow, but not the one that owns the case
        vm.expectRevert(bytes("not assigned"));
        registry.slashTimeoutStake(firstDeal);
    }
}
