// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GhostTestBaseD} from "./utils/GhostTestBaseD.sol";
import {GhostEscrowV2CImpl} from "../src/GhostEscrowV2CImpl.sol";
import {GhostEscrowV2OpenCImpl} from "../src/GhostEscrowV2OpenCImpl.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// v5 contract batch (plans/ghost-escrow-v5-contracts-plan.md): random arbitrator draw, explicit dispute phases,
/// stalemate split, % arbitrator fee, keeper tips, withdrawal tranches, and the Sept-audit fixes F1–F8.
contract V5Test is GhostTestBaseD {
    uint256 internal constant HV_AMOUNT = 30_000e6;

    function _phase(GhostEscrowV2CImpl e) internal view returns (uint256) {
        return uint256(e.arbPhase());
    }

    function _deal(uint256 salt) internal returns (GhostEscrowV2CImpl e) {
        e = _createStd(bytes32(salt));
        _fundActive(e);
    }

    function _hvDeal(uint256 salt) internal returns (GhostEscrowV2CImpl e) {
        bytes memory d =
            abi.encode(address(token), buyer, seller, address(0), HV_AMOUNT, uint256(0), DEPOSIT_TIMEOUT, AUTO_RELEASE);
        e = GhostEscrowV2CImpl(factory.createDeal(address(stdImpl), d, bytes32(salt)));
        _fund(buyer, HV_AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), HV_AMOUNT);
        vm.prank(buyer);
        e.deposit(HV_AMOUNT);
    }

    function _releaseSigs(GhostEscrowV2CImpl e) internal returns (uint256 dl, bytes memory b, bytes memory s) {
        dl = _deadline();
        bytes32 d = SigUtils.releaseDigest(address(e), chainId, e.nonce(), dl);
        b = _sig(buyerPk, d);
        s = _sig(sellerPk, d);
    }

    // ─── size gate (R6) ────────────────────────────────────────────────────

    function test_sizeGate_templatesFitWithHeadroom() public view {
        assertLt(address(stdImpl).code.length, 24_576 - 512, "std template");
        assertLt(address(openImpl).code.length, 24_576 - 512, "open template");
        assertLt(address(registry).code.length, 24_576, "registry");
        assertLt(address(court).code.length, 24_576, "court");
    }

    // ─── D3/R4: arbitrator fee is protocol-set, readable from creation ─────

    function test_arbFee_onePercent_minFive() public {
        GhostEscrowV2CImpl big = _createStd(bytes32(uint256(1)));
        assertEq(big.arbitratorFee(), 42e6, "1 % of $4200");
        bytes memory small =
            abi.encode(address(token), buyer, seller, address(0), uint256(200e6), uint256(0), DEPOSIT_TIMEOUT, AUTO_RELEASE);
        GhostEscrowV2CImpl s = GhostEscrowV2CImpl(factory.createDeal(address(stdImpl), small, bytes32(uint256(2))));
        assertEq(s.arbitratorFee(), 5e6, "$5 minimum");
        assertEq(s.arbitrator(), address(0), "no arbitrator at creation");
    }

    function test_F6_dealTokenMustBeStakingToken() public {
        MockERC20 other = new MockERC20("X", "X", 6);
        bytes memory d =
            abi.encode(address(other), buyer, seller, address(0), AMOUNT, uint256(0), DEPOSIT_TIMEOUT, AUTO_RELEASE);
        vm.expectRevert(bytes("token != staking token"));
        factory.createDeal(address(stdImpl), d, bytes32(uint256(3)));
    }

    // ─── D1/R1/R2/R5: random draw + phases ─────────────────────────────────

    function test_draw_phasesGateTheOldSentinelPaths() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(10);
        _openDisputeOnly(e);
        assertEq(_phase(e), uint256(GhostEscrowV2CImpl.ArbPhase.Drawing));
        // R1: none of the "arbitrator == 0" paths open up while the draw is pending.
        vm.prank(buyer);
        vm.expectRevert(bytes("not slashed"));
        e.escalateAfterTimeout();
        vm.warp(block.timestamp + 31 days);
        vm.prank(buyer);
        vm.expectRevert(bytes("not stranded"));
        e.claimStrandedPot();
        vm.expectRevert(bytes("no seated arb"));
        e.slashForTimeout();
        vm.prank(arb);
        vm.expectRevert(bytes("not arbitrator"));
        e.rule(0, AMOUNT, keccak256("r"));
    }

    function test_draw_seatsEligible_startsSla_paysTip() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(11);
        _openDisputeOnly(e);
        vm.expectRevert(bytes("too early"));
        e.drawArbitrator();
        vm.roll(e.drawBlock() + 1);
        vm.prank(stranger);
        e.drawArbitrator();
        assertEq(e.arbitrator(), arb);
        assertEq(_phase(e), uint256(GhostEscrowV2CImpl.ArbPhase.Seated));
        (bool assigned, address a,,, uint256 assignedAt) = registry.assignmentOf(address(e));
        assertTrue(assigned);
        assertEq(a, arb);
        assertEq(assignedAt, block.timestamp, "SLA anchor = draw time");
        assertGt(e.tipOwed(stranger), 0, "the drawer earns a tip");
    }

    function test_draw_excludesParties_andLateStakers_sameBlockToo() public {
        // buyer and seller stake (they're eligible amounts) — never drawable on their own deal.
        _stake(buyer, STAKE_FOR_AMOUNT, "b");
        _stake(seller, STAKE_FOR_AMOUNT, "s");
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(12)));
        // `arb` stakes in the SAME block as the deal's creation → still not drawable (strict R5).
        token.mint(arb, STAKE_FOR_AMOUNT);
        vm.prank(arb);
        token.approve(address(registry), STAKE_FOR_AMOUNT);
        vm.prank(arb);
        registry.stake(STAKE_FOR_AMOUNT, "a");
        assertEq(registry.stakedSinceBlockOf(arb), e.createdAtBlock());
        _fundActive(e);
        _openDisputeOnly(e);
        vm.roll(e.drawBlock() + 1);
        vm.expectRevert(bytes("no eligible arb"));
        e.drawArbitrator();
    }

    function test_draw_roughlyUniform() public {
        address[4] memory pool = [vm.addr(0xA1), vm.addr(0xA2), vm.addr(0xA3), vm.addr(0xA4)];
        for (uint256 i = 0; i < 4; i++) _stake(pool[i], STAKE_FOR_AMOUNT, "p");
        uint256[4] memory hits;
        for (uint256 k = 0; k < 80; k++) {
            GhostEscrowV2CImpl e = _deal(1000 + k);
            _openDisputeOnly(e);
            vm.roll(e.drawBlock() + 1 + (k % 7));
            e.drawArbitrator();
            for (uint256 i = 0; i < 4; i++) if (e.arbitrator() == pool[i]) hits[i]++;
        }
        for (uint256 i = 0; i < 4; i++) assertGt(hits[i], 8, "each eligible arb drawn a fair share (>10 % of 80)");
    }

    function test_draw_rearmsTwiceThenExhausts_andAnyCallerDrawsTheSameArb() public {
        _stakeArbEligible();
        _stake(p1, STAKE_FOR_AMOUNT, "p1");
        GhostEscrowV2CImpl e = _deal(13);
        _openDisputeOnly(e);
        // Determinism: whoever calls inside the horizon gets the same arbitrator (no grinding by caller choice).
        vm.roll(e.drawBlock() + 2);
        uint256 snap = vm.snapshotState();
        vm.prank(seller);
        e.drawArbitrator();
        address bySeller = e.arbitrator();
        vm.revertToState(snap);
        vm.prank(stranger);
        e.drawArbitrator();
        assertEq(e.arbitrator(), bySeller, "same block, same seed, same arbitrator");
        vm.revertToState(snap);

        // Withheld past the horizon three times: two re-arms, then Exhausted.
        for (uint256 i = 0; i < 2; i++) {
            vm.roll(e.drawBlock() + 300);
            e.drawArbitrator();
            assertEq(_phase(e), uint256(GhostEscrowV2CImpl.ArbPhase.Drawing));
            assertEq(e.rearms(), i + 1);
        }
        vm.roll(e.drawBlock() + 300);
        e.drawArbitrator();
        assertEq(_phase(e), uint256(GhostEscrowV2CImpl.ArbPhase.Exhausted));
        vm.expectRevert(bytes("not drawing"));
        e.drawArbitrator();
        assertEq(e.tipsTotal(), 0, "re-arms and exhaustion never tip");
    }

    // ─── E1/R8: stalemate split ────────────────────────────────────────────

    function test_stalemate_noEligibleArb_after14d_fiftyFifty_potToOpener() public {
        GhostEscrowV2CImpl e = _deal(20); // nobody staked → no draw possible
        _openDisputeOnly(e);
        vm.prank(seller);
        vm.expectRevert(bytes("too early"));
        e.stalemateSplit();
        vm.warp(block.timestamp + 14 days);
        vm.prank(stranger);
        vm.expectRevert(bytes("not party"));
        e.stalemateSplit();
        uint256 b0 = token.balanceOf(buyer);
        uint256 s0 = token.balanceOf(seller);
        vm.prank(seller);
        e.stalemateSplit();
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.Completed));
        assertEq(token.balanceOf(seller) - s0, AMOUNT / 2, "fee-free half");
        assertEq(token.balanceOf(buyer) - b0, AMOUNT / 2 + ARB_FEE, "half + the fee pot back to the opener");
        assertEq(token.balanceOf(feeRecipient), 0, "no platform fee on a stalemate");
    }

    function test_stalemate_refusedWhileSeated() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(21);
        _openDispute(e); // seated
        vm.warp(block.timestamp + 14 days);
        vm.prank(buyer);
        vm.expectRevert(bytes("decidable"));
        e.stalemateSplit();
    }

    function test_stalemate_highValue_noPanel_afterDismiss() public {
        GhostEscrowV2CImpl e = _hvDeal(22);
        _openDisputeOnly(e);
        assertEq(_phase(e), uint256(GhostEscrowV2CImpl.ArbPhase.Panel));
        vm.warp(block.timestamp + 14 days);
        vm.prank(buyer);
        vm.expectRevert(bytes("decidable")); // the first-panel case is still in flight
        e.stalemateSplit();
        court.dismiss(address(e)); // pool too small: never drawn, SLA passed
        vm.prank(buyer);
        vm.expectRevert(bytes("use stalemateSplit"));
        e.requestFirstPanel();
        vm.prank(buyer);
        e.stalemateSplit();
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.Completed));
    }

    // ─── D4: keeper tips ───────────────────────────────────────────────────

    function test_tips_cappedByPlatformFee_netOfFee_claimAfterSettle() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(30);
        _openDisputeOnly(e);
        vm.roll(e.drawBlock() + 1);
        vm.prank(p1);
        e.drawArbitrator(); // tip 1
        vm.prank(arb);
        e.rule(0, AMOUNT, keccak256("r"));
        vm.warp(block.timestamp + e.APPEAL_WINDOW() + 1);
        vm.prank(p2);
        e.finalize(); // tip 2
        uint256 tip = (AMOUNT * 1) / 10_000 > 1e5 ? (AMOUNT * 1) / 10_000 : 1e5; // 0.01 %, min $0.10
        assertEq(e.tipOwed(p1), tip);
        assertEq(e.tipOwed(p2), tip);
        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), fee - 2 * tip, "fee recipient gets the fee net of tips");
        vm.prank(p1);
        e.claimTip();
        assertEq(token.balanceOf(p1), tip);
        vm.prank(p1);
        vm.expectRevert(bytes("no tip"));
        e.claimTip();
    }

    function test_tips_claimRefusedBeforeSettle_andCapNeverExceedsFee() public {
        _stakeArbEligible();
        bytes memory tiny =
            abi.encode(address(token), buyer, seller, address(0), uint256(10e6), uint256(0), DEPOSIT_TIMEOUT, AUTO_RELEASE);
        GhostEscrowV2CImpl e = GhostEscrowV2CImpl(factory.createDeal(address(stdImpl), tiny, bytes32(uint256(31))));
        _fund(buyer, 10e6);
        vm.prank(buyer);
        token.approve(address(e), 10e6);
        vm.prank(buyer);
        e.deposit(10e6);
        _openDisputeOnly(e);
        vm.roll(e.drawBlock() + 1);
        vm.prank(p1);
        e.drawArbitrator();
        uint256 fee = (10e6 * FEE_BPS) / 10_000; // $0.15 platform fee on a $10 deal
        assertEq(e.tipsTotal(), 1e5, "min tip $0.10");
        vm.prank(p1);
        vm.expectRevert(bytes("not settled"));
        e.claimTip();
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(p2);
        e.slashForTimeout(); // second tip, capped to what's left of the fee
        assertEq(e.tipsTotal(), fee, "tips never exceed the platform fee");
    }

    function test_tips_courtDismissCreditsCaller() public {
        GhostEscrowV2CImpl e = _hvDeal(32);
        _openDisputeOnly(e);
        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.prank(p3);
        court.dismiss(address(e));
        assertGt(e.tipOwed(p3), 0, "court-made un-sticking call earns the tip");
    }

    function test_tips_appealDismissCreditsCaller_beforeSettlement() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(33);
        _stakePanel(); // after the deal: only `arb` is drawable as arbitrator; the panel can still seat
        _toDrawnAppeal(e);
        vm.warp(block.timestamp + SLA_DURATION + 1); // panel never reached a majority
        uint256 feeBefore = token.balanceOf(feeRecipient);
        vm.prank(p3);
        court.dismiss(address(e));
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.Completed));
        uint256 tip = e.tipOwed(p3);
        assertGt(tip, 0, "keeper paid for closing a stuck appeal");
        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient) - feeBefore, fee - e.tipsTotal(), "tip funded out of the fee");
        vm.prank(p3);
        e.claimTip();
        assertEq(token.balanceOf(p3), tip);
    }

    function test_F3_blockedKeeperClaimWaits_settlementDoesNot() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(34);
        _openDisputeOnly(e);
        vm.roll(e.drawBlock() + 1);
        vm.prank(p1);
        e.drawArbitrator();
        MockERC20(address(token)).setBlocked(p1, true);
        (uint256 dl, bytes memory b, bytes memory s) = _releaseSigs(e);
        e.release(dl, b, s); // settles despite a blocked keeper
        vm.prank(p1);
        vm.expectRevert(bytes("blocked"));
        e.claimTip(); // the keeper's own claim waits until they can receive
        MockERC20(address(token)).setBlocked(p1, false);
        vm.prank(p1);
        e.claimTip();
    }

    // ─── F1: arbitrator stays locked through the appeal window ─────────────

    function test_F1_noExitDuringAppealWindow_eligibilityCountsFreeStakeOnly() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(40);
        _openDispute(e);
        vm.prank(arb);
        e.rule(0, AMOUNT, keccak256("r"));
        assertEq(registry.openCases(arb), 1, "still open in the appeal window");
        vm.prank(arb);
        vm.expectRevert(bytes("open cases"));
        registry.requestUnbond(1);
        vm.warp(block.timestamp + e.APPEAL_WINDOW() + 1);
        e.finalize();
        assertEq(registry.openCases(arb), 0);
        // A queued withdrawal no longer counts toward eligibility.
        vm.prank(arb);
        registry.requestUnbond(STAKE_FOR_AMOUNT); // full exit queued
        assertFalse(registry.isEligible(arb, AMOUNT), "queued stake isn't eligible stake");
    }

    // ─── F2 / F3: nothing can be bricked by a blocked recipient ────────────

    function test_F2_expireNeverPushes_blockedBuyerCanStillExpireAndLaterClaim() public {
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(50)));
        _fund(buyer, 100e6);
        vm.prank(buyer);
        token.approve(address(e), 100e6);
        vm.prank(buyer);
        e.deposit(100e6);
        MockERC20(address(token)).setBlocked(buyer, true);
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        e.expire(); // would have reverted on v4 (push to a blocked buyer)
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.Expired));
        MockERC20(address(token)).setBlocked(buyer, false);
        vm.prank(buyer);
        e.claimExpired();
        assertEq(token.balanceOf(buyer), 100e6);
    }

    function test_F3_blockedSellerAndFeeRecipient_settleAnyway_pullLater() public {
        GhostEscrowV2CImpl e = _deal(51);
        MockERC20(address(token)).setBlocked(seller, true);
        MockERC20(address(token)).setBlocked(feeRecipient, true);
        (uint256 dl, bytes memory b, bytes memory s) = _releaseSigs(e);
        e.release(dl, b, s);
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.Completed));
        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(e.owed(seller), AMOUNT - fee);
        assertEq(e.owed(feeRecipient), fee);
        MockERC20(address(token)).setBlocked(seller, false);
        vm.prank(seller);
        e.withdrawOwed();
        assertEq(token.balanceOf(seller), AMOUNT - fee);
    }

    function test_F3_courtAndRegistryPayoutsPullOnBlock() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _deal(52);
        _openDispute(e);
        MockERC20(address(token)).setBlocked(buyer, true); // the opener, compensated by the SLA slash
        vm.warp(block.timestamp + SLA_DURATION + 1);
        e.slashForTimeout();
        uint256 comp = (STAKE_FOR_AMOUNT * SLA_SLASH_BPS) / 10_000;
        assertEq(registry.owed(buyer), comp, "registry parks the compensation");
        MockERC20(address(token)).setBlocked(buyer, false);
        vm.prank(buyer);
        registry.withdrawOwed();
        assertEq(token.balanceOf(buyer), comp);
    }

    // ─── F4: the top-staked arbitrator can be appealed ─────────────────────

    function test_F4_topStakedArbIsAppealable() public {
        _stake(arb, STAKE_FOR_AMOUNT * 10, "whale"); // highest stake in the pool
        GhostEscrowV2CImpl e = _deal(60);
        _stakePanel(); // lower stakes than `arb`, staked after the deal (not drawable as arbitrator)
        uint256 bond = _toDrawnAppeal(e);
        assertGt(bond, 0);
        (, uint8 len) = court.panelOf(address(e));
        assertEq(uint256(len), 3, "a panel seats even though every candidate has less stake than the arbitrator");
    }

    // ─── D5: withdrawal tranches ───────────────────────────────────────────

    function test_unbond_tranches_ownClocks_floor_andCap() public {
        _stake(arb, 1_000e6, "a");
        // vm.getBlockTimestamp(), not block.timestamp: under via_ir the compiler may evaluate block.timestamp
        // lazily (after a later vm.warp) within one test function.
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(arb);
        registry.requestUnbond(200e6);
        vm.warp(t0 + 5 days);
        vm.prank(arb);
        registry.requestUnbond(300e6);
        (uint256[] memory amts,) = registry.pendingTranches(arb);
        assertEq(amts.length, 2);
        assertEq(registry.freeStakeOf(arb), 500e6);
        // First tranche matures first; the second keeps its own clock.
        vm.warp(t0 + UNBONDING + 1);
        vm.prank(arb);
        registry.withdraw();
        assertEq(token.balanceOf(arb), 200e6);
        (amts,) = registry.pendingTranches(arb);
        assertEq(amts.length, 1);
        assertEq(amts[0], 300e6);
        vm.prank(arb);
        vm.expectRevert(bytes("nothing matured"));
        registry.withdraw();
        vm.warp(t0 + 5 days + UNBONDING + 1);
        vm.prank(arb);
        registry.withdraw();
        assertEq(token.balanceOf(arb), 500e6);
        assertEq(registry.stakeOf(arb), 500e6);
    }

    function test_unbond_trancheLimit() public {
        _stake(arb, 1_000e6, "a");
        vm.startPrank(arb);
        for (uint256 i = 0; i < registry.MAX_TRANCHES(); i++) registry.requestUnbond(10e6);
        vm.expectRevert(bytes("too many tranches"));
        registry.requestUnbond(10e6);
        vm.stopPrank();
    }
}
